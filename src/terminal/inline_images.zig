const InlineImages = @This();
const std = @import("std");
const vt = @import("vt");
const Sixel = @import("sixel.zig");

// Platforms install a file decoder separately from Kitty's PNG-only hook.
pub var decode_image: ?vt.sys.DecodePngFn = null;

allocator: std.mem.Allocator,
enabled: bool = true,
state: enum { normal, prefix, payload, escape } = .normal,
kind: enum { sixel, iterm, iterm_begin, iterm_part, iterm_end } = .sixel,
prefix: [64]u8 = undefined,
prefix_len: usize = 0,
payload: std.ArrayList(u8) = .empty,
discard: bool = false,
transparent: bool = false,
transfer: std.ArrayList(u8) = .empty,
transferring: bool = false,

pub fn deinit(self: *InlineImages) void {
    self.payload.deinit(self.allocator);
    self.transfer.deinit(self.allocator);
}

pub fn feed(self: *InlineImages, stream: *vt.TerminalStream, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (self.state == .normal and stream.parser.state != .escape) {
            // Preserve the upstream bulk text/APC path between escapes.
            const end = if (std.mem.indexOfScalar(u8, bytes[i..], 0x1b)) |n| i + n + 1 else bytes.len;
            stream.nextSlice(bytes[i..end]);
            i = end;
            continue;
        }
        self.next(stream, bytes[i]);
        i += 1;
    }
}

fn next(self: *InlineImages, stream: *vt.TerminalStream, ch: u8) void {
    switch (self.state) {
        .normal => {
            if (stream.parser.state == .escape and (ch == 'P' or ch == ']')) {
                self.kind = if (ch == 'P') .sixel else .iterm;
                self.prefix[0] = ch;
                self.prefix_len = 1;
                self.state = .prefix;
            } else stream.nextSlice(&.{ch});
        },
        .prefix => {
            if (self.prefix_len == self.prefix.len) {
                self.forwardPrefix(stream, ch);
                return;
            }
            self.prefix[self.prefix_len] = ch;
            self.prefix_len += 1;
            const prefix = self.prefix[0..self.prefix_len];
            const matched = switch (self.kind) {
                .iterm, .iterm_begin, .iterm_part, .iterm_end => blk: {
                    inline for (.{
                        .{ "]1337;File=", .iterm },
                        .{ "]1337;MultipartFile=", .iterm_begin },
                        .{ "]1337;FilePart=", .iterm_part },
                        .{ "]1337;FileEnd", .iterm_end },
                    }) |entry| {
                        if (std.mem.startsWith(u8, entry[0], prefix)) {
                            if (prefix.len == entry[0].len) self.kind = entry[1];
                            break :blk prefix.len == entry[0].len;
                        }
                    }
                    stream.nextSlice(prefix);
                    self.state = .normal;
                    return;
                },
                .sixel => blk: {
                    if (ch != 'q' and ch != ';' and !std.ascii.isDigit(ch)) {
                        stream.nextSlice(prefix);
                        self.state = .normal;
                        return;
                    }
                    break :blk ch == 'q';
                },
            };
            if (matched) {
                // The held introducer belongs to us; cancel upstream's ESC.
                stream.nextSlice("\x18");
                self.state = .payload;
                self.discard = !self.enabled;
                self.transparent = false;
                self.payload.clearRetainingCapacity();
                if (self.kind == .sixel) {
                    var params = std.mem.splitScalar(u8, prefix[1 .. prefix.len - 1], ';');
                    _ = params.next();
                    self.transparent = std.mem.eql(u8, params.next() orelse "", "1");
                }
            }
        },
        .payload => switch (ch) {
            0x18, 0x1a => {
                self.transferring = false;
                self.reset();
            },
            0x1b => self.state = .escape,
            0x07 => if (self.kind != .sixel) {
                self.finish(stream.handler.terminal);
            },
            else => {
                if (!self.discard) {
                    if (self.payload.items.len == Sixel.max_bytes) {
                        self.discard = true;
                    } else self.payload.append(self.allocator, ch) catch {
                        self.discard = true;
                    };
                }
            },
        },
        .escape => {
            if (ch == '\\') {
                self.finish(stream.handler.terminal);
            } else {
                self.reset();
                stream.nextSlice("\x1b");
                self.next(stream, ch);
            }
        },
    }
}

fn forwardPrefix(self: *InlineImages, stream: *vt.TerminalStream, ch: u8) void {
    stream.nextSlice(self.prefix[0..self.prefix_len]);
    stream.nextSlice(&.{ch});
    self.state = .normal;
}

fn reset(self: *InlineImages) void {
    self.state = .normal;
    self.payload.clearRetainingCapacity();
}

fn finish(self: *InlineImages, term: *vt.Terminal) void {
    defer self.reset();
    if (!self.enabled or self.discard) {
        self.transferring = false;
        return;
    }
    self.complete(term) catch |err| {
        self.transferring = false;
        std.log.warn("inline image rejected: {s}", .{@errorName(err)});
    };
}

fn complete(self: *InlineImages, term: *vt.Terminal) !void {
    switch (self.kind) {
        .sixel, .iterm => try self.display(term, self.payload.items),
        .iterm_begin => {
            self.transferring = false;
            self.transfer.clearRetainingCapacity();
            try self.transfer.appendSlice(self.allocator, self.payload.items);
            try self.transfer.append(self.allocator, ':');
            self.transferring = true;
        },
        .iterm_part => {
            if (!self.transferring) return;
            if (self.payload.items.len > Sixel.max_bytes -| self.transfer.items.len) return error.InvalidData;
            try self.transfer.appendSlice(self.allocator, self.payload.items);
        },
        .iterm_end => {
            if (!self.transferring) return;
            self.transferring = false;
            if (self.payload.items.len != 0) return error.InvalidData;
            try self.display(term, self.transfer.items);
            self.transfer.clearRetainingCapacity();
        },
    }
}

fn display(self: *InlineImages, term: *vt.Terminal, payload: []const u8) !void {
    const cell_width = term.width_px / term.cols;
    const cell_height = term.height_px / term.rows;
    if (cell_width == 0 or cell_height == 0) return error.InvalidSize;
    const alloc = term.gpa();
    const bg: vt.color.RGB = term.colors.background.get() orelse .{ .r = 0, .g = 0, .b = 0 };
    const image = switch (self.kind) {
        .sixel => try Sixel.decode(alloc, payload, self.transparent, .{ bg.r, bg.g, bg.b, 255 }),
        else => try decodeFile(alloc, payload, term.width_px, term.height_px, cell_width, cell_height),
    };
    var owned = true;
    defer if (owned) alloc.free(image.data);
    const screen = term.screens.active;
    const storage = &screen.kitty_images;
    // Allocate from upstream's implicit-ID range, skipping resident IDs.
    var id = storage.next_image_id;
    while (id == 0 or storage.imageById(id) != null) id +%= 1;
    storage.next_image_id = id +% 1;
    const pin = try screen.pages.trackPin(screen.cursor.page_pin.*);
    var pin_owned = true;
    defer if (pin_owned) screen.pages.untrackPin(pin);
    try storage.addImage(term.io(), alloc, screen, .{
        .id = id,
        .width = image.width,
        .height = image.height,
        .format = .rgba,
        .data = .{ .complete = image.data },
        .metadata = .{ .implicit_id = true },
    });
    owned = false;
    try storage.addPlacement(term.io(), alloc, screen, id, 0, .{ .location = .{ .pin = pin } });
    pin_owned = false;
    // A following prompt starts on the first complete row below the image.
    const rows = std.math.divCeil(u32, image.height, cell_height) catch unreachable;
    term.carriageReturn();
    for (0..rows) |_| try term.index();
}

fn decodeFile(allocator: std.mem.Allocator, payload: []const u8, viewport_width: u32, viewport_height: u32, cell_width: u32, cell_height: u32) !vt.sys.Image {
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return error.InvalidData;
    var inline_image = false;
    var preserve_aspect = true;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var options = std.mem.splitScalar(u8, payload[0..colon], ';');
    while (options.next()) |option| {
        const equals = std.mem.indexOfScalar(u8, option, '=') orelse continue;
        const key = option[0..equals];
        const value = option[equals + 1 ..];
        if (std.mem.eql(u8, key, "inline")) {
            inline_image = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "width")) {
            width = try dimension(value, viewport_width, cell_width);
        } else if (std.mem.eql(u8, key, "height")) {
            height = try dimension(value, viewport_height, cell_height);
        } else if (std.mem.eql(u8, key, "preserveAspectRatio")) {
            preserve_aspect = !std.mem.eql(u8, value, "0");
        }
    }
    if (!inline_image) return error.InvalidData;
    const decoder = std.base64.standard.Decoder;
    const encoded = payload[colon + 1 ..];
    const data = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer allocator.free(data);
    try decoder.decode(data, encoded);
    const decode = decode_image orelse vt.sys.decode_png orelse return error.UnsupportedFormat;
    const image = try decode(allocator, data);
    defer allocator.free(image.data);
    if (image.width == 0 or image.height == 0) return error.InvalidData;
    var w = width orelse image.width;
    var h = height orelse image.height;
    if (preserve_aspect) {
        const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(image.width));
        const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(image.height));
        const scale = if (width == null and height != null) sy else if (height == null and width != null) sx else @min(sx, sy);
        w = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(image.width)) * scale)));
        h = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(image.height)) * scale)));
    }
    if (w == 0 or h == 0 or w > Sixel.max_dimension or h > Sixel.max_dimension or @as(usize, w) * h * 4 > Sixel.max_bytes) return error.InvalidSize;
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const source = ((y * image.height / h) * image.width + x * image.width / w) * 4;
            @memcpy(pixels[(y * w + x) * 4 ..][0..4], image.data[source..][0..4]);
        }
    }
    return .{ .width = w, .height = h, .data = pixels };
}

fn dimension(value: []const u8, viewport: u32, cell: u32) !?u32 {
    if (std.mem.eql(u8, value, "auto")) return null;
    const pixels = std.mem.endsWith(u8, value, "px");
    const percent = std.mem.endsWith(u8, value, "%");
    const digits = value[0 .. value.len - @as(usize, if (pixels) 2 else if (percent) 1 else 0)];
    const n = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidSize;
    const result: u64 = if (pixels) n else if (percent) @as(u64, n) * viewport / 100 else @as(u64, n) * cell;
    if (result == 0 or result > Sixel.max_dimension) return error.InvalidSize;
    return @intCast(result);
}

test "iTerm dimensions interpret pixels, cells, percent and auto" {
    try std.testing.expectEqual(@as(?u32, 17), try dimension("17px", 800, 8));
    try std.testing.expectEqual(@as(?u32, 80), try dimension("10", 800, 8));
    try std.testing.expectEqual(@as(?u32, 400), try dimension("50%", 800, 8));
    try std.testing.expectEqual(@as(?u32, null), try dimension("auto", 800, 8));
    try std.testing.expectError(error.InvalidSize, dimension("0", 800, 8));
    try std.testing.expectError(error.InvalidSize, dimension("4294967295", 800, 8));
}
