pub const panic = std.debug.FullPanic(panicHandler);

threadlocal var thread_is_panicking = false;

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (!thread_is_panicking) {
        thread_is_panicking = true;
        crashMessageBox(msg, ret_addr orelse @returnAddress());
    }
    std.debug.defaultPanic(msg, ret_addr);
}

fn crashMessageBox(msg: []const u8, ret_addr: usize) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // don't free, we're about to crash
    const arena = arena_instance.allocator();
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const write_result = writeCrash(&allocating.writer, msg, ret_addr);
    const final_msg: [*:0]const u8 = blk: {
        write_result catch {
            const marker = "[TRUNCATED]";
            const buf = allocating.writer.buffer;
            if (buf.len <= marker.len) break :blk "failed to allocate memory for error";
            // Prefer to append after the written content; if there isn't room,
            // overwrite the tail of the buffer instead.
            const max_start = buf.len - marker.len - 1;
            const start = @min(allocating.writer.end, max_start);
            @memcpy(buf[start..][0..marker.len], marker);
            buf[start + marker.len] = 0;
        };
        break :blk @ptrCast(allocating.writer.buffer.ptr);
    };
    _ = win32.MessageBoxA(null, final_msg, "Mite Crashed", .{ .ICONHAND = 1 });
}

fn writeCrash(writer: *std.Io.Writer, msg: []const u8, ret_addr: usize) error{WriteFailed}!void {
    try writer.print("{s}\n\n", .{msg});
    try std.debug.dumpCurrentStackTraceToWriter(ret_addr, writer);
    try writer.writeByte(0);
}

const global = struct {
    var icons: Icons = undefined;
    var renderer: d3d11 = undefined;
    var state: ?State = null;
    var term_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var high_surrogate: ?u16 = null;
    var resizing: bool = false;
    var mouse_in_scrollbar: bool = false;
    var tracking_mouse: bool = false;
    var mouse_capture: MouseCapture = .none;
    var scrollbar_drag_offset: f32 = 0;
    var selection_fade: f32 = 0;
};

const MouseCapture = enum {
    none,
    scrollbar_drag,
    selecting,
};

const window_style = win32.WS_OVERLAPPEDWINDOW;
const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    //.ACCEPTFILES = 1,
    .NOREDIRECTIONBITMAP = 1,
};

const WM_APP_CHILD_PROCESS_DATA = win32.WM_APP + 0;
const WM_APP_CHILD_PROCESS_DATA_RESULT = 0x1bb502b6;
const TIMER_SELECTION_FADE: usize = 1;

const State = struct {
    hwnd: win32.HWND,
    bounds: ?WindowBounds = null,
    child_process: ChildProcess,
    term: *vt.Terminal,
    vt_stream: vt.Stream(VtHandler),
    pub fn reportError(state: *State, comptime fmt: []const u8, args: anytype) void {
        _ = state;
        std.log.err("error: " ++ fmt, args);
    }
};

const VtHandler = struct {
    const vt_mod = @import("vt");

    readonly: vt_mod.ReadonlyHandler,
    hwnd: win32.HWND,

    pub fn vt(
        self: *VtHandler,
        comptime action: vt_mod.StreamAction.Tag,
        value: vt_mod.StreamAction.Value(action),
    ) void {
        switch (action) {
            .window_title => setTitle(self.hwnd, value.title),
            else => {},
        }
        self.readonly.vt(action, value);
    }

    pub fn deinit(self: *VtHandler) void {
        self.readonly.deinit();
    }

    fn setTitle(hwnd: win32.HWND, title: []const u8) void {
        const max_u16 = 500;
        var utf16_buf: [max_u16 + 1]u16 = undefined;
        const result = utf8ToUtf16Short(title, utf16_buf[0..max_u16]);
        if (result.replacement_count > 0) {
            std.log.warn("window title contained {} invalid utf-8 sequence(s)", .{result.replacement_count});
        }
        if (result.bytes_consumed < title.len) {
            std.log.warn("window title truncated: used {}/{} bytes, {} utf-16 units", .{ result.bytes_consumed, title.len, result.len });
        }
        utf16_buf[result.len] = 0;
        if (win32.SetWindowTextW(hwnd, @ptrCast(&utf16_buf)) == 0) {
            std.log.err("SetWindowTextW failed, error={f}", .{win32.GetLastError()});
        }
    }
};

const Utf8ToUtf16Result = struct {
    len: usize,
    replacement_count: usize,
    bytes_consumed: usize,
};

/// Converts UTF-8 to UTF-16, replacing invalid sequences with U+FFFD
/// and truncating if the output buffer is too small.
fn utf8ToUtf16Short(utf8: []const u8, buf: []u16) Utf8ToUtf16Result {
    const replacement = std.mem.nativeToLittle(u16, 0xFFFD);
    var bytes_consumed: usize = 0;
    var out: usize = 0;
    var replacement_count: usize = 0;
    while (bytes_consumed < utf8.len and out < buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[bytes_consumed]) catch {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            bytes_consumed += 1;
            continue;
        };
        if (bytes_consumed + seq_len > utf8.len) {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(utf8[bytes_consumed..][0..seq_len]) catch {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            bytes_consumed += seq_len;
            continue;
        };
        if (cp >= 0x10000) {
            if (out + 2 > buf.len) break;
            const high: u16 = @intCast((cp - 0x10000) >> 10);
            const low: u16 = @intCast((cp - 0x10000) & 0x3FF);
            buf[out] = std.mem.nativeToLittle(u16, 0xD800 + high);
            buf[out + 1] = std.mem.nativeToLittle(u16, 0xDC00 + low);
            out += 2;
        } else {
            buf[out] = std.mem.nativeToLittle(u16, @intCast(cp));
            out += 1;
        }
        bytes_consumed += seq_len;
    }
    return .{
        .len = out,
        .replacement_count = replacement_count,
        .bytes_consumed = bytes_consumed,
    };
}
fn stateFromHwnd(hwnd: win32.HWND) *State {
    std.debug.assert(hwnd == global.state.?.hwnd);
    return &global.state.?;
}

const GridPos = struct {
    row: u16,
    col: u16,
    pub fn count(self: GridPos) u32 {
        return @as(u32, self.row) * @as(u32, self.col);
    }

    pub fn eql(self: GridPos, other: GridPos) bool {
        return self.row == other.row and self.col == other.col;
    }
};

// TODO: should we define WinMain instead?
pub fn main() !void {
    // var args_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // const cmdline = blk: {
    //     var args_it = try std.process.argsWithAllocator(args_arena.allocator());
    //     break :blk try Cmdline.parse(&args_it);
    // };

    const opt: struct {
        window_placement: WindowPlacementOptions = .{},
    } = .{};

    const maybe_monitor: ?win32.HMONITOR = blk: {
        break :blk win32.MonitorFromPoint(
            .{
                .x = opt.window_placement.left orelse 0,
                .y = opt.window_placement.top orelse 0,
            },
            win32.MONITOR_DEFAULTTOPRIMARY,
        ) orelse {
            std.log.warn("MonitorFromPoint failed, error={f}", .{win32.GetLastError()});
            break :blk null;
        };
    };

    const dpi: XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var dpi: XY(u32) = undefined;
        const hr = win32.GetDpiForMonitor(
            monitor,
            win32.MDT_EFFECTIVE_DPI,
            &dpi.x,
            &dpi.y,
        );
        if (hr < 0) {
            std.log.warn("GetDpiForMonitor failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
            break :blk .{ .x = 96, .y = 96 };
        }
        std.log.debug("primary monitor dpi {}x{}", .{ dpi.x, dpi.y });
        break :blk dpi;
    };

    global.icons = getIcons(dpi);
    global.renderer = d3d11.init(@max(dpi.x, dpi.y));
    const cell_size = global.renderer.cell_size;
    const placement = calcWindowPlacement(
        maybe_monitor,
        @max(dpi.x, dpi.y),
        cell_size,
        opt.window_placement,
    );

    const CLASS_NAME = win32.L("MiteWindow");

    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            //.style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .style = .{},
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = global.icons.small,
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32(
            "RegisterClass",
            win32.GetLastError(),
        );
    }

    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME,
        win32.L("Mite"),
        window_style,
        placement.pos.x,
        placement.pos.y,
        placement.size.cx,
        placement.size.cy,
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={f}",
            .{ dark_value, win32.GetLastError() },
        );
    }
    {
        // Title bar color (COLORREF = 0x00BBGGRR)
        const caption_color: u32 = 0x00120B0F; // RGB(0x0F, 0x0B, 0x12) - darker, matches gradient tint
        const hr = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_CAPTION_COLOR, &caption_color, @sizeOf(@TypeOf(caption_color)));
        if (hr < 0) std.log.warn("DwmSetWindowAttribute caption color failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    {
        const margins = win32.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 0 };
        const hr = win32.DwmExtendFrameIntoClientArea(hwnd, &margins);
        if (hr < 0) std.log.warn("DwmExtendFrameIntoClientArea failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }
    {
        const bb = win32.DWM_BLURBEHIND{
            .dwFlags = 0x1 | 0x4, // DWM_BB_ENABLE | DWM_BB_TRANSITIONONMAXIMIZED
            .fEnable = 1,
            .hRgnBlur = null, // null = entire window
            .fTransitionOnMaximized = 1,
        };
        const hr = win32.DwmEnableBlurBehindWindow(hwnd, &bb);
        if (hr < 0) std.log.warn("DwmEnableBlurBehindWindow failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    if (0 == win32.UpdateWindow(hwnd)) win32.panicWin32("UpdateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    // try some things to bring our window to the top
    const HWND_TOP: ?win32.HWND = null;
    _ = win32.SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1 });
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);

    while (true) {
        const state: *State = blk: {
            while (true) {
                if (global.state) |*state| break :blk state;
                var msg: win32.MSG = undefined;
                const result = win32.GetMessageW(&msg, null, 0, 0);
                if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
                if (result == 0) onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        };

        var handles = [1]win32.HANDLE{state.child_process.process_handle};
        const wait_result = win32.MsgWaitForMultipleObjectsEx(
            1,
            &handles,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 },
        );
        if (wait_result == 0) {
            // Child process exited. We can't do orderly cleanup here
            // because ClosePseudoConsole blocks until the pipe is
            // drained, but the read thread drains via SendMessage which
            // needs us to pump messages - a deadlock. Since we're
            // exiting anyway, let the OS clean up all handles.
            std.process.exit(0);
        } else std.debug.assert(wait_result == 1);

        flushMessages();
    }
}

pub fn flushMessages() void {
    var msg: win32.MSG = undefined;
    while (true) {
        const result = win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE);
        if (result < 0) win32.panicWin32("PeekMessage", win32.GetLastError());
        if (result == 0) break;
        if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

const WindowPlacementOptions = struct {
    left: ?i32 = null,
    top: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

const WindowPlacement = struct {
    dpi: XY(u32),
    size: win32.SIZE,
    pos: win32.POINT,
    pub fn default(opt: WindowPlacementOptions) WindowPlacement {
        return .{
            .dpi = .{
                .x = 96,
                .y = 96,
            },
            .pos = .{
                .x = if (opt.left) |left| left else win32.CW_USEDEFAULT,
                .y = if (opt.top) |top| top else win32.CW_USEDEFAULT,
            },
            .size = .{
                .cx = win32.CW_USEDEFAULT,
                .cy = win32.CW_USEDEFAULT,
            },
        };
    }
};

fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: win32.SIZE,
    opt: WindowPlacementOptions,
) WindowPlacement {
    var result = WindowPlacement.default(opt);

    const monitor = maybe_monitor orelse return result;

    const work_rect: win32.RECT = blk: {
        var info: win32.MONITORINFO = undefined;
        info.cbSize = @sizeOf(win32.MONITORINFO);
        if (0 == win32.GetMonitorInfoW(monitor, &info)) {
            std.log.warn("GetMonitorInfo failed, error={f}", .{win32.GetLastError()});
            return result;
        }
        break :blk info.rcWork;
    };

    const work_size: win32.SIZE = .{
        .cx = work_rect.right - work_rect.left,
        .cy = work_rect.bottom - work_rect.top,
    };
    std.log.debug(
        "monitor work topleft={},{} size={}x{}",
        .{ work_rect.left, work_rect.top, work_size.cx, work_size.cy },
    );

    const wanted_size: win32.SIZE = .{
        .cx = win32.scaleDpi(i32, @as(i32, @intCast(opt.width orelse 900)), result.dpi.x),
        .cy = win32.scaleDpi(i32, @as(i32, @intCast(opt.height orelse 700)), result.dpi.y),
    };
    const bounding_size: win32.SIZE = .{
        .cx = @min(wanted_size.cx, work_size.cx),
        .cy = @min(wanted_size.cy, work_size.cy),
    };
    const bouding_rect: win32.RECT = rectIntFromSize(.{
        .left = work_rect.left + @divTrunc(work_size.cx - bounding_size.cx, 2),
        .top = work_rect.top + @divTrunc(work_size.cy - bounding_size.cy, 2),
        .width = bounding_size.cx,
        .height = bounding_size.cy,
    });
    const adjusted_rect: win32.RECT = calcWindowRect(
        dpi,
        bouding_rect,
        null,
        cell_size,
    );
    result.pos = .{
        .x = if (opt.left) |left| left else adjusted_rect.left,
        .y = if (opt.top) |top| top else adjusted_rect.top,
    };
    result.size = .{
        .cx = adjusted_rect.right - adjusted_rect.left,
        .cy = adjusted_rect.bottom - adjusted_rect.top,
    };
    return result;
}

fn calcWindowRect(
    dpi: u32,
    bounding_rect: win32.RECT,
    maybe_edge: ?win32.WPARAM,
    cell_size: win32.SIZE,
) win32.RECT {
    const client_inset = getClientInset(dpi);
    const scrollbar_px: i32 = d3d11.scrollbarWidth(dpi);
    const bounding_client_size: win32.SIZE = .{
        .cx = (bounding_rect.right - bounding_rect.left) - client_inset.cx,
        .cy = (bounding_rect.bottom - bounding_rect.top) - client_inset.cy,
    };
    const trim: win32.SIZE = .{
        .cx = @mod(@max(bounding_client_size.cx - scrollbar_px, 0), cell_size.cx),
        .cy = @mod(bounding_client_size.cy, cell_size.cy),
    };
    const Adjustment = enum { low, high, both };
    const adjustments: XY(Adjustment) = if (maybe_edge) |edge| switch (edge) {
        win32.WMSZ_LEFT => .{ .x = .low, .y = .both },
        win32.WMSZ_RIGHT => .{ .x = .high, .y = .both },
        win32.WMSZ_TOP => .{ .x = .both, .y = .low },
        win32.WMSZ_TOPLEFT => .{ .x = .low, .y = .low },
        win32.WMSZ_TOPRIGHT => .{ .x = .high, .y = .low },
        win32.WMSZ_BOTTOM => .{ .x = .both, .y = .high },
        win32.WMSZ_BOTTOMLEFT => .{ .x = .low, .y = .high },
        win32.WMSZ_BOTTOMRIGHT => .{ .x = .high, .y = .high },
        else => .{ .x = .both, .y = .both },
    } else .{ .x = .both, .y = .both };

    return .{
        .left = bounding_rect.left + switch (adjustments.x) {
            .low => trim.cx,
            .high => 0,
            .both => @divTrunc(trim.cx, 2),
        },
        .top = bounding_rect.top + switch (adjustments.y) {
            .low => trim.cy,
            .high => 0,
            .both => @divTrunc(trim.cy, 2),
        },
        .right = bounding_rect.right - switch (adjustments.x) {
            .low => 0,
            .high => trim.cx,
            .both => @divTrunc(trim.cx + 1, 2),
        },
        .bottom = bounding_rect.bottom - switch (adjustments.y) {
            .low => 0,
            .high => trim.cy,
            .both => @divTrunc(trim.cy + 1, 2),
        },
    };
}

fn getClientInset(dpi: u32) win32.SIZE {
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
    };
    if (0 == win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        0,
        window_style_ex,
        dpi,
    )) win32.panicWin32(
        "AdjustWindowRect",
        win32.GetLastError(),
    );
    return .{
        .cx = rect.right - rect.left,
        .cy = rect.bottom - rect.top,
    };
}

fn rectIntFromSize(args: struct { left: i32, top: i32, width: i32, height: i32 }) win32.RECT {
    return .{
        .left = args.left,
        .top = args.top,
        .right = args.left + args.width,
        .bottom = args.top + args.height,
    };
}

fn setWindowPosRect(hwnd: win32.HWND, rect: win32.RECT) void {
    if (0 == win32.SetWindowPos(
        hwnd,
        null, // ignored via NOZORDER
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) win32.panicWin32("SetWindowPos", win32.GetLastError());
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);

            const client_size = win32.getClientSize(hwnd);
            const cs = global.renderer.cell_size;
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd)));
            const cell_count: GridPos = .{
                .row = @intCast(@divTrunc(client_size.cy + cs.cy - 1, cs.cy)),
                .col = @intCast(@divTrunc(grid_w + cs.cx - 1, cs.cx)),
            };
            if (cell_count.row == 0 or cell_count.col == 0) std.debug.panic("todo: handle cell counts {}", .{cell_count});
            std.log.info(
                "screen is {} rows and {} cols (cell size {}x{}, pixel size {}x{})",
                .{ cell_count.row, cell_count.col, cs.cx, cs.cy, client_size.cx, client_size.cy },
            );

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var err: Error = undefined;
            const child_process = ChildProcess.startConPtyWin32(
                &err,
                arena.allocator(),
                win32.L("C:\\Windows\\System32\\cmd.exe"),
                null,
                hwnd,
                WM_APP_CHILD_PROCESS_DATA,
                WM_APP_CHILD_PROCESS_DATA_RESULT,
                cell_count,
            ) catch std.debug.panic("{f}", .{err});

            const term = std.heap.page_allocator.create(vt.Terminal) catch oom(error.OutOfMemory);
            term.* = vt.Terminal.init(global.term_arena.allocator(), .{
                .cols = cell_count.col,
                .rows = cell_count.row,
            }) catch |e| std.debug.panic("Terminal.init: {}", .{e});

            global.state = .{
                .hwnd = hwnd,
                .child_process = child_process,
                .term = term,
                .vt_stream = .initAlloc(global.gpa.allocator(), .{ .readonly = term.vtHandler(), .hwnd = hwnd }),
            };
            std.debug.assert(&(global.state.?) == stateFromHwnd(hwnd));

            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // put in a test pattern for the moment
            // screen.clear();
            // {
            //     const pattern = "Mite is coming...";
            //     for (screen.cells, 0..) |*cell, i| {
            //         cell.* = .{
            //             .glyph_index = global.state.?.render_state.generateGlyph(
            //                 font,
            //                 pattern[i % pattern.len ..][0..1],
            //             ),
            //             .background = render.Color.initRgba(0, 0, 0, 0),
            //             .foreground = render.Color.initRgb(255, 0, 0),
            //         };
            //     }
            // }

            return 0;
        },
        win32.WM_CLOSE, win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        // win32.WM_MOUSEMOVE => {
        //     const point = win32ext.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        // },
        // win32.WM_LBUTTONDOWN => {
        //     const point = ddui.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        //     state.mouse.setLeftDown();
        // },
        // win32.WM_LBUTTONUP => {
        //     const point = ddui.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        //     // if (state.mouse.setLeftUp()) |target| switch (target) {
        //     //     .new_window_button => newWindow(),
        //     // };
        // },
        win32.WM_LBUTTONDOWN => {
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const client_size = win32.getClientSize(hwnd);
            const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
            const grid_w = client_size.cx -| @as(i32, sb_px);
            if (mouse_x >= grid_w) {
                const state = stateFromHwnd(hwnd);
                const screen = state.term.screens.active;
                const sb = screen.pages.scrollbar();
                if (sb.total > sb.len) {
                    const win_h: f32 = @floatFromInt(client_size.cy);
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    const max_offset = sb.total - sb.len;
                    const track_y = @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);
                    const mouse_yf: f32 = @floatFromInt(mouse_y);

                    if (mouse_yf >= track_y and mouse_yf < track_y + track_height) {
                        // Clicked on thumb: drag with offset
                        global.mouse_capture = .scrollbar_drag;
                        global.scrollbar_drag_offset = mouse_yf - track_y;
                    } else {
                        // Clicked on track: jump to position
                        global.mouse_capture = .scrollbar_drag;
                        global.scrollbar_drag_offset = track_height / 2.0;
                        scrollbarDragTo(state, mouse_yf - track_height / 2.0, win_h, track_height);
                    }
                    _ = win32.SetCapture(hwnd);
                    win32.invalidateHwnd(hwnd);
                }
            } else {
                // Click in grid area: start text selection
                const state = stateFromHwnd(hwnd);
                const screen = state.term.screens.active;
                global.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                const cs = global.renderer.cell_size;
                const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
                const row: usize = @intCast(@divTrunc(@max(mouse_y, 0), cs.cy));
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                    screen.clearSelection();
                    const sel = vt.Selection.init(pin, pin, false);
                    screen.select(sel) catch oom(error.OutOfMemory);
                    global.mouse_capture = .selecting;
                    _ = win32.SetCapture(hwnd);
                    win32.invalidateHwnd(hwnd);
                }
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            switch (global.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    global.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    win32.invalidateHwnd(hwnd);
                },
                .selecting => {
                    global.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    // Copy selection to clipboard and start fade
                    const state = stateFromHwnd(hwnd);
                    const screen = state.term.screens.active;
                    if (screen.selection) |sel| {
                        const alloc = global.gpa.allocator();
                        const text = screen.selectionString(alloc, .{ .sel = sel }) catch oom(error.OutOfMemory);
                        defer alloc.free(text);
                        if (text.len > 0) {
                            copyToClipboard(hwnd, text);
                        }
                        global.selection_fade = 1.0;
                        _ = win32.SetTimer(hwnd, TIMER_SELECTION_FADE, 16, null); // ~60fps
                    }
                },
            }
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEWHEEL => {
            const state = stateFromHwnd(hwnd);
            const delta: i16 = @bitCast(win32.hiword(wparam));
            const scroll_lines: isize = if (delta > 0) -3 else 3;
            const screen = state.term.screens.active;
            screen.scroll(.{ .delta_row = scroll_lines });
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            // Track whether mouse is in the scrollbar area
            if (!global.tracking_mouse) {
                var tme = win32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = win32.TrackMouseEvent(&tme);
                global.tracking_mouse = true;
            }
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd)));

            switch (global.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    const state = stateFromHwnd(hwnd);
                    const win_h: f32 = @floatFromInt(client_size.cy);
                    const sb = state.term.screens.active.pages.scrollbar();
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    scrollbarDragTo(state, @as(f32, @floatFromInt(mouse_y)) - global.scrollbar_drag_offset, win_h, track_height);
                    win32.invalidateHwnd(hwnd);
                },
                .selecting => {
                    const state = stateFromHwnd(hwnd);
                    const screen = state.term.screens.active;
                    const cs = global.renderer.cell_size;
                    const clamped_x: i32 = @max(0, @min(mouse_x, grid_w - 1));
                    const clamped_y: i32 = @max(0, @min(mouse_y, client_size.cy - 1));
                    const col: usize = @intCast(@divTrunc(clamped_x, cs.cx));
                    const row: usize = @intCast(@divTrunc(clamped_y, cs.cy));
                    if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                        if (screen.selection) |*sel| {
                            sel.endPtr().* = pin;
                            win32.invalidateHwnd(hwnd);
                        }
                    }
                },
            }

            const in_scrollbar = mouse_x >= grid_w;
            if (in_scrollbar != global.mouse_in_scrollbar) {
                global.mouse_in_scrollbar = in_scrollbar;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            global.tracking_mouse = false;
            if (global.mouse_in_scrollbar) {
                global.mouse_in_scrollbar = false;
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            global.resizing = false;
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            if (!global.resizing) {
                global.resizing = true;
                win32.invalidateHwnd(hwnd);
            }
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            const new_rect = calcWindowRect(dpi, rect.*, wparam, global.renderer.cell_size);
            state.bounds = .{
                .token = new_rect,
                .rect = rect.*,
            };
            rect.* = new_rect;
            return 0;
        },
        win32.WM_WINDOWPOSCHANGED => {
            const state = stateFromHwnd(hwnd);
            const client_size = win32.getClientSize(hwnd);
            const cs = global.renderer.cell_size;
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd)));
            const col_count: u16 = @intCast(@max(1, @divTrunc(grid_w, cs.cx)));
            const row_count: u16 = @intCast(@max(1, @divTrunc(client_size.cy, cs.cy)));

            state.term.resize(global.term_arena.allocator(), col_count, row_count) catch |e|
                std.debug.panic("Terminal.resize: {}", .{e});
            var resize_err: Error = undefined;
            state.child_process.resize(&resize_err, .{
                .row = row_count,
                .col = col_count,
            }) catch std.debug.panic("{f}", .{resize_err});
            // Render immediately to avoid flicker - with NOREDIRECTIONBITMAP
            // there's no DWM surface to show between resize and next WM_PAINT.
            global.renderer.render(hwnd, state.term, global.resizing, global.mouse_in_scrollbar, if (global.mouse_capture == .selecting) 1.0 else global.selection_fade);
            _ = win32.ValidateRect(hwnd, null);
            return 0;
        },
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const state = stateFromHwnd(hwnd);
            global.renderer.render(hwnd, state.term, global.resizing, global.mouse_in_scrollbar, if (global.mouse_capture == .selecting) 1.0 else global.selection_fade);
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(current_dpi));
            const col_count = @max(1, @divTrunc(grid_w, cs.cx));
            const row_count = @max(1, @divTrunc(client_size.cy, cs.cy));
            if (col_count != 1) std.debug.assert(grid_w == col_count * cs.cx);
            if (row_count != 1) std.debug.assert(client_size.cy == row_count * cs.cy);

            const new_cs = global.renderer.cellSizeForDpi(new_dpi);
            const new_client_w = col_count * new_cs.cx + @as(i32, d3d11.scrollbarWidth(new_dpi));
            const new_client_h = row_count * new_cs.cy;
            const new_inset = getClientInset(new_dpi);
            inout_size.* = .{
                .cx = new_client_w + new_inset.cx,
                .cy = new_client_h + new_inset.cy,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
            if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
            global.renderer.updateDpi(dpi);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            state.bounds = null;
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_KEYDOWN => {
            const state = stateFromHwnd(hwnd);

            const pty = state.child_process.pty orelse {
                state.reportError("pty closed", .{});
                return 0;
            };
            // Ctrl+Shift+V or Shift+Insert: paste from clipboard
            if ((wparam == @intFromEnum(win32.VK_V) and win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0 and win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0) or
                (wparam == @intFromEnum(win32.VK_INSERT) and win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0))
            {
                pasteClipboard(hwnd, state);
                return 0;
            }

            // Clear text selection on any keypress
            const screen = state.term.screens.active;
            if (screen.selection != null) {
                screen.clearSelection();
                global.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                win32.invalidateHwnd(hwnd);
            }

            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                win32.invalidateHwnd(hwnd);
            }

            const seq: ?[]const u8 = switch (wparam) {
                @intFromEnum(win32.VK_BACK) => "\x7f",
                @intFromEnum(win32.VK_UP) => "\x1b[A",
                @intFromEnum(win32.VK_DOWN) => "\x1b[B",
                @intFromEnum(win32.VK_RIGHT) => "\x1b[C",
                @intFromEnum(win32.VK_LEFT) => "\x1b[D",
                @intFromEnum(win32.VK_HOME) => "\x1b[H",
                @intFromEnum(win32.VK_END) => "\x1b[F",
                @intFromEnum(win32.VK_INSERT) => "\x1b[2~",
                @intFromEnum(win32.VK_DELETE) => "\x1b[3~",
                @intFromEnum(win32.VK_PRIOR) => "\x1b[5~", // Page Up
                @intFromEnum(win32.VK_NEXT) => "\x1b[6~", // Page Down
                @intFromEnum(win32.VK_F1) => "\x1bOP",
                @intFromEnum(win32.VK_F2) => "\x1bOQ",
                @intFromEnum(win32.VK_F3) => "\x1bOR",
                @intFromEnum(win32.VK_F4) => "\x1bOS",
                @intFromEnum(win32.VK_F5) => "\x1b[15~",
                @intFromEnum(win32.VK_F6) => "\x1b[17~",
                @intFromEnum(win32.VK_F7) => "\x1b[18~",
                @intFromEnum(win32.VK_F8) => "\x1b[19~",
                @intFromEnum(win32.VK_F9) => "\x1b[20~",
                @intFromEnum(win32.VK_F10) => "\x1b[21~",
                @intFromEnum(win32.VK_F11) => "\x1b[23~",
                @intFromEnum(win32.VK_F12) => "\x1b[24~",
                else => null,
            };
            if (seq) |s| {
                pty.writeFlushAll(s) catch |e| state.reportError(
                    "write to pty failed: {s}",
                    .{@errorName(e)},
                );
            }
            return 0;
        },
        win32.WM_CHAR => {
            const state = stateFromHwnd(hwnd);
            const pty = state.child_process.pty orelse {
                state.reportError("pty closed", .{});
                return 0;
            };
            const screen = state.term.screens.active;
            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                win32.invalidateHwnd(hwnd);
            }
            const char: u16 = std.math.cast(u16, wparam) orelse {
                std.log.warn("unexpected WM_CHAR wparam: {}", .{wparam});
                return 0;
            };
            // Backspace is handled in WM_KEYDOWN (sends \x7f)
            if (char == 0x08) return 0;
            // Suppress Ctrl+Shift+V control character (paste is handled in WM_KEYDOWN)
            if (char == 0x16 and win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0) return 0;
            if (std.unicode.utf16IsHighSurrogate(char)) {
                global.high_surrogate = char;
                return 0;
            }
            const codepoint: u21 = blk: {
                if (global.high_surrogate) |high| {
                    global.high_surrogate = null;
                    if (std.unicode.utf16IsLowSurrogate(char)) {
                        break :blk std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, char }) catch return 0;
                    }
                }
                break :blk @intCast(char);
            };
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
            pty.writeFlushAll(utf8_buf[0..len]) catch |e| state.reportError(
                "write to pty failed: {s}",
                .{@errorName(e)},
            );
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            const state = stateFromHwnd(hwnd);
            pasteClipboard(hwnd, state);
            return 0;
        },
        win32.WM_TIMER => {
            if (wparam == TIMER_SELECTION_FADE) {
                global.selection_fade -= 0.05;
                if (global.selection_fade <= 0) {
                    global.selection_fade = 0;
                    _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                    const state = stateFromHwnd(hwnd);
                    state.term.screens.active.clearSelection();
                }
                win32.invalidateHwnd(hwnd);
            }
            return 0;
        },
        WM_APP_CHILD_PROCESS_DATA => {
            const buffer: [*]const u8 = @ptrFromInt(wparam);
            const len: usize = @bitCast(lparam);
            std.debug.assert(len > 0);
            const state = stateFromHwnd(hwnd);
            state.vt_stream.nextSlice(buffer[0..len]);
            win32.invalidateHwnd(hwnd);
            return WM_APP_CHILD_PROCESS_DATA_RESULT;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};

fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.debug("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
    });
    const small = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for small icon", win32.GetLastError());
    const large = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for large icon", win32.GetLastError());
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}

fn onWmQuit(wparam: win32.WPARAM) noreturn {
    if (std.math.cast(u32, wparam)) |exit_code| {
        std.log.info("quit {}", .{exit_code});
        win32.ExitProcess(exit_code);
    }
    std.log.info("quit {} (0xffffffff)", .{wparam});
    win32.ExitProcess(0xffffffff);
}

fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

const Error = struct {
    what: [:0]const u8,
    code: Code,

    pub fn setZig(self: *Error, what: [:0]const u8, code: anyerror) error{Error} {
        self.* = .{ .what = what, .code = .{ .zig = code } };
        return error.Error;
    }
    pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
        self.* = .{ .what = what, .code = .{ .win32 = code } };
        return error.Error;
    }
    pub fn setHresult(self: *Error, what: [:0]const u8, code: i32) error{Error} {
        self.* = .{ .what = what, .code = .{ .hresult = code } };
        return error.Error;
    }

    const Code = union(enum) {
        zig: anyerror,
        win32: win32.WIN32_ERROR,
        hresult: win32.HRESULT,
        pub fn format(self: Code, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (self) {
                .zig => |e| try writer.print("error {s}", .{@errorName(e)}),
                .win32 => |code| try code.format(writer),
                .hresult => |hr| try writer.print("HRESULT 0x{x}", .{@as(u32, @bitCast(hr))}),
            }
        }
    };

    pub fn format(self: Error, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("{s} failed, error={f}", .{ self.what, self.code });
    }
};

const ChildProcess = struct {
    pty: ?Pty,
    read: win32.HANDLE,
    thread: std.Thread,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,

    const Pty = struct {
        write: std.fs.File,
        hpcon: win32.HPCON,
        pub fn deinit(self: *Pty) void {
            win32.ClosePseudoConsole(self.hpcon);
            win32.closeHandle(self.write);
        }
        pub fn writeFlushAll(self: *const Pty, slice: []const u8) !void {
            try self.write.writeAll(slice);
        }
    };

    // this must be called before calling join
    pub fn closePty(self: *ChildProcess) void {
        if (self.pty) |*pty| {
            pty.deinit();
            self.pty = null;
        }
    }

    // Start a child process attached to a win32 pseudo-console (ConPty).
    //
    // allocator is only used for temporary storage of attributes to start
    // the process, the memory will be cleaned up before returning.
    //
    // application_name and command_line are simply forwarded to CreateProcess as the
    // first two parameters. note that command_line being mutable is not a mistake, for some
    // reason windows requires this be mutable.
    //
    // As far as I know, there's no way to asynchronously read from ConPty...so...this
    // function will start its own thread where it will read input from the pseudo-console
    // with a stack-allocated buffer (sized with std.mem.page_size).  When it reads data,
    // it will response by calling SendMessage on the given hwnd with the given hwnd_msg and
    // data that was read.
    //
    // size.row and size.col must both be > 0, the pseudo-console will fail otherwise.
    pub fn startConPtyWin32(
        out_err: *Error,
        allocator: std.mem.Allocator,
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        hwnd: win32.HWND,
        hwnd_msg: u32,
        hwnd_msg_result: win32.LRESULT,
        cell_count: GridPos,
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

        try setInherit(out_err, our_write, false);
        try setInherit(out_err, our_read, false);

        // start the thread before creating the console since
        // closing the console is what could cause the thread to stop
        const thread = std.Thread.spawn(
            .{},
            readConsoleThread,
            .{ hwnd, hwnd_msg, hwnd_msg_result, our_read },
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
            // important to close these here so our thread won't get stuck
            // if CreatePseudoConsole fails
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
                // USESTDHANDLES is important, otherwise the child process can
                // inherit our handles and end up having IO hooked up to one of
                // our ancestor processes instead of our pseudo terminal. Setting
                // the actual handle values to null seems to work in that the child
                // process will be hooked up to the PTY.
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
        // Ensure child process sees a proper terminal environment regardless
        // of how mite itself was launched (e.g. from Emacs with TERM=dumb).
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("TERM"), win32.L("xterm-256color"));
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("NO_COLOR"), null);
        _ = std.os.windows.kernel32.SetEnvironmentVariableW(win32.L("COLORTERM"), win32.L("truecolor"));

        var process_info: win32.PROCESS_INFORMATION = undefined;
        if (0 == win32.CreateProcessW(
            application_name,
            command_line,
            null,
            null,
            0, // inherit handles
            .{
                .CREATE_SUSPENDED = 1,
                // Adding this causes output not to work?
                //.CREATE_NO_WINDOW = 1,
                .EXTENDED_STARTUPINFO_PRESENT = 1,
            },
            null,
            null,
            &startup_info.StartupInfo,
            &process_info,
        )) return out_err.setWin32("CreateProcess", win32.GetLastError());
        defer win32.closeHandle(process_info.hThread.?);
        errdefer win32.closeHandle(process_info.hProcess.?);

        // The job object allows us to automatically kill our child process
        // if our process dies.
        // TODO: should we cache/reuse this?
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

        {
            const suspend_count = win32.ResumeThread(process_info.hThread);
            if (suspend_count == -1) return out_err.setWin32(.{
                "ResumeThread",
                win32.GetLastError(),
            });
        }

        return .{
            .pty = .{
                .write = .{ .handle = our_write },
                .hpcon = hpcon,
            },
            .read = our_read,
            .thread = thread,
            .job = job,
            .process_handle = process_info.hProcess.?,
        };
    }

    pub fn resize(self: *const ChildProcess, out_err: *Error, size: GridPos) error{Error}!void {
        const pty = self.pty orelse return;
        const hr = win32.ResizePseudoConsole(
            pty.hpcon,
            .{ .X = @intCast(size.col), .Y = @intCast(size.row) },
        );
        if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
    }

    fn setInherit(out_err: *Error, handle: win32.HANDLE, enable: bool) error{Error}!void {
        if (0 == win32.SetHandleInformation(
            handle,
            @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
            .{ .INHERIT = if (enable) 1 else 0 },
        )) return out_err.setWin32(
            "SetHandleInformation",
            win32.GetLastError(),
        );
    }

    fn readConsoleThread(
        hwnd: win32.HWND,
        hwnd_msg: u32,
        hwnd_msg_result: win32.LRESULT,
        read: win32.HANDLE,
    ) void {
        while (true) {
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
                    std.log.info("console output closed", .{});
                    return;
                },
                .ERROR_HANDLE_EOF => {
                    @panic("todo: eof");
                },
                .ERROR_NO_DATA => {
                    @panic("todo: nodata");
                },
                else => |e| std.debug.panic("todo: handle error {f}", .{e}),
            };
            if (read_len == 0) {
                @panic("possible for ReadFile to return 0 bytes?");
            }
            std.debug.assert(hwnd_msg_result == win32.SendMessageW(
                hwnd,
                hwnd_msg,
                @intFromPtr(&buffer),
                read_len,
            ));
        }
    }
};

fn scrollbarDragTo(state: *State, track_top: f32, win_h: f32, track_height: f32) void {
    const screen = state.term.screens.active;
    const sb = screen.pages.scrollbar();
    if (sb.total <= sb.len) return;
    const max_offset = sb.total - sb.len;
    const scrollable = win_h - track_height;
    if (scrollable <= 0) return;
    const ratio = std.math.clamp(track_top / scrollable, 0.0, 1.0);
    const target_row: usize = @intFromFloat(ratio * @as(f32, @floatFromInt(max_offset)));
    screen.scroll(.{ .row = target_row });
}

fn globalUnlock(hmem: isize) void {
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.GlobalUnlock(hmem)) {
        const err = win32.GetLastError();
        if (err != .NO_ERROR) win32.panicWin32("GlobalUnlock", err);
    }
}

fn copyToClipboard(hwnd: win32.HWND, utf8: [:0]const u8) void {
    if (win32.OpenClipboard(hwnd) == 0) {
        std.log.err("copy: OpenClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());

    if (win32.EmptyClipboard() == 0) {
        std.log.err("copy: EmptyClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }

    const u16_len = std.unicode.calcUtf16LeLen(utf8) catch {
        std.log.err("copy: invalid utf-8 in selection", .{});
        return;
    };
    const hmem = win32.GlobalAlloc(.{ .MEM_MOVEABLE = 1 }, (u16_len + 1) * @sizeOf(u16));
    if (hmem == 0) {
        std.log.err("copy: GlobalAlloc failed, error={f}", .{win32.GetLastError()});
        return;
    }
    var hmem_owned = true;
    defer if (hmem_owned) if (0 != win32.GlobalFree(hmem)) win32.panicWin32("GlobalFree", win32.GetLastError());

    {
        const ptr: [*]u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse {
            std.log.err("copy: GlobalLock failed, error={f}", .{win32.GetLastError()});
            return;
        }));
        defer globalUnlock(hmem);

        // Const ptr: [*]u16 = @ptrFromInt(@as(usize, @bitCast(hmem)));
        const len = std.unicode.utf8ToUtf16Le(ptr[0 .. u16_len + 1], utf8) catch unreachable;
        std.debug.assert(len == u16_len);
        ptr[u16_len] = 0;
    }

    const handle: win32.HANDLE = @ptrFromInt(@as(usize, @bitCast(hmem)));
    if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), handle) == null) {
        std.log.err("copy: SetClipboardData failed, error={f}", .{win32.GetLastError()});
    } else {
        hmem_owned = false;
    }
}

fn pasteClipboard(hwnd: win32.HWND, state: *State) void {
    const pty = state.child_process.pty orelse {
        state.reportError("paste: pty closed", .{});
        return;
    };
    if (win32.OpenClipboard(hwnd) == 0) {
        state.reportError("paste: OpenClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());
    const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse {
        state.reportError("paste: GetClipboardData failed, error={f}", .{win32.GetLastError()});
        return;
    };
    const hmem: isize = @bitCast(@intFromPtr(handle));
    const mem: [*:0]const u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse {
        state.reportError("paste: GlobalLock failed, error={f}", .{win32.GetLastError()});
        return;
    }));
    defer globalUnlock(hmem);
    var buf: [4096]u8 = undefined;
    var pty_writer = pty.write.writerStreaming(&buf);
    pasteUtf16(state, mem, &pty_writer.interface) catch |err| switch (err) {
        error.WriteFailed => state.reportError("paste: write to pty failed with {t}", .{pty_writer.err.?}),
        error.Reported => {},
    };
}

const paste_end = "\x1b[201~";

const PasteEndStripper = struct {
    matched: usize = 0,

    pub fn finish(stripper: *PasteEndStripper, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (stripper.matched != 0) {
            try writer.writeAll(paste_end[0..stripper.matched]);
            stripper.matched = 0;
        }
    }

    pub fn onCodepoint(
        stripper: *PasteEndStripper,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) error{WriteFailed}!enum { consumed, ignored } {
        if (codepoint == paste_end[stripper.matched]) {
            stripper.matched += 1;
            // Full marker matched: drop it entirely and start over.
            if (stripper.matched == paste_end.len) {
                std.log.warn("stripped paste-end marker from clipboard data", .{});
                stripper.matched = 0;
            }
            return .consumed;
        }

        if (stripper.matched != 0) {
            try writer.writeAll(paste_end[0..stripper.matched]);
            stripper.matched = 0;
        }

        if (codepoint == paste_end[0]) {
            stripper.matched = 1;
            return .consumed;
        }
        return .ignored;
    }
};

fn pasteUtf16(state: *State, utf16: [*:0]const u16, writer: *std.Io.Writer) error{ WriteFailed, Reported }!void {
    const bracketed = state.term.modes.get(.bracketed_paste);
    if (bracketed) try writer.writeAll("\x1b[200~");
    var end_stripper: PasteEndStripper = .{};

    var i: usize = 0;
    while (utf16[i] != 0) {
        const cp: u21 = blk: {
            if (std.unicode.utf16IsHighSurrogate(utf16[i])) {
                const high = utf16[i];
                i += 1;
                if (utf16[i] == 0 or !std.unicode.utf16IsLowSurrogate(utf16[i])) {
                    state.reportError("paste: lone high surrogate 0x{x} at index {}", .{ high, i - 1 });
                    return error.Reported;
                }
                const pair = std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, utf16[i] }) catch {
                    state.reportError("paste: bad surrogate pair 0x{x} 0x{x} at index {}", .{ high, utf16[i], i - 1 });
                    return error.Reported;
                };
                i += 1;
                break :blk pair;
            }
            if (std.unicode.utf16IsLowSurrogate(utf16[i])) {
                state.reportError("paste: lone low surrogate 0x{x} at index {}", .{ utf16[i], i });
                return error.Reported;
            }
            const c: u21 = @intCast(utf16[i]);
            i += 1;
            break :blk c;
        };

        switch (if (bracketed) try end_stripper.onCodepoint(writer, cp) else .ignored) {
            .consumed => {},
            .ignored => {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                    state.reportError("paste: invalid codepoint U+{x} at index {}", .{ cp, i });
                    return error.Reported;
                };
                try writer.writeAll(utf8_buf[0..len]);
            },
        }
    }
    try end_stripper.finish(writer);
    if (bracketed) try writer.writeAll(paste_end);
    try writer.flush();
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const d3d11 = @import("win32/d3d11.zig");
const vt = @import("vt");
const std = @import("std");
const win32 = @import("win32").everything;
const cimport = @cImport({
    @cInclude("ResourceNames.h");
});
const Cmdline = @import("Cmdline.zig");
