const std = @import("std");
const vt = @import("vt");

pub const max_bytes = 64 * 1024 * 1024;
pub const max_dimension = 10000;

pub fn decode(allocator: std.mem.Allocator, data: []const u8, transparent: bool, background: [4]u8) !vt.sys.Image {
    var measure: Decoder = .{};
    try measure.run(data);
    if (measure.width == 0 or measure.height == 0) return error.InvalidData;
    const len = @as(usize, measure.width) * measure.height * 4;
    if (len > max_bytes) return error.InvalidData;
    const pixels = try allocator.alloc(u8, len);
    errdefer allocator.free(pixels);
    var i: usize = 0;
    while (i < len) : (i += 4) @memcpy(pixels[i..][0..4], if (transparent) &@as([4]u8, .{ 0, 0, 0, 0 }) else &background);
    var render: Decoder = .{ .pixels = pixels, .stride = measure.width };
    try render.run(data);
    return .{ .width = measure.width, .height = measure.height, .data = pixels };
}

const Decoder = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixels: ?[]u8 = null,
    stride: u32 = 0,
    color: usize = 0,
    palette: [256][4]u8 = defaultPalette(),

    fn run(self: *Decoder, data: []const u8) !void {
        var i: usize = 0;
        while (i < data.len) {
            const ch = data[i];
            i += 1;
            switch (ch) {
                '?'...'~' => try self.paint(ch - '?', 1),
                '$' => self.x = 0,
                '-' => {
                    self.x = 0;
                    self.y += 6;
                    if (self.y > max_dimension) return error.InvalidData;
                },
                '!' => {
                    const count = try number(data, &i);
                    if (i == data.len or data[i] < '?' or data[i] > '~') return error.InvalidData;
                    try self.paint(data[i] - '?', @max(1, count));
                    i += 1;
                },
                '#', '"' => {
                    var params: [5]u32 = @splat(0);
                    var count: usize = 0;
                    while (true) {
                        if (count == params.len) return error.InvalidData;
                        params[count] = try number(data, &i);
                        count += 1;
                        if (i == data.len or data[i] != ';') break;
                        i += 1;
                    }
                    if (ch == '"') {
                        if (count != 4 or params[0] == 0 or params[1] == 0) return error.InvalidData;
                        if (params[2] > max_dimension or params[3] > max_dimension) return error.InvalidData;
                        self.width = @max(self.width, params[2]);
                        self.height = @max(self.height, params[3]);
                    } else {
                        if (params[0] >= self.palette.len) return error.InvalidData;
                        self.color = params[0];
                        if (count == 5) {
                            self.palette[self.color] = switch (params[1]) {
                                2 => .{ try percent(params[2]), try percent(params[3]), try percent(params[4]), 255 },
                                1 => try hls(params[2], params[3], params[4]),
                                else => return error.InvalidData,
                            };
                        } else if (count != 1) return error.InvalidData;
                    }
                },
                0...31, 127 => {},
                else => return error.InvalidData,
            }
        }
    }

    fn paint(self: *Decoder, bits: u8, count: u32) !void {
        if (count > max_dimension or self.x + count > max_dimension) return error.InvalidData;
        const height: u32 = if (bits == 0) 6 else 8 - @as(u32, @clz(bits));
        if (self.y + height > max_dimension) return error.InvalidData;
        self.width = @max(self.width, self.x + count);
        self.height = @max(self.height, self.y + height);
        if (@as(usize, self.width) * self.height * 4 > max_bytes) return error.InvalidData;
        if (self.pixels) |pixels| {
            for (0..6) |bit| {
                if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                for (0..count) |dx| {
                    const offset = ((@as(usize, self.y) + bit) * self.stride + self.x + dx) * 4;
                    @memcpy(pixels[offset..][0..4], &self.palette[self.color]);
                }
            }
        }
        self.x += count;
    }
};

fn number(data: []const u8, i: *usize) !u32 {
    const start = i.*;
    while (i.* < data.len and std.ascii.isDigit(data[i.*])) i.* += 1;
    if (i.* == start) return 0;
    return std.fmt.parseInt(u32, data[start..i.*], 10) catch error.InvalidData;
}

fn percent(value: u32) !u8 {
    if (value > 100) return error.InvalidData;
    return @intCast((value * 255 + 50) / 100);
}

fn hls(hue: u32, lightness: u32, saturation: u32) ![4]u8 {
    if (hue > 360 or lightness > 100 or saturation > 100) return error.InvalidData;
    // DEC's hue starts at blue (0), red is 120, and green is 240.
    const h: f32 = @as(f32, @floatFromInt((hue + 240) % 360)) / 60;
    const l: f32 = @as(f32, @floatFromInt(lightness)) / 100;
    const s: f32 = @as(f32, @floatFromInt(saturation)) / 100;
    const c = (1 - @abs(2 * l - 1)) * s;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(h))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    var result: [4]u8 = .{ 0, 0, 0, 255 };
    for (rgb, 0..) |channel, i| result[i] = @intFromFloat(@round(std.math.clamp(channel + l - c / 2, 0, 1) * 255));
    return result;
}

fn defaultPalette() [256][4]u8 {
    var result: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    const colors = [16][3]u8{
        .{ 0, 0, 0 },      .{ 51, 51, 204 },  .{ 204, 33, 33 },  .{ 51, 204, 51 },
        .{ 204, 51, 204 }, .{ 51, 204, 204 }, .{ 204, 204, 51 }, .{ 135, 135, 135 },
        .{ 66, 66, 66 },   .{ 84, 84, 153 },  .{ 153, 66, 66 },  .{ 84, 153, 84 },
        .{ 153, 84, 153 }, .{ 84, 153, 153 }, .{ 153, 153, 84 }, .{ 204, 204, 204 },
    };
    for (colors, 0..) |rgb, i| result[i] = .{ rgb[0], rgb[1], rgb[2], 255 };
    return result;
}

test "Sixel raster, repeats, color planes and transparency" {
    const image = try decode(std.testing.allocator, "\"1;1;3;6#1;2;100;0;0!3~$#2;1;240;50;100@", true, .{ 0, 0, 0, 255 });
    defer std.testing.allocator.free(image.data);
    try std.testing.expectEqual(@as(u32, 3), image.width);
    try std.testing.expectEqual(@as(u32, 6), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, image.data[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.data[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.data[60..64]);
    const blank = try decode(std.testing.allocator, "\"1;1;1;1", true, .{ 10, 20, 30, 255 });
    defer std.testing.allocator.free(blank.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, blank.data);
}

test "Sixel rejects oversized and malformed input" {
    for ([_][]const u8{ "!10001~", "\"1;1;10000;10000", "#1;2;101;0;0~", "!99999999999999999~", "" }) |input| {
        try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, input, true, .{ 0, 0, 0, 255 }));
    }
}
