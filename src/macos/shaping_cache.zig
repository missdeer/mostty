//! Bounded, direct-mapped CTLine cache. Font identities are valid until clear().
const std = @import("std");
const text = @import("apple.zig").text;
const ShapingCache = @This();

pub const capacity = 1024;
const max_characters = 128;

pub const Shape = struct {
    line: *text.Line,
    ascent: f64,
    descent: f64,
    advance: f64,

    pub fn create(characters: []const u16, font: *text.Font) !Shape {
        const line = try text.Line.create(characters, font);
        var result: Shape = .{ .line = line, .ascent = 0, .descent = 0, .advance = 0 };
        result.advance = line.getTypographicBounds(&result.ascent, &result.descent);
        return result;
    }
};

pub const Result = struct {
    shape: Shape,
    owned: bool,

    // Cache hits and inserted shapes are borrowed until the next get/clear.
    pub fn deinit(self: Result) void {
        if (self.owned) self.shape.line.release();
    }
};

const Entry = struct {
    font: *text.Font,
    characters: [max_characters]u16,
    len: usize,
    shape: Shape,
};

entries: []?Entry = &.{},

pub fn clear(self: *ShapingCache) void {
    for (self.entries) |*entry| {
        if (entry.*) |value| value.shape.line.release();
        entry.* = null;
    }
}

pub fn deinit(self: *ShapingCache, allocator: std.mem.Allocator) void {
    self.clear();
    allocator.free(self.entries);
    self.* = .{};
}

pub fn get(self: *ShapingCache, allocator: std.mem.Allocator, characters: []const u16, font: *text.Font) !Result {
    // Unusually long graphemes still render, without growing the cache budget.
    if (characters.len > max_characters) return .{ .shape = try Shape.create(characters, font), .owned = true };
    if (self.entries.len == 0) {
        self.entries = try allocator.alloc(?Entry, capacity);
        @memset(self.entries, null);
    }
    const hash = std.hash.Wyhash.hash(@intFromPtr(font), std.mem.sliceAsBytes(characters));
    const slot = &self.entries[hash % capacity];
    if (slot.*) |*entry| {
        if (entry.font == font and std.mem.eql(u16, entry.characters[0..entry.len], characters))
            return .{ .shape = entry.shape, .owned = false };
    }
    // A failed shape leaves the previous slot intact.
    const shape = try Shape.create(characters, font);
    if (slot.*) |entry| entry.shape.line.release();
    slot.* = .{ .font = font, .characters = undefined, .len = characters.len, .shape = shape };
    @memcpy(slot.*.?.characters[0..characters.len], characters);
    return .{ .shape = shape, .owned = false };
}
