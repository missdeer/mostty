const std = @import("std");

const d3d11 = @import("d3d11.zig");
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

pub fn buildTabBarRow(window: *Window, total_cols: usize, row: []d3d11.TabBarCell) void {
    const bg_default = d3d11.TabBarCell.rgba(types.tab_bar_bg);
    const fg_default = d3d11.TabBarCell.rgba(types.tab_bar_fg);
    for (row) |*c| c.* = .{ .codepoint = ' ', .bg = bg_default, .fg = fg_default };

    const layout = layoutTabBar(window, total_cols);
    for (layout.entries()) |e| {
        const is_active = e.tab_index == window.active_index;
        const tab = window.tabs.items[e.tab_index];
        const close_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .close => |idx| idx == e.tab_index,
            else => false,
        } else false;
        const tab_hovered = if (window.tab_bar_hover) |h| switch (h) {
            .activate => |idx| idx == e.tab_index,
            else => false,
        } else false;
        const bg_u24: u24 = if (is_active) types.tab_active_bg else if (tab_hovered) types.tab_hover_bg else types.tab_bar_bg;
        const fg_u24: u24 = if (is_active) types.tab_active_fg else types.tab_bar_fg;
        const cell_bg = d3d11.TabBarCell.rgba(bg_u24);
        const cell_fg = d3d11.TabBarCell.rgba(fg_u24);

        var col = e.col_start;
        while (col < e.col_end) : (col += 1) {
            row[col] = .{ .codepoint = ' ', .bg = cell_bg, .fg = cell_fg };
        }

        // Title text, leaving room for a leading space and trailing " x"
        const title_start = e.col_start + 1;
        const title_end_inclusive = if (e.close_col > 1) e.close_col - 2 else e.col_start;
        const max_title_cols = if (title_end_inclusive >= title_start) title_end_inclusive - title_start + 1 else 0;

        const title = displayTitle(tab.title_buf[0..tab.title_len]);
        var title_cols_written: usize = 0;
        var i: usize = 0;
        while (i < title.len and title_cols_written < max_title_cols) {
            const seq_len = std.unicode.utf8ByteSequenceLength(title[i]) catch {
                row[title_start + title_cols_written] = .{ .codepoint = '?', .bg = cell_bg, .fg = cell_fg };
                title_cols_written += 1;
                i += 1;
                continue;
            };
            if (i + seq_len > title.len) break;
            const cp = std.unicode.utf8Decode(title[i .. i + seq_len]) catch {
                row[title_start + title_cols_written] = .{ .codepoint = '?', .bg = cell_bg, .fg = cell_fg };
                title_cols_written += 1;
                i += seq_len;
                continue;
            };
            row[title_start + title_cols_written] = .{ .codepoint = @intCast(cp), .bg = cell_bg, .fg = cell_fg };
            title_cols_written += 1;
            i += seq_len;
        }
        // Pad title area with tab id digit if no title yet
        if (tab.title_len == 0 and max_title_cols > 0) {
            var idbuf: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&idbuf, "tab {d}", .{e.tab_index + 1}) catch idbuf[0..0];
            const lim = @min(s.len, max_title_cols);
            for (s[0..lim], 0..) |ch, k| {
                row[title_start + k] = .{ .codepoint = ch, .bg = cell_bg, .fg = cell_fg };
            }
        }

        // Close button '×'
        if (e.close_col < e.col_end) {
            const close_fg_u24: u24 = if (close_hovered) 0xff5555 else fg_u24;
            row[e.close_col] = .{
                .codepoint = 'x',
                .bg = cell_bg,
                .fg = d3d11.TabBarCell.rgba(close_fg_u24),
            };
        }
    }
    if (layout.new_tab_col) |c| {
        const hover = if (window.tab_bar_hover) |h| h == .new_tab else false;
        const fg_u24: u24 = if (hover) 0xffffff else types.new_tab_button_fg;
        row[c] = .{
            .codepoint = '+',
            .bg = d3d11.TabBarCell.rgba(types.tab_bar_bg),
            .fg = d3d11.TabBarCell.rgba(fg_u24),
        };
    }
}
