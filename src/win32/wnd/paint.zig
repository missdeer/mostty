const std = @import("std");
const win32 = @import("win32").everything;

const d3d11 = @import("../d3d11.zig");
const err_mod = @import("../error.zig");
const global_mod = @import("../global.zig");
const render = @import("../render.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const window_geom = @import("../window_geom.zig");

const Error = err_mod.Error;
const Window = state.Window;
const global = global_mod.global;

// Wraps renderWindow with a QueryPerformanceCounter timing pair and folds
// the elapsed microseconds into window.diag_render_us / diag_render_max_us.
// Both onPaint and onWindowPosChanged (resize path) go through this so the
// 1Hz logDiagnostics flush sees every render in the window.
fn timedRender(window: *Window) void {
    const t0 = state.qpcNow();
    render.renderWindow(window);
    const us = state.qpcUsSince(t0);
    window.diag_render_us += us;
    if (us > window.diag_render_max_us) window.diag_render_max_us = us;
}

pub fn onEraseBkgnd(_: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    return 1;
}

pub fn onPaint(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    _, var ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);

    const window = global_mod.windowFromHwnd(hwnd);
    // Match onWindowPosChanged: don't consume render_pending while iconic so
    // any request that landed before this paint still fires on restore.
    if (win32.IsIconic(hwnd) != 0) return 0;
    window.render_pending = false;
    timedRender(window);
    window.noteRender();
    return 0;
}

pub fn onDisplayChange(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    window.requestRender();
    return 0;
}

pub fn onExitSizeMove(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    window.resizing = false;
    window.requestRender();
    return 0;
}

pub fn onSizing(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    if (!window.resizing) {
        window.resizing = true;
        window.requestRender();
    }
    const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const dpi = win32.dpiFromHwnd(hwnd);
    const new_rect = window_geom.calcWindowRect(dpi, rect.*, wparam, global.renderer.cell_size);
    window.bounds = .{
        .token = new_rect,
        .rect = rect.*,
    };
    rect.* = new_rect;
    return 0;
}

pub fn onWindowPosChanged(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const pos: *const win32.WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const iconic = win32.IsIconic(hwnd) != 0;

    if (pos.flags.NOSIZE == 0 and !iconic) {
        const cell_count = window_geom.computeGridCellCount(hwnd, global.renderer.cell_size);

        for (window.tabs.items) |tab| {
            if (tab.closing) continue;
            if (tab.term.cols == cell_count.col and tab.term.rows == cell_count.row) continue;
            tab.term.resize(tab.term_arena.allocator(), cell_count.col, cell_count.row) catch |e|
                std.debug.panic("Terminal.resize: {}", .{e});
            var resize_err: Error = undefined;
            tab.child_process.resize(&resize_err, cell_count) catch |e| switch (e) {
                error.Closed => {
                    tab.closing = true;
                    _ = win32.PostMessageW(hwnd, types.WM_APP_CLOSE_TAB, tab.id, 0);
                },
                error.Error => std.debug.panic("{f}", .{resize_err}),
            };
        }
    }

    // Nothing to paint while minimized; leave render_pending alone so any
    // request that landed before this message still fires on restore.
    if (iconic) return 0;

    // Pure move (no size change): the swap-chain back buffer is unchanged
    // and DComposition handles the screen-position update — no render is
    // required. A title-bar drag fires WM_WINDOWPOSCHANGED at mouse-move
    // rate (60-125 Hz); rendering on every event bypasses the SetTimer
    // throttle and on WARP burns ~30% CPU for no visible change. Any
    // pending render request remains queued and will fire via the normal
    // SetTimer / WM_PAINT path. Z-order/show/hide-only changes fall here
    // too; Windows posts a separate WM_PAINT when those need repainting.
    if (pos.flags.NOSIZE != 0) return 0;

    // Size changed: render synchronously so the new client area shows
    // correct content immediately (avoids a single-frame stretch glitch
    // from DWM until the next WM_PAINT). Clear render_pending before
    // render so requests fired *during* render still schedule a follow-up
    // frame; skip the unconditional ValidateRect when a new request
    // landed during render — otherwise it would cancel the WM_PAINT
    // requestRender just posted, leaving render_pending stuck true and
    // the next frame lost.
    window.render_pending = false;
    timedRender(window);
    window.noteRender();
    if (!window.render_pending) {
        _ = win32.ValidateRect(hwnd, null);
    }
    return 0;
}

pub fn onGetDpiScaledSize(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const new_dpi: u32 = @intCast(0xffffffff & wparam);
    const current_dpi = win32.dpiFromHwnd(hwnd);
    const cs = global.renderer.cell_size;

    const tbh_cur = global.renderer.tab_bar_height;
    const client_size = win32.getClientSize(hwnd);
    const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(current_dpi));
    const grid_h_cur = @max(0, client_size.cy - tbh_cur);
    const col_count = @max(1, @divTrunc(grid_w, cs.cx));
    const row_count = @max(1, @divTrunc(grid_h_cur, cs.cy));
    if (col_count != 1) std.debug.assert(grid_w == col_count * cs.cx);
    if (row_count != 1) std.debug.assert(grid_h_cur == row_count * cs.cy);

    const new_cs = global.renderer.cellSizeForDpi(new_dpi);
    const new_client_w = col_count * new_cs.cx + @as(i32, d3d11.scrollbarWidth(new_dpi));
    const new_grid_h = row_count * new_cs.cy;
    const new_client_h = new_grid_h + global.renderer.tabBarHeightForDpi(new_dpi); // add tab bar band at new dpi
    const new_inset = util.getClientInset(new_dpi);
    inout_size.* = .{
        .cx = new_client_w + new_inset.cx,
        .cy = new_client_h + new_inset.cy,
    };
    return 1;
}

pub fn onDpiChanged(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const dpi = win32.dpiFromHwnd(hwnd);
    if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
    if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
    global.renderer.updateDpi(dpi);
    const suggested: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    // While fullscreen, the OS suggests a windowed-shaped rect for the new
    // DPI, which would visually un-fullscreen the window without clearing
    // fullscreen_saved_style — desyncing the toggle state. Snap to the new
    // monitor's rcMonitor instead so fullscreen stays sticky across DPI moves.
    const rect: win32.RECT = blk: {
        if (window.fullscreen_saved_style != null) {
            if (win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST)) |monitor| {
                var mi: win32.MONITORINFO = undefined;
                mi.cbSize = @sizeOf(win32.MONITORINFO);
                if (0 != win32.GetMonitorInfoW(monitor, &mi)) break :blk mi.rcMonitor;
            }
        }
        break :blk suggested.*;
    };
    util.setWindowPosRect(hwnd, rect);
    window.bounds = null;
    window.requestRender();
    return 0;
}
