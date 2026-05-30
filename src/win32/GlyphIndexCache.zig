const GlyphIndexCache = @This();
const std = @import("std");

pub const Half = enum(u2) { single, wide_left, wide_right };

// One slot per (codepoint, half, style) so the same character rendered in
// regular/bold/italic/bold-italic occupies distinct atlas entries. We trust
// the LRU to absorb the 4x style fanout — real workloads are regular-dominant
// with bold/italic as sparse syntax/prompt embellishments.
pub const Style = enum(u2) { regular, bold, italic, bold_italic };

pub const Key = struct {
    hash_a: u64,
    hash_b: u64,
    len: u16,
    half: Half,
    style: Style,

    pub fn init(first: u21, rest: []const u21, half: Half, style: Style) Key {
        var h_a = std.hash.Wyhash.init(0);
        h_a.update(std.mem.asBytes(&first));
        h_a.update(std.mem.sliceAsBytes(rest));

        var h_b = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        h_b.update(std.mem.asBytes(&first));
        h_b.update(std.mem.sliceAsBytes(rest));

        return .{
            .hash_a = h_a.final(),
            .hash_b = h_b.final(),
            .len = @intCast(1 + rest.len),
            .half = half,
            .style = style,
        };
    }
};

const Node = struct {
    prev: ?u32,
    next: ?u32,
    key: ?Key,
    // Frame counter of the last cache hit that promoted this node. Used
    // to dampen LRU promotion to once per frame so the inner render loop
    // doesn't rewrite linked-list pointers on every cell visit. See
    // `reserve` and `beginFrame`.
    touched_frame: u32 = 0,
};

map: std.AutoHashMapUnmanaged(Key, u32) = .{},
nodes: []Node,
front: u32,
back: u32,
/// Monotonic frame counter bumped by `beginFrame()`. Wraps cleanly;
/// equality compare against `Node.touched_frame` is the only use.
frame: u32 = 0,

pub fn init(allocator: std.mem.Allocator, capacity: u32) error{OutOfMemory}!GlyphIndexCache {
    var result: GlyphIndexCache = .{
        .map = .{},
        .nodes = try allocator.alloc(Node, capacity),
        .front = undefined,
        .back = undefined,
    };
    result.clearRetainingCapacity();
    return result;
}

pub fn clearRetainingCapacity(self: *GlyphIndexCache) void {
    self.map.clearRetainingCapacity();
    self.nodes[0] = .{ .prev = null, .next = 1, .key = null };
    self.nodes[self.nodes.len - 1] = .{ .prev = @intCast(self.nodes.len - 2), .next = null, .key = null };
    for (self.nodes[1 .. self.nodes.len - 1], 1..) |*node, index| {
        node.* = .{
            .prev = @intCast(index - 1),
            .next = @intCast(index + 1),
            .key = null,
        };
    }
    self.front = 0;
    self.back = @intCast(self.nodes.len - 1);
    self.frame = 0;
}

/// Begin a render frame. Caller must invoke this once per render() so
/// the per-frame LRU dampening below works.
pub fn beginFrame(self: *GlyphIndexCache) void {
    self.frame +%= 1;
}

pub fn deinit(self: *GlyphIndexCache, allocator: std.mem.Allocator) void {
    allocator.free(self.nodes);
    self.map.deinit(allocator);
}

const Reserved = struct {
    index: u32,
    replaced: ?Key,
};
pub fn reserve(self: *GlyphIndexCache, allocator: std.mem.Allocator, key: Key) error{OutOfMemory}!union(enum) {
    newly_reserved: Reserved,
    already_reserved: u32,
} {
    {
        const entry = try self.map.getOrPut(allocator, key);
        if (entry.found_existing) {
            const idx = entry.value_ptr.*;
            // Per-frame LRU dampening: a single render frame visits
            // many cells that hit the same glyph (think every space in
            // a row). Promoting on the first hit per frame is enough to
            // preserve LRU ordering; subsequent same-frame hits skip
            // the linked-list rewrite. Cuts ~12k pointer writes/frame
            // at a 200x60 grid down to a few hundred.
            if (self.nodes[idx].touched_frame != self.frame) {
                self.nodes[idx].touched_frame = self.frame;
                self.moveToBack(idx);
            }
            return .{ .already_reserved = idx };
        }
        entry.value_ptr.* = self.front;
    }

    std.debug.assert(self.nodes[self.front].prev == null);
    std.debug.assert(self.nodes[self.front].next != null);
    const replaced = self.nodes[self.front].key;
    self.nodes[self.front].key = key;
    self.nodes[self.front].touched_frame = self.frame;
    if (replaced) |r| {
        const removed = self.map.remove(r);
        std.debug.assert(removed);
    }
    const save_front = self.front;
    self.moveToBack(self.front);
    return .{ .newly_reserved = .{ .index = save_front, .replaced = replaced } };
}

/// Force `index` to the LRU back, unconditionally — bypasses the per-frame
/// dampening in `reserve`. Use when the caller is about to perform another
/// `reserve` whose miss path could otherwise evict the just-hit slot.
///
/// Motivating case: `D3d11Renderer.generateWidePair` reserves wide_left then
/// wide_right. If wide_left was already touched this frame, `reserve` skips
/// moveToBack to amortize the linked-list rewrite (see the dampening comment
/// in `reserve`). A subsequent wide_right miss would then evict the current
/// `self.front`, which may now be wide_left's slot if intervening misses
/// pushed it back toward the front. Calling `touch(left_index)` between the
/// two reserves restores the LRU invariant that left is at back.
pub fn touch(self: *GlyphIndexCache, index: u32) void {
    self.nodes[index].touched_frame = self.frame;
    self.moveToBack(index);
}

fn moveToBack(self: *GlyphIndexCache, index: u32) void {
    if (index == self.back) return;

    const node = &self.nodes[index];
    if (node.prev) |prev| {
        self.nodes[prev].next = node.next;
    } else {
        self.front = node.next.?;
    }

    if (node.next) |next| {
        self.nodes[next].prev = node.prev;
    }

    self.nodes[self.back].next = index;
    node.prev = self.back;
    node.next = null;
    self.back = index;
}

// Pins the load-bearing invariant for D3d11Renderer.generateWidePair:
// `touch(idx)` must promote `idx` to the LRU back even when the per-frame
// dampening in `reserve` would have left it at the front.
test "touch promotes a dampened slot past the next miss-eviction" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 3);
    defer cache.deinit(allocator);

    cache.beginFrame();

    const k_a: Key = .init('a', &.{}, .single, .regular);
    const k_b: Key = .init('b', &.{}, .single, .regular);
    const k_c: Key = .init('c', &.{}, .single, .regular);
    const k_d: Key = .init('d', &.{}, .single, .regular);

    const ra = try cache.reserve(allocator, k_a);
    const idx_a = switch (ra) {
        .newly_reserved => |r| r.index,
        .already_reserved => unreachable,
    };
    _ = try cache.reserve(allocator, k_b);
    _ = try cache.reserve(allocator, k_c);
    // LRU order: a (front, victim), b, c (back).

    // Hit a again in the same frame. Dampening skips moveToBack, so a stays
    // at the front — the very situation generateWidePair triggers when a
    // wide_left was already touched earlier in the frame.
    const ra_dampened = try cache.reserve(allocator, k_a);
    try std.testing.expectEqual(idx_a, switch (ra_dampened) {
        .already_reserved => |idx| idx,
        .newly_reserved => unreachable,
    });

    // Force-promote. Without this call, the next miss would evict a.
    cache.touch(idx_a);

    // Miss → evicts the current front. If touch worked, front is b, not a.
    _ = try cache.reserve(allocator, k_d);

    // a must survive (hit, same index).
    const ra_after = try cache.reserve(allocator, k_a);
    try std.testing.expectEqual(idx_a, switch (ra_after) {
        .already_reserved => |idx| idx,
        .newly_reserved => unreachable,
    });
    // b must have been the eviction victim.
    const rb_after = try cache.reserve(allocator, k_b);
    try std.testing.expect(switch (rb_after) {
        .newly_reserved => true,
        .already_reserved => false,
    });
}

test "grapheme keys include full codepoint sequence" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 4);
    defer cache.deinit(allocator);

    cache.beginFrame();

    const thumbs_up: Key = .init(0x1F44D, &.{}, .single, .regular);
    const thumbs_up_medium_skin: Key = .init(0x1F44D, &.{0x1F3FD}, .single, .regular);
    const family: Key = .init(0x1F468, &.{ 0x200D, 0x1F469, 0x200D, 0x1F467 }, .wide_left, .regular);

    const a = try cache.reserve(allocator, thumbs_up);
    const b = try cache.reserve(allocator, thumbs_up_medium_skin);
    const c = try cache.reserve(allocator, family);

    try std.testing.expect(switch (a) {
        .newly_reserved => true,
        .already_reserved => false,
    });
    try std.testing.expect(switch (b) {
        .newly_reserved => true,
        .already_reserved => false,
    });
    try std.testing.expect(switch (c) {
        .newly_reserved => true,
        .already_reserved => false,
    });
}
