pub const panic = std.debug.FullPanic(panic_mod.panicHandler);

pub const WndProc = dispatch.WndProc;

// Temporary file logger: subsystem=Windows has no console, so the default
// std.log writer drops everything. Route std.log.* into `tmp/mostty.log` so
// the diagnostic counters (state.zig:logDiagnostics, d3d11.zig:maybeLogDiag)
// are actually readable. Truncated on each startup so consecutive runs don't
// pile up. Each line is also mirrored to OutputDebugStringW so DebugView/VS
// catches output even when the file sink is unavailable (e.g. cwd is not
// writable, AV blocks creation). Remove when render-perf work is done
// (see TODO 临时诊断代码处置).
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = fileLogFn,
};

var log_state: struct {
    mutex: std.Thread.Mutex = .{},
    file: ?std.fs.File = null,
    init_attempted: bool = false,
} = .{};

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_state.mutex.lock();
    defer log_state.mutex.unlock();

    if (!log_state.init_attempted) {
        log_state.init_attempted = true;
        std.fs.cwd().makePath("tmp") catch {};
        log_state.file = std.fs.cwd().createFile("tmp/mostty.log", .{ .truncate = true }) catch null;
    }

    var buf: [4096]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{d} [{s}] ({s}) ", .{
        std.time.milliTimestamp(),
        @tagName(level),
        @tagName(scope),
    }) catch return;
    const body = std.fmt.bufPrint(buf[head.len..], format ++ "\n", args) catch return;
    const line = buf[0 .. head.len + body.len];

    if (log_state.file) |f| f.writeAll(line) catch {};

    // Mirror to OutputDebugStringW: visible in DebugView / VS Output even
    // when the file sink is gone, and effectively free when no debugger is
    // attached. Reuse a stack buffer for the UTF-16 conversion; if the
    // conversion fails or fills the buffer (no room for the NUL), the
    // mirror is skipped for this line — the file write above already
    // captured it. The size matches `buf` above (line ≤ 4096 UTF-8 bytes
    // → ≤ 4096 UTF-16 units), so in practice the skip only triggers when
    // the line was malformed.
    var w_buf: [4096]u16 = undefined;
    const w_len = std.unicode.utf8ToUtf16Le(&w_buf, line) catch w_buf.len;
    if (w_len < w_buf.len) {
        w_buf[w_len] = 0;
        win32.OutputDebugStringW(@ptrCast(&w_buf));
    }
}

// Subsystem=Windows + MSVC ABI pulls libcmt's exe_winmain.obj as the startup,
// which calls WinMain instead of the Zig-style `main`. We can't suppress
// libcmt's startup (highway/simdutf require linkLibC), so provide a WinMain
// that delegates to main. Use @export rather than a root `pub export fn WinMain`
// because Zig's std/start.zig has a @compileError on @hasDecl(root, "WinMain")
// for the link_libc=false path; routing through a differently-named local
// decl keeps that path compileable.
comptime {
    if (builtin.link_libc) {
        @export(&winMain, .{ .name = "WinMain" });
    }
}

fn winMain(
    _: ?win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    _: ?win32.PSTR,
    _: c_int,
) callconv(.winapi) c_int {
    main() catch return 1;
    return 0;
}

pub fn main() !void {
    const opt: struct {
        window_placement: window_geom.WindowPlacementOptions = .{},
    } = .{};

    const maybe_monitor: ?win32.HMONITOR = blk: {
        const pt: win32.POINT = if (opt.window_placement.left != null or opt.window_placement.top != null) .{
            .x = opt.window_placement.left orelse 0,
            .y = opt.window_placement.top orelse 0,
        } else cursor: {
            // No explicit placement: center on the monitor the cursor is on.
            var cursor: win32.POINT = undefined;
            if (0 == win32.GetCursorPos(&cursor)) {
                std.log.warn("GetCursorPos failed, error={f}", .{win32.GetLastError()});
                break :cursor win32.POINT{ .x = 0, .y = 0 };
            }
            break :cursor cursor;
        };
        break :blk win32.MonitorFromPoint(
            pt,
            win32.MONITOR_DEFAULTTOPRIMARY,
        ) orelse {
            std.log.warn("MonitorFromPoint failed, error={f}", .{win32.GetLastError()});
            break :blk null;
        };
    };

    const dpi: util.XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var dpi: util.XY(u32) = undefined;
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
        std.log.debug("monitor dpi {}x{}", .{ dpi.x, dpi.y });
        break :blk dpi;
    };

    global.icons = icons_mod.getIcons(dpi);

    // Load user config and convert font-family list to UTF-16 sentinel-terminated
    // strings. The UTF-16 storage is leaked: it lives for the lifetime of the
    // global renderer (i.e. the whole process).
    global.config = Config.loadDefault(global.gpa.allocator());
    const gpa_alloc = global.gpa.allocator();
    const font_families_u16 = util.utf16FontFamilies(gpa_alloc, global.config.font_families);
    const codepoint_maps_u16 = util.utf16CodepointMaps(gpa_alloc, global.config.font_codepoint_maps);
    const font_config: d3d11.FontConfig = .{
        .families = font_families_u16,
        .family_bold = util.utf16FamilyOptional(gpa_alloc, global.config.font_family_bold),
        .family_italic = util.utf16FamilyOptional(gpa_alloc, global.config.font_family_italic),
        .family_bold_italic = util.utf16FamilyOptional(gpa_alloc, global.config.font_family_bold_italic),
        .synthesize_bold = global.config.font_synthetic_style.bold,
        .synthesize_italic = global.config.font_synthetic_style.italic,
        .synthesize_bold_italic = global.config.font_synthetic_style.bold_italic,
        .style_specs = .{
            util.convertStyleSpec(gpa_alloc, global.config.font_style),
            util.convertStyleSpec(gpa_alloc, global.config.font_style_bold),
            util.convertStyleSpec(gpa_alloc, global.config.font_style_italic),
            util.convertStyleSpec(gpa_alloc, global.config.font_style_bold_italic),
        },
        .font_size_pt = global.config.font_size_pt,
        .codepoint_maps = codepoint_maps_u16,
        .tabbar_family = util.utf16FamilyOptional(gpa_alloc, global.config.tabbar_font_family),
        .tabbar_font_size_pt = global.config.tabbar_font_size_pt,
    };
    global.renderer = d3d11.init(@max(dpi.x, dpi.y), font_config);
    const cell_size = global.renderer.cell_size;
    const placement = window_geom.calcWindowPlacement(
        maybe_monitor,
        @max(dpi.x, dpi.y),
        cell_size,
        opt.window_placement,
    );

    const CLASS_NAME = win32.L("MosttyWindow");

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
        types.window_style_ex,
        CLASS_NAME,
        win32.L("Mostty"),
        types.window_style,
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
    // UIPI: when mostty runs elevated, Explorer (a lower-integrity process)
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

    config_watch.start(hwnd);

    while (true) {
        const window: *state.Window = blk: {
            while (true) {
                if (global.window) |*w| {
                    if (w.tabs.items.len > 0) break :blk w;
                }
                var msg: win32.MSG = undefined;
                const result = win32.GetMessageW(&msg, null, 0, 0);
                if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
                if (result == 0) global_mod.onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        };

        const n_tabs = window.tabs.items.len;
        var handles_buf: [types.MAX_TABS]win32.HANDLE = undefined;
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
                    _ = win32.PostMessageW(hwnd, types.WM_APP_CLOSE_TAB, tab.id, 0);
                }
            }
            global_mod.flushMessages();
            continue;
        }
        // wait_result == n_tabs: messages available.
        std.debug.assert(wait_result == n_tabs);
        global_mod.flushMessages();
    }
}

const Config = @import("Config.zig");
const config_watch = @import("win32/config_watch.zig");
const d3d11 = @import("win32/d3d11.zig");
const dispatch = @import("win32/wnd/dispatch.zig");
const global_mod = @import("win32/global.zig");
const icons_mod = @import("win32/icons.zig");
const panic_mod = @import("win32/panic.zig");
const state = @import("win32/state.zig");
const types = @import("win32/types.zig");
const util = @import("win32/util.zig");
const window_geom = @import("win32/window_geom.zig");
const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;

const global = global_mod.global;
