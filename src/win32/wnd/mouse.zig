const win32 = @import("win32").everything;
const vt = @import("vt");

const d3d11 = @import("../d3d11.zig");
const global_mod = @import("../global.zig");
const launcher = @import("../launcher.zig");
const paste = @import("../paste.zig");
const tab_bar = @import("../tab_bar.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const window_geom = @import("../window_geom.zig");

const global = global_mod.global;

pub fn onLButtonDown(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const cs = global.renderer.cell_size;
    const client_size = win32.getClientSize(hwnd);
    const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, sb_px);

    // Tab bar gets first dibs on a fresh click.
    if (mouse_y < cs.cy) {
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        switch (hit) {
            .none => {},
            .activate => |idx| tab_mgmt.switchToTab(window, idx),
            .close => |idx| {
                if (idx >= window.tabs.items.len) return 0;
                tab_mgmt.confirmAndCloseTab(window, window.tabs.items[idx].id);
            },
            .new_tab => tab_mgmt.newTab(window),
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
                window_geom.scrollbarDragTo(window.active(), mouse_yf - track_height / 2.0, win_h, track_height);
            }
            _ = win32.SetCapture(hwnd);
            window.requestRender();
        }
    } else {
        const screen = window.active().term.screens.active;
        window.selection_fade = 0;
        _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
        const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
        const row: usize = @intCast(@divTrunc(@max(grid_mouse_y, 0), cs.cy));
        if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
            screen.clearSelection();
            const sel = vt.Selection.init(pin, pin, false);
            screen.select(sel) catch util.oom(error.OutOfMemory);
            window.mouse_capture = .selecting;
            _ = win32.SetCapture(hwnd);
            window.requestRender();
        }
    }
    return 0;
}

pub fn onLButtonUp(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
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
                const text = screen.selectionString(alloc, .{ .sel = sel }) catch util.oom(error.OutOfMemory);
                defer alloc.free(text);
                if (text.len > 0) {
                    paste.copyToClipboard(hwnd, text);
                }
                window.selection_fade = 1.0;
                _ = win32.SetTimer(hwnd, types.TIMER_SELECTION_FADE, 16, null);
            }
        },
    }
    return 0;
}

pub fn onMouseWheel(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const delta: i16 = @bitCast(win32.hiword(wparam));
    const scroll_lines: isize = if (delta > 0) -3 else 3;
    const screen = window.active().term.screens.active;
    screen.scroll(.{ .delta_row = scroll_lines });
    window.requestRender();
    return 0;
}

pub fn onMouseMove(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
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
                window_geom.scrollbarDragTo(window.active(), @as(f32, @floatFromInt(grid_mouse_y)) - window.scrollbar_drag_offset, win_h, track_height);
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
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        if (!util.hitEql(window.tab_bar_hover, hit)) {
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
}

pub fn onMouseLeave(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
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
}

pub fn onRButtonDown(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const cs = global.renderer.cell_size;
    if (mouse_y < cs.cy) {
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        if (hit == .new_tab) {
            launcher.showLauncherMenu(window, mouse_x, mouse_y);
        }
        return 0;
    }
    paste.pasteClipboard(hwnd, window.active());
    return 0;
}

