const Session = @This();

const std = @import("std");
const vt = @import("vt");
const InlineImages = @import("inline_images.zig");

pub const DEFAULT_SCROLLBACK_BYTES: usize = 10_000_000;

pub const SizeResponse = effectReturnType("size");

pub const Hooks = struct {
    context: *anyopaque,
    title_changed: ?*const fn (*anyopaque, *vt.Terminal) void = null,
    write_pty: ?*const fn (*anyopaque, [:0]const u8) void = null,
    size: ?*const fn (*anyopaque, *vt.Terminal) SizeResponse = null,
};

pub const Options = struct {
    io: std.Io,
    terminal_allocator: std.mem.Allocator,
    stream_allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    hooks: Hooks,
    images_enabled: bool = true,
};

terminal_allocator: std.mem.Allocator,
terminal_arena: std.heap.ArenaAllocator,
term: *vt.Terminal,
stream: vt.TerminalStream,
hooks: Hooks,
images: InlineImages,

pub fn init(self: *Session, options: Options) !void {
    self.terminal_allocator = options.terminal_allocator;
    self.terminal_arena = std.heap.ArenaAllocator.init(options.terminal_allocator);
    errdefer self.terminal_arena.deinit();

    self.term = try options.terminal_allocator.create(vt.Terminal);
    errdefer options.terminal_allocator.destroy(self.term);
    self.term.* = try vt.Terminal.init(
        options.io,
        self.terminal_arena.allocator(),
        terminalInitOptions(options.cols, options.rows),
    );
    self.hooks = options.hooks;
    self.images = .{ .allocator = options.stream_allocator, .enabled = options.images_enabled };
    self.setImagesEnabled(options.images_enabled);

    var handler = self.term.vtHandler();
    handler.effects = effects: {
        var effects: vt.TerminalStream.Handler.Effects = .readonly;
        effects.title_changed = onTitleChanged;
        effects.write_pty = onWritePty;
        effects.device_attributes = onDeviceAttributes;
        effects.xtversion = onXtVersion;
        effects.size = onSize;
        break :effects effects;
    };

    self.stream = .init(.{
        .allocator = options.stream_allocator,
        .handler = handler,
    });
}

pub fn deinit(self: *Session) void {
    self.images.deinit();
    self.stream.deinit();
    self.term.deinit(self.terminal_arena.allocator());
    self.terminal_arena.deinit();
    self.terminal_allocator.destroy(self.term);
    self.* = undefined;
}

pub fn feed(self: *Session, bytes: []const u8) void {
    self.images.feed(&self.stream, bytes);
}

pub fn setImagesEnabled(self: *Session, enabled: bool) void {
    self.images.enabled = enabled;
    if (!enabled) {
        self.images.discard = true;
        self.images.transferring = false;
        self.images.transfer.clearRetainingCapacity();
    }
    self.term.setKittyGraphicsSizeLimit(self.term.gpa(), if (enabled) 320 * 1000 * 1000 else 0);
}

pub fn resize(self: *Session, cols: u16, rows: u16) !void {
    try self.term.resize(self.terminal_arena.allocator(), .{
        .cols = cols,
        .rows = rows,
    });
}

pub fn syncPixelSize(self: *Session, cell_width: u32, cell_height: u32) void {
    if (cell_width == 0 or cell_height == 0) return;
    self.term.width_px = @as(u32, self.term.cols) * cell_width;
    self.term.height_px = @as(u32, self.term.rows) * cell_height;
}

fn terminalInitOptions(cols: u16, rows: u16) vt.Terminal.Options {
    return .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = DEFAULT_SCROLLBACK_BYTES,
        .default_modes = .{ .grapheme_cluster = true },
    };
}

fn sessionFromEffectHandler(handler: *vt.TerminalStream.Handler) *Session {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    return @fieldParentPtr("stream", stream);
}

fn onTitleChanged(handler: *vt.TerminalStream.Handler) void {
    const self = sessionFromEffectHandler(handler);
    const callback = self.hooks.title_changed orelse return;
    callback(self.hooks.context, self.term);
}

fn onWritePty(handler: *vt.TerminalStream.Handler, data: [:0]const u8) void {
    const self = sessionFromEffectHandler(handler);
    const callback = self.hooks.write_pty orelse return;
    callback(self.hooks.context, data);
}

fn onDeviceAttributes(handler: *vt.TerminalStream.Handler) effectReturnType("device_attributes") {
    return if (sessionFromEffectHandler(handler).images.enabled)
        .{ .primary = .{ .features = &.{ .sixel, .ansi_color } } }
    else
        .{};
}

fn onXtVersion(_: *vt.TerminalStream.Handler) []const u8 {
    return "mostty";
}

fn onSize(handler: *vt.TerminalStream.Handler) SizeResponse {
    const self = sessionFromEffectHandler(handler);
    const callback = self.hooks.size orelse return null;
    return callback(self.hooks.context, self.term);
}

fn effectReturnType(comptime field: []const u8) type {
    const Effects = vt.TerminalStream.Handler.Effects;
    const optional = @typeInfo(@FieldType(Effects, field)).optional;
    const pointer = @typeInfo(optional.child).pointer;
    const function = @typeInfo(pointer.child).@"fn";
    return function.return_type.?;
}

test "session owns VT state and routes terminal effects" {
    const Capture = struct {
        response: [64]u8 = undefined,
        response_len: usize = 0,
        title: [64]u8 = undefined,
        title_len: usize = 0,

        fn writePty(context: *anyopaque, data: [:0]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.response_len = @min(data.len, self.response.len);
            @memcpy(self.response[0..self.response_len], data[0..self.response_len]);
        }

        fn titleChanged(context: *anyopaque, term: *vt.Terminal) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const title = term.getTitle() orelse return;
            self.title_len = @min(title.len, self.title.len);
            @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
        }
    };

    var capture: Capture = .{};
    var session: Session = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 10,
        .rows = 2,
        .hooks = .{
            .context = &capture,
            .title_changed = Capture.titleChanged,
            .write_pty = Capture.writePty,
        },
    });
    defer session.deinit();

    session.feed("hello\x1b]0;shared core\x07\x1b[>0q");

    const contents = try session.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("hello", contents);
    try std.testing.expectEqualStrings("shared core", capture.title[0..capture.title_len]);
    try std.testing.expectEqualStrings("\x1bP>|mostty\x1b\\", capture.response[0..capture.response_len]);
}

test "session resize rejects a zero grid without changing terminal state" {
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 10,
        .rows = 2,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();

    try std.testing.expectError(error.InvalidValue, session.resize(0, 4));
    try std.testing.expectEqual(@as(usize, 10), session.term.cols);
    try std.testing.expectEqual(@as(usize, 2), session.term.rows);

    try session.resize(8, 4);
    session.syncPixelSize(9, 18);
    try std.testing.expectEqual(@as(u32, 72), session.term.width_px);
    try std.testing.expectEqual(@as(u32, 72), session.term.height_px);
}

test "default scrollback preserves early normal output" {
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 215,
        .rows = 2,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line {d:0>4}\r\n", .{i});
        session.feed(line);
    }

    session.term.screens.active.scroll(.{ .top = {} });
    const dump = try session.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "line 0000") != null);
}

test "Sixel survives every chunk boundary and advances below its anchored image" {
    const sequence = "\x1bP0;1q\"1;1;2;12#1;2;100;0;0!2~-!2~\x1b\\";
    for (0..sequence.len + 1) |split| {
        var context: u8 = 0;
        var session: Session = undefined;
        try session.init(.{ .io = std.testing.io, .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 10, .rows = 5, .hooks = .{ .context = &context } });
        defer session.deinit();
        session.syncPixelSize(8, 6);
        session.feed(sequence[0..split]);
        session.feed(sequence[split..]);
        const storage = &session.term.screens.active.kitty_images;
        try std.testing.expectEqual(@as(u32, 1), storage.images.count());
        try std.testing.expectEqual(@as(u32, 1), storage.placements.count());
        try std.testing.expectEqual(@as(usize, 2), session.term.screens.active.cursor.y);
        try std.testing.expectEqual(@as(usize, 0), session.term.screens.active.cursor.x);
        var images = storage.images.valueIterator();
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, images.next().?.data.bytes().?[0..4]);
        session.feed("\x1b[H\x1b[2J\x1b[3J");
        try std.testing.expectEqual(@as(u32, 0), storage.placements.count());
    }
}

test "image disable suppresses all protocols and Sixel capability, including alternate screens" {
    const Capture = struct {
        response: [64]u8 = undefined,
        len: usize = 0,
        fn write(context: *anyopaque, bytes: [:0]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.len = bytes.len;
            @memcpy(self.response[0..bytes.len], bytes);
        }
    };
    var capture: Capture = .{};
    var session: Session = undefined;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 10, .rows = 5, .hooks = .{ .context = &capture, .write_pty = Capture.write } });
    defer session.deinit();
    session.syncPixelSize(8, 6);
    session.feed("\x1b[c");
    try std.testing.expectEqualStrings("\x1b[?62;4;22c", capture.response[0..capture.len]);
    session.feed("\x1bPq#1;2;100;0;0~\x1b\\");
    session.setImagesEnabled(false);
    try std.testing.expectEqual(@as(u32, 0), session.term.screens.active.kitty_images.images.count());
    for ([_][]const u8{ "", "\x1b[?1049h" }) |screen| {
        session.feed(screen);
        session.feed("\x1b[H\x1b[2J");
        session.feed("\x1b[c");
        try std.testing.expectEqualStrings("\x1b[?62;22c", capture.response[0..capture.len]);
        capture.len = 0;
        const input = "\x1b_Ga=T,f=24,s=1,v=1,i=1;/wAA\x1b\\\x1bPq#1;2;100;0;0~\x1b\\\x1b]1337;File=inline=1:AAAA\x07ok";
        for (input) |ch| session.feed(&.{ch});
        try std.testing.expectEqual(@as(u32, 0), session.term.screens.active.kitty_images.images.count());
        const text = try session.term.plainString(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("ok", std.mem.trim(u8, text, "\n"));
    }
    session.setImagesEnabled(true);
    session.feed("\x1bPq#1;2;100;0;0~\x1b\\");
    try std.testing.expectEqual(@as(u32, 1), session.term.screens.active.kitty_images.images.count());
}

test "image interception preserves non-image strings and recovers after cancellation" {
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 20, .rows = 5, .hooks = .{ .context = &context } });
    defer session.deinit();
    session.syncPixelSize(8, 6);
    const input = "\x1b]0;title\x07\x1bP$qm\x1b\\\x1bPq~\x18\x1b]1337;File=inline=1:AAAA\x1b[31mhello";
    for (input) |ch| session.feed(&.{ch});
    try std.testing.expectEqualStrings("title", session.term.getTitle().?);
    try std.testing.expectEqual(@as(u32, 0), session.term.screens.active.kitty_images.images.count());
    const text = try session.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}
