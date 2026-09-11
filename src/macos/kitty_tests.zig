const std = @import("std");
const vt = @import("vt");
const Session = @import("../terminal/session.zig");
const Renderer = @import("core_text_renderer.zig");
const alloc = std.testing.allocator;

const Fixture = struct {
    session: Session,
    renderer: Renderer,
    response: [256]u8 = undefined,
    response_len: usize = 0,

    fn init(self: *Fixture) !void {
        @import("png_decoder.zig").install();
        self.response_len = 0;
        self.renderer = try Renderer.init(.{ .allocator = alloc, .pixel_width = 240, .pixel_height = 160, .paint = .{ .background_alpha = 255 } });
        errdefer self.renderer.deinit();
        const grid = self.renderer.gridSize();
        try self.session.init(.{ .io = std.testing.io, .terminal_allocator = alloc, .stream_allocator = alloc, .cols = @intCast(grid.cols), .rows = @intCast(grid.rows), .hooks = .{ .context = self, .write_pty = write } });
        self.session.syncPixelSize(self.renderer.metrics.cell_width, self.renderer.metrics.cell_height);
        self.session.feed("\x1b]11;#000000\x07");
    }

    fn deinit(self: *Fixture) void {
        self.renderer.deinit();
        self.session.deinit();
    }

    fn write(context: *anyopaque, data: [:0]const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.response_len = @min(data.len, self.response.len);
        @memcpy(self.response[0..self.response_len], data[0..self.response_len]);
    }

    fn transmit(self: *Fixture, options: []const u8, pixels: []const u8) !void {
        const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(pixels.len));
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, pixels);
        const command = try std.fmt.allocPrint(alloc, "\x1b_G{s};{s}\x1b\\", .{ options, encoded });
        defer alloc.free(command);
        self.session.feed(command);
    }

    fn render(self: *Fixture) !void {
        _ = try self.renderer.render(&self.session, null);
    }

    fn pixel(self: *const Fixture, x: u32, y: u32) [4]u8 {
        const bytes = self.renderer.pixels[(@as(usize, y) * self.renderer.pixel_width + x) * 4 ..][0..4];
        return .{ bytes[2], bytes[1], bytes[0], bytes[3] };
    }

    fn expectPixel(self: *const Fixture, x: u32, y: u32, expected: [4]u8) !void {
        try std.testing.expectEqualSlices(u8, &expected, &self.pixel(x, y));
    }
};

test "Kitty direct RGBA ACK, orientation, alpha, crop, replacement and deletion" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.session.feed("\x1b]11;#0000ff\x07");
    try f.transmit("a=T,f=32,s=2,v=2,i=1,c=4,r=4,C=1", &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0 });
    try std.testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    try f.expectPixel(3 * cw, ch, .{ 0, 128, 127, 255 });
    try f.expectPixel(cw, 3 * ch, .{ 0, 0, 255, 255 });
    try f.expectPixel(3 * cw, 3 * ch, .{ 0, 0, 255, 255 });
    const generation = f.renderer.kitty_images.images.get(1).?.generation;
    f.session.feed("\x1b_Ga=d,d=a\x1b\\\x1b_Ga=p,i=1,x=1,y=0,w=1,h=1,c=2,r=2,C=1\x1b\\");
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 128, 127, 255 });
    try f.transmit("a=T,f=24,s=1,v=1,i=1,c=2,r=2,C=1", &.{ 255, 255, 0 });
    try f.render();
    try std.testing.expect(f.renderer.kitty_images.images.get(1).?.generation != generation);
    try f.expectPixel(cw, ch, .{ 255, 255, 0, 255 });
    f.session.feed("\x1b_Ga=d,d=I,i=1\x1b\\");
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.expectPixel(cw, ch, .{ 0, 0, 255, 255 });
}

test "Kitty z layers preserve explicit backgrounds and text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    // Full-block sprites make foreground coverage deterministic at cell centers.
    f.session.feed("\x1b[38;2;255;255;255m\u{2588}\x1b[48;2;0;0;255m \x1b[0m\x1b[H");
    for ([_]struct { z: i32, first: [4]u8, second: [4]u8 }{
        .{ .z = -1073741825, .first = .{ 255, 255, 255, 255 }, .second = .{ 0, 0, 255, 255 } },
        .{ .z = -1, .first = .{ 255, 255, 255, 255 }, .second = .{ 255, 0, 0, 255 } },
        .{ .z = 0, .first = .{ 255, 0, 0, 255 }, .second = .{ 255, 0, 0, 255 } },
    }) |case| {
        f.session.feed("\x1b_Ga=d,d=A\x1b\\");
        const options = try std.fmt.allocPrint(alloc, "a=T,f=24,s=1,v=1,i=1,c=3,r=1,C=1,z={d}", .{case.z});
        defer alloc.free(options);
        try f.transmit(options, &.{ 255, 0, 0 });
        try f.render();
        try f.expectPixel(cw / 2, ch / 2, case.first);
        try f.expectPixel(cw + cw / 2, ch / 2, case.second);
        try f.expectPixel(2 * cw + cw / 2, ch / 2, .{ 255, 0, 0, 255 });
    }
    // Higher z wins regardless of transmission/image-ID ordering.
    try f.transmit("a=T,f=24,s=1,v=1,i=2,c=3,r=1,C=1,z=2", &.{ 0, 255, 0 });
    try f.transmit("a=T,f=24,s=1,v=1,i=3,c=3,r=1,C=1,z=1", &.{ 0, 0, 255 });
    try f.render();
    try f.expectPixel(cw / 2, ch / 2, .{ 0, 255, 0, 255 });
}

test "Kitty clipping, scrolling, alternate screens and renderer ownership" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.transmit("a=T,f=24,s=1,v=2,i=1,c=2,r=4,C=1", &.{ 255, 0, 0, 0, 255, 0 });
    const rows = f.session.term.rows;
    for (0..rows + 4) |_| f.session.feed("\r\n");
    f.session.term.scrollViewport(.top);
    try f.render();
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    f.session.term.scrollViewport(.{ .row = 2 });
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 255, 0, 255 });
    f.session.feed("\x1b[?1049h\x1b[H");
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.transmit("a=T,f=24,s=1,v=1,i=1,c=2,r=2,C=1", &.{ 0, 0, 255 });
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 0, 255, 255 });
    f.session.feed("\x1b[?1049l");
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 255, 0, 255 });
    f.session.term.scrollViewport(.bottom);
    const move = try std.fmt.allocPrint(alloc, "\x1b[{d};{d}H", .{ rows, f.session.term.cols });
    defer alloc.free(move);
    f.session.feed(move);
    try f.transmit("a=T,f=24,s=1,v=1,i=2,c=100,r=100,C=1", &.{ 255, 255, 255 });
    try f.render();
    try f.expectPixel((f.session.term.cols - 1) * cw, (rows - 1) * ch, .{ 255, 255, 255, 255 });
    try f.expectPixel(0, f.renderer.pixel_height - 1, .{ 0, 0, 0, 255 });
    var other: Fixture = undefined;
    try other.init();
    defer other.deinit();
    try other.render();
    try std.testing.expectEqual(@as(u32, 0), other.renderer.kitty_images.images.count());
    try other.expectPixel(cw, ch, .{ 0, 0, 0, 255 });
}

test "Kitty Unicode placeholders use VT placement geometry without glyph boxes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.transmit("a=T,f=24,s=1,v=1,i=42,c=1,r=1,U=1", &.{ 255, 0, 0 });
    f.session.feed("\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}\x1b[0m");
    try f.render();
    try std.testing.expectEqual(@as(usize, 1), f.renderer.kitty_images.placements.items.len);
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw / 2, ch / 2, .{ 255, 0, 0, 255 });
    f.session.feed("\x1b_Ga=d,d=I,i=42\x1b\\");
    try f.render();
    for (0..ch) |y| for (0..cw) |x| {
        try f.expectPixel(@intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
    };
}

test "Kitty PNG uses ImageIO with straight alpha and rejects invalid payloads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // PNG fixture encoded independently with Go image/png: red, half-alpha green,
    // blue and transparent black, in top-to-bottom order.
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHElEQVR4nATAAREAAAgDIc7kNv9xkTwKFgAA//87AAV+M2k18gAAAABJRU5ErkJggg==";
    var png: [try std.base64.standard.Decoder.calcSizeForSlice(encoded)]u8 = undefined;
    try std.base64.standard.Decoder.decode(&png, encoded);
    const decoded = try vt.sys.decode_png.?(alloc, &png);
    defer alloc.free(decoded.data);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0 }, decoded.data);
    try f.transmit("a=T,f=100,i=6,c=4,r=4,C=1", &png);
    try std.testing.expectEqualStrings("\x1b_Gi=6;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    try f.expectPixel(3 * cw, ch, .{ 0, 128, 0, 255 });
    try f.expectPixel(cw, 3 * ch, .{ 0, 0, 255, 255 });
    try f.expectPixel(3 * cw, 3 * ch, .{ 0, 0, 0, 255 });
    try f.transmit("a=T,f=100,i=7", "not a PNG");
    try std.testing.expect(std.mem.indexOf(u8, f.response[0..f.response_len], "EINVAL") != null);
    try std.testing.expect(f.session.term.screens.active.kitty_images.imageById(7) == null);
    try std.testing.expectError(error.InvalidData, vt.sys.decode_png.?(alloc, "not a PNG"));
}

test "Kitty chunk completion and query replies do not publish partial images" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.transmit("a=q,f=24,s=1,v=1,i=99", &.{ 255, 0, 0 });
    try std.testing.expectEqualStrings("\x1b_Gi=99;OK\x1b\\", f.response[0..f.response_len]);
    try std.testing.expect(f.session.term.screens.active.kitty_images.imageById(99) == null);
    f.response_len = 0;
    try f.transmit("a=T,f=32,s=1,v=2,i=8,c=2,r=4,C=1,m=1", &.{ 255, 0, 0, 255 });
    try std.testing.expectEqual(@as(usize, 0), f.response_len);
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.transmit("m=0", &.{ 0, 255, 0, 255 });
    try std.testing.expectEqualStrings("\x1b_Gi=8;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    try f.expectPixel(f.renderer.metrics.cell_width, f.renderer.metrics.cell_height, .{ 255, 0, 0, 255 });
    try f.expectPixel(f.renderer.metrics.cell_width, 3 * f.renderer.metrics.cell_height, .{ 0, 255, 0, 255 });
}

test "Sixel shares the renderer, scrolls with text, and disappears on clear" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.session.feed("\x1b[?25l\x1bP0;1q\"1;1;12;12#1;2;100;0;0!12~-#2;2;0;100;0!12~\x1b\\");
    try f.render();
    try f.expectPixel(3, 2, .{ 255, 0, 0, 255 });
    try f.expectPixel(3, 9, .{ 0, 255, 0, 255 });
    const rows = f.session.term.rows;
    for (0..rows + 1) |_| f.session.feed("\r\n");
    try f.render();
    try std.testing.expectEqual(@as(usize, 0), f.renderer.kitty_images.placements.items.len);
    f.session.term.scrollViewport(.top);
    try f.render();
    try f.expectPixel(3, 2, .{ 255, 0, 0, 255 });
    f.session.feed("\x1b[H\x1b[2J\x1b[3J");
    try f.render();
    try std.testing.expectEqual(@as(usize, 0), f.renderer.kitty_images.placements.items.len);
}

test "iTerm PNG size units, aspect ratio, fragmented input and disabled rendering" {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHElEQVR4nATAAREAAAgDIc7kNv9xkTwKFgAA//87AAV+M2k18gAAAABJRU5ErkJggg==";
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.session.feed("\x1b[?25l");
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    for ([_]struct { options: []const u8, width: u32, height: u32 }{
        .{ .options = "width=20px;height=12px;preserveAspectRatio=0", .width = 20, .height = 12 },
        .{ .options = "width=20px;height=12px;preserveAspectRatio=1", .width = 12, .height = 12 },
        .{ .options = "width=2;height=1;preserveAspectRatio=0", .width = 2 * cw, .height = ch },
        .{ .options = "width=50%;height=auto", .width = f.session.term.width_px / 2, .height = f.session.term.width_px / 2 },
        .{ .options = "width=auto;height=auto", .width = 2, .height = 2 },
    }) |case| {
        f.session.feed("\x1b[H\x1b[2J\x1b[3J");
        const sequence = try std.fmt.allocPrint(alloc, "\x1b]1337;File=inline=1;{s}:{s}\x07", .{ case.options, png });
        defer alloc.free(sequence);
        for (sequence) |byte| f.session.feed(&.{byte});
        try f.render();
        try std.testing.expectEqual(@as(usize, 1), f.renderer.kitty_images.placements.items.len);
        var images = f.session.term.screens.active.kitty_images.images.valueIterator();
        // Clear removes placements; storage may retain older image data.
        var matched = false;
        while (images.next()) |image| {
            if (image.metadata.placement_count == 0) continue;
            try std.testing.expectEqual(case.width, image.width);
            try std.testing.expectEqual(case.height, image.height);
            matched = true;
        }
        try std.testing.expect(matched);
        const cursor_row = try std.math.divCeil(u32, case.height, ch);
        try std.testing.expectEqual(cursor_row, f.session.term.screens.active.cursor.y);
        try f.expectPixel(case.width / 4, case.height / 4, .{ 255, 0, 0, 255 });
        try f.expectPixel(case.width / 4, case.height * 3 / 4, .{ 0, 0, 255, 255 });
    }
    f.session.setImagesEnabled(false);
    try f.render();
    try std.testing.expectEqual(@as(usize, 0), f.renderer.kitty_images.placements.items.len);
    f.session.feed("\x1b]1337;File=inline=1:invalid\x1b\\");
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
}

test "imgcat multipart transfer publishes only on FileEnd and disable cancels pending data" {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHElEQVR4nATAAREAAAgDIc7kNv9xkTwKFgAA//87AAV+M2k18gAAAABJRU5ErkJggg==";
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.session.feed("\x1b[?25l\x1b]1337;MultipartFile=inline=1;width=20px\x07");
    for ([_][]const u8{ png[0..60], png[60..] }) |part| {
        f.session.feed("\x1b]1337;FilePart=");
        for (part) |byte| f.session.feed(&.{byte});
        f.session.feed("\x07");
        try std.testing.expectEqual(@as(u32, 0), f.session.term.screens.active.kitty_images.images.count());
    }
    f.session.feed("\x1b]1337;FileEnd\x07");
    try f.render();
    try std.testing.expectEqual(@as(usize, 1), f.renderer.kitty_images.placements.items.len);
    try f.expectPixel(5, 5, .{ 255, 0, 0, 255 });
    try f.expectPixel(5, 15, .{ 0, 0, 255, 255 });
    f.session.feed("\x1b]1337;MultipartFile=inline=1\x07\x1b]1337;FilePart=");
    f.session.feed(png);
    f.session.feed("\x07");
    f.session.setImagesEnabled(false);
    f.session.setImagesEnabled(true);
    f.session.feed("\x1b]1337;FileEnd\x07");
    try std.testing.expectEqual(@as(u32, 0), f.session.term.screens.active.kitty_images.images.count());
}
