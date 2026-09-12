//! ImageIO wallpaper resources. No borrowed config strings survive reload.
const BackgroundImage = @This();
const std = @import("std");
const Config = @import("../config.zig");
const graphics = @import("apple.zig").graphics;
const geometry = @import("../renderer/background_geometry.zig");

pub const Options = struct {
    path: []const u8 = "",
    opacity: f32 = 1,
    fit: Config.BackgroundImageFit = .contain,
    position: Config.BackgroundImagePosition = .center,
    repeat: bool = false,
};

path: []const u8 = "",
image: ?*graphics.Image = null,
boosted: ?*graphics.Image = null,
options: Options = .{},

pub fn deinit(self: *BackgroundImage, allocator: std.mem.Allocator) void {
    if (self.image) |image| image.release();
    if (self.boosted) |image| image.release();
    allocator.free(self.path);
    self.* = .{};
}

pub fn reconfigure(self: *BackgroundImage, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    if (!std.mem.eql(u8, self.path, options.path) or (self.image == null and options.path.len > 0)) {
        const path = try allocator.dupe(u8, options.path);
        errdefer allocator.free(path);
        const image = if (path.len == 0) null else load(allocator, io, path) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            std.log.warn("background-image: '{s}': {t}; clearing image", .{ path, err });
            break :blk null;
        };
        errdefer if (image) |value| value.release();
        const boosted = if (options.opacity > 1 and image != null)
            try boostOpacity(allocator, image.?, options.opacity)
        else
            null;
        // Publish only after decoding and alpha conversion have both succeeded.
        self.deinit(allocator);
        self.path = path;
        self.image = image;
        self.boosted = boosted;
    } else if (options.opacity != self.options.opacity or (options.opacity > 1 and self.boosted == null)) {
        const boosted = if (options.opacity > 1 and self.image != null)
            try boostOpacity(allocator, self.image.?, options.opacity)
        else
            null;
        if (self.boosted) |image| image.release();
        self.boosted = boosted;
    }
    self.options = options;
    self.options.path = self.path;
}

fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*graphics.Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    return graphics.Image.createEncoded(bytes, false);
}

// CGContext's global alpha is limited to 1. Preserve the config's >1 support
// by multiplying source alpha, including partially transparent PNG pixels.
fn boostOpacity(allocator: std.mem.Allocator, image: *graphics.Image, opacity: f32) !*graphics.Image {
    const w = image.getWidth();
    const h = image.getHeight();
    const pixels = try allocator.alloc(u8, try std.math.mul(usize, try std.math.mul(usize, w, h), 4));
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const space = try graphics.ColorSpace.createDeviceRGB();
    defer space.release();
    const context = try graphics.BitmapContext.create(pixels, w, h, 8, w * 4, space, @intFromEnum(graphics.ImageAlphaInfo.premultiplied_last));
    defer graphics.Context.release(context);
    graphics.Context.drawImage(context, graphics.Rect.init(0, 0, @floatFromInt(w), @floatFromInt(h)), image);
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        const pixel = pixels[offset..][0..4];
        const alpha: u32 = pixel[3];
        if (alpha == 0) continue;
        for (pixel[0..3]) |*channel| channel.* = @intCast(@min(255, (@as(u32, channel.*) * 255 + alpha / 2) / alpha));
        pixel[3] = @intFromFloat(@min(255, @round(@as(f32, @floatFromInt(alpha)) * opacity)));
    }
    return graphics.Image.createRgba(pixels, @intCast(w), @intCast(h));
}

pub fn draw(self: *const BackgroundImage, context: *graphics.BitmapContext, width: u32, height: u32) void {
    const image = self.boosted orelse self.image orelse return;
    if (self.options.opacity <= 0) return;
    const dest = geometry.computeDest(@floatFromInt(image.getWidth()), @floatFromInt(image.getHeight()), @floatFromInt(width), @floatFromInt(height), self.options.fit, self.options.position);
    if (dest[2] <= 0 or dest[3] <= 0) return;
    const rect = graphics.Rect.init(dest[0], @as(f64, @floatFromInt(height)) - dest[1] - dest[3], dest[2], dest[3]);
    const ctx = graphics.Context;
    ctx.save(context);
    defer ctx.restore(context);
    ctx.clipToRect(context, graphics.Rect.init(0, 0, width, height));
    ctx.setAlpha(context, @min(1, self.options.opacity));
    if (self.options.repeat) ctx.drawTiledImage(context, rect, image) else ctx.drawImage(context, rect, image);
}

test "wallpaper loads PNG retries failures and releases removed configuration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "tmp/macos-background-image-test.png";
    try std.Io.Dir.cwd().createDirPath(io, "tmp");
    const png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 16, 73, 68, 65, 84, 120, 1, 1, 5, 0, 250, 255, 0, 255, 0, 0, 128, 4, 129, 1, 128, 25, 47, 133, 176, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &png });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var wallpaper: BackgroundImage = .{};
    defer wallpaper.deinit(allocator);
    try wallpaper.reconfigure(allocator, io, .{ .path = path, .opacity = 2 });
    try std.testing.expectEqual(@as(usize, 1), wallpaper.image.?.getWidth());
    try std.testing.expect(wallpaper.boosted != null);
    var pixels: [4]u8 = @splat(0);
    const space = try graphics.ColorSpace.createDeviceRGB();
    defer space.release();
    const context = try graphics.BitmapContext.create(&pixels, 1, 1, 8, 4, space, @intFromEnum(graphics.ImageAlphaInfo.premultiplied_last));
    defer graphics.Context.release(context);
    wallpaper.draw(context, 1, 1);
    // 50% PNG alpha multiplied by 2 reaches opacity 1, rather than remaining
    // 50% when a native global-alpha API clamps the multiplier prematurely.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &pixels);
    try wallpaper.reconfigure(allocator, io, .{ .path = path, .opacity = 0.5 });
    graphics.Context.clearRect(context, graphics.Rect.init(0, 0, 1, 1));
    wallpaper.draw(context, 1, 1);
    try std.testing.expectEqual(@as(u8, 64), pixels[3]);
    // Fail every allocation in a path-changing reload, including the late
    // alpha buffer allocation. The old resource and pixels must survive.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const old_image = wallpaper.image;
        wallpaper.reconfigure(failing.allocator(), io, .{ .path = "./" ++ path, .opacity = 2 }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(old_image, wallpaper.image);
            try std.testing.expectEqualStrings(path, wallpaper.path);
            try std.testing.expectEqual(@as(f32, 0.5), wallpaper.options.opacity);
            graphics.Context.clearRect(context, graphics.Rect.init(0, 0, 1, 1));
            wallpaper.draw(context, 1, 1);
            try std.testing.expectEqual(@as(u8, 64), pixels[3]);
            continue;
        };
        break;
    }
    try std.testing.expect(fail_index >= 3);
    graphics.Context.clearRect(context, graphics.Rect.init(0, 0, 1, 1));
    wallpaper.draw(context, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &pixels);
    try wallpaper.reconfigure(allocator, io, .{ .path = "tmp/missing-mostty-wallpaper.png" });
    try std.testing.expect(wallpaper.image == null and wallpaper.boosted == null);
    try wallpaper.reconfigure(allocator, io, .{ .path = path });
    try std.testing.expect(wallpaper.image != null);
    try wallpaper.reconfigure(allocator, io, .{});
    try std.testing.expect(wallpaper.image == null and wallpaper.path.len == 0);
}
