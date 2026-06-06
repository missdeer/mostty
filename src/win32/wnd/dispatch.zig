const win32 = @import("win32").everything;

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
    // mouse
    .{ .msg = win32.WM_LBUTTONDOWN, .handler = &mouse.onLButtonDown },
    .{ .msg = win32.WM_LBUTTONUP, .handler = &mouse.onLButtonUp },
    .{ .msg = win32.WM_MBUTTONDOWN, .handler = &mouse.onMButtonDown },
    .{ .msg = win32.WM_MBUTTONUP, .handler = &mouse.onMButtonUp },
    .{ .msg = win32.WM_MOUSEWHEEL, .handler = &mouse.onMouseWheel },
    .{ .msg = win32.WM_MOUSEMOVE, .handler = &mouse.onMouseMove },
    .{ .msg = win32.WM_MOUSELEAVE, .handler = &mouse.onMouseLeave },
    // Menu activation (system menu, theme submenu, launcher) and other
    // mode-cancel events don't fire WM_KILLFOCUS; route them through the
    // same hide handler so the tracking tooltip doesn't get stuck.
    .{ .msg = win32.WM_KILLFOCUS, .handler = &mouse.onKillFocus },
    .{ .msg = win32.WM_CANCELMODE, .handler = &mouse.onKillFocus },
    .{ .msg = win32.WM_RBUTTONDOWN, .handler = &mouse.onRButtonDown },
    .{ .msg = win32.WM_RBUTTONUP, .handler = &mouse.onRButtonUp },
    // keyboard
    .{ .msg = win32.WM_KEYDOWN, .handler = &keyboard.onKeyDown },
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
    // misc
    .{ .msg = win32.WM_TIMER, .handler = &misc.onTimer },
    .{ .msg = win32.WM_SYSCOMMAND, .handler = &misc.onSysCommand },
    .{ .msg = win32.WM_INITMENUPOPUP, .handler = &misc.onInitMenuPopup },
    .{ .msg = win32.WM_SETTINGCHANGE, .handler = &misc.onSettingChange },
    .{ .msg = win32.WM_WTSSESSION_CHANGE, .handler = &misc.onWtsSessionChange },
    .{ .msg = win32.WM_DROPFILES, .handler = &misc.onDropFiles },
    .{ .msg = types.WM_APP_CHILD_PROCESS_DATA, .handler = &misc.onAppChildProcessData },
    .{ .msg = types.WM_APP_CONFIG_CHANGED, .handler = &misc.onAppConfigChanged },
};

comptime {
    // Duplicate msg entries would silently shadow the later one; the switch
    // form used to make this a compile error, but a flat table can be
    // reordered without noticing. Enforce uniqueness up front.
    for (TABLE, 0..) |a, i| {
        for (TABLE[i + 1 ..]) |b| {
            if (a.msg == b.msg) @compileError("duplicate WM message in dispatch TABLE");
        }
    }
}

pub fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    // `inline for` unrolls into a chain of constant compares; for ~25 entries
    // the overhead is negligible compared to handler work. We don't depend on
    // LLVM forming a jump table here.
    inline for (TABLE) |e| {
        if (e.msg == msg) {
            return e.handler(hwnd, wparam, lparam) orelse win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        }
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
