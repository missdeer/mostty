//! CPU pixel conversion shared by native image uploaders.
const std = @import("std");
const vt = @import("vt");

pub fn toRgba(allocator: std.mem.Allocator, image: vt.kitty.graphics.Image) ![]u8 {
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
    const rgba = try allocator.alloc(u8, try std.math.mul(usize, count, 4));
    if (channels == 4) {
        @memcpy(rgba, data);
        return rgba;
    }
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
    return rgba;
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
        defer std.testing.allocator.free(rgba);
        try std.testing.expectEqualSlices(u8, case.expected, rgba);
    }
}

test "pixel conversion rejects missing, malformed and overflowing payloads before allocation" {
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .width = 1, .height = 1, .data = .{ .pending = 3 } }));
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .width = 1, .height = 1 }));
    try std.testing.expectError(error.InvalidData, toRgba(std.testing.allocator, .{ .format = .png }));
    try std.testing.expectError(error.Overflow, toRgba(std.testing.allocator, .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .format = .rgba }));
}
