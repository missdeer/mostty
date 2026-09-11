//! Thin host bridge; all layout decisions remain in SplitLayout.
//! Handles are owned by one tab and accessed only on the UI thread.
const std = @import("std");
const Layout = @import("SplitLayout.zig");
const allocator = std.heap.page_allocator;
const Divider = extern struct { id: u32, axis: u32, rect: Layout.Rect };

export fn mostty_layout_create(first: u32) ?*Layout {
    const layout = allocator.create(Layout) catch return null;
    layout.* = Layout.init(allocator, first) catch {
        allocator.destroy(layout);
        return null;
    };
    return layout;
}

export fn mostty_layout_destroy(layout: *Layout) void {
    layout.deinit();
    allocator.destroy(layout);
}

export fn mostty_layout_bounds(layout: *Layout, bounds: Layout.Rect, minimum: Layout.Size, gap: f64) bool {
    layout.setBounds(bounds, minimum, gap) catch return false;
    return true;
}

export fn mostty_layout_minimum(layout: *Layout) Layout.Size {
    return layout.minimumSize();
}

export fn mostty_layout_active(layout: *Layout) u32 {
    return layout.active orelse 0;
}

export fn mostty_layout_can_split(layout: *Layout, target: u32, axis: u32) bool {
    return layout.canSplit(target, std.enums.fromInt(Layout.Axis, axis) orelse return false);
}

export fn mostty_layout_split(layout: *Layout, target: u32, new_id: u32, axis: u32) bool {
    layout.split(target, new_id, std.enums.fromInt(Layout.Axis, axis) orelse return false) catch return false;
    return true;
}

export fn mostty_layout_close(layout: *Layout, id: u32) bool {
    return layout.close(id);
}

export fn mostty_layout_focus(layout: *Layout, id: u32) bool {
    return layout.focus(id);
}

export fn mostty_layout_direction(layout: *Layout, direction: u32) bool {
    return layout.focusDirection(std.enums.fromInt(Layout.Direction, direction) orelse return false);
}

export fn mostty_layout_maximize(layout: *Layout) void {
    layout.toggleMaximize();
}

export fn mostty_layout_panes(layout: *Layout, output: ?[*]Layout.Pane, cap: usize) usize {
    return layout.writePanes(if (output) |p| p[0..cap] else &.{});
}

export fn mostty_layout_divider(layout: *Layout, x: f64, y: f64, output: *Divider) bool {
    const divider = layout.hitDivider(x, y) orelse return false;
    output.* = .{ .id = divider.id, .axis = @intFromEnum(divider.axis), .rect = divider.rect };
    return true;
}

export fn mostty_layout_drag(layout: *Layout, id: u32, position: f64) bool {
    return layout.drag(id, position);
}

test "C bridge preserves shared four-pane geometry, focus, drag, maximize and collapse" {
    const t = std.testing;
    const layout = mostty_layout_create(1).?;
    defer mostty_layout_destroy(layout);
    try t.expect(mostty_layout_bounds(layout, .{ .x = 0, .y = 0, .width = 804, .height = 604 }, .{ .width = 80, .height = 40 }, 4));
    try t.expect(mostty_layout_can_split(layout, 1, 0));
    try t.expect(mostty_layout_split(layout, 1, 2, 0));
    try t.expect(mostty_layout_split(layout, 1, 3, 1));
    try t.expect(mostty_layout_split(layout, 2, 4, 1));
    try t.expectEqual(@as(usize, 4), mostty_layout_panes(layout, null, 0));
    var panes: [4]Layout.Pane = undefined;
    try t.expectEqual(@as(usize, 4), mostty_layout_panes(layout, &panes, panes.len));
    try t.expectEqual(Layout.Rect{ .x = 404, .y = 304, .width = 400, .height = 300 }, panes[3].rect);
    var divider: Divider = undefined;
    try t.expect(mostty_layout_divider(layout, 402, 100, &divider));
    try t.expect(mostty_layout_drag(layout, divider.id, 1));
    _ = mostty_layout_panes(layout, &panes, panes.len);
    try t.expectEqual(@as(f64, 80), panes[0].rect.width);
    try t.expectEqual(@as(u32, 4), mostty_layout_active(layout));
    try t.expect(mostty_layout_direction(layout, 0));
    try t.expectEqual(@as(u32, 3), mostty_layout_active(layout));
    mostty_layout_maximize(layout);
    try t.expectEqual(@as(usize, 1), mostty_layout_panes(layout, &panes, panes.len));
    try t.expectEqual(@as(f64, 804), panes[0].rect.width);
    try t.expect(mostty_layout_direction(layout, 2));
    try t.expectEqual(@as(u32, 1), mostty_layout_active(layout));
    mostty_layout_maximize(layout);
    _ = mostty_layout_panes(layout, &panes, panes.len);
    try t.expectEqual(@as(f64, 80), panes[0].rect.width);
    try t.expect(mostty_layout_close(layout, 1));
    try t.expectEqual(@as(u32, 3), mostty_layout_active(layout));
    try t.expect(mostty_layout_close(layout, 3));
    try t.expect(!mostty_layout_drag(layout, divider.id, 200));
    try t.expect(mostty_layout_close(layout, 2));
    try t.expect(mostty_layout_close(layout, 4));
    try t.expectEqual(@as(u32, 0), mostty_layout_active(layout));
    try t.expectEqual(@as(usize, 0), mostty_layout_panes(layout, null, 0));
}

test "C bridge rejects invalid enum and geometry inputs without changing layout" {
    const t = std.testing;
    try t.expect(mostty_layout_create(0) == null);
    const layout = mostty_layout_create(1).?;
    defer mostty_layout_destroy(layout);
    try t.expect(!mostty_layout_bounds(layout, .{ .x = 0, .y = 0, .width = std.math.nan(f64), .height = 100 }, .{ .width = 80, .height = 40 }, 4));
    try t.expect(!mostty_layout_can_split(layout, 1, 2));
    try t.expect(!mostty_layout_split(layout, 1, 2, 2));
    try t.expect(!mostty_layout_direction(layout, 4));
    try t.expect(!mostty_layout_focus(layout, 0));
    try t.expectEqual(@as(u32, 1), mostty_layout_active(layout));
    try t.expectEqual(@as(usize, 1), mostty_layout_panes(layout, null, 100));
}
