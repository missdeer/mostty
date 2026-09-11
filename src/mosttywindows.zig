pub const panic = std.debug.FullPanic(panic_mod.panicHandler);

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

pub const WndProc = dispatch.WndProc;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    diag.log(level, scope, format, args);
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
    _: ?[*:0]u8,
    show_cmd: c_int,
) callconv(.winapi) c_int {
    mainWithShowCommand(@bitCast(@as(u32, @intCast(show_cmd)))) catch return 1;
    return 0;
}

pub fn main() !void {
    return mainWithShowCommand(win32.SW_SHOWNORMAL);
}

fn mainWithShowCommand(startup_show_cmd: win32.SHOW_WINDOW_CMD) !void {
    diag.init();
    const process_args: std.process.Args = .{
        .vector = std.os.windows.peb().ProcessParameters.CommandLine.slice(),
    };
    var args = try process_args.iterateAllocator(global.gpa.allocator());
    defer args.deinit();
    var cmdline = try Cmdline.parse(&args);
    switch (cmdline.renderer) {
        .invalid => |value| {
            if (!confirmInvalidRendererFallback(value)) return error.RendererFallbackDeclined;
            cmdline.renderer = .{ .backend = .d3d11 };
            std.log.warn("renderer: user accepted command-line fallback from invalid value '{s}' to d3d11", .{value});
        },
        else => {},
    }

    const com_initialized = png_decode.initUiComApartment();
    defer if (com_initialized) win32.CoUninitialize();
    png_decode.install();

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
    cmdline.applyConfigOverrides(&global.config);
    const gpa_alloc = global.gpa.allocator();
    const font_families_u16 = util.utf16FontFamilies(gpa_alloc, global.config.font_families);
    const emoji_families_u16 = util.utf16FontFamilies(gpa_alloc, global.config.emoji_font_families);
    const codepoint_maps_u16 = util.utf16CodepointMaps(gpa_alloc, global.config.font_codepoint_maps);
    const font_features = util.dwriteFontFeatures(gpa_alloc, global.config.font_features);
    const font_config: Renderer.FontConfig = .{
        .families = font_families_u16,
        .emoji_families = emoji_families_u16,
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
        .font_features = font_features,
        .codepoint_maps = codepoint_maps_u16,
        .tabbar_family = util.utf16FamilyOptional(gpa_alloc, global.config.tabbar_font_family),
        .tabbar_font_size_pt = global.config.tabbar_font_size_pt,
    };
    global.renderer.init(
        @max(dpi.x, dpi.y),
        font_config,
        global.config.font_ligatures,
        global.config.gpu,
        global.config.renderer,
        global.config.requiresAlphaComposition(),
    ) catch |err| {
        std.log.err("renderer: d3d11 startup failed ({s}): {s}", .{ @errorName(err), Renderer.d3d11InitErrorDescription(err) });
        Renderer.reportD3d11Unavailable(null, err);
        return error.RendererStartupFailed;
    };
    const cell_size = global.renderer.common.cell_size;
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
            // CS_DBLCLKS: required for WM_LBUTTONDBLCLK to be delivered;
            // without it the second click of a double-click arrives as a
            // plain WM_LBUTTONDOWN and word-selection can't be distinguished.
            // CS_OWNDC gives the optional WGL backend one stable device
            // context for the window's lifetime. The D3D paths are unchanged.
            .style = .{ .DBLCLKS = 1, .OWNDC = 1 },
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
        types.windowStyleEx(global.config.renderer.usesDwmRedirection()),
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

    if (global.renderer.initializeWindow(hwnd, global.config.gpu)) |failure| {
        const fallback = Renderer.recommendStartupFallback(global.config.renderer, true) orelse
            return error.RendererStartupFailed;
        std.log.err(
            "renderer: {s} startup failed ({s}): {s}",
            .{ @tagName(fallback.configured), failure.codeName(), failure.description() },
        );
        if (!confirmRendererFallback(hwnd, fallback, failure)) {
            _ = win32.DestroyWindow(hwnd);
            return error.RendererFallbackDeclined;
        }
        global.renderer.fallbackToD3d11(global.config.gpu) catch |err| {
            std.log.err("renderer: d3d11 startup fallback failed ({s}): {s}", .{ @errorName(err), Renderer.d3d11InitErrorDescription(err) });
            Renderer.reportD3d11Unavailable(hwnd, err);
            _ = win32.DestroyWindow(hwnd);
            return error.RendererFallbackUnavailable;
        };
        global.config.renderer = fallback.replacement;
        std.log.warn(
            "renderer: user accepted startup fallback from {s} to {s} after {s}",
            .{ @tagName(fallback.configured), @tagName(fallback.replacement), failure.codeName() },
        );
    }
    if (global.window) |*window| window.applyRenderInterval(
        global.config.render_interval_local_ms,
        global.config.render_interval_remote_ms,
        global.renderer.common.remote_or_software_adapter,
    );

    // Start the glyph raster worker now that the renderer sits at its final
    // address and we have an HWND to PostMessage results back to. Submit
    // callsites only fire from the render path (well after this point), so
    // there's no race between startup and the first job.
    @import("win32/pane_native.zig").reflow(&global.window.?);
    global.renderer.setWorkerHwnd(gpa_alloc, hwnd);

    // Kick the background-image WIC decode onto a worker thread so the
    // 100ms+ decode runs in parallel with DWM setup / ShowWindow rather
    // than blocking the window's first paint. The worker posts
    // WM_APP_BG_IMAGE_DECODED once the message pump (below) starts spinning.
    global.renderer.reloadBackgroundImage(gpa_alloc, &global.config, hwnd);

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
    util.applyBlurBehind(hwnd, global.config.background_blur, global.window.?.dwm_redirected);

    win32.DragAcceptFiles(hwnd, 1);
    // UIPI: when mostty runs elevated, Explorer (a lower-integrity process)
    // can't post WM_DROPFILES / WM_COPYGLOBALDATA into our window unless
    // we explicitly allow them through the message filter. Without this,
    // drag-and-drop silently fails when "Run as administrator".
    _ = win32.ChangeWindowMessageFilterEx(hwnd, win32.WM_DROPFILES, win32.MSGFLT_ALLOW, null);
    _ = win32.ChangeWindowMessageFilterEx(hwnd, 0x0049, win32.MSGFLT_ALLOW, null); // WM_COPYGLOBALDATA

    if (0 == win32.UpdateWindow(hwnd)) win32.panicWin32("UpdateWindow", win32.GetLastError());
    // Show maximized first when configured so that toggling fullscreen off
    // later restores the maximized state, not a normal-sized window — the
    // toggle snapshots WINDOWPLACEMENT at entry.
    const show_cmd = initialShowCommand(global.config.maximize, startup_show_cmd);
    _ = win32.ShowWindow(hwnd, show_cmd);
    if (global.config.fullscreen) wnd_misc.toggleFullscreen(hwnd);

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

        const n_tabs = window.panes.items.len;
        var handles_buf: [types.MAX_PANES]win32.HANDLE = undefined;
        for (window.panes.items, 0..) |t, i| {
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
            if (i < window.panes.items.len) {
                const tab = window.panes.items[i];
                if (!tab.closing) {
                    tab.closing = true;
                    _ = win32.PostMessageW(hwnd, types.WM_APP_CLOSE_PANE, tab.id, 0);
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

fn initialShowCommand(config_maximize: bool, startup_show_cmd: win32.SHOW_WINDOW_CMD) win32.SHOW_WINDOW_CMD {
    return if (config_maximize) win32.SW_SHOWMAXIMIZED else startup_show_cmd;
}

test "shortcut maximize survives startup fallback dialogs" {
    try std.testing.expectEqual(
        win32.SW_SHOWMAXIMIZED,
        initialShowCommand(false, win32.SW_SHOWMAXIMIZED),
    );
    try std.testing.expectEqual(
        win32.SW_SHOWMAXIMIZED,
        initialShowCommand(true, win32.SW_SHOWNORMAL),
    );
}

fn confirmRendererFallback(
    hwnd: win32.HWND,
    fallback: Renderer.StartupFallback,
    failure: Renderer.StartupFailure,
) bool {
    var message_buf: [768]u8 = undefined;
    const remote_note: []const u8 = if (win32.GetSystemMetrics(win32.SM_REMOTESESSION) != 0)
        "The capability check failed in a Remote Desktop session. RDP graphics " ++
            "capabilities vary by host and session, and this session did not satisfy the configured renderer's requirements.\n\n"
    else
        "";
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "The configured renderer ({s}) failed its startup capability check.\n\n" ++
            "{s}.\n\n{s}Use D3D11 for this session instead?\n\n" ++
            "Choose Yes to continue with D3D11, or No to exit Mostty.",
        .{ @tagName(fallback.configured), failure.description(), remote_note },
    ) catch unreachable;
    return win32.MessageBoxA(
        hwnd,
        message,
        "Mostty Renderer Fallback",
        // zigwin32 represents MB_ICONWARNING as these two aliasing bits.
        .{ .YESNO = 1, .ICONHAND = 1, .ICONQUESTION = 1, .DEFBUTTON2 = 1 },
    ) == win32.IDYES;
}

fn confirmInvalidRendererFallback(value: []const u8) bool {
    var message_buf: [768]u8 = undefined;
    const display_value = value[0..@min(value.len, 128)];
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "The command-line renderer value ({s}) is not recognized.\n\n" ++
            "Expected d3d11, d3d12, opengl, pure-opengl, vulkan, or native-vulkan.\n\n" ++
            "Use D3D11 for this session instead?\n\n" ++
            "Choose Yes to continue with D3D11, or No to exit Mostty.",
        .{display_value},
    ) catch unreachable;
    return win32.MessageBoxA(
        null,
        message,
        "Mostty Renderer Fallback",
        .{ .YESNO = 1, .ICONHAND = 1, .ICONQUESTION = 1, .DEFBUTTON2 = 1 },
    ) == win32.IDYES;
}

const Config = @import("config.zig");
const Cmdline = @import("cmdline.zig");
const Renderer = @import("win32/renderer.zig");
const config_watch = @import("win32/config_watch.zig");
const diag = @import("win32/diag.zig");
const dispatch = @import("win32/wnd/dispatch.zig");
const global_mod = @import("win32/global.zig");
const icons_mod = @import("win32/icons.zig");
const panic_mod = @import("win32/panic.zig");
const png_decode = @import("win32/png_decode.zig");
const state = @import("win32/state.zig");
const types = @import("win32/types.zig");
const util = @import("win32/util.zig");
const window_geom = @import("win32/window_geom.zig");
const wnd_misc = @import("win32/wnd/misc.zig");
const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;

const global = global_mod.global;
