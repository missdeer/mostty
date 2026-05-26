const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const render = @import("../render.zig");
const state = @import("../state.zig");

const Window = state.Window;

fn setImeCompositionPos(window: *Window) void {
    const caret = render.caretPixelPos(window) orelse return;
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
    const caret = render.caretPixelPos(window) orelse return;
    const cs = global_mod.global.renderer.cell_size;
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

pub fn onImeStartComposition(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    setImeCompositionPos(window);
    return null; // fall through to DefWindowProcW
}

pub fn onImeComposition(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    // Re-pin while the composition string is updating so the IME UI
    // tracks the caret if PTY output scrolls mid-composition.
    const GCS_COMPSTR: usize = 0x0008;
    if ((@as(usize, @bitCast(lparam)) & GCS_COMPSTR) != 0) {
        const window = global_mod.windowFromHwnd(hwnd);
        setImeCompositionPos(window);
    }
    return null;
}

pub fn onImeNotify(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (wparam == win32.IMN_OPENCANDIDATE or wparam == win32.IMN_CHANGECANDIDATE) {
        const window = global_mod.windowFromHwnd(hwnd);
        setImeCandidatePos(window);
    }
    return null;
}
