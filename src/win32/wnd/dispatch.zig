const std = @import("std");
const win32 = @import("win32").everything;

const panic_mod = @import("../panic.zig");
const types = @import("../types.zig");

const ime = @import("ime.zig");
const keyboard = @import("keyboard.zig");
const lifecycle = @import("lifecycle.zig");
const misc = @import("misc.zig");
const mouse = @import("mouse.zig");
const paint = @import("paint.zig");

pub const HandlerFn = *const fn (
    hwnd: win32.HWND,
    wp: win32.WPARAM,
    lp: win32.LPARAM,
) ?win32.LRESULT;

// null  = delegate to DefWindowProcW (used for WM_IME_* which self-handle
//         and then need the default-window-proc post-processing).
// value = concrete WndProc result.
const TABLE = [_]struct { msg: u32, handler: HandlerFn }{
    // lifecycle
    .{ .msg = win32.WM_CREATE, .handler = &lifecycle.onCreate },
    .{ .msg = win32.WM_CLOSE, .handler = &lifecycle.onClose },
    .{ .msg = win32.WM_DESTROY, .handler = &lifecycle.onDestroy },
    .{ .msg = types.WM_APP_CLOSE_TAB, .handler = &lifecycle.onAppCloseTab },
    .{ .msg = types.WM_APP_CLOSE_PANE, .handler = &lifecycle.onAppClosePane },
    // mouse
    .{ .msg = win32.WM_LBUTTONDOWN, .handler = &mouse.onLButtonDown },
    .{ .msg = win32.WM_LBUTTONUP, .handler = &mouse.onLButtonUp },
    .{ .msg = win32.WM_LBUTTONDBLCLK, .handler = &mouse.onLButtonDblClk },
    .{ .msg = win32.WM_MBUTTONDOWN, .handler = &mouse.onMButtonDown },
    .{ .msg = win32.WM_MBUTTONUP, .handler = &mouse.onMButtonUp },
    // CS_DBLCLKS (enabled on the window class for left-click word-select)
    // also suppresses the second WM_RBUTTONDOWN / WM_MBUTTONDOWN of a fast
    // double-click in favor of the *DBLCLK variants. Forward them back to
    // the down handlers so the second paste / mouse-report press isn't lost.
    .{ .msg = win32.WM_RBUTTONDBLCLK, .handler = &mouse.onRButtonDown },
    .{ .msg = win32.WM_MBUTTONDBLCLK, .handler = &mouse.onMButtonDown },
    .{ .msg = win32.WM_MOUSEWHEEL, .handler = &mouse.onMouseWheel },
    .{ .msg = win32.WM_MOUSEMOVE, .handler = &mouse.onMouseMove },
    .{ .msg = win32.WM_MOUSELEAVE, .handler = &mouse.onMouseLeave },
    .{ .msg = win32.WM_SETCURSOR, .handler = &mouse.onSetCursor },
    // Menu activation (system menu, theme submenu, launcher) and other
    // mode-cancel events don't fire WM_KILLFOCUS; route them through the
    // same hide handler so the tracking tooltip doesn't get stuck.
    .{ .msg = win32.WM_KILLFOCUS, .handler = &mouse.onKillFocus },
    .{ .msg = win32.WM_CANCELMODE, .handler = &mouse.onKillFocus },
    .{ .msg = win32.WM_RBUTTONDOWN, .handler = &mouse.onRButtonDown },
    .{ .msg = win32.WM_RBUTTONUP, .handler = &mouse.onRButtonUp },
    // keyboard
    .{ .msg = win32.WM_KEYDOWN, .handler = &keyboard.onKeyDown },
    .{ .msg = win32.WM_SYSKEYDOWN, .handler = &keyboard.onSysKeyDown },
    .{ .msg = win32.WM_SYSCHAR, .handler = &keyboard.onSysChar },
    .{ .msg = win32.WM_CHAR, .handler = &keyboard.onChar },
    // paint / sizing / dpi
    .{ .msg = win32.WM_ERASEBKGND, .handler = &paint.onEraseBkgnd },
    .{ .msg = win32.WM_PAINT, .handler = &paint.onPaint },
    .{ .msg = win32.WM_DISPLAYCHANGE, .handler = &paint.onDisplayChange },
    .{ .msg = win32.WM_EXITSIZEMOVE, .handler = &paint.onExitSizeMove },
    .{ .msg = win32.WM_SIZING, .handler = &paint.onSizing },
    .{ .msg = win32.WM_WINDOWPOSCHANGED, .handler = &paint.onWindowPosChanged },
    .{ .msg = win32.WM_GETDPISCALEDSIZE, .handler = &paint.onGetDpiScaledSize },
    .{ .msg = win32.WM_DPICHANGED, .handler = &paint.onDpiChanged },
    // IME
    .{ .msg = win32.WM_IME_STARTCOMPOSITION, .handler = &ime.onImeStartComposition },
    .{ .msg = win32.WM_IME_COMPOSITION, .handler = &ime.onImeComposition },
    .{ .msg = win32.WM_IME_NOTIFY, .handler = &ime.onImeNotify },
    .{ .msg = win32.WM_INPUTLANGCHANGE, .handler = &ime.onInputLangChange },
    // misc
    .{ .msg = win32.WM_TIMER, .handler = &misc.onTimer },
    .{ .msg = win32.WM_SYSCOMMAND, .handler = &misc.onSysCommand },
    .{ .msg = win32.WM_INITMENUPOPUP, .handler = &misc.onInitMenuPopup },
    .{ .msg = win32.WM_SETTINGCHANGE, .handler = &misc.onSettingChange },
    .{ .msg = win32.WM_WTSSESSION_CHANGE, .handler = &misc.onWtsSessionChange },
    .{ .msg = win32.WM_DROPFILES, .handler = &misc.onDropFiles },
    .{ .msg = types.WM_APP_CHILD_PROCESS_DATA, .handler = &misc.onAppChildProcessData },
    .{ .msg = types.WM_APP_CONFIG_CHANGED, .handler = &misc.onAppConfigChanged },
    .{ .msg = types.WM_APP_BG_IMAGE_DECODED, .handler = &misc.onAppBgImageDecoded },
    .{ .msg = types.WM_APP_GLYPH_READY, .handler = &misc.onAppGlyphReady },
    .{ .msg = types.WM_APP_TEST_D3D12_REMOVAL, .handler = &misc.onAppTestD3d12Removal },
};

comptime {
    // The O(n^2) uniqueness scan below exceeds the default backwards-branch
    // quota once the table grows past ~25 entries.
    @setEvalBranchQuota(4000);
    // Duplicate msg entries would silently shadow the later one; the switch
    // form used to make this a compile error, but a flat table can be
    // reordered without noticing. Enforce uniqueness up front.
    for (TABLE, 0..) |a, i| {
        for (TABLE[i + 1 ..]) |b| {
            if (a.msg == b.msg) @compileError("duplicate WM message in dispatch TABLE");
        }
    }
}

pub fn handlerFor(msg: u32) ?HandlerFn {
    // The crash MessageBox runs a modal loop that pumps this thread's queue, so
    // dispatch is re-entered while the process is already dying. Running a
    // handler there panics a second time and buries the first crash site.
    if (panic_mod.threadIsPanicking()) return null;
    // `inline for` unrolls into a chain of constant compares; for ~25 entries
    // the overhead is negligible compared to handler work. We don't depend on
    // LLVM forming a jump table here.
    inline for (TABLE) |e| {
        if (e.msg == msg) return e.handler;
    }
    return null;
}

pub fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (@import("../global.zig").global.window) |*window| {
        if (@import("../pane_native.zig").mainMessage(window, msg, wparam, lparam)) |result| return result;
    }
    if (handlerFor(msg)) |handler| {
        if (handler(hwnd, wparam, lparam)) |result| return result;
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "a panicking thread routes every window message to the default proc" {
    const Probe = struct {
        routed_before: bool = false,
        latched: bool = false,
        routed_glyph: bool = false,
        routed_paint: bool = false,

        fn run(self: *@This()) void {
            self.routed_before = handlerFor(types.WM_APP_GLYPH_READY) != null;
            self.latched = panic_mod.enterPanic();
            self.routed_glyph = handlerFor(types.WM_APP_GLYPH_READY) != null;
            self.routed_paint = handlerFor(win32.WM_PAINT) != null;
        }
    };

    var probe: Probe = .{};
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();

    try std.testing.expect(probe.routed_before);
    try std.testing.expect(probe.latched);
    try std.testing.expect(!probe.routed_glyph);
    try std.testing.expect(!probe.routed_paint);
    // Suppression is per-thread: a panic elsewhere must not deafen this thread.
    try std.testing.expect(handlerFor(types.WM_APP_GLYPH_READY) != null);
}
