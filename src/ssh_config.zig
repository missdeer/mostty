//! Concrete aliases from top-level SSH configuration. Returned names borrow input.
const std = @import("std");

pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    names: std.mem.TokenIterator(u8, .any) = std.mem.tokenizeAny(u8, "", " \t\r"),

    pub fn init(source: []const u8) Iterator {
        const bytes = if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) source[3..] else source;
        return .{ .lines = std.mem.splitScalar(u8, bytes, '\n') };
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        while (true) {
            while (self.names.next()) |name| {
                if (name[0] == '#') break;
                if (std.mem.indexOfAny(u8, name, "*?!\"") != null) continue;
                if (!std.unicode.utf8ValidateSlice(name)) continue;
                return name;
            }
            const line = self.lines.next() orelse return null;
            self.names = std.mem.tokenizeAny(u8, line, " \t\r");
            const keyword = self.names.next() orelse continue;
            if (!std.ascii.eqlIgnoreCase(keyword, "Host")) {
                self.names = std.mem.tokenizeAny(u8, "", " \t\r");
            }
        }
    }
};

test "only concrete top-level Host aliases become launchers" {
    var it = Iterator.init("\xef\xbb\xbf# comment\r\nHost alpha beta * !blocked ?pattern \"quoted\" # ignored\nHostName wrong\n\thOsT\tgamma 日本\nInclude ignored\nHost \xff valid\n");
    for ([_][]const u8{ "alpha", "beta", "gamma", "日本", "valid" }) |expected| {
        try std.testing.expectEqualStrings(expected, it.next().?);
    }
    try std.testing.expect(it.next() == null);
}

test "aliases retain shell syntax for the platform quoting layer" {
    var it = Iterator.init("Host -oProxyCommand=$(id);'literal' duplicate duplicate\n");
    try std.testing.expectEqualStrings("-oProxyCommand=$(id);'literal'", it.next().?);
    try std.testing.expectEqualStrings("duplicate", it.next().?);
    try std.testing.expectEqualStrings("duplicate", it.next().?);
    try std.testing.expect(it.next() == null);
}
