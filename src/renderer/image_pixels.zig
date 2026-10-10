//! CPU pixel conversion shared by native image uploaders.
const std = @import("std");
const vt = @import("vt");

/// Borrowed bytes remain valid only while the source image is alive and unchanged.
/// Uploaders must consume them or copy into backend-owned staging before returning.
pub const Rgba = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    pub fn bytes(self: Rgba) []const u8 {
        return switch (self) {
            .borrowed => |data| data,
            .owned => |data| data,
        };
    }

    pub fn deinit(self: Rgba, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |data| allocator.free(data),
        }
    }
};

pub fn toRgba(allocator: std.mem.Allocator, image: vt.kitty.graphics.Image) !Rgba {
    const data = image.data.bytes() orelse return error.InvalidData;
    const channels: usize = switch (image.format) {
        .rgba => 4,
        .rgb => 3,
        .gray_alpha => 2,
        .gray => 1,
        .png => return error.InvalidData,
    };
    const count = try std.math.mul(usize, image.width, image.height);
    if (data.len != try std.math.mul(usize, count, channels)) return error.InvalidData;
    if (channels == 4) return .{ .borrowed = data };
    const rgba = try allocator.alloc(u8, try std.math.mul(usize, count, 4));
    for (0..count) |i| {
        const src = data[i * channels ..][0..channels];
        const dst = rgba[i * 4 ..][0..4];
        if (channels >= 3) {
            @memcpy(dst[0..3], src[0..3]);
        } else {
            @memset(dst[0..3], src[0]);
        }
        dst[3] = if (channels == 2) src[channels - 1] else 255;
    }
    return .{ .owned = rgba };
}

test "pixel conversion expands channels and preserves alpha" {
    const Case = struct { format: @FieldType(vt.kitty.graphics.Image, "format"), source: []const u8, expected: []const u8 };
    for ([_]Case{
        .{ .format = .rgba, .source = &.{ 1, 2, 3, 4 }, .expected = &.{ 1, 2, 3, 4 } },
        .{ .format = .rgb, .source = &.{ 1, 2, 3 }, .expected = &.{ 1, 2, 3, 255 } },
        .{ .format = .gray, .source = &.{42}, .expected = &.{ 42, 42, 42, 255 } },
        .{ .format = .gray_alpha, .source = &.{ 42, 7 }, .expected = &.{ 42, 42, 42, 7 } },
    }) |case| {
        const rgba = try toRgba(std.testing.allocator, .{ .width = 1, .height = 1, .format = case.format, .data = .{ .complete = case.source } });
        defer rgba.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, case.expected, rgba.bytes());
    }
}

test "pixel conversion rejects missing, malformed and overflowing payloads before allocation" {
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .width = 1, .height = 1, .data = .{ .pending = 3 } }));
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .width = 1, .height = 1 }));
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .format = .png }));
    try std.testing.expectError(error.Overflow, toRgba(std.testing.allocator, .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .format = .rgba }));
}

test "RGBA borrows without allocation and release leaves source alive" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const source = try std.testing.allocator.dupe(u8, &.{ 11, 22, 33, 0, 44, 55, 66, 127 });
    defer std.testing.allocator.free(source);
    const hash = std.hash.Wyhash.hash(0, source);
    const rgba = try toRgba(failing.allocator(), .{ .width = 2, .height = 1, .format = .rgba, .data = .{ .complete = source } });
    try std.testing.expect(rgba == .borrowed);
    // Identity proves no pixel copy, including transparent RGB and partial alpha.
    try std.testing.expectEqual(source.ptr, rgba.bytes().ptr);
    try std.testing.expectEqual(hash, std.hash.Wyhash.hash(0, rgba.bytes()));
    rgba.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing.deallocations);
    try std.testing.expectEqual(hash, std.hash.Wyhash.hash(0, source));
}

test "channel expansion owns exactly one allocation and handles allocation failure" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image: vt.kitty.graphics.Image = .{ .width = 1, .height = 1, .format = .rgb, .data = .{ .complete = &.{ 11, 22, 33 } } };
    const rgba = try toRgba(counted.allocator(), image);
    try std.testing.expect(rgba == .owned);
    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33, 255 }, rgba.bytes());
    rgba.deinit(counted.allocator());
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, toRgba(failing.allocator(), image));
}
