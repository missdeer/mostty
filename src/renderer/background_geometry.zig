//! Background-image geometry in top-left pixel coordinates, shared by backends.
const Config = @import("../config.zig");
const std = @import("std");

pub fn computeDest(sw: f32, sh: f32, container_w: f32, container_h: f32, fit: Config.BackgroundImageFit, position: Config.BackgroundImagePosition) [4]f32 {
    if (sw <= 0 or sh <= 0 or container_w <= 0 or container_h <= 0) return .{ 0, 0, 0, 0 };

    var dw: f32 = sw;
    var dh: f32 = sh;
    switch (fit) {
        .none => {},
        .stretch => {
            dw = container_w;
            dh = container_h;
        },
        .contain => {
            const s = @min(container_w / sw, container_h / sh);
            dw = sw * s;
            dh = sh * s;
        },
        .cover => {
            const s = @max(container_w / sw, container_h / sh);
            dw = sw * s;
            dh = sh * s;
        },
    }

    const free_x = container_w - dw;
    const free_y = container_h - dh;
    const ox: f32 = switch (position) {
        .top_left, .center_left, .bottom_left => 0,
        .top_center, .center, .bottom_center => free_x * 0.5,
        .top_right, .center_right, .bottom_right => free_x,
    };
    const oy: f32 = switch (position) {
        .top_left, .top_center, .top_right => 0,
        .center_left, .center, .center_right => free_y * 0.5,
        .bottom_left, .bottom_center, .bottom_right => free_y,
    };
    return .{ ox, oy, dw, dh };
}

test "background fits and anchors preserve size and crop direction" {
    try std.testing.expectEqual([4]f32{ 0, 25, 100, 50 }, computeDest(20, 10, 100, 100, .contain, .center));
    try std.testing.expectEqual([4]f32{ -100, 0, 200, 100 }, computeDest(20, 10, 100, 100, .cover, .bottom_right));
    try std.testing.expectEqual([4]f32{ 0, 0, 100, 100 }, computeDest(20, 10, 100, 100, .stretch, .top_left));
    for (std.enums.values(Config.BackgroundImagePosition), 0..) |position, index| {
        const rect = computeDest(20, 10, 100, 100, .none, position);
        try std.testing.expectEqual(@as(f32, @floatFromInt(index % 3)) * 40, rect[0]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(index / 3)) * 45, rect[1]);
        try std.testing.expectEqual(@as(f32, 20), rect[2]);
        try std.testing.expectEqual(@as(f32, 10), rect[3]);
    }
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, computeDest(0, 10, 100, 100, .cover, .center));
}
