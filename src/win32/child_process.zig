const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");
const util = @import("util.zig");
const err_mod = @import("error.zig");

const Error = err_mod.Error;
const GridPos = types.GridPos;
const TabId = types.TabId;
const ReadMsg = types.ReadMsg;

pub const ChildProcess = struct {
    pty: ?Pty,
    read: win32.HANDLE,
    thread: std.Thread,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,

    pub const Pty = struct {
        write: std.fs.File,
        hpcon: win32.HPCON,
        pub fn deinit(self: *Pty) void {
            win32.ClosePseudoConsole(self.hpcon);
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
        const hr = win32.ResizePseudoConsole(
            pty.hpcon,
            .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
        );
        if (hr == ERROR_NO_DATA_HRESULT or hr == ERROR_BROKEN_PIPE_HRESULT) return error.Closed;
        if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
    }

    fn buildChildEnvBlock(allocator: std.mem.Allocator) ![]u16 {
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

        const term_override = try util.utf16ZAlloc(allocator, "TERM=xterm-256color");
        try override_bufs.append(allocator, term_override);

        var modified: std.ArrayListUnmanaged([]const u16) = .empty;
        defer modified.deinit(allocator);

        outer: for (entries.items) |entry| {
            for (override_bufs.items) |override| {
                if (entryNameMatches(entry, override)) {
                    try modified.append(allocator, override);
                    continue :outer;
                }
            }
            try modified.append(allocator, entry);
        }
        // Append overrides that weren't present in the original block.
        for (override_bufs.items) |override| {
            var found = false;
            for (modified.items) |entry| {
                if (entry.ptr == override.ptr) {
                    found = true;
                    break;
                }
            }
            if (!found) try modified.append(allocator, override);
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

    fn entryNameMatches(entry: []const u16, override: []const u16) bool {
        const eq: u16 = '=';
        const ei = std.mem.indexOfScalar(u16, entry, eq) orelse return false;
        const oi = std.mem.indexOfScalar(u16, override, eq) orelse return false;
        if (ei != oi) return false;
        return std.mem.eql(u16, entry[0..ei], override[0..oi]);
    }

    pub fn startConPtyWin32(
        out_err: *Error,
        allocator: std.mem.Allocator,
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        working_directory: ?[*:0]const u16,
        hwnd: win32.HWND,
        hwnd_msg: u32,
        hwnd_msg_result: win32.LRESULT,
        cell_count: GridPos,
        tab_id: TabId,
        stop_flag: *std.atomic.Value(bool),
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
            .{ hwnd, hwnd_msg, hwnd_msg_result, our_read, tab_id, stop_flag },
        ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);
        errdefer thread.join();

        var hpcon: win32.HPCON = undefined;
        {
            const hr = win32.CreatePseudoConsole(
                .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
                pty_read,
                pty_write,
                0,
                @ptrCast(&hpcon),
            );
            win32.closeHandle(pty_read);
            win32.closeHandle(pty_write);
            pty_handles_closed = true;
            if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
        }
        errdefer win32.ClosePseudoConsole(hpcon);

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
        const child_env = buildChildEnvBlock(allocator) catch |e| switch (e) {
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
            .pty = .{ .write = .{ .handle = our_write }, .hpcon = hpcon },
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
        hwnd_msg_result: win32.LRESULT,
        read: win32.HANDLE,
        tab_id: TabId,
        stop_flag: *std.atomic.Value(bool),
    ) void {
        while (true) {
            if (stop_flag.load(.acquire)) return;
            var buffer: [4096]u8 = undefined;
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
            var msg: ReadMsg = .{
                .tab_id = tab_id,
                .data = &buffer,
                .len = read_len,
            };
            std.debug.assert(hwnd_msg_result == win32.SendMessageW(
                hwnd,
                hwnd_msg,
                @intFromPtr(&msg),
                0,
            ));
            if (stop_flag.load(.acquire)) return;
        }
    }
};
