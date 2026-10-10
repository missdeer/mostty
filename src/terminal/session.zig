const Session = @This();

const std = @import("std");
const vt = @import("vt");
const InlineImages = @import("inline_images.zig");

pub const DEFAULT_SCROLLBACK_BYTES: usize = 10_000_000;

const SessionStream = vt.Stream(StreamHandler);
const Terminal = vt.Terminal;
const VtHandler = vt.TerminalStream.Handler;
const StreamAction = vt.StreamAction;

const StreamHandler = struct {
    terminal: *Terminal,
    inner: VtHandler,

    pub fn deinit(self: *StreamHandler) void {
        self.inner.deinit();
    }

    pub fn vt(self: *StreamHandler, comptime action: StreamAction.Tag, value: StreamAction.Value(action)) void {
        // Both native hosts still encode legacy key events, including releases.
        // Do not advertise or negotiate a keyboard protocol they cannot honor.
        switch (action) {
            .kitty_keyboard_query, .kitty_keyboard_push, .kitty_keyboard_pop, .kitty_keyboard_set, .kitty_keyboard_set_or, .kitty_keyboard_set_not => return,
            else => {},
        }
        if (action == .erase_display_scrollback) {
            // ED3 relocates erased history pins without marking them garbage.
            // Retire image anchors first so they cannot reappear at the top.
            const screen = self.terminal.screens.active;
            var changed = false;
            var placements = screen.kitty_images.placements.valueIterator();
            while (placements.next()) |placement| {
                const pin = switch (placement.location) {
                    .pin => |pin| pin,
                    .virtual, .relative => continue,
                };
                if (pin.garbage or screen.pages.pointFromPin(.active, pin.*) != null) continue;
                pin.garbage = true;
                changed = true;
            }
            if (changed) screen.kitty_images.markMutated(self.terminal.io());
        }
        self.inner.vt(action, value);
    }
};

pub const SizeResponse = effectReturnType("size");

pub const Hooks = struct {
    context: *anyopaque,
    title_changed: ?*const fn (*anyopaque, *vt.Terminal) void = null,
    write_pty: ?*const fn (*anyopaque, []const u8) void = null,
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
term: *vt.Terminal,
stream: SessionStream,
hooks: Hooks,
images: InlineImages,

pub fn init(self: *Session, options: Options) !void {
    self.terminal_allocator = options.terminal_allocator;

    self.term = try options.terminal_allocator.create(vt.Terminal);
    errdefer options.terminal_allocator.destroy(self.term);
    self.term.* = try vt.Terminal.init(
        options.io,
        options.terminal_allocator,
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
        .handler = .{ .terminal = self.term, .inner = handler },
    });
}

pub fn deinit(self: *Session) void {
    self.images.deinit();
    self.stream.deinit();
    self.term.deinit(self.terminal_allocator);
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
    try self.term.resize(self.terminal_allocator, .{
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
    const wrapper: *StreamHandler = @fieldParentPtr("inner", handler);
    const stream: *SessionStream = @fieldParentPtr("handler", wrapper);
    return @fieldParentPtr("stream", stream);
}

fn onTitleChanged(handler: *vt.TerminalStream.Handler) void {
    const self = sessionFromEffectHandler(handler);
    const callback = self.hooks.title_changed orelse return;
    callback(self.hooks.context, self.term);
}

fn onWritePty(handler: *vt.TerminalStream.Handler, data: []const u8) void {
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

        fn writePty(context: *anyopaque, data: []const u8) void {
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

test "image replacement releases allocations during a live session" {
    var counted: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer std.testing.expect(counted.deinit() == .ok) catch @panic("leaked image memory");
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = counted.allocator(), .stream_allocator = counted.allocator(), .cols = 10, .rows = 2, .hooks = .{ .context = &context } });
    defer session.deinit();
    const image = "\x1b_Ga=t,f=24,s=1,v=1,i=1;/wAA\x1b\\";
    for (0..8) |_| session.feed(image);
    const plateau = counted.total_requested_bytes;
    for (0..128) |_| {
        session.feed(image);
        try std.testing.expectEqual(@as(u32, 1), session.term.screens.active.kitty_images.images.count());
        // Final deinit alone cannot detect a pane-lifetime arena regression.
        try std.testing.expectEqual(plateau, counted.total_requested_bytes);
    }
}

test "legacy hosts neither advertise nor negotiate Kitty keyboard flags" {
    const Capture = struct {
        replies: usize = 0,
        fn write(context: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.replies += 1;
        }
    };
    var capture: Capture = .{};
    var session: Session = undefined;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 10, .rows = 2, .hooks = .{ .context = &capture, .write_pty = Capture.write } });
    defer session.deinit();
    session.feed("\x1b[?u\x1b[>31u\x1b[=31;1u\x1b[=31;2u\x1b[=31;3u\x1b[<1u\x1b[?u");
    try std.testing.expectEqual(@as(usize, 0), capture.replies);
    try std.testing.expectEqual(@as(u8, 0), session.term.screens.active.kitty_keyboard.current().int());
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

test "every wrapped URL cell resolves the full mixed-character address" {
    const url_hover = @import("url_hover.zig");
    const suffix = "a-b_C%2F+9=" ** 8;
    const urls = [_][]const u8{
        "https://example.test/login?redirect_uri=https%3A%2F%2Fexample.test%2Fcallback&state=" ++ suffix ++ "#fragment",
        "https://example.test/login?redirect_uri=http://redirect.test/finish?state=" ++ suffix,
        "http://example.test/login#next=https://redirect.test/finish?state=" ++ suffix,
        "https://[2001:db8::1]:8443/path(a)/@user!$&'()*+,;=:-._~%20?key=" ++ suffix,
        "https://example.test/path?state=abc{def}|ghi^jkl\\mno&token=" ++ suffix,
        "https://example.test/\u{6587}\u{4ef6}/\u{62a5}\u{544a}?\u{540d}\u{79f0}=\u{6d4b}\u{8bd5}&token=" ++ suffix,
        "https://example.test/cafe\u{301}/\u{1f469}\u{200d}\u{1f4bb}?token=" ++ suffix,
    };
    for ([_]u16{ 11, 32 }) |cols| {
        for (urls) |url| {
            var context: u8 = 0;
            var session: Session = undefined;
            try session.init(.{
                .io = std.testing.io,
                .terminal_allocator = std.testing.allocator,
                .stream_allocator = std.testing.allocator,
                .cols = cols,
                .rows = 64,
                .hooks = .{ .context = &context },
            });
            defer session.deinit();
            session.feed(url);
            for (0..session.term.rows) |row| {
                const pin = session.term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(row) } }).?;
                const cells = pin.node.page().getCells(pin.rowAndCell().row);
                for (cells[0..cols], 0..) |cell, col| {
                    if (cell.wide == .spacer_head or (!cell.hasText() and cell.wide != .spacer_tail)) continue;
                    const hit = url_hover.detectAt(session.term, @intCast(col), @intCast(row));
                    try std.testing.expect(hit != null);
                    // A wrap or a multibyte glyph must never change the browser target.
                    try std.testing.expectEqualStrings(url, hit.?.url());
                    try std.testing.expect(hit.?.contains(@intCast(row), @intCast(col), cols - 1));
                }
            }
        }
    }
}

test "URL detection keeps prose boundaries and enforces the UTF-8 byte limit" {
    const url_hover = @import("url_hover.zig");
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 64,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    const url = "https://example.test/\u{4e2d}?value={a|b}";
    for ([_][]const u8{ " more", "\u{a0}more", "\u{3000}more", "\u{ff0c}more", "} more" }) |boundary| {
        session.feed("\x1b[2J\x1b[H");
        session.feed(url);
        session.feed(boundary);
        const hit = url_hover.detectAt(session.term, 0, 0).?;
        // Adjacent prose and an unmatched closing brace are not part of the address.
        try std.testing.expectEqualStrings(url, hit.url());
    }
    const limit_url = "https://x/" ++ ("\u{4e2d}" ** 1362);
    try std.testing.expectEqual(url_hover.MAX_URL_LEN, limit_url.len);
    session.feed("\x1b[2J\x1b[H" ++ limit_url);
    const hit = url_hover.detectAt(session.term, 0, 0).?;
    try std.testing.expectEqualStrings(limit_url, hit.url());
    session.feed("a");
    // Oversized UTF-8 addresses must not open a silently shortened prefix.
    try std.testing.expect(url_hover.detectAt(session.term, 0, 0) == null);
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

test "fragmented ED3 retires history images and preserves active image anchors" {
    var context: u8 = 0;
    var session: Session = undefined;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 10, .rows = 5, .hooks = .{ .context = &context } });
    defer session.deinit();
    session.syncPixelSize(8, 6);
    const image = "\x1bPq#1;2;100;0;0~\x1b\\";
    session.feed(image);
    const screen = session.term.screens.active;
    var placements = screen.kitty_images.placements.valueIterator();
    const history_pin = placements.next().?.location.pin;
    for (0..session.term.rows + 1) |_| session.feed("\r\n");
    try std.testing.expect(screen.pages.pointFromPin(.active, history_pin.*) == null);
    session.feed(image);
    placements = screen.kitty_images.placements.valueIterator();
    var active_pin: ?*vt.Pin = null;
    while (placements.next()) |placement| {
        if (placement.location.pin != history_pin) active_pin = placement.location.pin;
    }
    try std.testing.expect(active_pin != null);
    screen.kitty_images.dirty = false;
    const generation = screen.kitty_images.generation;
    for ("\x1b[3J") |byte| session.feed(&.{byte});
    // Removed history must never be rendered at a relocated pin's new position.
    try std.testing.expect(history_pin.garbage);
    try std.testing.expect(!active_pin.?.garbage);
    try std.testing.expect(screen.pages.pointFromPin(.active, active_pin.?.*) != null);
    // Windows also needs a mutation signal to repaint the disappearing image.
    try std.testing.expect(screen.kitty_images.dirty);
    try std.testing.expect(screen.kitty_images.generation != generation);
}

test "image disable suppresses all protocols and Sixel capability, including alternate screens" {
    const Capture = struct {
        response: [64]u8 = undefined,
        len: usize = 0,
        fn write(context: *anyopaque, bytes: []const u8) void {
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
