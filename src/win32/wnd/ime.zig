const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const render = @import("../render.zig");
const state = @import("../state.zig");

const Window = state.Window;

fn setImeCompositionPos(hwnd: win32.HWND) void {
    const caret = render.caretPixelPos(hwnd) orelse return;
    const himc = win32.ImmGetContext(hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(hwnd, himc);
    var comp: win32.COMPOSITIONFORM = .{
        .dwStyle = win32.CFS_POINT,
        .ptCurrentPos = caret,
        .rcArea = std.mem.zeroes(win32.RECT),
    };
    const placed = win32.ImmSetCompositionWindow(himc, &comp);
    if (@import("../diag.zig").isEnabled()) std.log.info("IME composition anchor: pane={} x={} y={} placed={}", .{ global_mod.inputPane(hwnd).id, caret.x, caret.y, placed });
}

fn setImeCandidatePos(hwnd: win32.HWND) void {
    const caret = render.caretPixelPos(hwnd) orelse return;
    const cs = global_mod.global.renderer.common.cell_size;
    const himc = win32.ImmGetContext(hwnd) orelse return;
    defer _ = win32.ImmReleaseContext(hwnd, himc);
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
    const placed = win32.ImmSetCandidateWindow(himc, &cand);
    if (@import("../diag.zig").isEnabled()) std.log.info("IME candidate anchor: pane={} x={} y={} placed={}", .{ global_mod.inputPane(hwnd).id, caret.x, caret.y, placed });
}

pub fn onImeStartComposition(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    setImeCompositionPos(hwnd);
    return null; // fall through to DefWindowProcW
}

pub fn onImeComposition(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    // Re-pin while the composition string is updating so the IME UI
    // tracks the caret if PTY output scrolls mid-composition.
    const GCS_COMPSTR: usize = 0x0008;
    const GCS_RESULTSTR: usize = 0x0800;
    if (@import("../diag.zig").isEnabled() and (@as(usize, @bitCast(lparam)) & GCS_RESULTSTR) != 0) {
        if (win32.ImmGetContext(hwnd)) |himc| {
            defer _ = win32.ImmReleaseContext(hwnd, himc);
            const bytes = win32.ImmGetCompositionStringW(himc, win32.GCS_RESULTSTR, null, 0);
            if (bytes > 0) std.log.info("IME commit: pane={} utf16_units={}", .{ global_mod.inputPane(hwnd).id, @divTrunc(bytes, 2) });
        }
    }
    if ((@as(usize, @bitCast(lparam)) & GCS_COMPSTR) != 0) {
        setImeCompositionPos(hwnd);
    }
    return null;
}

pub fn onImeNotify(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (wparam == win32.IMN_OPENCANDIDATE or wparam == win32.IMN_CHANGECANDIDATE) {
        setImeCandidatePos(hwnd);
    }
    return null;
}

// The user switched input method (Win+Space, language bar, Ctrl+Shift, ...).
// lparam is the new input-locale HKL; remember it on the active tab so the
// choice is restored when this tab is activated again (MOSTTY-44). Fall
// through to DefWindowProcW so the OS completes the change.
pub fn onInputLangChange(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const raw: usize = @bitCast(lparam);
    const hkl: ?win32.HKL = if (raw == 0) null else @ptrFromInt(raw);
    // DefWindowProc broadcasts language changes to child HWNDs; remember
    // the choice only for the focused pane, not every recipient.
    if (hwnd == window.hwnd or win32.GetFocus() == hwnd) window.recordActiveInputLayout(hkl);
    return null;
}
