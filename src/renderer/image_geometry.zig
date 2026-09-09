//! Source cropping and viewport arithmetic without native placement storage.
const std = @import("std");

pub const Crop = struct { x: u32, y: u32, width: u32, height: u32 };

pub fn sourceCrop(width: u32, height: u32, x: u32, y: u32, crop_width: u32, crop_height: u32) ?Crop {
    const sx = @min(width, x);
    const sy = @min(height, y);
    const w = @min(width - sx, if (crop_width > 0) crop_width else width);
    const h = @min(height - sy, if (crop_height > 0) crop_height else height);
    if (w == 0 or h == 0) return null;
    return .{ .x = sx, .y = sy, .width = w, .height = h };
}

pub fn relativeRow(row: u32, viewport_top: u32) i64 {
    return @as(i64, row) - @as(i64, viewport_top);
}

test "source crop defaults to remaining pixels and clips at image edges" {
    try std.testing.expectEqual(Crop{ .x = 2, .y = 3, .width = 8, .height = 17 }, sourceCrop(10, 20, 2, 3, 0, 0).?);
    try std.testing.expectEqual(Crop{ .x = 2, .y = 3, .width = 4, .height = 17 }, sourceCrop(10, 20, 2, 3, 4, 99).?);
    try std.testing.expect(sourceCrop(10, 20, 10, 0, 0, 0) == null);
    try std.testing.expect(sourceCrop(10, 20, 0, 21, 0, 0) == null);
    try std.testing.expectEqual(@as(i64, -5), relativeRow(5, 10));
    try std.testing.expectEqual(@as(i64, 4_294_967_295), relativeRow(std.math.maxInt(u32), 0));
}
