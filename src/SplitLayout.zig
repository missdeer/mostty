//! Layout state shared by native Windows and macOS pane containers.
//! Coordinates use the host's units (pixels or points). Sessions and native
//! views remain host-owned; rearrangement only changes geometry and focus.
const SplitLayout = @This();
const std = @import("std");

pub const PaneId = u32;
pub const SplitId = u32;
pub const Axis = enum(u32) { columns, rows };
pub const Direction = enum(u32) { left, right, up, down };
pub const Size = extern struct { width: f64, height: f64 };
pub const Rect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
};
pub const Pane = extern struct { id: PaneId, rect: Rect };
pub const Divider = struct { id: SplitId, axis: Axis, rect: Rect };

const Branch = struct {
    id: SplitId,
    axis: Axis,
    ratio: f64 = 0.5,
    first: *Node,
    second: *Node,
};
const Node = struct {
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    data: union(enum) { pane: PaneId, branch: Branch },

    fn findPane(self: *Node, id: PaneId) ?*Node {
        return switch (self.data) {
            .pane => |pane| if (pane == id) self else null,
            .branch => |b| b.first.findPane(id) orelse b.second.findPane(id),
        };
    }

    fn findSplit(self: *Node, id: SplitId) ?*Node {
        return switch (self.data) {
            .pane => null,
            .branch => |b| if (b.id == id) self else b.first.findSplit(id) orelse b.second.findSplit(id),
        };
    }

    fn firstPane(self: *Node) PaneId {
        return switch (self.data) {
            .pane => |id| id,
            .branch => |b| b.first.firstPane(),
        };
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .pane => {},
            .branch => |b| {
                b.first.deinit(allocator);
                b.second.deinit(allocator);
            },
        }
        allocator.destroy(self);
    }

    fn minimum(self: *Node, leaf: Size, gap: f64) Size {
        return switch (self.data) {
            .pane => leaf,
            .branch => |b| blk: {
                const a = b.first.minimum(leaf, gap);
                const c = b.second.minimum(leaf, gap);
                break :blk switch (b.axis) {
                    .columns => .{ .width = a.width + c.width + gap, .height = @max(a.height, c.height) },
                    .rows => .{ .width = @max(a.width, c.width), .height = a.height + c.height + gap },
                };
            },
        };
    }

    fn arrange(self: *Node, rect: Rect, leaf: Size, gap: f64) void {
        self.rect = rect;
        switch (self.data) {
            .pane => {},
            .branch => |b| {
                const a = b.first.minimum(leaf, gap);
                const c = b.second.minimum(leaf, gap);
                const columns = b.axis == .columns;
                const extent = if (columns) rect.width else rect.height;
                const separator = @min(gap, extent);
                const available = extent - separator;
                const lo = if (columns) a.width else a.height;
                const hi = if (columns) c.width else c.height;
                // A forced small host resize must still partition its bounds.
                // Preserve the requested ratio so restoring size restores layout.
                const first = if (available >= lo + hi)
                    std.math.clamp(available * b.ratio, lo, available - hi)
                else
                    available * (lo / (lo + hi));
                var r1 = rect;
                var r2 = rect;
                if (columns) {
                    r1.width = first;
                    r2.x += first + separator;
                    r2.width = available - first;
                } else {
                    r1.height = first;
                    r2.y += first + separator;
                    r2.height = available - first;
                }
                b.first.arrange(r1, leaf, gap);
                b.second.arrange(r2, leaf, gap);
            },
        }
    }

    fn divider(self: *Node) Divider {
        const b = self.data.branch;
        const a = b.first.rect;
        const c = b.second.rect;
        return .{ .id = b.id, .axis = b.axis, .rect = switch (b.axis) {
            .columns => .{ .x = a.x + a.width, .y = self.rect.y, .width = @max(0, c.x - a.x - a.width), .height = self.rect.height },
            .rows => .{ .x = self.rect.x, .y = a.y + a.height, .width = self.rect.width, .height = @max(0, c.y - a.y - a.height) },
        } };
    }

    fn hitDivider(self: *Node, x: f64, y: f64) ?Divider {
        return switch (self.data) {
            .pane => null,
            .branch => |b| if (self.divider().rect.contains(x, y)) self.divider() else b.first.hitDivider(x, y) orelse b.second.hitDivider(x, y),
        };
    }

    fn writePanes(self: *Node, output: []Pane, count: *usize) void {
        switch (self.data) {
            .pane => |id| {
                if (count.* < output.len) output[count.*] = .{ .id = id, .rect = self.rect };
                count.* += 1;
            },
            .branch => |b| {
                b.first.writePanes(output, count);
                b.second.writePanes(output, count);
            },
        }
    }

    fn closeChild(self: *Node, allocator: std.mem.Allocator, id: PaneId) ?PaneId {
        switch (self.data) {
            .pane => return null,
            .branch => |b| {
                const removed: ?*Node = if (b.first.data == .pane and b.first.data.pane == id)
                    b.first
                else if (b.second.data == .pane and b.second.data.pane == id)
                    b.second
                else
                    null;
                if (removed) |leaf| {
                    const sibling = if (leaf == b.first) b.second else b.first;
                    const next = sibling.firstPane();
                    self.data = sibling.data;
                    allocator.destroy(leaf);
                    allocator.destroy(sibling);
                    return next;
                }
                return b.first.closeChild(allocator, id) orelse b.second.closeChild(allocator, id);
            },
        }
    }
};

allocator: std.mem.Allocator,
root: ?*Node,
active: ?PaneId,
maximized: bool = false,
count: usize = 1,
last_pane_id: PaneId,
last_split_id: SplitId = 0,
bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
leaf_minimum: Size = .{ .width = 1, .height = 1 },
gap: f64 = 0,

pub fn init(allocator: std.mem.Allocator, first: PaneId) !SplitLayout {
    if (first == 0) return error.InvalidId;
    const node = try allocator.create(Node);
    node.* = .{ .data = .{ .pane = first } };
    return .{ .allocator = allocator, .root = node, .active = first, .last_pane_id = first };
}

pub fn deinit(self: *SplitLayout) void {
    if (self.root) |root| root.deinit(self.allocator);
    self.* = undefined;
}

/// The host supplies one consistent unit system. Invalid geometry is rejected
/// without replacing the last usable layout (including NaN from a C caller).
pub fn setBounds(self: *SplitLayout, bounds: Rect, minimum: Size, gap: f64) !void {
    for ([_]f64{ bounds.x, bounds.y, bounds.width, bounds.height, minimum.width, minimum.height, gap }) |v| {
        if (!std.math.isFinite(v)) return error.InvalidGeometry;
    }
    if (bounds.width < 0 or bounds.height < 0 or minimum.width <= 0 or minimum.height <= 0 or gap < 0)
        return error.InvalidGeometry;
    self.bounds = bounds;
    self.leaf_minimum = minimum;
    self.gap = gap;
    self.arrange();
}

fn arrange(self: *SplitLayout) void {
    if (self.root) |root| root.arrange(self.bounds, self.leaf_minimum, self.gap);
}

pub fn minimumSize(self: *SplitLayout) Size {
    return if (self.root) |root| root.minimum(self.leaf_minimum, self.gap) else .{ .width = 0, .height = 0 };
}

/// Check geometry before starting a host session. The mutating split checks
/// again because native session creation may allow the host bounds to change.
pub fn canSplit(self: *SplitLayout, target: PaneId, axis: Axis) bool {
    const root = self.root orelse return false;
    const node = root.findPane(target) orelse return false;
    const m = self.leaf_minimum;
    const needed: Size = switch (axis) {
        .columns => .{ .width = m.width * 2 + self.gap, .height = m.height },
        .rows => .{ .width = m.width, .height = m.height * 2 + self.gap },
    };
    return node.rect.width >= needed.width and node.rect.height >= needed.height;
}

/// IDs are host-issued, strictly increasing and never reused in this layout.
/// Failure leaves geometry, focus and identities unchanged.
pub fn split(self: *SplitLayout, target: PaneId, new_id: PaneId, axis: Axis) !void {
    const root = self.root orelse return error.UnknownPane;
    const node = root.findPane(target) orelse return error.UnknownPane;
    if (new_id <= self.last_pane_id) return error.InvalidId;
    if (self.last_split_id == std.math.maxInt(SplitId)) return error.IdExhausted;
    if (!self.canSplit(target, axis)) return error.TooSmall;
    const first = try self.allocator.create(Node);
    errdefer self.allocator.destroy(first);
    const second = try self.allocator.create(Node);
    first.* = node.*;
    second.* = .{ .data = .{ .pane = new_id } };
    self.last_split_id += 1;
    node.data = .{ .branch = .{ .id = self.last_split_id, .axis = axis, .first = first, .second = second } };
    self.last_pane_id = new_id;
    self.count += 1;
    self.active = new_id;
    self.maximized = false;
    self.arrange();
}

pub fn close(self: *SplitLayout, id: PaneId) bool {
    const root = self.root orelse return false;
    if (root.data == .pane) {
        if (root.data.pane != id) return false;
        self.allocator.destroy(root);
        self.root = null;
        self.active = null;
        self.count = 0;
        self.maximized = false;
        return true;
    }
    const next = root.closeChild(self.allocator, id) orelse return false;
    self.count -= 1;
    if (self.count == 1) self.maximized = false;
    if (self.active == id) {
        self.active = next;
        self.maximized = false;
    }
    self.arrange();
    return true;
}

pub fn focus(self: *SplitLayout, id: PaneId) bool {
    const root = self.root orelse return false;
    if (root.findPane(id) == null) return false;
    self.active = id;
    return true;
}

pub fn toggleMaximize(self: *SplitLayout) void {
    if (self.count > 1) self.maximized = !self.maximized;
}

pub fn paneRect(self: *SplitLayout, id: PaneId) ?Rect {
    const root = self.root orelse return null;
    const node = root.findPane(id) orelse return null;
    if (self.maximized) return if (self.active == id) self.bounds else null;
    return node.rect;
}

/// Returns the required output count even for a size query (empty output).
pub fn writePanes(self: *SplitLayout, output: []Pane) usize {
    const root = self.root orelse return 0;
    if (self.maximized) {
        if (output.len > 0) output[0] = .{ .id = self.active.?, .rect = self.bounds };
        return 1;
    }
    var count: usize = 0;
    root.writePanes(output, &count);
    return count;
}

pub fn hitDivider(self: *SplitLayout, x: f64, y: f64) ?Divider {
    if (self.maximized) return null;
    const root = self.root orelse return null;
    return root.hitDivider(x, y);
}

/// Position is the divider's leading edge in host coordinates. A capture
/// stores SplitId, not a node pointer: collapsed splits cannot be retargeted.
pub fn drag(self: *SplitLayout, id: SplitId, position: f64) bool {
    if (self.maximized or !std.math.isFinite(position)) return false;
    const root = self.root orelse return false;
    const node = root.findSplit(id) orelse return false;
    const b = &node.data.branch;
    const a = b.first.minimum(self.leaf_minimum, self.gap);
    const c = b.second.minimum(self.leaf_minimum, self.gap);
    const columns = b.axis == .columns;
    const available = (if (columns) node.rect.width else node.rect.height) - self.gap;
    const lo = if (columns) a.width else a.height;
    const hi = if (columns) c.width else c.height;
    if (available < lo + hi) return false;
    const offset = position - (if (columns) node.rect.x else node.rect.y);
    b.ratio = std.math.clamp(offset, lo, available - hi) / available;
    self.arrange();
    return true;
}

const FocusCandidate = struct { id: ?PaneId = null, distance: f64 = std.math.inf(f64), cross: f64 = std.math.inf(f64) };

fn directional(node: *Node, source: Rect, current: PaneId, direction: Direction, best: *FocusCandidate) void {
    switch (node.data) {
        .branch => |b| {
            directional(b.first, source, current, direction, best);
            directional(b.second, source, current, direction, best);
        },
        .pane => |id| {
            if (id == current) return;
            const r = node.rect;
            const horizontal = direction == .left or direction == .right;
            const overlap = if (horizontal)
                @min(source.y + source.height, r.y + r.height) - @max(source.y, r.y)
            else
                @min(source.x + source.width, r.x + r.width) - @max(source.x, r.x);
            if (overlap <= 0) return;
            const distance = switch (direction) {
                .left => source.x - r.x - r.width,
                .right => r.x - source.x - source.width,
                .up => source.y - r.y - r.height,
                .down => r.y - source.y - source.height,
            };
            if (distance < -0.000001) return;
            const cross = if (horizontal)
                @abs(source.y + source.height / 2 - r.y - r.height / 2)
            else
                @abs(source.x + source.width / 2 - r.x - r.width / 2);
            if (distance < best.distance or (distance == best.distance and cross < best.cross))
                best.* = .{ .id = id, .distance = distance, .cross = cross };
        },
    }
}

/// Uses the underlying split geometry while maximized, so changing focus can
/// reveal another pane without losing the saved tree or ratios. No wrapping.
pub fn focusDirection(self: *SplitLayout, direction: Direction) bool {
    const root = self.root orelse return false;
    const current = self.active orelse return false;
    const source = root.findPane(current).?.rect;
    var candidate: FocusCandidate = .{};
    directional(root, source, current, direction, &candidate);
    const id = candidate.id orelse return false;
    self.active = id;
    return true;
}

test "four nested panes partition bounds and focus follows physical direction" {
    var layout = try SplitLayout.init(std.testing.allocator, 1);
    defer layout.deinit();
    try layout.setBounds(.{ .x = 10, .y = 20, .width = 804, .height = 604 }, .{ .width = 80, .height = 40 }, 4);
    try layout.split(1, 2, .columns);
    try layout.split(1, 3, .rows);
    try layout.split(2, 4, .rows);
    try std.testing.expectEqual(@as(usize, 4), layout.count);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .width = 400, .height = 300 }, layout.paneRect(1).?);
    try std.testing.expectEqual(Rect{ .x = 414, .y = 324, .width = 400, .height = 300 }, layout.paneRect(4).?);
    try std.testing.expect(layout.focusDirection(.left));
    try std.testing.expectEqual(@as(?PaneId, 3), layout.active);
    try std.testing.expect(layout.focusDirection(.up));
    try std.testing.expectEqual(@as(?PaneId, 1), layout.active);
    try std.testing.expect(!layout.focusDirection(.up));
    try std.testing.expect(layout.focusDirection(.right));
    try std.testing.expectEqual(@as(?PaneId, 2), layout.active);
    var panes: [4]Pane = undefined;
    try std.testing.expectEqual(@as(usize, 4), layout.writePanes(&panes));
    try std.testing.expectEqual(@as(usize, 4), layout.writePanes(&.{}));
    try std.testing.expectEqualSlices(PaneId, &.{ 1, 3, 2, 4 }, &.{ panes[0].id, panes[1].id, panes[2].id, panes[3].id });
}

test "divider drag respects both subtree minima and restores ratios after small bounds" {
    var layout = try SplitLayout.init(std.testing.allocator, 10);
    defer layout.deinit();
    const bounds: Rect = .{ .x = 20, .y = 30, .width = 1000, .height = 600 };
    const minimum: Size = .{ .width = 80, .height = 40 };
    try layout.setBounds(bounds, minimum, 4);
    try layout.split(10, 11, .columns);
    try layout.split(11, 12, .columns);
    const divider = layout.hitDivider(519, 40).?;
    try std.testing.expect(layout.drag(divider.id, 10000));
    try std.testing.expectEqual(@as(f64, 80), layout.paneRect(11).?.width);
    try std.testing.expectEqual(@as(f64, 80), layout.paneRect(12).?.width);
    const saved = layout.paneRect(10).?;
    try layout.setBounds(.{ .x = 20, .y = 30, .width = 10, .height = 2 }, minimum, 4);
    var panes: [3]Pane = undefined;
    _ = layout.writePanes(&panes);
    for (panes) |pane| {
        try std.testing.expect(pane.rect.width >= 0 and pane.rect.height >= 0);
        try std.testing.expect(pane.rect.x + pane.rect.width <= 30);
    }
    try std.testing.expect(!layout.drag(divider.id, 25));
    try layout.setBounds(bounds, minimum, 4);
    try std.testing.expectEqual(saved, layout.paneRect(10).?);
    try std.testing.expectEqual(Size{ .width = 248, .height = 40 }, layout.minimumSize());
}

test "maximize and focus preserve layout; close collapses only the removed pane" {
    var layout = try SplitLayout.init(std.testing.allocator, 1);
    defer layout.deinit();
    try layout.setBounds(.{ .x = 0, .y = 0, .width = 804, .height = 604 }, .{ .width = 80, .height = 40 }, 4);
    try layout.split(1, 2, .columns);
    try layout.split(2, 3, .rows);
    const saved = layout.paneRect(3).?;
    layout.toggleMaximize();
    try std.testing.expectEqual(layout.bounds, layout.paneRect(3).?);
    try std.testing.expectEqual(@as(?Rect, null), layout.paneRect(1));
    try std.testing.expectEqual(@as(usize, 1), layout.writePanes(&.{}));
    try std.testing.expect(layout.focusDirection(.up));
    try std.testing.expectEqual(@as(?PaneId, 2), layout.active);
    layout.toggleMaximize();
    try std.testing.expectEqual(saved, layout.paneRect(3).?);
    const divider = layout.hitDivider(500, 301).?;
    try std.testing.expect(layout.close(2));
    try std.testing.expectEqual(@as(?PaneId, 3), layout.active);
    try std.testing.expectEqual(@as(f64, 604), layout.paneRect(3).?.height);
    try std.testing.expect(!layout.drag(divider.id, 100));
    try std.testing.expect(!layout.close(2));
    try std.testing.expect(layout.close(1));
    try std.testing.expectEqual(layout.bounds, layout.paneRect(3).?);
    try std.testing.expect(layout.close(3));
    try std.testing.expectEqual(@as(usize, 0), layout.count);
    try std.testing.expectEqual(@as(?PaneId, null), layout.active);
    try std.testing.expect(!layout.focusDirection(.left));
}

test "failed split and invalid geometry leave the previous layout intact" {
    var layout = try SplitLayout.init(std.testing.allocator, 1);
    defer layout.deinit();
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 163, .height = 80 };
    try layout.setBounds(bounds, .{ .width = 80, .height = 40 }, 4);
    try std.testing.expect(!layout.canSplit(1, .columns));
    try std.testing.expectError(error.TooSmall, layout.split(1, 2, .columns));
    try std.testing.expectEqual(@as(usize, 1), layout.count);
    try std.testing.expectEqual(bounds, layout.paneRect(1).?);
    try std.testing.expectError(error.InvalidGeometry, layout.setBounds(bounds, .{ .width = std.math.nan(f64), .height = 1 }, 4));
    try std.testing.expectEqual(bounds, layout.bounds);
    try std.testing.expectError(error.UnknownPane, layout.split(42, 2, .rows));
    try std.testing.expectError(error.InvalidId, layout.split(1, 1, .rows));
    try layout.setBounds(.{ .x = 0, .y = 0, .width = 164, .height = 80 }, .{ .width = 80, .height = 40 }, 4);
    try std.testing.expect(layout.canSplit(1, .columns));
    try layout.split(1, 2, .columns);
    try std.testing.expectEqual(@as(f64, 80), layout.paneRect(1).?.width);
    try std.testing.expect(layout.close(2));
    try std.testing.expectError(error.InvalidId, layout.split(1, 2, .columns));
    try layout.split(1, 3, .columns);
}

test "allocation failure during split does not consume IDs or change ownership" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var layout = try SplitLayout.init(allocator, 1);
            defer layout.deinit();
            try layout.setBounds(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .width = 80, .height = 40 }, 4);
            layout.split(1, 2, .columns) catch |err| {
                try std.testing.expectEqual(@as(usize, 1), layout.count);
                try std.testing.expectEqual(@as(PaneId, 1), layout.last_pane_id);
                try std.testing.expectEqual(layout.bounds, layout.paneRect(1).?);
                return err;
            };
            try std.testing.expectEqual(@as(usize, 2), layout.count);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}
