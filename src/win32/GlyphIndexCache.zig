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
    // The slot has been reserved for a key whose pixels are still being
    // rasterized off the UI thread; LRU eviction must skip it. Cleared by
    // `markReady` once the worker uploads the glyph.
    pending: bool = false,
    // Bumped on every reserve that takes this slot. The worker captures this
    // value at submit time; `markReady` rejects results whose captured
    // generation no longer matches (the slot was reused for another key).
    gen: u32 = 0,
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

pub const NewlyReservedPending = struct {
    index: u32,
    slot_gen: u32,
    replaced: ?Key,
};
pub const ReserveResult = union(enum) {
    // Slot already populated and not pending — use immediately.
    ready: u32,
    // Slot freshly assigned to this key; caller must submit a raster job
    // and call `markReady` (with `slot_gen`) when the pixels land.
    newly_reserved_pending: NewlyReservedPending,
    // Slot exists for this key but a previous reserve's raster is still
    // in flight — caller renders a placeholder this frame.
    already_pending: u32,
    // Every slot is pending; nothing can be evicted. Caller should
    // placeholder and retry on a later frame after pendings drain.
    no_slot,
};

pub fn reserve(self: *GlyphIndexCache, allocator: std.mem.Allocator, key: Key) error{OutOfMemory}!ReserveResult {
    const entry = try self.map.getOrPut(allocator, key);
    if (entry.found_existing) {
        const idx = entry.value_ptr.*;
        // Per-frame LRU dampening: a single render frame visits many cells
        // that hit the same glyph (think every space in a row). Promoting
        // on the first hit per frame is enough to preserve LRU ordering;
        // subsequent same-frame hits skip the linked-list rewrite. Cuts
        // ~12k pointer writes/frame at a 200x60 grid down to a few hundred.
        if (self.nodes[idx].touched_frame != self.frame) {
            self.nodes[idx].touched_frame = self.frame;
            self.moveToBack(idx);
        }
        return if (self.nodes[idx].pending) .{ .already_pending = idx } else .{ .ready = idx };
    }

    // Miss path: walk LRU forward from `front` and take the first
    // non-pending node as victim. Pending slots are skipped because their
    // in-flight raster owns those pixels — evicting would orphan the upload.
    var victim_opt: ?u32 = self.front;
    while (victim_opt) |idx| : (victim_opt = self.nodes[idx].next) {
        if (!self.nodes[idx].pending) break;
    }
    const victim = victim_opt orelse {
        // All slots pending. Roll back the getOrPut so the map stays
        // consistent (the entry's value was never written).
        const removed = self.map.remove(key);
        std.debug.assert(removed);
        return .no_slot;
    };

    // Write the new map entry's value before any further map mutation —
    // `map.remove` below may invalidate `entry.value_ptr`.
    entry.value_ptr.* = victim;

    const replaced = self.nodes[victim].key;
    self.nodes[victim].key = key;
    self.nodes[victim].touched_frame = self.frame;
    self.nodes[victim].pending = true;
    self.nodes[victim].gen +%= 1;
    const slot_gen = self.nodes[victim].gen;
    if (replaced) |r| {
        const removed = self.map.remove(r);
        std.debug.assert(removed);
    }
    self.moveToBack(victim);
    return .{ .newly_reserved_pending = .{ .index = victim, .slot_gen = slot_gen, .replaced = replaced } };
}

/// Clear the pending flag on a slot whose raster worker just produced
/// pixels. Returns true iff the slot is still bound to `expected_key` at
/// `slot_gen`; on false the caller must discard the result (slot was
/// already reused, cleared, or never pending).
pub fn markReady(self: *GlyphIndexCache, idx: u32, slot_gen: u32, expected_key: Key) bool {
    const node = &self.nodes[idx];
    if (!node.pending) return false;
    if (node.gen != slot_gen) return false;
    const k = node.key orelse return false;
    if (!std.meta.eql(k, expected_key)) return false;
    node.pending = false;
    return true;
}

/// Drop a pending reservation without uploading anything (e.g. the worker
/// queue rejected the submit). Clears `pending`, releases the slot, and
/// removes the key from the map. The old replaced key is *not* restored —
/// next miss to this slot will re-raster fresh. Asserts that `slot_gen`
/// still matches; if not, the caller raced with a re-reserve and must not
/// touch the slot.
///
/// The now-empty slot is moved to the LRU front so the next miss picks it
/// first — otherwise the slot would sit at the back (where reserve placed
/// it) and the next miss would evict a perfectly-good ready glyph before
/// reusing this empty slot.
pub fn unreserve(self: *GlyphIndexCache, idx: u32, slot_gen: u32) void {
    const node = &self.nodes[idx];
    std.debug.assert(node.pending);
    std.debug.assert(node.gen == slot_gen);
    const k = node.key.?;
    const removed = self.map.remove(k);
    std.debug.assert(removed);
    node.key = null;
    node.pending = false;
    self.moveToFront(idx);
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

fn moveToFront(self: *GlyphIndexCache, index: u32) void {
    if (index == self.front) return;

    const node = &self.nodes[index];
    if (node.next) |next| {
        self.nodes[next].prev = node.prev;
    } else {
        self.back = node.prev.?;
    }

    if (node.prev) |prev| {
        self.nodes[prev].next = node.next;
    }

    self.nodes[self.front].prev = index;
    node.next = self.front;
    node.prev = null;
    self.front = index;
}

// Reserve a key and immediately mark its slot ready — convenience for tests
// that don't care about the pending state machine but need an evictable slot.
fn reserveReady(cache: *GlyphIndexCache, allocator: std.mem.Allocator, key: Key) !u32 {
    const r = try cache.reserve(allocator, key);
    const p = switch (r) {
        .newly_reserved_pending => |p| p,
        else => return error.TestExpectedNewlyReserved,
    };
    try std.testing.expect(cache.markReady(p.index, p.slot_gen, key));
    return p.index;
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

    const idx_a = try reserveReady(&cache, allocator, k_a);
    _ = try reserveReady(&cache, allocator, k_b);
    _ = try reserveReady(&cache, allocator, k_c);
    // LRU order: a (front, victim), b, c (back).

    // Hit a again in the same frame. Dampening skips moveToBack, so a stays
    // at the front — the very situation generateWidePair triggers when a
    // wide_left was already touched earlier in the frame.
    const ra_dampened = try cache.reserve(allocator, k_a);
    try std.testing.expectEqual(idx_a, switch (ra_dampened) {
        .ready => |idx| idx,
        else => unreachable,
    });

    // Force-promote. Without this call, the next miss would evict a.
    cache.touch(idx_a);

    // Miss → evicts the current front. If touch worked, front is b, not a.
    _ = try reserveReady(&cache, allocator, k_d);

    // a must survive (hit, same index).
    const ra_after = try cache.reserve(allocator, k_a);
    try std.testing.expectEqual(idx_a, switch (ra_after) {
        .ready => |idx| idx,
        else => unreachable,
    });
    // b must have been the eviction victim.
    const rb_after = try cache.reserve(allocator, k_b);
    try std.testing.expect(switch (rb_after) {
        .newly_reserved_pending => true,
        else => false,
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
        .newly_reserved_pending => true,
        else => false,
    });
    try std.testing.expect(switch (b) {
        .newly_reserved_pending => true,
        else => false,
    });
    try std.testing.expect(switch (c) {
        .newly_reserved_pending => true,
        else => false,
    });
}

test "reserve state transitions: pending → already_pending → ready" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 4);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const k: Key = .init('x', &.{}, .single, .regular);

    const first = try cache.reserve(allocator, k);
    const p = switch (first) {
        .newly_reserved_pending => |p| p,
        else => return error.TestExpectedNewlyReserved,
    };
    try std.testing.expectEqual(@as(?Key, null), p.replaced);

    // Same key again before markReady → already_pending, same slot.
    const second = try cache.reserve(allocator, k);
    try std.testing.expectEqual(p.index, switch (second) {
        .already_pending => |idx| idx,
        else => unreachable,
    });

    try std.testing.expect(cache.markReady(p.index, p.slot_gen, k));

    // After markReady → ready hits.
    const third = try cache.reserve(allocator, k);
    try std.testing.expectEqual(p.index, switch (third) {
        .ready => |idx| idx,
        else => unreachable,
    });

    // Double markReady is rejected (slot is no longer pending).
    try std.testing.expect(!cache.markReady(p.index, p.slot_gen, k));
}

test "LRU victim search skips pending slots" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 3);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const k_a: Key = .init('a', &.{}, .single, .regular);
    const k_b: Key = .init('b', &.{}, .single, .regular);
    const k_c: Key = .init('c', &.{}, .single, .regular);
    const k_d: Key = .init('d', &.{}, .single, .regular);

    // a stays pending; b and c are marked ready.
    const a_first = try cache.reserve(allocator, k_a);
    const a_p = switch (a_first) {
        .newly_reserved_pending => |p| p,
        else => unreachable,
    };
    const idx_b = try reserveReady(&cache, allocator, k_b);
    _ = try reserveReady(&cache, allocator, k_c);
    // LRU front-to-back: a (pending), b, c.

    // Miss on d — victim search must skip a and pick b (the first ready node).
    const rd = try cache.reserve(allocator, k_d);
    const d_p = switch (rd) {
        .newly_reserved_pending => |p| p,
        else => unreachable,
    };
    try std.testing.expectEqual(idx_b, d_p.index);
    try std.testing.expectEqual(@as(?Key, k_b), d_p.replaced);

    // a's slot must still be valid for markReady.
    try std.testing.expect(cache.markReady(a_p.index, a_p.slot_gen, k_a));
}

test "all-pending cache returns no_slot without polluting the map" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 2);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const k_a: Key = .init('a', &.{}, .single, .regular);
    const k_b: Key = .init('b', &.{}, .single, .regular);
    const k_c: Key = .init('c', &.{}, .single, .regular);

    _ = try cache.reserve(allocator, k_a);
    _ = try cache.reserve(allocator, k_b);
    // Both slots pending.

    const rc = try cache.reserve(allocator, k_c);
    try std.testing.expect(switch (rc) {
        .no_slot => true,
        else => false,
    });
    // Rolled back — k_c was never permanently inserted.
    try std.testing.expect(!cache.map.contains(k_c));
    try std.testing.expectEqual(@as(u32, 2), cache.map.count());
}

test "markReady rejects mismatched expected_key" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 2);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const k_a: Key = .init('a', &.{}, .single, .regular);
    const k_other: Key = .init('z', &.{}, .single, .regular);

    const ra = try cache.reserve(allocator, k_a);
    const a_p = switch (ra) {
        .newly_reserved_pending => |p| p,
        else => unreachable,
    };

    // Worker delivers under a key that doesn't match the slot's actual key.
    // Could happen if a result message is somehow misrouted; the key guard
    // must reject it. Slot stays pending.
    try std.testing.expect(!cache.markReady(a_p.index, a_p.slot_gen, k_other));
    try std.testing.expect(cache.nodes[a_p.index].pending);

    // Correct key still lands.
    try std.testing.expect(cache.markReady(a_p.index, a_p.slot_gen, k_a));
}

test "markReady rejects stale slot generation" {
    const allocator = std.testing.allocator;
    var cache = try GlyphIndexCache.init(allocator, 2);
    defer cache.deinit(allocator);

    cache.beginFrame();
    const k_a: Key = .init('a', &.{}, .single, .regular);
    const k_b: Key = .init('b', &.{}, .single, .regular);
    const k_c: Key = .init('c', &.{}, .single, .regular);

    const a_first = try cache.reserve(allocator, k_a);
    const a_p = switch (a_first) {
        .newly_reserved_pending => |p| p,
        else => unreachable,
    };
    try std.testing.expect(cache.markReady(a_p.index, a_p.slot_gen, k_a));

    // Fill the second slot and miss with k_c, forcing eviction of a (LRU
    // front, ready). The slot keeps the same index but its `gen` bumps.
    _ = try reserveReady(&cache, allocator, k_b);
    const rc = try cache.reserve(allocator, k_c);
    const c_p = switch (rc) {
        .newly_reserved_pending => |p| p,
        else => unreachable,
    };
    try std.testing.expectEqual(a_p.index, c_p.index);
    try std.testing.expectEqual(@as(?Key, k_a), c_p.replaced);

    // Stale a-result arrives after the slot has been reissued to c.
    try std.testing.expect(!cache.markReady(a_p.index, a_p.slot_gen, k_a));
    // Fresh c-result still lands.
    try std.testing.expect(cache.markReady(c_p.index, c_p.slot_gen, k_c));
}
