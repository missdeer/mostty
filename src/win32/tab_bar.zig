const std = @import("std");

const state = @import("state.zig");
const types = @import("types.zig");

const Window = state.Window;
const TabHit = types.TabHit;
const MAX_TABS = types.MAX_TABS;

pub const TabLayoutEntry = struct {
    tab_index: usize,
    col_start: usize,
    col_end: usize, // exclusive
    close_col: usize, // column index of close 'x' (relative to total grid)
};

pub const TabBarLayout = struct {
    entries_buf: [MAX_TABS]TabLayoutEntry,
    entries_len: usize,
    new_tab_col: ?usize,

    pub fn entries(self: *const TabBarLayout) []const TabLayoutEntry {
        return self.entries_buf[0..self.entries_len];
    }
};

pub fn layoutTabBar(window: *Window, total_cols: usize) TabBarLayout {
    var layout: TabBarLayout = .{ .entries_buf = undefined, .entries_len = 0, .new_tab_col = null };
    if (total_cols == 0 or window.tabs.items.len == 0) return layout;

    const new_tab_w: usize = 3; // " + "
    const min_tab_w: usize = 6;
    const ideal_tab_w: usize = 20;

    const usable_for_tabs = if (total_cols > new_tab_w) total_cols - new_tab_w else 0;
    const n = window.tabs.items.len;
    var tab_w = ideal_tab_w;
    if (tab_w * n > usable_for_tabs) tab_w = usable_for_tabs / n;
    if (tab_w < min_tab_w) tab_w = min_tab_w;

    var col: usize = 0;
    for (window.tabs.items, 0..) |_, i| {
        if (col >= total_cols) break;
        var end = col + tab_w;
        if (end > total_cols) end = total_cols;
        if (end - col < 3) break;
        const close_col = end - 2;
        if (layout.entries_len >= layout.entries_buf.len) break;
        layout.entries_buf[layout.entries_len] = .{
            .tab_index = i,
            .col_start = col,
            .col_end = end,
            .close_col = close_col,
        };
        layout.entries_len += 1;
        col = end;
    }
    if (col + new_tab_w <= total_cols) {
        layout.new_tab_col = col + 1;
    }
    return layout;
}

pub fn hitTestTabBar(window: *Window, total_cols: usize, mouse_x: i32, cs_x: i32) TabHit {
    const col: usize = @intCast(@max(0, @divTrunc(mouse_x, cs_x)));
    const layout = layoutTabBar(window, total_cols);
    for (layout.entries()) |e| {
        if (col >= e.col_start and col < e.col_end) {
            if (col == e.close_col) return .{ .close = e.tab_index };
            return .{ .activate = e.tab_index };
        }
    }
    if (layout.new_tab_col) |c| {
        if (col == c) return .new_tab;
    }
    return .none;
}

/// When a title looks like a file/path (contains `\` or `/`), strip
/// everything up to and including the last separator so only the
/// basename is shown. Titles without separators (e.g. "cmd", "node")
/// are returned unchanged.
pub fn displayTitle(title: []const u8) []const u8 {
    var i: usize = title.len;
    while (i > 0) {
        i -= 1;
        if (title[i] == '\\' or title[i] == '/') {
            return title[i + 1 ..];
        }
    }
    return title;
}

// Builds the per-tab drawing list consumed by the proportional D2D painter.
// Column ranges come straight from `layoutTabBar` (tab widths/buttons stay
// column-based); the painter converts columns to pixels and draws titles with
// DirectWrite. `buf` must hold at least MAX_TABS entries; titles borrow each
// tab's title buffer and are valid only for the current render call.
pub fn buildTabBarDraw(window: *Window, total_cols: usize, buf: []types.TabDrawInfo) types.TabBarDraw {
    const layout = layoutTabBar(window, total_cols);
    var n: usize = 0;
    for (layout.entries()) |e| {
        if (n >= buf.len) break;
        const tab = window.tabs.items[e.tab_index];
        const close_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .close => |idx| idx == e.tab_index,
            else => false,
        } else false;
        const tab_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .activate => |idx| idx == e.tab_index,
            else => false,
        } else false;
        buf[n] = .{
            .col_start = @intCast(e.col_start),
            .col_end = @intCast(e.col_end),
            .close_col = @intCast(e.close_col),
            .tab_number = @intCast(e.tab_index + 1),
            .active = e.tab_index == window.active_index,
            .hovered = tab_hovered,
            .close_hovered = close_hovered,
            .title = displayTitle(tab.title_buf[0..tab.title_len]),
        };
        n += 1;
    }
    return .{
        .tabs = buf[0..n],
        .new_tab_col = if (layout.new_tab_col) |c| @intCast(c) else null,
        .new_tab_hovered = if (window.tab_bar_hover) |h| h == .new_tab else false,
    };
}
