const std = @import("std");
const vt = @import("vt");
const graphics = @import("apple.zig").graphics;

pub fn install() void {
    vt.sys.decode_png = decode;
    @import("../terminal/inline_images.zig").decode_image = decodeFile;
}

fn decode(allocator: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    return decodeImage(allocator, data, true);
}

fn decodeFile(allocator: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    return decodeImage(allocator, data, false);
}

fn decodeImage(allocator: std.mem.Allocator, data: []const u8, png_only: bool) vt.sys.DecodeError!vt.sys.Image {
    const image = try graphics.Image.createEncoded(data, png_only);
    defer image.release();
    const width = image.getWidth();
    const height = image.getHeight();
    if (width == 0 or height == 0 or width > 10000 or height > 10000) return error.InvalidData;
    const pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    const space = try graphics.ColorSpace.createDeviceRGB();
    defer space.release();
    const context = try graphics.BitmapContext.create(pixels, width, height, 8, width * 4, space, @intFromEnum(graphics.ImageAlphaInfo.premultiplied_last));
    defer graphics.Context.release(context);
    graphics.Context.drawImage(context, graphics.Rect.init(0, 0, @floatFromInt(width), @floatFromInt(height)), image);
    // CoreGraphics draws premultiplied RGBA; VT owns straight RGBA payloads.
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const alpha: u32 = pixels[i + 3];
        if (alpha == 0 or alpha == 255) continue;
        for (pixels[i..][0..3]) |*channel| {
            channel.* = @intCast(@min(255, (@as(u32, channel.*) * 255 + alpha / 2) / alpha));
        }
    }
    return .{ .width = @intCast(width), .height = @intCast(height), .data = pixels };
}
