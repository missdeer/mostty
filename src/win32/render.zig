const win32 = @import("win32").everything;

const global_mod = @import("global.zig");
const state = @import("state.zig");
const tab_bar = @import("tab_bar.zig");
const types = @import("types.zig");
const window_geom = @import("window_geom.zig");

const Window = state.Window;
const global = global_mod.global;

pub fn renderWindow(window: *Window) void {
    const cs = global.renderer.cell_size;
    const cell_count = window_geom.computeGridCellCount(window.hwnd, cs);
    const total_cols = cell_count.col;
    var tab_buf: [types.MAX_TABS]types.TabDrawInfo = undefined;
    const tabbar = tab_bar.buildTabBarDraw(window, total_cols, &tab_buf);
    const theme = &global.config.theme;
    global.renderer.render(
        window.hwnd,
        window.active().term,
        tabbar,
        window.resizing,
        window.mouse_in_scrollbar,
        if (window.mouse_capture == .selecting) 1.0 else window.selection_fade,
        theme.cursor_text,
        theme.selection_background,
        theme.selection_foreground,
        global.config.background_opacity,
    );
}

// Pixel position of the top-left of the active tab's cursor cell, including
// the tab-bar band offset at the top.
pub fn caretPixelPos(window: *Window) ?win32.POINT {
    if (window.tabs.items.len == 0) return null;
    const screen = window.active().term.screens.active;
    const cs = global.renderer.cell_size;
    const x: i32 = @as(i32, @intCast(screen.cursor.x)) * cs.cx;
    const y: i32 = @as(i32, @intCast(screen.cursor.y)) * cs.cy + global.renderer.tab_bar_height;
    return .{ .x = x, .y = y };
}
