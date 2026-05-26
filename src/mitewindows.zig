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

const TabId = u32;

const MAX_TABS: usize = 32;

const Tab = struct {
    id: TabId,
    child_process: ChildProcess,
    term: *vt.Terminal,
    term_arena: std.heap.ArenaAllocator,
    vt_stream: vt.Stream(VtHandler),
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    // UTF-16 high surrogate carried across two WM_CHAR calls. Per-tab
    // because keyboard shortcuts can switch tabs between the high and
    // low surrogate arriving.
    high_surrogate: ?u16 = null,
    // Set to true when close is initiated; further reader-thread
    // messages targeted at this tab id are dropped (but the handler
    // still returns the magic result so the reader's assertion holds).
    closing: bool = false,
    // Atomic stop flag read by the reader thread after each SendMessage.
    // Set together with CancelIoEx in the close sequence.
    reader_stop: std.atomic.Value(bool) = .init(false),
};

const Window = struct {
    hwnd: win32.HWND,
    bounds: ?WindowBounds = null,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    active_index: usize = 0,
    next_tab_id: TabId = 1,
    // window-scope interaction state (was in `global` previously)
    tracking_mouse: bool = false,
    mouse_in_scrollbar: bool = false,
    selection_fade: f32 = 0,
    mouse_capture: MouseCapture = .none,
    scrollbar_drag_offset: f32 = 0,
    resizing: bool = false,
    tab_bar_hover: ?TabHit = null,
    // True while a close-confirmation MessageBox is up. The modal pumps
    // messages, so a second WM_CLOSE (e.g. Alt+F4 hammering) or another
    // tab-bar 'x' click could otherwise stack a nested dialog.
    confirming_close: bool = false,
    // Coalesce paint requests: PTY data arrives in small chunks and each
    // chunk currently asks for a redraw. Without this, bursty output
    // (`find /`, `cat large.log`) submits one InvalidateRect syscall per
    // chunk; Windows still coalesces them into one WM_PAINT, but the
    // duplicate syscalls cost real CPU and contend on the message queue.
    // Flag is set on the first request after a paint and cleared inside
    // WM_PAINT before render() so events fired *during* render still
    // schedule a follow-up frame.
    render_pending: bool = false,

    fn active(self: *Window) *Tab {
        return self.tabs.items[self.active_index];
    }

    fn requestRender(self: *Window) void {
        if (self.render_pending) return;
        self.render_pending = true;
        win32.invalidateHwnd(self.hwnd);
    }

    fn findById(self: *Window, id: TabId) ?*Tab {
        for (self.tabs.items) |t| if (t.id == id) return t;
        return null;
    }

    fn findIndexById(self: *Window, id: TabId) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    fn onActiveChanged(self: *Window) void {
        self.selection_fade = 0;
        _ = win32.KillTimer(self.hwnd, TIMER_SELECTION_FADE);
        self.refreshWindowTitle();
        self.requestRender();
    }

    fn refreshWindowTitle(self: *Window) void {
        const tab = self.active();
        if (tab.title_len == 0) {
            _ = win32.SetWindowTextW(self.hwnd, win32.L("Mite"));
            return;
        }
        setWindowTitleFromUtf8(self.hwnd, tab.title_buf[0..tab.title_len]);
    }
};

const TabHit = union(enum) {
    none,
    activate: usize,
    close: usize,
    new_tab,
};

const MouseCapture = enum {
    none,
    scrollbar_drag,
    selecting,
};

const window_style = win32.WS_OVERLAPPEDWINDOW;
const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    .NOREDIRECTIONBITMAP = 1,
};

const WM_APP_CHILD_PROCESS_DATA = win32.WM_APP + 0;
const WM_APP_CHILD_PROCESS_DATA_RESULT = 0x1bb502b6;
const WM_APP_CLOSE_TAB = win32.WM_APP + 1;
const TIMER_SELECTION_FADE: usize = 1;

const ReadMsg = struct {
    tab_id: TabId,
    data: [*]const u8,
    len: u32,
};

const VtHandler = struct {
    const vt_mod = @import("vt");

    readonly: vt_mod.ReadonlyHandler,
    hwnd: win32.HWND,
    tab_id: TabId,

    pub fn vt(
        self: *VtHandler,
        comptime action: vt_mod.StreamAction.Tag,
        value: vt_mod.StreamAction.Value(action),
    ) void {
        switch (action) {
            .window_title => self.handleTitle(value.title),
            else => {},
        }
        self.readonly.vt(action, value);
    }

    pub fn deinit(self: *VtHandler) void {
        self.readonly.deinit();
    }

    fn handleTitle(self: *VtHandler, title: []const u8) void {
        if (global.window == null) return;
        const window = &global.window.?;
        const tab = window.findById(self.tab_id) orelse return;
        const n = @min(title.len, tab.title_buf.len);
        @memcpy(tab.title_buf[0..n], title[0..n]);
        tab.title_len = n;
        if (window.tabs.items[window.active_index] == tab) {
            setWindowTitleFromUtf8(self.hwnd, tab.title_buf[0..tab.title_len]);
        }
        window.requestRender();
    }
};

fn setWindowTitleFromUtf8(hwnd: win32.HWND, title: []const u8) void {
    const max_u16 = 500;
    var utf16_buf: [max_u16 + 1]u16 = undefined;
    const result = utf8ToUtf16Short(title, utf16_buf[0..max_u16]);
    if (result.replacement_count > 0) {
        std.log.warn("window title contained {} invalid utf-8 sequence(s)", .{result.replacement_count});
    }
    utf16_buf[result.len] = 0;
    if (win32.SetWindowTextW(hwnd, @ptrCast(&utf16_buf)) == 0) {
        std.log.err("SetWindowTextW failed, error={f}", .{win32.GetLastError()});
    }
}

const Utf8ToUtf16Result = struct {
    len: usize,
    replacement_count: usize,
    bytes_consumed: usize,
};

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

const global = struct {
    var icons: Icons = undefined;
    var renderer: d3d11 = undefined;
    var window: ?Window = null;
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var config: *const Config = undefined;
};

fn windowFromHwnd(hwnd: win32.HWND) *Window {
    std.debug.assert(hwnd == global.window.?.hwnd);
    return &global.window.?;
}

pub fn main() !void {
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

    // Load user config and convert font-family list to UTF-16 sentinel-terminated
    // strings. The UTF-16 storage is leaked: it lives for the lifetime of the
    // global renderer (i.e. the whole process).
    var config = Config.loadDefault(global.gpa.allocator());
    defer config.deinit();
    global.config = &config;
    const font_families_u16 = utf16FontFamilies(global.gpa.allocator(), config.font_families);
    const font_config: d3d11.FontConfig = .{
        .families = font_families_u16,
        .font_size_pt = config.font_size_pt,
    };
    global.renderer = d3d11.init(@max(dpi.x, dpi.y), font_config);
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
        null,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindow", win32.GetLastError());

    {
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
        const caption_color: u32 = 0x00120B0F;
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
            .dwFlags = 0x1 | 0x4,
            .fEnable = 1,
            .hRgnBlur = null,
            .fTransitionOnMaximized = 1,
        };
        const hr = win32.DwmEnableBlurBehindWindow(hwnd, &bb);
        if (hr < 0) std.log.warn("DwmEnableBlurBehindWindow failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    win32.DragAcceptFiles(hwnd, 1);
    // UIPI: when mite runs elevated, Explorer (a lower-integrity process)
    // can't post WM_DROPFILES / WM_COPYGLOBALDATA into our window unless
    // we explicitly allow them through the message filter. Without this,
    // drag-and-drop silently fails when "Run as administrator".
    _ = win32.ChangeWindowMessageFilterEx(hwnd, win32.WM_DROPFILES, win32.MSGFLT_ALLOW, null);
    _ = win32.ChangeWindowMessageFilterEx(hwnd, 0x0049, win32.MSGFLT_ALLOW, null); // WM_COPYGLOBALDATA

    if (0 == win32.UpdateWindow(hwnd)) win32.panicWin32("UpdateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    const HWND_TOP: ?win32.HWND = null;
    _ = win32.SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1 });
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);

    while (true) {
        const window: *Window = blk: {
            while (true) {
                if (global.window) |*w| {
                    if (w.tabs.items.len > 0) break :blk w;
                }
                var msg: win32.MSG = undefined;
                const result = win32.GetMessageW(&msg, null, 0, 0);
                if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
                if (result == 0) onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        };

        const n_tabs = window.tabs.items.len;
        var handles_buf: [MAX_TABS]win32.HANDLE = undefined;
        for (window.tabs.items, 0..) |t, i| {
            handles_buf[i] = t.child_process.process_handle;
        }
        const wait_result = win32.MsgWaitForMultipleObjectsEx(
            @intCast(n_tabs),
            &handles_buf,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 },
        );

        if (wait_result == @intFromEnum(win32.WAIT_FAILED)) {
            win32.panicWin32("MsgWaitForMultipleObjectsEx", win32.GetLastError());
        }
        const wait_io_completion: u32 = 0xc0;
        if (wait_result == wait_io_completion) {
            // No APCs queued today; defensive.
            continue;
        }
        if (wait_result < n_tabs) {
            // Tab i's child process exited.
            const i = wait_result;
            if (i < window.tabs.items.len) {
                const tab = window.tabs.items[i];
                if (!tab.closing) {
                    tab.closing = true;
                    _ = win32.PostMessageW(hwnd, WM_APP_CLOSE_TAB, tab.id, 0);
                }
            }
            flushMessages();
            continue;
        }
        // wait_result == n_tabs: messages available.
        std.debug.assert(wait_result == n_tabs);
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
            .dpi = .{ .x = 96, .y = 96 },
            .pos = .{
                .x = if (opt.left) |left| left else win32.CW_USEDEFAULT,
                .y = if (opt.top) |top| top else win32.CW_USEDEFAULT,
            },
            .size = .{ .cx = win32.CW_USEDEFAULT, .cy = win32.CW_USEDEFAULT },
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
    // Reserve one cell row for the tab bar before snapping.
    const tabbar_h: i32 = cell_size.cy;
    const bounding_client_size: win32.SIZE = .{
        .cx = (bounding_rect.right - bounding_rect.left) - client_inset.cx,
        .cy = (bounding_rect.bottom - bounding_rect.top) - client_inset.cy,
    };
    const grid_cy = @max(0, bounding_client_size.cy - tabbar_h);
    const trim: win32.SIZE = .{
        .cx = @mod(@max(bounding_client_size.cx - scrollbar_px, 0), cell_size.cx),
        .cy = @mod(grid_cy, cell_size.cy),
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
    var rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (0 == win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        0,
        window_style_ex,
        dpi,
    )) win32.panicWin32("AdjustWindowRect", win32.GetLastError());
    return .{ .cx = rect.right - rect.left, .cy = rect.bottom - rect.top };
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
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) win32.panicWin32("SetWindowPos", win32.GetLastError());
}

const SpecialKey = union(enum) {
    cursor: u8,
    tilde: u8,
    fkey14: u8,
};

fn vkToSpecial(wparam: win32.WPARAM) ?SpecialKey {
    return switch (wparam) {
        @intFromEnum(win32.VK_UP) => .{ .cursor = 'A' },
        @intFromEnum(win32.VK_DOWN) => .{ .cursor = 'B' },
        @intFromEnum(win32.VK_RIGHT) => .{ .cursor = 'C' },
        @intFromEnum(win32.VK_LEFT) => .{ .cursor = 'D' },
        @intFromEnum(win32.VK_HOME) => .{ .cursor = 'H' },
        @intFromEnum(win32.VK_END) => .{ .cursor = 'F' },
        @intFromEnum(win32.VK_INSERT) => .{ .tilde = 2 },
        @intFromEnum(win32.VK_DELETE) => .{ .tilde = 3 },
        @intFromEnum(win32.VK_PRIOR) => .{ .tilde = 5 },
        @intFromEnum(win32.VK_NEXT) => .{ .tilde = 6 },
        @intFromEnum(win32.VK_F1) => .{ .fkey14 = 'P' },
        @intFromEnum(win32.VK_F2) => .{ .fkey14 = 'Q' },
        @intFromEnum(win32.VK_F3) => .{ .fkey14 = 'R' },
        @intFromEnum(win32.VK_F4) => .{ .fkey14 = 'S' },
        @intFromEnum(win32.VK_F5) => .{ .tilde = 15 },
        @intFromEnum(win32.VK_F6) => .{ .tilde = 17 },
        @intFromEnum(win32.VK_F7) => .{ .tilde = 18 },
        @intFromEnum(win32.VK_F8) => .{ .tilde = 19 },
        @intFromEnum(win32.VK_F9) => .{ .tilde = 20 },
        @intFromEnum(win32.VK_F10) => .{ .tilde = 21 },
        @intFromEnum(win32.VK_F11) => .{ .tilde = 23 },
        @intFromEnum(win32.VK_F12) => .{ .tilde = 24 },
        else => null,
    };
}

fn xtermModifier() u8 {
    const shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
    const alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;
    const ctrl = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
    return 1 + @as(u8, if (shift) 1 else 0) + @as(u8, if (alt) 2 else 0) + @as(u8, if (ctrl) 4 else 0);
}

fn formatSpecialKey(buf: *[16]u8, key: SpecialKey, mod: u8) []const u8 {
    return switch (key) {
        .cursor => |final| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1b[{c}", .{final}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable,
        .tilde => |num| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1b[{d}~", .{num}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ num, mod }) catch unreachable,
        .fkey14 => |final| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1bO{c}", .{final}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable,
    };
}

fn computeGridCellCount(hwnd: win32.HWND, cs: win32.SIZE) GridPos {
    const client_size = win32.getClientSize(hwnd);
    const sb_px: i32 = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| sb_px;
    const grid_h = @max(0, client_size.cy - cs.cy); // reserve one row for tab bar
    return .{
        .col = @intCast(@max(1, @divTrunc(grid_w, cs.cx))),
        .row = @intCast(@max(1, @divTrunc(grid_h, cs.cy))),
    };
}

fn newTab(window: *Window) void {
    const launcher: ?*const Config.Launcher = if (global.config.launchers.len > 0)
        &global.config.launchers[0]
    else
        null;
    newTabWithLauncher(window, launcher);
}

fn newTabWithLauncher(window: *Window, launcher: ?*const Config.Launcher) void {
    if (window.tabs.items.len >= MAX_TABS) {
        std.log.warn("tab limit reached ({}); not opening new tab", .{MAX_TABS});
        return;
    }
    const cs = global.renderer.cell_size;
    const cell_count = computeGridCellCount(window.hwnd, cs);

    const tab = global.gpa.allocator().create(Tab) catch oom(error.OutOfMemory);
    tab.* = .{
        .id = window.next_tab_id,
        .child_process = undefined,
        .term = undefined,
        .term_arena = .init(std.heap.page_allocator),
        .vt_stream = undefined,
    };
    window.next_tab_id += 1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var application_name: ?[*:0]const u16 = null;
    var command_line: ?[*:0]u16 = null;
    var working_directory: ?[*:0]const u16 = null;
    if (launcher) |L| {
        const cmd_u16 = utf16ZAllocMut(arena.allocator(), L.command_line) catch |e| oom(e);
        command_line = cmd_u16;
        if (L.working_directory.len > 0) {
            const cwd_u16 = utf16ZAllocConst(arena.allocator(), L.working_directory) catch |e| oom(e);
            working_directory = cwd_u16;
        }
    } else {
        application_name = win32.L("C:\\Windows\\System32\\cmd.exe");
    }

    var err: Error = undefined;
    tab.child_process = ChildProcess.startConPtyWin32(
        &err,
        arena.allocator(),
        application_name,
        command_line,
        working_directory,
        window.hwnd,
        WM_APP_CHILD_PROCESS_DATA,
        WM_APP_CHILD_PROCESS_DATA_RESULT,
        cell_count,
        tab.id,
        &tab.reader_stop,
    ) catch {
        // User-configurable launchers can fail (bad path, missing exe, etc.);
        // surface and abandon this tab rather than crashing the whole app.
        // The fallback cmd.exe path (launcher == null) still panics on failure
        // because that's a system-level problem.
        if (launcher != null) {
            std.log.err("launcher '{s}' failed to start: {f}", .{ launcher.?.label, err });
            tab.term_arena.deinit();
            global.gpa.allocator().destroy(tab);
            return;
        }
        std.debug.panic("{f}", .{err});
    };

    tab.term = std.heap.page_allocator.create(vt.Terminal) catch oom(error.OutOfMemory);
    tab.term.* = vt.Terminal.init(tab.term_arena.allocator(), .{
        .cols = cell_count.col,
        .rows = cell_count.row,
    }) catch |e| std.debug.panic("Terminal.init: {}", .{e});

    tab.vt_stream = .initAlloc(global.gpa.allocator(), .{
        .readonly = tab.term.vtHandler(),
        .hwnd = window.hwnd,
        .tab_id = tab.id,
    });

    window.tabs.append(global.gpa.allocator(), tab) catch oom(error.OutOfMemory);
    window.active_index = window.tabs.items.len - 1;
    window.onActiveChanged();
}

const SshHost = struct {
    name: []const u8,
};

// Parses ~/.ssh/config and returns concrete host aliases. Wildcards (`*`,
// `?`) and negations (`!`) are skipped — they're patterns, not connectable
// targets. Include directives are not followed; keep it to the top-level
// file to avoid recursive globbing.
fn loadSshHosts(arena: std.mem.Allocator) []const SshHost {
    return loadSshHostsErr(arena) catch |err| {
        std.log.debug("ssh config: load failed: {s}", .{@errorName(err)});
        return &.{};
    };
}

fn loadSshHostsErr(arena: std.mem.Allocator) ![]const SshHost {
    const home = std.process.getEnvVarOwned(arena, "USERPROFILE") catch return &.{};
    const path = try std.fs.path.join(arena, &.{ home, ".ssh", "config" });
    const raw = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const bytes = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;

    var hosts: std.ArrayListUnmanaged(SshHost) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len < 5) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..4], "Host")) continue;
        // Require whitespace after "Host" so "HostName" doesn't match.
        if (line[4] != ' ' and line[4] != '\t') continue;
        const rest = std.mem.trim(u8, line[4..], " \t");
        var nit = std.mem.tokenizeAny(u8, rest, " \t");
        while (nit.next()) |name| {
            if (name[0] == '#') break; // trailing comment
            if (std.mem.indexOfAny(u8, name, "*?!\"") != null) continue;
            if (!std.unicode.utf8ValidateSlice(name)) continue;
            try hosts.append(arena, .{ .name = try arena.dupe(u8, name) });
        }
    }
    return hosts.toOwnedSlice(arena);
}

fn showLauncherMenu(window: *Window, client_x: i32, client_y: i32) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const launchers = global.config.launchers;
    const ssh_hosts = loadSshHosts(a);
    if (launchers.len == 0 and ssh_hosts.len == 0) return;

    const menu = win32.CreatePopupMenu() orelse {
        std.log.err("CreatePopupMenu failed, error={f}", .{win32.GetLastError()});
        return;
    };
    defer _ = win32.DestroyMenu(menu);

    for (launchers, 0..) |L, i| {
        const label_u16 = utf16ZAllocConst(a, L.label) catch |e| oom(e);
        const id: usize = i + 1; // 0 reserved for "cancelled"
        if (0 == win32.AppendMenuW(menu, win32.MF_STRING, id, label_u16)) {
            std.log.err("AppendMenuW failed, error={f}", .{win32.GetLastError()});
            return;
        }
    }

    if (launchers.len > 0 and ssh_hosts.len > 0) {
        _ = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null);
    }

    for (ssh_hosts, 0..) |h, i| {
        const label = std.fmt.allocPrint(a, "[SSH: {s}]", .{h.name}) catch |e| oom(e);
        const label_u16 = utf16ZAllocConst(a, label) catch |e| oom(e);
        const id: usize = launchers.len + i + 1;
        if (0 == win32.AppendMenuW(menu, win32.MF_STRING, id, label_u16)) {
            std.log.err("AppendMenuW failed, error={f}", .{win32.GetLastError()});
            return;
        }
    }

    var pt: win32.POINT = .{ .x = client_x, .y = client_y };
    _ = win32.ClientToScreen(window.hwnd, &pt);

    // MSDN-recommended quirk: ensure foreground so the menu dismisses
    // correctly when the user clicks outside it.
    _ = win32.SetForegroundWindow(window.hwnd);

    const flags = win32.TRACK_POPUP_MENU_FLAGS{
        .RETURNCMD = 1,
        .RIGHTBUTTON = 1,
    };
    const selected = win32.TrackPopupMenu(menu, flags, pt.x, pt.y, 0, window.hwnd, null);
    if (selected <= 0) return;
    const idx: usize = @intCast(selected - 1);
    if (idx < launchers.len) {
        newTabWithLauncher(window, &launchers[idx]);
        return;
    }
    const ssh_idx = idx - launchers.len;
    if (ssh_idx >= ssh_hosts.len) return;
    // `--` so hostnames starting with `-` can't be reinterpreted as ssh options
    // (e.g. `-oProxyCommand=...`).
    const cmd = std.fmt.allocPrint(
        a,
        "ssh -- {s}",
        .{ssh_hosts[ssh_idx].name},
    ) catch |e| oom(e);
    const launcher: Config.Launcher = .{
        .label = ssh_hosts[ssh_idx].name,
        .command_line = cmd,
        .working_directory = "",
    };
    newTabWithLauncher(window, &launcher);
}

fn switchToTab(window: *Window, new_idx: usize) void {
    if (new_idx == window.active_index) return;
    if (new_idx >= window.tabs.items.len) return;
    window.active_index = new_idx;
    window.onActiveChanged();
}

fn closeTabByIndex(window: *Window, idx: usize) void {
    if (idx >= window.tabs.items.len) return;
    const tab = window.tabs.items[idx];
    if (tab.closing) return;
    tab.closing = true;
    _ = win32.PostMessageW(window.hwnd, WM_APP_CLOSE_TAB, tab.id, 0);
}

fn confirmYesNo(hwnd: win32.HWND, text: [*:0]const u16, caption: [*:0]const u16) bool {
    const result = win32.MessageBoxW(hwnd, text, caption, .{
        .YESNO = 1,
        .ICONQUESTION = 1,
        // Default to "No" so an accidental Enter doesn't close.
        .DEFBUTTON2 = 1,
    });
    return result == win32.IDYES;
}

fn confirmAndCloseTab(window: *Window, tab_id: TabId) void {
    if (window.confirming_close) return;
    window.confirming_close = true;
    defer window.confirming_close = false;
    if (!confirmYesNo(
        window.hwnd,
        win32.L("Close this tab?"),
        win32.L("Mite"),
    )) return;
    // Re-look the index: the modal's nested message pump may have
    // shifted indices (or destroyed the target tab entirely).
    if (window.findIndexById(tab_id)) |idx| {
        closeTabByIndex(window, idx);
    }
}

fn destroyTab(window: *Window, tab: *Tab) void {
    // Mark closing so any in-flight reader-thread SendMessage during the
    // pump-while-wait below drops its payload (the handler still returns
    // the magic value). Also unhook from window.tabs before any pump or
    // free: queued WM_APP_CLOSE_TAB for this tab won't re-enter
    // destroyTab once findById returns null, and the eventual free can't
    // be observed via findIndexById from a re-entrant message.
    tab.closing = true;
    const removed_idx_opt = window.findIndexById(tab.id);
    if (removed_idx_opt) |idx| {
        _ = window.tabs.orderedRemove(idx);
        if (window.tabs.items.len == 0) {
            window.active_index = 0;
        } else if (window.active_index >= window.tabs.items.len) {
            window.active_index = window.tabs.items.len - 1;
        } else if (window.active_index > idx) {
            window.active_index -= 1;
        }
    }

    tab.reader_stop.store(true, .release);
    _ = win32.CancelIoEx(tab.child_process.read, null);

    const thread_handle: win32.HANDLE = tab.child_process.thread.getHandle();
    while (true) {
        var handles = [_]win32.HANDLE{thread_handle};
        const r = win32.MsgWaitForMultipleObjects(
            1,
            &handles,
            0,
            win32.INFINITE,
            win32.QS_SENDMESSAGE,
        );
        if (r == 0) break; // thread exited
        if (r == 1) {
            var msg: win32.MSG = undefined;
            while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) > 0) {
                if (msg.message == win32.WM_QUIT) {
                    _ = win32.PostQuitMessage(@intCast(msg.wParam));
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            continue;
        }
        if (r == @intFromEnum(win32.WAIT_FAILED)) {
            win32.panicWin32("MsgWaitForMultipleObjects (destroyTab)", win32.GetLastError());
        }
    }

    tab.child_process.closePty();
    tab.child_process.thread.join();
    win32.closeHandle(tab.child_process.read);
    win32.closeHandle(tab.child_process.job);
    win32.closeHandle(tab.child_process.process_handle);

    tab.vt_stream.deinit();
    tab.term_arena.deinit();
    std.heap.page_allocator.destroy(tab.term);
    global.gpa.allocator().destroy(tab);

    if (window.tabs.items.len == 0) {
        win32.PostQuitMessage(0);
        return;
    }
    window.onActiveChanged();
}

fn writeToActivePty(window: *Window, bytes: []const u8) void {
    const tab = window.active();
    const pty = tab.child_process.pty orelse {
        std.log.err("write: pty closed for tab {}", .{tab.id});
        return;
    };
    pty.writeFlushAll(bytes) catch |e| std.log.err(
        "write to pty failed: {s}",
        .{@errorName(e)},
    );
}

const tab_bar_bg: u24 = 0x1f1f1f;
const tab_bar_fg: u24 = 0x808080;
const tab_active_bg: u24 = 0x2a2a2a;
const tab_active_fg: u24 = 0xffffff;
const tab_hover_bg: u24 = 0x252525;
const new_tab_button_fg: u24 = 0xc8c4d0;

const TabLayoutEntry = struct {
    tab_index: usize,
    col_start: usize,
    col_end: usize, // exclusive
    close_col: usize, // column index of close 'x' (relative to total grid)
};

const TabBarLayout = struct {
    entries_buf: [MAX_TABS]TabLayoutEntry,
    entries_len: usize,
    new_tab_col: ?usize,

    fn entries(self: *const TabBarLayout) []const TabLayoutEntry {
        return self.entries_buf[0..self.entries_len];
    }
};

fn layoutTabBar(window: *Window, total_cols: usize) TabBarLayout {
    var layout: TabBarLayout = .{ .entries_buf = undefined, .entries_len = 0, .new_tab_col = null };
    if (total_cols == 0 or window.tabs.items.len == 0) return layout;

    const new_tab_w: usize = 3; // " + "
    const min_tab_w: usize = 6;
    const ideal_tab_w: usize = 20;

    const usable_for_tabs = if (total_cols > new_tab_w) total_cols - new_tab_w else 0;
    const n = window.tabs.items.len;
    var tab_w = ideal_tab_w;
    if (tab_w * n > usable_for_tabs) tab_w = usable_for_tabs / n;
    if (tab_w < min_tab_w) tab_w = min_tab_w;

    var col: usize = 0;
    for (window.tabs.items, 0..) |_, i| {
        if (col >= total_cols) break;
        var end = col + tab_w;
        if (end > total_cols) end = total_cols;
        if (end - col < 3) break;
        const close_col = end - 2;
        if (layout.entries_len >= layout.entries_buf.len) break;
        layout.entries_buf[layout.entries_len] = .{
            .tab_index = i,
            .col_start = col,
            .col_end = end,
            .close_col = close_col,
        };
        layout.entries_len += 1;
        col = end;
    }
    if (col + new_tab_w <= total_cols) {
        layout.new_tab_col = col + 1;
    }
    return layout;
}

fn hitTestTabBar(window: *Window, total_cols: usize, mouse_x: i32, cs_x: i32) TabHit {
    const col: usize = @intCast(@max(0, @divTrunc(mouse_x, cs_x)));
    const layout = layoutTabBar(window, total_cols);
    for (layout.entries()) |e| {
        if (col >= e.col_start and col < e.col_end) {
            if (col == e.close_col) return .{ .close = e.tab_index };
            return .{ .activate = e.tab_index };
        }
    }
    if (layout.new_tab_col) |c| {
        if (col == c) return .new_tab;
    }
    return .none;
}

/// When a title looks like a file/path (contains `\` or `/`), strip
/// everything up to and including the last separator so only the
/// basename is shown. Titles without separators (e.g. "cmd", "node")
/// are returned unchanged.
fn displayTitle(title: []const u8) []const u8 {
    var i: usize = title.len;
    while (i > 0) {
        i -= 1;
        if (title[i] == '\\' or title[i] == '/') {
            return title[i + 1 ..];
        }
    }
    return title;
}

fn buildTabBarRow(window: *Window, total_cols: usize, row: []d3d11.TabBarCell) void {
    const bg_default = d3d11.TabBarCell.rgba(tab_bar_bg);
    const fg_default = d3d11.TabBarCell.rgba(tab_bar_fg);
    for (row) |*c| c.* = .{ .codepoint = ' ', .bg = bg_default, .fg = fg_default };

    const layout = layoutTabBar(window, total_cols);
    for (layout.entries()) |e| {
        const is_active = e.tab_index == window.active_index;
        const tab = window.tabs.items[e.tab_index];
        const close_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .close => |idx| idx == e.tab_index,
            else => false,
        } else false;
        const tab_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .activate => |idx| idx == e.tab_index,
            else => false,
        } else false;
        const bg_u24: u24 = if (is_active) tab_active_bg else if (tab_hovered) tab_hover_bg else tab_bar_bg;
        const fg_u24: u24 = if (is_active) tab_active_fg else tab_bar_fg;
        const cell_bg = d3d11.TabBarCell.rgba(bg_u24);
        const cell_fg = d3d11.TabBarCell.rgba(fg_u24);

        var col = e.col_start;
        while (col < e.col_end) : (col += 1) {
            row[col] = .{ .codepoint = ' ', .bg = cell_bg, .fg = cell_fg };
        }

        // Title text, leaving room for a leading space and trailing " x"
        const title_start = e.col_start + 1;
        const title_end_inclusive = if (e.close_col > 1) e.close_col - 2 else e.col_start;
        const max_title_cols = if (title_end_inclusive >= title_start) title_end_inclusive - title_start + 1 else 0;

        const title = displayTitle(tab.title_buf[0..tab.title_len]);
        var title_cols_written: usize = 0;
        var i: usize = 0;
        while (i < title.len and title_cols_written < max_title_cols) {
            const seq_len = std.unicode.utf8ByteSequenceLength(title[i]) catch {
                row[title_start + title_cols_written] = .{ .codepoint = '?', .bg = cell_bg, .fg = cell_fg };
                title_cols_written += 1;
                i += 1;
                continue;
            };
            if (i + seq_len > title.len) break;
            const cp = std.unicode.utf8Decode(title[i .. i + seq_len]) catch {
                row[title_start + title_cols_written] = .{ .codepoint = '?', .bg = cell_bg, .fg = cell_fg };
                title_cols_written += 1;
                i += seq_len;
                continue;
            };
            row[title_start + title_cols_written] = .{ .codepoint = @intCast(cp), .bg = cell_bg, .fg = cell_fg };
            title_cols_written += 1;
            i += seq_len;
        }
        // Pad title area with tab id digit if no title yet
        if (tab.title_len == 0 and max_title_cols > 0) {
            var idbuf: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&idbuf, "tab {d}", .{e.tab_index + 1}) catch idbuf[0..0];
            const lim = @min(s.len, max_title_cols);
            for (s[0..lim], 0..) |ch, k| {
                row[title_start + k] = .{ .codepoint = ch, .bg = cell_bg, .fg = cell_fg };
            }
        }

        // Close button '×'
        if (e.close_col < e.col_end) {
            const close_fg_u24: u24 = if (close_hovered) 0xff5555 else fg_u24;
            row[e.close_col] = .{
                .codepoint = 'x',
                .bg = cell_bg,
                .fg = d3d11.TabBarCell.rgba(close_fg_u24),
            };
        }
    }
    if (layout.new_tab_col) |c| {
        const hover = if (window.tab_bar_hover) |h| h == .new_tab else false;
        const fg_u24: u24 = if (hover) 0xffffff else new_tab_button_fg;
        row[c] = .{
            .codepoint = '+',
            .bg = d3d11.TabBarCell.rgba(tab_bar_bg),
            .fg = d3d11.TabBarCell.rgba(fg_u24),
        };
    }
}

fn renderWindow(window: *Window) void {
    const cs = global.renderer.cell_size;
    const cell_count = computeGridCellCount(window.hwnd, cs);
    var row_buf: [4096]d3d11.TabBarCell = undefined;
    const total_cols = cell_count.col;
    if (total_cols > row_buf.len) return;
    buildTabBarRow(window, total_cols, row_buf[0..total_cols]);
    global.renderer.render(
        window.hwnd,
        window.active().term,
        row_buf[0..total_cols],
        window.resizing,
        window.mouse_in_scrollbar,
        if (window.mouse_capture == .selecting) 1.0 else window.selection_fade,
    );
}

fn isCtrlDown() bool {
    return win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
}
fn isShiftDown() bool {
    return win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
}

fn handleShortcut(window: *Window, wparam: win32.WPARAM) bool {
    const ctrl = isCtrlDown();
    const shift = isShiftDown();
    if (!ctrl) return false;
    if (!shift) {
        switch (wparam) {
            @intFromEnum(win32.VK_T) => {
                newTab(window);
                return true;
            },
            @intFromEnum(win32.VK_W) => {
                // tabs can be empty when WM_KEYDOWN is dispatched from a
                // nested pump during teardown; bounds-check before active().
                if (window.tabs.items.len > 0) {
                    confirmAndCloseTab(window, window.active().id);
                }
                return true;
            },
            @intFromEnum(win32.VK_TAB) => {
                const n = window.tabs.items.len;
                if (n > 1) switchToTab(window, (window.active_index + 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_PRIOR) => {
                const n = window.tabs.items.len;
                if (n > 1) switchToTab(window, (window.active_index + n - 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_NEXT) => {
                const n = window.tabs.items.len;
                if (n > 1) switchToTab(window, (window.active_index + 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_1)...@intFromEnum(win32.VK_9) => {
                const digit: usize = wparam - @intFromEnum(win32.VK_1);
                if (digit < window.tabs.items.len) switchToTab(window, digit);
                return true;
            },
            else => return false,
        }
    } else {
        if (wparam == @intFromEnum(win32.VK_TAB)) {
            const n = window.tabs.items.len;
            if (n > 1) switchToTab(window, (window.active_index + n - 1) % n);
            return true;
        }
    }
    return false;
}

const GridPos = struct {
    col: u16,
    row: u16,
};

// Pixel position of the top-left of the active tab's cursor cell, including
// the tab-bar offset (one cell row at the top).
fn caretPixelPos(window: *Window) ?win32.POINT {
    if (window.tabs.items.len == 0) return null;
    const screen = window.active().term.screens.active;
    const cs = global.renderer.cell_size;
    const x: i32 = @as(i32, @intCast(screen.cursor.x)) * cs.cx;
    const y: i32 = (@as(i32, @intCast(screen.cursor.y)) + 1) * cs.cy;
    return .{ .x = x, .y = y };
}

fn setImeCompositionPos(window: *Window) void {
    const caret = caretPixelPos(window) orelse return;
    const himc = win32.ImmGetContext(window.hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(window.hwnd, himc);
    var comp: win32.COMPOSITIONFORM = .{
        .dwStyle = win32.CFS_POINT,
        .ptCurrentPos = caret,
        .rcArea = std.mem.zeroes(win32.RECT),
    };
    _ = win32.ImmSetCompositionWindow(himc, &comp);
}

fn setImeCandidatePos(window: *Window) void {
    const caret = caretPixelPos(window) orelse return;
    const cs = global.renderer.cell_size;
    const himc = win32.ImmGetContext(window.hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(window.hwnd, himc);
    // CFS_EXCLUDE: anchor the candidate list at ptCurrentPos and tell the IME
    // to avoid covering rcArea (the caret cell). The IME flips above/below
    // automatically when the caret is near the screen edge.
    var cand: win32.CANDIDATEFORM = .{
        .dwIndex = 0,
        .dwStyle = win32.CFS_EXCLUDE,
        .ptCurrentPos = caret,
        .rcArea = .{
            .left = caret.x,
            .top = caret.y,
            .right = caret.x + cs.cx,
            .bottom = caret.y + cs.cy,
        },
    };
    _ = win32.ImmSetCandidateWindow(himc, &cand);
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.window == null);
            global.window = .{ .hwnd = hwnd };
            const window = &global.window.?;
            newTab(window);
            return 0;
        },
        win32.WM_CLOSE => {
            if (global.window) |*window| {
                if (window.confirming_close) return 0;
                window.confirming_close = true;
                defer window.confirming_close = false;
                if (!confirmYesNo(
                    window.hwnd,
                    win32.L("Close window and all tabs?"),
                    win32.L("Mite"),
                )) return 0;
                while (window.tabs.items.len > 0) {
                    const tab = window.tabs.items[0];
                    destroyTab(window, tab);
                }
            } else {
                win32.PostQuitMessage(0);
            }
            return 0;
        },
        win32.WM_DESTROY => {
            if (global.window) |*window| {
                while (window.tabs.items.len > 0) {
                    const tab = window.tabs.items[0];
                    destroyTab(window, tab);
                }
            } else {
                win32.PostQuitMessage(0);
            }
            return 0;
        },
        WM_APP_CLOSE_TAB => {
            const window = windowFromHwnd(hwnd);
            const tab_id: TabId = @intCast(wparam);
            const tab = window.findById(tab_id) orelse return 0;
            destroyTab(window, tab);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const window = windowFromHwnd(hwnd);
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const cs = global.renderer.cell_size;
            const client_size = win32.getClientSize(hwnd);
            const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
            const grid_w = client_size.cx -| @as(i32, sb_px);

            // Tab bar gets first dibs on a fresh click.
            if (mouse_y < cs.cy) {
                const cell_count = computeGridCellCount(hwnd, cs);
                const hit = hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
                switch (hit) {
                    .none => {},
                    .activate => |idx| switchToTab(window, idx),
                    .close => |idx| {
                        if (idx >= window.tabs.items.len) return 0;
                        confirmAndCloseTab(window, window.tabs.items[idx].id);
                    },
                    .new_tab => newTab(window),
                }
                return 0;
            }

            // Below tab bar: existing scrollbar / selection logic with y offset.
            const grid_mouse_y = mouse_y - cs.cy;
            if (mouse_x >= grid_w) {
                const screen = window.active().term.screens.active;
                const sb = screen.pages.scrollbar();
                if (sb.total > sb.len) {
                    const win_h: f32 = @floatFromInt(client_size.cy - cs.cy);
                    const min_track_height: f32 = 20.0;
                    const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                    const max_offset = sb.total - sb.len;
                    const track_y = @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);
                    const mouse_yf: f32 = @floatFromInt(grid_mouse_y);

                    if (mouse_yf >= track_y and mouse_yf < track_y + track_height) {
                        window.mouse_capture = .scrollbar_drag;
                        window.scrollbar_drag_offset = mouse_yf - track_y;
                    } else {
                        window.mouse_capture = .scrollbar_drag;
                        window.scrollbar_drag_offset = track_height / 2.0;
                        scrollbarDragTo(window.active(), mouse_yf - track_height / 2.0, win_h, track_height);
                    }
                    _ = win32.SetCapture(hwnd);
                    window.requestRender();
                }
            } else {
                const screen = window.active().term.screens.active;
                window.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
                const row: usize = @intCast(@divTrunc(@max(grid_mouse_y, 0), cs.cy));
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                    screen.clearSelection();
                    const sel = vt.Selection.init(pin, pin, false);
                    screen.select(sel) catch oom(error.OutOfMemory);
                    window.mouse_capture = .selecting;
                    _ = win32.SetCapture(hwnd);
                    window.requestRender();
                }
            }
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const window = windowFromHwnd(hwnd);
            switch (window.mouse_capture) {
                .none => {},
                .scrollbar_drag => {
                    window.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    window.requestRender();
                },
                .selecting => {
                    window.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                    const screen = window.active().term.screens.active;
                    if (screen.selection) |sel| {
                        const alloc = global.gpa.allocator();
                        const text = screen.selectionString(alloc, .{ .sel = sel }) catch oom(error.OutOfMemory);
                        defer alloc.free(text);
                        if (text.len > 0) {
                            copyToClipboard(hwnd, text);
                        }
                        window.selection_fade = 1.0;
                        _ = win32.SetTimer(hwnd, TIMER_SELECTION_FADE, 16, null);
                    }
                },
            }
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEWHEEL => {
            const window = windowFromHwnd(hwnd);
            const delta: i16 = @bitCast(win32.hiword(wparam));
            const scroll_lines: isize = if (delta > 0) -3 else 3;
            const screen = window.active().term.screens.active;
            screen.scroll(.{ .delta_row = scroll_lines });
            window.requestRender();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const window = windowFromHwnd(hwnd);
            if (!window.tracking_mouse) {
                var tme = win32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = win32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = win32.TrackMouseEvent(&tme);
                window.tracking_mouse = true;
            }
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const cs = global.renderer.cell_size;
            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd)));

            // Capture in progress takes priority over tab-bar hover.
            if (window.mouse_capture != .none) {
                const grid_mouse_y = mouse_y - cs.cy;
                switch (window.mouse_capture) {
                    .none => {},
                    .scrollbar_drag => {
                        const win_h: f32 = @floatFromInt(client_size.cy - cs.cy);
                        const sb = window.active().term.screens.active.pages.scrollbar();
                        const min_track_height: f32 = 20.0;
                        const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                        scrollbarDragTo(window.active(), @as(f32, @floatFromInt(grid_mouse_y)) - window.scrollbar_drag_offset, win_h, track_height);
                        window.requestRender();
                    },
                    .selecting => {
                        const screen = window.active().term.screens.active;
                        const clamped_x: i32 = @max(0, @min(mouse_x, grid_w - 1));
                        const clamped_y: i32 = @max(0, @min(grid_mouse_y, client_size.cy - cs.cy - 1));
                        const col: usize = @intCast(@divTrunc(clamped_x, cs.cx));
                        const row: usize = @intCast(@divTrunc(clamped_y, cs.cy));
                        if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                            if (screen.selection) |*sel| {
                                sel.endPtr().* = pin;
                                window.requestRender();
                            }
                        }
                    },
                }
                return 0;
            }

            // Tab bar hover
            if (mouse_y < cs.cy) {
                const cell_count = computeGridCellCount(hwnd, cs);
                const hit = hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
                if (!hitEql(window.tab_bar_hover, hit)) {
                    window.tab_bar_hover = if (hit == .none) null else hit;
                    window.requestRender();
                }
                if (window.mouse_in_scrollbar) {
                    window.mouse_in_scrollbar = false;
                    window.requestRender();
                }
                return 0;
            } else if (window.tab_bar_hover != null) {
                window.tab_bar_hover = null;
                window.requestRender();
            }

            const in_scrollbar = mouse_x >= grid_w;
            if (in_scrollbar != window.mouse_in_scrollbar) {
                window.mouse_in_scrollbar = in_scrollbar;
                window.requestRender();
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            const window = windowFromHwnd(hwnd);
            window.tracking_mouse = false;
            if (window.mouse_in_scrollbar) {
                window.mouse_in_scrollbar = false;
                window.requestRender();
            }
            if (window.tab_bar_hover != null) {
                window.tab_bar_hover = null;
                window.requestRender();
            }
            return 0;
        },
        win32.WM_DISPLAYCHANGE => {
            const window = windowFromHwnd(hwnd);
            window.requestRender();
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            const window = windowFromHwnd(hwnd);
            window.resizing = false;
            window.requestRender();
            return 0;
        },
        win32.WM_SIZING => {
            const window = windowFromHwnd(hwnd);
            if (!window.resizing) {
                window.resizing = true;
                window.requestRender();
            }
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = win32.dpiFromHwnd(hwnd);
            const new_rect = calcWindowRect(dpi, rect.*, wparam, global.renderer.cell_size);
            window.bounds = .{
                .token = new_rect,
                .rect = rect.*,
            };
            rect.* = new_rect;
            return 0;
        },
        win32.WM_WINDOWPOSCHANGED => {
            const window = windowFromHwnd(hwnd);
            const cell_count = computeGridCellCount(hwnd, global.renderer.cell_size);

            for (window.tabs.items) |tab| {
                tab.term.resize(tab.term_arena.allocator(), cell_count.col, cell_count.row) catch |e|
                    std.debug.panic("Terminal.resize: {}", .{e});
                var resize_err: Error = undefined;
                tab.child_process.resize(&resize_err, cell_count) catch std.debug.panic("{f}", .{resize_err});
            }
            // Clear before render so requests fired during render() still
            // schedule a follow-up frame. Skip the unconditional
            // ValidateRect when a new request landed during render —
            // otherwise it would cancel the WM_PAINT requestRender just
            // posted, leaving render_pending stuck true and the next
            // frame lost.
            window.render_pending = false;
            renderWindow(window);
            if (!window.render_pending) {
                _ = win32.ValidateRect(hwnd, null);
            }
            return 0;
        },
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            defer win32.endPaint(hwnd, &ps);

            const window = windowFromHwnd(hwnd);
            window.render_pending = false;
            renderWindow(window);
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const cs = global.renderer.cell_size;

            const client_size = win32.getClientSize(hwnd);
            const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(current_dpi));
            const grid_h_cur = @max(0, client_size.cy - cs.cy);
            const col_count = @max(1, @divTrunc(grid_w, cs.cx));
            const row_count = @max(1, @divTrunc(grid_h_cur, cs.cy));
            if (col_count != 1) std.debug.assert(grid_w == col_count * cs.cx);
            if (row_count != 1) std.debug.assert(grid_h_cur == row_count * cs.cy);

            const new_cs = global.renderer.cellSizeForDpi(new_dpi);
            const new_client_w = col_count * new_cs.cx + @as(i32, d3d11.scrollbarWidth(new_dpi));
            const new_grid_h = row_count * new_cs.cy;
            const new_client_h = new_grid_h + new_cs.cy; // add new tab bar height
            const new_inset = getClientInset(new_dpi);
            inout_size.* = .{
                .cx = new_client_w + new_inset.cx,
                .cy = new_client_h + new_inset.cy,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const window = windowFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
            if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
            global.renderer.updateDpi(dpi);
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            window.bounds = null;
            window.requestRender();
            return 0;
        },
        win32.WM_KEYDOWN => {
            const window = windowFromHwnd(hwnd);

            // Shortcut interception first.
            if (handleShortcut(window, wparam)) return 0;

            const tab = window.active();
            const pty = tab.child_process.pty orelse {
                std.log.err("pty closed", .{});
                return 0;
            };
            // Ctrl+Shift+V or Shift+Insert: paste from clipboard
            if ((wparam == @intFromEnum(win32.VK_V) and isCtrlDown() and isShiftDown()) or
                (wparam == @intFromEnum(win32.VK_INSERT) and isShiftDown()))
            {
                pasteClipboard(hwnd, tab);
                return 0;
            }

            const screen = tab.term.screens.active;
            if (screen.selection != null) {
                screen.clearSelection();
                window.selection_fade = 0;
                _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                window.requestRender();
            }

            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                window.requestRender();
            }

            var key_buf: [16]u8 = undefined;
            const seq: ?[]const u8 = seq_blk: {
                if (wparam == @intFromEnum(win32.VK_BACK)) break :seq_blk "\x7f";
                if (wparam == @intFromEnum(win32.VK_TAB)) {
                    break :seq_blk if (isShiftDown()) "\x1b[Z" else null;
                }
                if (vkToSpecial(wparam)) |key| {
                    break :seq_blk formatSpecialKey(&key_buf, key, xtermModifier());
                }
                break :seq_blk null;
            };
            if (seq) |s| {
                pty.writeFlushAll(s) catch |e| std.log.err(
                    "write to pty failed: {s}",
                    .{@errorName(e)},
                );
            }
            return 0;
        },
        win32.WM_CHAR => {
            const window = windowFromHwnd(hwnd);
            const tab = window.active();
            const pty = tab.child_process.pty orelse {
                std.log.err("pty closed", .{});
                return 0;
            };
            const screen = tab.term.screens.active;
            if (!screen.viewportIsBottom()) {
                screen.scroll(.active);
                window.requestRender();
            }
            const char: u16 = std.math.cast(u16, wparam) orelse {
                std.log.warn("unexpected WM_CHAR wparam: {}", .{wparam});
                return 0;
            };
            const ctrl = isCtrlDown();
            const shift = isShiftDown();
            // Backspace is handled in WM_KEYDOWN (sends \x7f)
            if (char == 0x08) return 0;
            // Shift+Tab is handled in WM_KEYDOWN (sends \x1b[Z); plain Tab falls through as \t
            if (char == 0x09 and shift) return 0;
            // Ctrl+Tab is a tab-switch shortcut; suppress the resulting \t.
            if (char == 0x09 and ctrl) return 0;
            // Suppress Ctrl+Shift+V control character (paste is handled in WM_KEYDOWN)
            if (char == 0x16 and shift) return 0;
            // Ctrl+T (0x14) and Ctrl+W (0x17) are tab shortcuts; suppress.
            if (ctrl and !shift) {
                if (char == 0x14 or char == 0x17) return 0;
                if (char >= '1' and char <= '9') return 0;
            }
            if (std.unicode.utf16IsHighSurrogate(char)) {
                tab.high_surrogate = char;
                return 0;
            }
            const codepoint: u21 = blk: {
                if (tab.high_surrogate) |high| {
                    tab.high_surrogate = null;
                    if (std.unicode.utf16IsLowSurrogate(char)) {
                        break :blk std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, char }) catch return 0;
                    }
                }
                break :blk @intCast(char);
            };
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
            pty.writeFlushAll(utf8_buf[0..len]) catch |e| std.log.err(
                "write to pty failed: {s}",
                .{@errorName(e)},
            );
            return 0;
        },
        win32.WM_DROPFILES => {
            const window = windowFromHwnd(hwnd);
            if (wparam == 0) return 0;
            const hdrop: win32.HDROP = @ptrFromInt(wparam);
            onDropFiles(window, hdrop);
            return 0;
        },
        win32.WM_IME_STARTCOMPOSITION => {
            const window = windowFromHwnd(hwnd);
            setImeCompositionPos(window);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_IME_COMPOSITION => {
            // Re-pin while the composition string is updating so the IME UI
            // tracks the caret if PTY output scrolls mid-composition.
            const GCS_COMPSTR: usize = 0x0008;
            if ((@as(usize, @bitCast(lparam)) & GCS_COMPSTR) != 0) {
                const window = windowFromHwnd(hwnd);
                setImeCompositionPos(window);
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_IME_NOTIFY => {
            if (wparam == win32.IMN_OPENCANDIDATE or wparam == win32.IMN_CHANGECANDIDATE) {
                const window = windowFromHwnd(hwnd);
                setImeCandidatePos(window);
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_RBUTTONDOWN => {
            const window = windowFromHwnd(hwnd);
            const mouse_x: i32 = win32.xFromLparam(lparam);
            const mouse_y: i32 = win32.yFromLparam(lparam);
            const cs = global.renderer.cell_size;
            if (mouse_y < cs.cy) {
                const cell_count = computeGridCellCount(hwnd, cs);
                const hit = hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
                if (hit == .new_tab) {
                    showLauncherMenu(window, mouse_x, mouse_y);
                    return 0;
                }
            }
            pasteClipboard(hwnd, window.active());
            return 0;
        },
        win32.WM_TIMER => {
            if (wparam == TIMER_SELECTION_FADE) {
                const window = windowFromHwnd(hwnd);
                window.selection_fade -= 0.05;
                if (window.selection_fade <= 0) {
                    window.selection_fade = 0;
                    _ = win32.KillTimer(hwnd, TIMER_SELECTION_FADE);
                    window.active().term.screens.active.clearSelection();
                }
                window.requestRender();
            }
            return 0;
        },
        WM_APP_CHILD_PROCESS_DATA => {
            const read_msg: *const ReadMsg = @ptrFromInt(wparam);
            // Always return the magic value, even when dropping payload.
            if (global.window == null) return WM_APP_CHILD_PROCESS_DATA_RESULT;
            const window = &global.window.?;
            const tab = window.findById(read_msg.tab_id) orelse return WM_APP_CHILD_PROCESS_DATA_RESULT;
            if (tab.closing) return WM_APP_CHILD_PROCESS_DATA_RESULT;
            tab.vt_stream.nextSlice(read_msg.data[0..read_msg.len]);
            window.requestRender();
            return WM_APP_CHILD_PROCESS_DATA_RESULT;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn hitEql(a: ?TabHit, b: TabHit) bool {
    if (a == null) return b == .none;
    const av = a.?;
    if (@as(std.meta.Tag(TabHit), av) != @as(std.meta.Tag(TabHit), b)) return false;
    return switch (av) {
        .none => true,
        .new_tab => true,
        .activate => |i| b.activate == i,
        .close => |i| b.close == i,
    };
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

    pub fn resize(self: *ChildProcess, out_err: *Error, cell_count: GridPos) error{Error}!void {
        const pty = self.pty orelse return;
        const hr = win32.ResizePseudoConsole(
            pty.hpcon,
            .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
        );
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

        const term_override = try utf16ZAlloc(allocator, "TERM=xterm-256color");
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

    fn utf16ZAlloc(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![]u16 {
        const required = std.unicode.calcUtf16LeLen(utf8) catch unreachable;
        const out = try allocator.alloc(u16, required);
        const written = std.unicode.utf8ToUtf16Le(out, utf8) catch unreachable;
        std.debug.assert(written == required);
        return out;
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
            error.OutOfMemory => oom(error.OutOfMemory),
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

fn scrollbarDragTo(tab: *Tab, track_top: f32, win_h: f32, track_height: f32) void {
    const screen = tab.term.screens.active;
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

fn pasteClipboard(hwnd: win32.HWND, tab: *Tab) void {
    const pty = tab.child_process.pty orelse {
        std.log.err("paste: pty closed", .{});
        return;
    };
    if (win32.OpenClipboard(hwnd) == 0) {
        std.log.err("paste: OpenClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());
    const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse {
        std.log.err("paste: GetClipboardData failed, error={f}", .{win32.GetLastError()});
        return;
    };
    const hmem: isize = @bitCast(@intFromPtr(handle));
    const mem: [*:0]const u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse {
        std.log.err("paste: GlobalLock failed, error={f}", .{win32.GetLastError()});
        return;
    }));
    defer globalUnlock(hmem);
    var buf: [4096]u8 = undefined;
    var pty_writer = pty.write.writerStreaming(&buf);
    pasteUtf16(tab, mem, &pty_writer.interface) catch |err| switch (err) {
        error.WriteFailed => std.log.err("paste: write to pty failed with {t}", .{pty_writer.err.?}),
        error.Reported => {},
    };
}

fn onDropFiles(window: *Window, hdrop: win32.HDROP) void {
    defer win32.DragFinish(hdrop);

    const tab = window.active();
    const pty = tab.child_process.pty orelse {
        std.log.err("drop: pty closed", .{});
        return;
    };

    const count = win32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a single UTF-16 buffer: each path is wrapped in double quotes
    // and separated by a space; one trailing space lets the user keep
    // typing arguments. Always-quote is the simplest defence against
    // shell metacharacters (cmd's `&|<>()^`, bash's `$()`, etc.) — file
    // paths on Windows can't contain `"` so escaping isn't needed.
    var combined: std.ArrayListUnmanaged(u16) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const wlen = win32.DragQueryFileW(hdrop, i, null, 0);
        if (wlen == 0) continue;
        const path = a.allocSentinel(u16, wlen, 0) catch |e| oom(e);
        const got = win32.DragQueryFileW(hdrop, i, path.ptr, wlen + 1);
        if (got == 0) continue;

        if (combined.items.len > 0) combined.append(a, ' ') catch |e| oom(e);
        combined.append(a, '"') catch |e| oom(e);
        combined.appendSlice(a, path[0..wlen]) catch |e| oom(e);
        combined.append(a, '"') catch |e| oom(e);
    }
    if (combined.items.len == 0) return;
    combined.append(a, ' ') catch |e| oom(e);

    const final = a.allocSentinel(u16, combined.items.len, 0) catch |e| oom(e);
    @memcpy(final[0..combined.items.len], combined.items);

    var write_buf: [4096]u8 = undefined;
    var pty_writer = pty.write.writerStreaming(&write_buf);
    pasteUtf16(tab, final.ptr, &pty_writer.interface) catch |err| switch (err) {
        error.WriteFailed => std.log.err("drop: write to pty failed with {t}", .{pty_writer.err.?}),
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

fn pasteUtf16(tab: *Tab, utf16: [*:0]const u16, writer: *std.Io.Writer) error{ WriteFailed, Reported }!void {
    const bracketed = tab.term.modes.get(.bracketed_paste);
    if (bracketed) try writer.writeAll("\x1b[200~");
    var end_stripper: PasteEndStripper = .{};

    var i: usize = 0;
    var last_was_cr = false;
    while (utf16[i] != 0) {
        const cp: u21 = blk: {
            if (std.unicode.utf16IsHighSurrogate(utf16[i])) {
                const high = utf16[i];
                i += 1;
                if (utf16[i] == 0 or !std.unicode.utf16IsLowSurrogate(utf16[i])) {
                    std.log.err("paste: lone high surrogate 0x{x} at index {}", .{ high, i - 1 });
                    return error.Reported;
                }
                const pair = std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, utf16[i] }) catch {
                    std.log.err("paste: bad surrogate pair 0x{x} 0x{x} at index {}", .{ high, utf16[i], i - 1 });
                    return error.Reported;
                };
                i += 1;
                break :blk pair;
            }
            if (std.unicode.utf16IsLowSurrogate(utf16[i])) {
                std.log.err("paste: lone low surrogate 0x{x} at index {}", .{ utf16[i], i });
                return error.Reported;
            }
            const c: u21 = @intCast(utf16[i]);
            i += 1;
            break :blk c;
        };

        // Normalize line endings to CR. Windows clipboards store newlines
        // as CRLF, but terminals treat Enter as a bare CR — passing the LF
        // through leaves it as a stray byte the shell can't interpret, so
        // pasted lines collapse onto one line. Matches xterm bracketed
        // paste spec and what alacritty/kitty/foot do.
        var out_cp: u21 = cp;
        if (cp == '\n') {
            if (last_was_cr) {
                last_was_cr = false;
                continue;
            }
            out_cp = '\r';
        } else {
            last_was_cr = (cp == '\r');
        }

        switch (if (bracketed) try end_stripper.onCodepoint(writer, out_cp) else .ignored) {
            .consumed => {},
            .ignored => {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(out_cp, &utf8_buf) catch {
                    std.log.err("paste: invalid codepoint U+{x} at index {}", .{ out_cp, i });
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

fn utf16ZAllocMut(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![*:0]u16 {
    const required = std.unicode.calcUtf16LeLen(utf8) catch unreachable;
    const buf = try allocator.allocSentinel(u16, required, 0);
    const written = std.unicode.utf8ToUtf16Le(buf[0..required], utf8) catch unreachable;
    std.debug.assert(written == required);
    return buf.ptr;
}

fn utf16ZAllocConst(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![*:0]const u16 {
    return utf16ZAllocMut(allocator, utf8);
}

// Converts UTF-8 family names to heap-allocated, null-terminated UTF-16
// strings. The returned outer slice and each inner string are leaked
// intentionally; they live for the lifetime of the renderer.
fn utf16FontFamilies(allocator: std.mem.Allocator, families: []const []const u8) []const [*:0]const u16 {
    var out: std.ArrayListUnmanaged([*:0]const u16) = .empty;
    for (families) |name| {
        const required = std.unicode.calcUtf16LeLen(name) catch {
            std.log.warn("config: invalid utf-8 in font-family '{s}'; skipping", .{name});
            continue;
        };
        const buf = allocator.allocSentinel(u16, required, 0) catch |e| oom(e);
        const written = std.unicode.utf8ToUtf16Le(buf[0..required], name) catch unreachable;
        std.debug.assert(written == required);
        out.append(allocator, buf.ptr) catch |e| oom(e);
    }
    if (out.items.len == 0) return &.{};
    return out.toOwnedSlice(allocator) catch |e| oom(e);
}

const Config = @import("Config.zig");
const d3d11 = @import("win32/d3d11.zig");
const vt = @import("vt");
const std = @import("std");
const win32 = @import("win32").everything;
const cimport = @cImport({
    @cInclude("ResourceNames.h");
});
