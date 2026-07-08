const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");
const util = @import("util.zig");
const err_mod = @import("error.zig");
const pty_ring_mod = @import("pty_ring.zig");
const Config = @import("../Config.zig");

const Error = err_mod.Error;
const GridPos = types.GridPos;
const TabId = types.TabId;
const PtyRing = pty_ring_mod.PtyRing;

const CONPTY_DLL_ENV = "MOSTTY_CONPTY_DLL";

pub const ChildProcess = struct {
    pty: ?Pty,
    read: win32.HANDLE,
    thread: std.Thread,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,

    pub const Pty = struct {
        write: std.fs.File,
        hpcon: win32.HPCON,
        conpty: ConptyApi,
        pub fn deinit(self: *Pty) void {
            self.conpty.close(self.hpcon);
            win32.closeHandle(self.write.handle);
        }
        pub fn writeFlushAll(self: *const Pty, slice: []const u8) !void {
            try self.write.writeAll(slice);
        }
    };

    pub fn closePty(self: *ChildProcess) void {
        if (self.pty) |*pty| {
            pty.deinit();
            self.pty = null;
        }
    }

    // Conhost dropped the pipe on its side. ERROR_NO_DATA shows up after a
    // degenerate (1x1) resize while minimized; ERROR_BROKEN_PIPE shows up
    // when the child process exited and the reader thread hasn't yet driven
    // the WM_APP_CLOSE_TAB lifecycle. Both mean the PTY is dead.
    const ERROR_NO_DATA_HRESULT: win32.HRESULT = @bitCast(@as(u32, 0x800700E8));
    const ERROR_BROKEN_PIPE_HRESULT: win32.HRESULT = @bitCast(@as(u32, 0x8007006D));

    pub fn resize(self: *ChildProcess, out_err: *Error, cell_count: GridPos) error{ Error, Closed }!void {
        const pty = self.pty orelse return;
        const hr = pty.conpty.resize(
            pty.hpcon,
            .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
        );
        if (hr == ERROR_NO_DATA_HRESULT or hr == ERROR_BROKEN_PIPE_HRESULT) return error.Closed;
        if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
    }

    fn buildChildEnvBlock(
        allocator: std.mem.Allocator,
        extra: []const Config.EnvEntry,
    ) ![]u16 {
        const block = win32.GetEnvironmentStringsW() orelse return error.GetEnvFailed;
        defer _ = win32.FreeEnvironmentStringsW(block);

        const block_ptr: [*]const u16 = @ptrCast(block);
        var entries: std.ArrayListUnmanaged([]const u16) = .empty;
        defer entries.deinit(allocator);

        var i: usize = 0;
        while (block_ptr[i] != 0) {
            const start = i;
            while (block_ptr[i] != 0) i += 1;
            try entries.append(allocator, block_ptr[start..i]);
            i += 1;
        }

        var override_bufs: std.ArrayListUnmanaged([]u16) = .empty;
        defer {
            for (override_bufs.items) |b| allocator.free(b);
            override_bufs.deinit(allocator);
        }

        // User-configured env entries first; later same-named user entries
        // replace earlier ones. The hardcoded TERM default is only added if
        // the user hasn't set one.
        for (extra) |e| {
            const line = try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.name, e.value });
            defer allocator.free(line);
            const u16_line = try util.utf16ZAlloc(allocator, line);
            // u16_line is unowned until the append below succeeds; free on early
            // exit so an OOM in append doesn't leak it (the outer defer only
            // frees what's already in override_bufs).
            errdefer allocator.free(u16_line);
            // Drop any earlier override with the same name so the last one
            // wins. orderedRemove (vs swapRemove) preserves declaration order
            // for deterministic env-block layout.
            var k: usize = 0;
            while (k < override_bufs.items.len) {
                if (entryNameMatches(override_bufs.items[k], u16_line)) {
                    const removed = override_bufs.orderedRemove(k);
                    allocator.free(removed);
                } else k += 1;
            }
            try override_bufs.append(allocator, u16_line);
        }

        if (!hasOverrideForAsciiName(override_bufs.items, "TERM")) {
            const term_override = try util.utf16ZAlloc(allocator, "TERM=xterm-256color");
            errdefer allocator.free(term_override);
            try override_bufs.append(allocator, term_override);
        }

        var modified: std.ArrayListUnmanaged([]const u16) = .empty;
        defer modified.deinit(allocator);

        // Track which overrides have already been emitted, so two parent-env
        // entries colliding to the same override (theoretical with case-insensitive
        // matching) don't duplicate the override in the output. Replaces the
        // older pass-2 ptr-equality scan with O(n) bookkeeping.
        var emitted: std.ArrayListUnmanaged(bool) = .empty;
        defer emitted.deinit(allocator);
        try emitted.resize(allocator, override_bufs.items.len);
        @memset(emitted.items, false);

        outer: for (entries.items) |entry| {
            for (override_bufs.items, 0..) |override, oi| {
                if (entryNameMatches(entry, override)) {
                    if (!emitted.items[oi]) {
                        try modified.append(allocator, override);
                        emitted.items[oi] = true;
                    }
                    continue :outer;
                }
            }
            try modified.append(allocator, entry);
        }
        // Append overrides that weren't present in the original block.
        for (override_bufs.items, 0..) |override, oi| {
            if (!emitted.items[oi]) try modified.append(allocator, override);
        }

        var total: usize = 1; // final double null
        for (modified.items) |e| total += e.len + 1;
        const buf = try allocator.alloc(u16, total);
        var off: usize = 0;
        for (modified.items) |e| {
            @memcpy(buf[off..][0..e.len], e);
            buf[off + e.len] = 0;
            off += e.len + 1;
        }
        buf[off] = 0;
        return buf;
    }

    // ASCII case-insensitive fold for u16 (matches Windows env semantics, which
    // are case-insensitive in the ASCII range; non-ASCII codepoints pass through
    // unchanged — fine because env names are conventionally ASCII).
    fn foldU16(c: u16) u16 {
        return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
    }

    fn entryNameMatches(entry: []const u16, override: []const u16) bool {
        const eq: u16 = '=';
        const ei = std.mem.indexOfScalar(u16, entry, eq) orelse return false;
        const oi = std.mem.indexOfScalar(u16, override, eq) orelse return false;
        if (ei != oi) return false;
        for (entry[0..ei], override[0..oi]) |a, b| {
            if (foldU16(a) != foldU16(b)) return false;
        }
        return true;
    }

    // True if any of `items` (each `NAME=VALUE` in UTF-16) has NAME equal to
    // the given ASCII string. Compared ASCII case-insensitively (shared
    // foldU16) to match Windows env conventions.
    fn hasOverrideForAsciiName(items: []const []u16, name: []const u8) bool {
        for (items) |item| {
            const eq: u16 = '=';
            const ei = std.mem.indexOfScalar(u16, item, eq) orelse continue;
            if (ei != name.len) continue;
            var ok = true;
            for (item[0..ei], name) |a, b| {
                if (foldU16(a) != foldU16(@as(u16, b))) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    pub fn startConPtyWin32(
        out_err: *Error,
        allocator: std.mem.Allocator,
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        working_directory: ?[*:0]const u16,
        hwnd: win32.HWND,
        hwnd_msg: u32,
        cell_count: GridPos,
        tab_id: TabId,
        stop_flag: *std.atomic.Value(bool),
        ring: *PtyRing,
        extra_env: []const Config.EnvEntry,
    ) error{Error}!ChildProcess {
        var sec_attr: win32.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .bInheritHandle = 1,
            .lpSecurityDescriptor = null,
        };

        var pty_read: win32.HANDLE = undefined;
        var our_write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&pty_read), @ptrCast(&our_write), &sec_attr, 0)) return out_err.setWin32(
            "CreateInputPipe",
            win32.GetLastError(),
        );
        var pty_handles_closed = false;
        defer if (!pty_handles_closed) win32.closeHandle(pty_read);
        errdefer win32.closeHandle(our_write);

        var our_read: win32.HANDLE = undefined;
        var pty_write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&our_read), @ptrCast(&pty_write), &sec_attr, 0)) return out_err.setWin32(
            "CreateOutputPipe",
            win32.GetLastError(),
        );
        defer if (!pty_handles_closed) win32.closeHandle(pty_write);
        // Registered before the reader-thread errdefer so it runs AFTER
        // thread.join — safe to close once the reader has exited.
        errdefer win32.closeHandle(our_read);

        try setInherit(out_err, our_write, false);
        try setInherit(out_err, our_read, false);

        const thread = std.Thread.spawn(
            .{},
            readConsoleThread,
            .{ hwnd, hwnd_msg, our_read, tab_id, stop_flag, ring },
        ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);
        // Plain `thread.join()` would deadlock here. Three park points to
        // cover before joining:
        //   - WaitForSingleObject on ring.wake_event (full ring) → SetEvent
        //   - ReadFile on our_read (in-flight)                   → CancelIoEx
        //   - between stop_flag check and ReadFile                → close
        //     the PTY's write end so ReadFile returns BROKEN_PIPE when
        //     reader finally enters it (CancelIoEx is a no-op if no I/O
        //     is pending). After CreatePseudoConsole succeeds the PTY owns
        //     pty_write/pty_read, so the close happens via the later
        //     ClosePseudoConsole errdefer (which fires BEFORE this block
        //     in LIFO order). This block only owns the close when the
        //     error fires before CreatePseudoConsole.
        errdefer {
            stop_flag.store(true, .release);
            _ = win32.SetEvent(ring.wake_event);
            _ = win32.CancelIoEx(our_read, null);
            if (!pty_handles_closed) {
                win32.closeHandle(pty_write);
                win32.closeHandle(pty_read);
                pty_handles_closed = true;
            }
            thread.join();
        }

        var hpcon: win32.HPCON = undefined;
        var conpty = try ConptyApi.create(
            out_err,
            allocator,
            .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
            pty_read,
            pty_write,
            &hpcon,
        );
        win32.closeHandle(pty_read);
        win32.closeHandle(pty_write);
        pty_handles_closed = true;
        errdefer conpty.close(hpcon);

        var attr_list_size: usize = undefined;
        std.debug.assert(0 == win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size));
        switch (win32.GetLastError()) {
            win32.ERROR_INSUFFICIENT_BUFFER => {},
            else => return out_err.setWin32("GetProcAttrsSize", win32.GetLastError()),
        }
        const attr_list = allocator.alloc(
            u8,
            attr_list_size,
        ) catch return out_err.setZig("AllocProcAttrs", error.OutOfMemory);
        defer allocator.free(attr_list);

        var second_attr_list_size: usize = attr_list_size;
        if (0 == win32.InitializeProcThreadAttributeList(
            attr_list.ptr,
            1,
            0,
            &second_attr_list_size,
        )) return out_err.setWin32("InitProcAttrs", win32.GetLastError());
        defer win32.DeleteProcThreadAttributeList(attr_list.ptr);
        std.debug.assert(second_attr_list_size == attr_list_size);
        if (0 == win32.UpdateProcThreadAttribute(
            attr_list.ptr,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpcon,
            @sizeOf(@TypeOf(hpcon)),
            null,
            null,
        )) return out_err.setWin32("UpdateProcThreadAttribute", win32.GetLastError());

        var startup_info = win32.STARTUPINFOEXW{
            .StartupInfo = .{
                .cb = @sizeOf(win32.STARTUPINFOEXW),
                .hStdError = null,
                .hStdOutput = null,
                .hStdInput = null,
                .dwFlags = .{ .USESTDHANDLES = 1 },
                .lpReserved = null,
                .lpDesktop = null,
                .lpTitle = null,
                .dwX = 0,
                .dwY = 0,
                .dwXSize = 0,
                .dwYSize = 0,
                .dwXCountChars = 0,
                .dwYCountChars = 0,
                .dwFillAttribute = 0,
                .wShowWindow = 0,
                .cbReserved2 = 0,
                .lpReserved2 = null,
            },
            .lpAttributeList = attr_list.ptr,
        };
        const child_env = buildChildEnvBlock(allocator, extra_env) catch |e| switch (e) {
            error.OutOfMemory => util.oom(error.OutOfMemory),
            error.GetEnvFailed => return out_err.setWin32("GetEnvironmentStringsW", win32.GetLastError()),
        };
        defer allocator.free(child_env);

        var process_info: win32.PROCESS_INFORMATION = undefined;
        if (0 == win32.CreateProcessW(
            application_name,
            command_line,
            null,
            null,
            0,
            .{
                .CREATE_SUSPENDED = 1,
                .EXTENDED_STARTUPINFO_PRESENT = 1,
                .CREATE_UNICODE_ENVIRONMENT = 1,
            },
            @ptrCast(child_env.ptr),
            working_directory,
            &startup_info.StartupInfo,
            &process_info,
        )) return out_err.setWin32("CreateProcess", win32.GetLastError());
        defer win32.closeHandle(process_info.hThread.?);
        errdefer win32.closeHandle(process_info.hProcess.?);

        const job = win32.CreateJobObjectW(null, null) orelse return out_err.setWin32(
            "CreateJobObject",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(job);

        {
            var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (0 == win32.SetInformationJobObject(
                job,
                win32.JobObjectExtendedLimitInformation,
                &info,
                @sizeOf(@TypeOf(info)),
            )) return out_err.setWin32(
                "SetInformationJobObject",
                win32.GetLastError(),
            );
        }

        if (0 == win32.AssignProcessToJobObject(
            job,
            process_info.hProcess,
        )) return out_err.setWin32(
            "AssignProcessToJobObject",
            win32.GetLastError(),
        );

        _ = win32.ResumeThread(process_info.hThread.?);

        return .{
            .pty = .{ .write = .{ .handle = our_write }, .hpcon = hpcon, .conpty = conpty },
            .read = our_read,
            .thread = thread,
            .job = job,
            .process_handle = process_info.hProcess.?,
        };
    }

    fn setInherit(out_err: *Error, handle: win32.HANDLE, inherit: bool) error{Error}!void {
        const flag: win32.HANDLE_FLAGS = if (inherit) win32.HANDLE_FLAG_INHERIT else .{};
        if (0 == win32.SetHandleInformation(handle, 1, flag)) {
            return out_err.setWin32("SetHandleInformation", win32.GetLastError());
        }
    }

    fn readConsoleThread(
        hwnd: win32.HWND,
        hwnd_msg: u32,
        read: win32.HANDLE,
        tab_id: TabId,
        stop_flag: *std.atomic.Value(bool),
        ring: *PtyRing,
    ) void {
        while (true) {
            if (stop_flag.load(.acquire)) return;
            var buffer: [65536]u8 = undefined;
            var read_len: u32 = undefined;
            if (0 == win32.ReadFile(
                read,
                &buffer,
                buffer.len,
                &read_len,
                null,
            )) switch (win32.GetLastError()) {
                .ERROR_BROKEN_PIPE => {
                    std.log.info("console output closed (tab {})", .{tab_id});
                    return;
                },
                .ERROR_OPERATION_ABORTED => {
                    std.log.info("console read cancelled (tab {})", .{tab_id});
                    return;
                },
                .ERROR_HANDLE_EOF => return,
                .ERROR_NO_DATA => return,
                else => |e| std.debug.panic("readConsoleThread: handle error {f}", .{e}),
            };
            if (read_len == 0) return;
            // ring.write returns false only when stop_flag tripped during a
            // full-ring wait (i.e. destroyTab is tearing us down). Exit then.
            if (!ring.write(buffer[0..read_len])) return;
            // Edge-triggered wake. ring.write performed head.store(.release)
            // before returning; posted.swap(.acq_rel) is sequenced after that
            // store in program order so any UI thread that observes
            // posted=true will, on the matching head.load(.acquire), see the
            // bytes we just published.
            if (ring.posted.swap(true, .acq_rel) == false) {
                // Retry on PostMessage failure. The two failure modes are
                // (a) transient — the per-thread message queue saturated at
                // its 10 000-message limit, (b) terminal — the window is
                // being destroyed. (a) clears within milliseconds once the
                // UI thread drains; (b) is paired with stop_flag being set
                // by destroyTab. Resetting `posted` and continuing the
                // outer loop (Codex's original suggestion) would strand the
                // already-published bytes in the ring with no wake-up in
                // flight, and the reader would later deadlock on a full
                // ring. Retry-until-stop is the only safe option.
                var attempt: u32 = 0;
                while (0 == win32.PostMessageW(hwnd, hwnd_msg, @intCast(tab_id), 0)) {
                    if (stop_flag.load(.acquire)) {
                        // Tab is closing; the ring's tail bytes are
                        // intentionally dropped (matches the documented
                        // close-time tail-output semantics).
                        ring.posted.store(false, .release);
                        return;
                    }
                    attempt += 1;
                    if (attempt == 1 or attempt % 100 == 0) {
                        std.log.warn(
                            "PostMessageW(CHILD_PROCESS_DATA) failed (tab {}, attempt {}): {f}",
                            .{ tab_id, attempt, win32.GetLastError() },
                        );
                    }
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                }
            }
            if (stop_flag.load(.acquire)) return;
        }
    }
};

const ConptyApi = union(enum) {
    system,
    dynamic: DynamicConptyApi,

    const CreatePseudoConsoleFn = *const fn (
        size: win32.COORD,
        hInput: ?win32.HANDLE,
        hOutput: ?win32.HANDLE,
        dwFlags: u32,
        phPC: ?*?win32.HPCON,
    ) callconv(.winapi) win32.HRESULT;

    const ResizePseudoConsoleFn = *const fn (
        hPC: ?win32.HPCON,
        size: win32.COORD,
    ) callconv(.winapi) win32.HRESULT;

    const ClosePseudoConsoleFn = *const fn (
        hPC: ?win32.HPCON,
    ) callconv(.winapi) void;

    const DynamicConptyApi = struct {
        // Keep the module loaded after close; ConPTY cleanup can outlive HPCON close.
        module: win32.HINSTANCE,
        resize: ResizePseudoConsoleFn,
        close_fn: ClosePseudoConsoleFn,
    };

    fn create(
        out_err: *Error,
        allocator: std.mem.Allocator,
        size: win32.COORD,
        h_input: win32.HANDLE,
        h_output: win32.HANDLE,
        hpcon: *win32.HPCON,
    ) error{Error}!ConptyApi {
        const maybe_dll_path = try conptyDllPathOwned(out_err, allocator);
        const dll_path = maybe_dll_path orelse return createSystem(out_err, size, h_input, h_output, hpcon);
        defer allocator.free(dll_path);

        const dll_path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, dll_path) catch |e| switch (e) {
            error.OutOfMemory => return out_err.setZig("Utf16ConptyDllPath", error.OutOfMemory),
            error.InvalidUtf8 => return out_err.setZig("Utf16ConptyDllPath", error.InvalidUtf8),
        };
        defer allocator.free(dll_path_w);

        const module = win32.LoadLibraryW(dll_path_w.ptr) orelse {
            std.log.warn("{s}={s}: LoadLibraryW failed: {f}", .{ CONPTY_DLL_ENV, dll_path, win32.GetLastError() });
            return out_err.setWin32("LoadConptyDll", win32.GetLastError());
        };
        errdefer _ = win32.FreeLibrary(module);

        const create_fn = getProc(CreatePseudoConsoleFn, module, "ConptyCreatePseudoConsole") orelse
            return out_err.setWin32("GetConptyCreatePseudoConsole", win32.GetLastError());
        const resize_fn = getProc(ResizePseudoConsoleFn, module, "ConptyResizePseudoConsole") orelse
            return out_err.setWin32("GetConptyResizePseudoConsole", win32.GetLastError());
        const close_fn = getProc(ClosePseudoConsoleFn, module, "ConptyClosePseudoConsole") orelse
            return out_err.setWin32("GetConptyClosePseudoConsole", win32.GetLastError());

        const hr = create_fn(size, h_input, h_output, 0, @ptrCast(hpcon));
        if (hr < 0) return out_err.setHresult("ConptyCreatePseudoConsole", hr);

        std.log.info("using experimental ConPTY DLL from {s}", .{dll_path});
        return .{ .dynamic = .{
            .module = module,
            .resize = resize_fn,
            .close_fn = close_fn,
        } };
    }

    fn createSystem(
        out_err: *Error,
        size: win32.COORD,
        h_input: win32.HANDLE,
        h_output: win32.HANDLE,
        hpcon: *win32.HPCON,
    ) error{Error}!ConptyApi {
        const hr = win32.CreatePseudoConsole(size, h_input, h_output, 0, @ptrCast(hpcon));
        if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
        return .system;
    }

    fn conptyDllPathOwned(out_err: *Error, allocator: std.mem.Allocator) error{Error}!?[]u8 {
        const env_path = std.process.getEnvVarOwned(allocator, CONPTY_DLL_ENV) catch |e| switch (e) {
            error.EnvironmentVariableNotFound => null,
            error.OutOfMemory => return out_err.setZig("ReadConptyDllEnv", error.OutOfMemory),
            else => |err| return out_err.setZig("ReadConptyDllEnv", err),
        };
        if (env_path) |path| {
            if (path.len > 0) return path;
            allocator.free(path);
        }

        const exe_path = std.fs.selfExePathAlloc(allocator) catch |e| switch (e) {
            error.OutOfMemory => return out_err.setZig("FindBundledConptyDll", error.OutOfMemory),
            else => |err| {
                std.log.warn("cannot locate Mostty executable path for bundled ConPTY: {s}", .{@errorName(err)});
                return null;
            },
        };
        defer allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
        const bundled_path = std.fs.path.join(allocator, &.{ exe_dir, "conpty", "conpty.dll" }) catch |e|
            return out_err.setZig("FindBundledConptyDll", e);
        errdefer allocator.free(bundled_path);

        std.fs.accessAbsolute(bundled_path, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                allocator.free(bundled_path);
                return null;
            },
            else => |err| return out_err.setZig("FindBundledConptyDll", err),
        };
        return bundled_path;
    }

    fn resize(self: ConptyApi, hpcon: win32.HPCON, size: win32.COORD) win32.HRESULT {
        return switch (self) {
            .system => win32.ResizePseudoConsole(hpcon, size),
            .dynamic => |api| api.resize(hpcon, size),
        };
    }

    fn close(self: *ConptyApi, hpcon: win32.HPCON) void {
        switch (self.*) {
            .system => win32.ClosePseudoConsole(hpcon),
            .dynamic => |api| {
                api.close_fn(hpcon);
                self.* = .system;
            },
        }
    }

    fn getProc(comptime Fn: type, module: win32.HINSTANCE, name: [:0]const u8) ?Fn {
        const proc = win32.GetProcAddress(module, name.ptr) orelse return null;
        return @ptrCast(proc);
    }
};
