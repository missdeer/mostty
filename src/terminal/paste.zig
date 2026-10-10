//! A single paste operation. Encoding and transport belong to the caller.
const std = @import("std");

pub const paste_start = "\x1b[200~";
pub const paste_end = "\x1b[201~";

pub fn validateUtf16(bytes: []const u16) !void {
    var it = std.unicode.Utf16LeIterator.init(bytes);
    while (try it.nextCodepoint()) |_| {}
}

pub fn writeUtf16(writer: *std.Io.Writer, bytes: []const u16, bracketed: bool) !void {
    try validateUtf16(bytes);
    var it = std.unicode.Utf16LeIterator.init(bytes);
    var state: State = .{ .bracketed = bracketed };
    try state.begin(writer);
    while (try it.nextCodepoint()) |cp| try state.onCodepoint(writer, cp);
    try state.finish(writer);
}

test "invalid UTF16 is rejected before any bracketed paste can be emitted" {
    try validateUtf16(&.{ 'a', 0xd83d, 0xde00 });
    try std.testing.expectError(error.DanglingSurrogateHalf, validateUtf16(&.{ 'a', 0xd800 }));
    try std.testing.expectError(error.UnexpectedSecondSurrogateHalf, validateUtf16(&.{ 'a', 0xdc00 }));
    const malformed = ([_]u16{'a'} ** 8192) ++ [_]u16{0xd800};
    var tiny: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&tiny);
    // A streaming writer would have flushed the prefix long before the bad
    // surrogate. Validation must win even over the tiny buffer's WriteFailed.
    try std.testing.expectError(error.DanglingSurrogateHalf, writeUtf16(&writer, &malformed, true));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var buffer: [64]u8 = undefined;
    writer = .fixed(&buffer);
    try writeUtf16(&writer, &.{ 'a', '\n', 0xd83d, 0xde00 }, true);
    try std.testing.expectEqualStrings(paste_start ++ "a\r😀" ++ paste_end, writer.buffered());
}

pub const State = struct {
    bracketed: bool,
    normalize_newlines: bool = true,
    matched: usize = 0,
    last_was_cr: bool = false,

    pub fn begin(self: *const State, writer: *std.Io.Writer) !void {
        if (self.bracketed) try writer.writeAll(paste_start);
    }

    pub fn onCodepoint(self: *State, writer: *std.Io.Writer, codepoint: u21) !void {
        var cp = codepoint;
        if (self.normalize_newlines) {
            if (cp == '\n') {
                if (self.last_was_cr) {
                    self.last_was_cr = false;
                    return;
                }
                cp = '\r';
            } else {
                self.last_was_cr = cp == '\r';
            }
        }
        if (self.bracketed) {
            if (cp == paste_end[self.matched]) {
                self.matched += 1;
                if (self.matched == paste_end.len) self.matched = 0;
                return;
            }
            if (self.matched != 0) {
                try writer.writeAll(paste_end[0..self.matched]);
                self.matched = 0;
            }
            if (cp == paste_end[0]) {
                self.matched = 1;
                return;
            }
        }
        var encoded: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &encoded);
        try writer.writeAll(encoded[0..n]);
    }

    pub fn finish(self: *State, writer: *std.Io.Writer) !void {
        try writer.writeAll(paste_end[0..self.matched]);
        self.matched = 0;
        if (self.bracketed) try writer.writeAll(paste_end);
    }
};

pub fn writeUtf8(writer: *std.Io.Writer, bytes: []const u8, bracketed: bool, normalize_newlines: bool) !void {
    // Validate before emitting the opening marker.
    const view = try std.unicode.Utf8View.init(bytes);
    var it = view.iterator();
    var state: State = .{ .bracketed = bracketed, .normalize_newlines = normalize_newlines };
    try state.begin(writer);
    while (it.nextCodepoint()) |cp| try state.onCodepoint(writer, cp);
    try state.finish(writer);
}

test "paste normalizes Enter and filters only complete embedded end markers" {
    const source = "界\r\nA\nB\rC\x1b\x1b[201~D\x1b[201~\x1b[20";
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeUtf8(&writer, source, true, true);
    try std.testing.expectEqualStrings(paste_start ++ "界\rA\rB\rC\x1bD\x1b[20" ++ paste_end, writer.buffered());
    writer.end = 0;
    try writeUtf8(&writer, source, false, false);
    try std.testing.expectEqualStrings(source, writer.buffered());
}

test "paste state survives every codepoint boundary and write failures propagate" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var state: State = .{ .bracketed = true };
    try state.begin(&writer);
    for ("a\r\n\x1b[201~b\n\n") |cp| try state.onCodepoint(&writer, cp);
    try state.finish(&writer);
    try std.testing.expectEqualStrings(paste_start ++ "a\rb\r\r" ++ paste_end, writer.buffered());
    var empty: std.Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.WriteFailed, writeUtf8(&empty, "hello", true, true));
    writer.end = 0;
    try std.testing.expectError(error.InvalidUtf8, writeUtf8(&writer, "\xff", true, true));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
