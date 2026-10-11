//! Warm-cache fixture for the actual shared renderer generateRun path.
//! No GPU/COM object is used: every requested slot is populated before timing.
const std = @import("std");
const Cache = @import("../glyph_index_cache.zig");
const Renderer = @import("../d3d11.zig");
const FontService = @import("../font_service.zig");
const glyph = @import("glyph.zig");
const Fixture = @This();

renderer: Renderer = undefined,
font: FontService = undefined,
cache: Cache = undefined,
expected: [26][32]u32 = undefined,
text: [32]u8 = undefined,
style: Cache.Style = .regular,

pub fn init(self: *Fixture, allocator: std.mem.Allocator, style: Cache.Style) !void {
    self.style = style;
    self.renderer.glyph_cache_arena = .init(allocator);
    errdefer self.renderer.glyph_cache_arena.deinit();
    self.renderer.font_service = &self.font;
    self.font.glyph_worker_started = true;
    self.font.cell_size_xy = .{ .x = 8, .y = 16 };
    self.cache = try Cache.init(self.renderer.glyph_cache_arena.allocator(), 1024);
    _ = try self.ready(Cache.Key.init(' ', &.{}, .single, .regular));
    for (&self.text, 0..) |*ch, i| ch.* = @intCast('a' + i % 26);
    for (0..26) |variant| {
        self.text[0] = @intCast('a' + variant);
        for (0..self.text.len) |offset| self.expected[variant][offset] = try self.ready(Cache.Key.initRun(&self.text, @intCast(offset), style));
    }
}

fn ready(self: *Fixture, key: Cache.Key) !u32 {
    const reserved = (try self.cache.reserve(self.renderer.glyph_cache_arena.allocator(), key)).newly_reserved_pending;
    try std.testing.expect(self.cache.markReady(reserved.index, reserved.slot_gen, key));
    return reserved.index;
}

pub fn deinit(self: *Fixture) void {
    self.renderer.glyph_cache_arena.deinit();
}

pub fn run(self: *Fixture, iteration: usize) !u64 {
    const variant = iteration % 26;
    self.text[0] = @intCast('a' + variant);
    std.mem.doNotOptimizeAway(&self.text);
    const result = glyph.generateRun(&self.renderer, &self.cache, .{ .x = 32, .y = 32 }, &self.text, self.style) orelse return error.MissingRun;
    try std.testing.expectEqual(@as(u8, 32), result.len);
    try std.testing.expectEqualSlices(u32, &self.expected[variant], result.glyphs[0..result.len]);
    var checksum: u64 = 0;
    for (result.glyphs[0..result.len]) |slot| checksum +%= slot;
    return checksum;
}
