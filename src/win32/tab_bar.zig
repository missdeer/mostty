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

pub fn layoutTabBar(total_cols: usize, tab_count: usize, active_index: usize) TabBarLayout {
    var layout: TabBarLayout = .{ .entries_buf = undefined, .entries_len = 0, .new_tab_col = null };
    if (total_cols == 0 or tab_count == 0) return layout;

    const new_tab_w: usize = 4;
    const min_tab_w: usize = 6;

    const usable_for_tabs = if (total_cols > new_tab_w) total_cols - new_tab_w else 0;
    if (total_cols >= new_tab_w) layout.new_tab_col = total_cols - 2;
    const n = @min(@min(tab_count, MAX_TABS), usable_for_tabs / min_tab_w);
    if (n == 0) return layout;
    // Keep the selected tab visible when the window cannot fit every tab.
    const selected = @min(active_index, tab_count - 1);
    const first = if (selected >= n) selected - n + 1 else 0;

    for (0..n) |i| {
        const col = usable_for_tabs * i / n;
        const end = usable_for_tabs * (i + 1) / n;
        if (layout.entries_len >= layout.entries_buf.len) break;
        layout.entries_buf[layout.entries_len] = .{
            .tab_index = first + i,
            .col_start = col,
            .col_end = end,
            .close_col = end - 2,
        };
        layout.entries_len += 1;
    }
    return layout;
}

pub fn hitTestTabBar(window: *Window, total_cols: usize, mouse_x: i32, cs_x: i32) TabHit {
    if (mouse_x < 0 or cs_x <= 0) return .none;
    const col: usize = @intCast(@max(0, @divTrunc(mouse_x, cs_x)));
    const layout = layoutTabBar(total_cols, window.tabs.items.len, window.active_index);
    for (layout.entries()) |e| {
        if (col >= e.col_start and col < e.col_end) {
            if (col == e.close_col) return .{ .close = e.tab_index };
            return .{ .activate = e.tab_index };
        }
    }
    if (layout.new_tab_col) |c| {
        if (col >= c - 1 and col <= c + 1) return .new_tab;
    }
    return .none;
}

/// Shared, platform-neutral presentation rule: a path-shaped title is reduced to
/// its final component for the tab bar; separator-free titles pass through. Kept
/// in the terminal core so Windows and macOS stay in sync (see `../terminal/title.zig`).
pub const displayTitle = @import("../terminal/title.zig").displayTitle;

// Builds the per-tab drawing list consumed by the proportional D2D painter.
// Column ranges come straight from `layoutTabBar` (tab widths/buttons stay
// column-based); the painter converts columns to pixels and draws titles with
// DirectWrite. `buf` must hold at least MAX_TABS entries; titles borrow each
// tab's title buffer and are valid only for the current render call.
pub fn buildTabBarDraw(window: *Window, total_cols: usize, buf: []types.TabDrawInfo) types.TabBarDraw {
    const layout = layoutTabBar(total_cols, window.tabs.items.len, window.active_index);
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

test "tabs fill available width equally and reserve the new-tab control" {
    for ([_]usize{ 40, 101, 240 }) |width| {
        const layout = layoutTabBar(width, 3, 0);
        try std.testing.expectEqual(3, layout.entries_len);
        try std.testing.expectEqual(0, layout.entries()[0].col_start);
        try std.testing.expectEqual(width - 4, layout.entries()[2].col_end);
        var previous_end: usize = 0;
        for (layout.entries()) |entry| {
            try std.testing.expectEqual(previous_end, entry.col_start);
            const tab_width = entry.col_end - entry.col_start;
            try std.testing.expect(tab_width >= (width - 4) / 3 and tab_width <= (width - 4) / 3 + 1);
            try std.testing.expectEqual(entry.col_end - 2, entry.close_col);
            previous_end = entry.col_end;
        }
        try std.testing.expect(layout.new_tab_col.? - 1 >= previous_end);
        try std.testing.expect(layout.new_tab_col.? + 1 < width);
    }
}

test "overflow keeps selected tab visible without displacing the new-tab control" {
    const layout = layoutTabBar(40, 32, 31);
    try std.testing.expectEqual(6, layout.entries_len);
    try std.testing.expectEqual(31, layout.entries()[5].tab_index);
    try std.testing.expectEqual(38, layout.new_tab_col.?);
    try std.testing.expectEqual(0, layoutTabBar(0, 3, 0).entries_len);
    try std.testing.expectEqual(0, layoutTabBar(40, 0, 0).entries_len);
    const tiny = layoutTabBar(4, 3, 0);
    try std.testing.expectEqual(0, tiny.entries_len);
    try std.testing.expectEqual(2, tiny.new_tab_col.?);
}
