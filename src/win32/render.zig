const win32 = @import("win32").everything;

const d3d11 = @import("d3d11.zig");
const global_mod = @import("global.zig");
const state = @import("state.zig");
const tab_bar = @import("tab_bar.zig");
const window_geom = @import("window_geom.zig");

const Window = state.Window;
const global = global_mod.global;

pub fn renderWindow(window: *Window) void {
    const cs = global.renderer.cell_size;
    const cell_count = window_geom.computeGridCellCount(window.hwnd, cs);
    var row_buf: [4096]d3d11.TabBarCell = undefined;
    const total_cols = cell_count.col;
    if (total_cols > row_buf.len) return;
    tab_bar.buildTabBarRow(window, total_cols, row_buf[0..total_cols]);
    const theme = &global.config.theme;
    global.renderer.render(
        window.hwnd,
        window.active().term,
        row_buf[0..total_cols],
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
// the tab-bar offset (one cell row at the top).
pub fn caretPixelPos(window: *Window) ?win32.POINT {
    if (window.tabs.items.len == 0) return null;
    const screen = window.active().term.screens.active;
    const cs = global.renderer.cell_size;
    const x: i32 = @as(i32, @intCast(screen.cursor.x)) * cs.cx;
    const y: i32 = (@as(i32, @intCast(screen.cursor.y)) + 1) * cs.cy;
    return .{ .x = x, .y = y };
}
