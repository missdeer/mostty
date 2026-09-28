//! Join selected wrapped URLs without changing ordinary multiline text.

const std = @import("std");
const vt = @import("vt");
const url_hover = @import("url_hover.zig");

fn matchesWrappedUri(text: []const u8, uri: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, 10) == null) return false;
    var remaining = uri;
    var lines = std.mem.splitScalar(u8, text, 10);
    while (lines.next()) |line| {
        const fragment = std.mem.trim(u8, line, &.{ 32, 9, 13 });
        if (fragment.len == 0) continue;
        if (!std.mem.startsWith(u8, remaining, fragment)) return false;
        remaining = remaining[fragment.len..];
    }
    return remaining.len == 0;
}

pub const CopyResult = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: CopyResult, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

fn detectedWrappedUri(term: *vt.Terminal, sel: vt.Selection, selected: []const u8, allocator: std.mem.Allocator) ?CopyResult {
    const screen = term.screens.active;
    var lines = std.mem.splitScalar(u8, selected, 10);
    var first_line = true;
    while (lines.next()) |line| {
        const fragment = std.mem.trim(u8, line, &.{ 32, 9, 13 });
        if (fragment.len == 0) continue;
        if (!first_line and (std.ascii.startsWithIgnoreCase(fragment, "https://") or
            std.ascii.startsWithIgnoreCase(fragment, "http://"))) return null;
        first_line = false;
    }
    const ordered = sel.ordered(screen, .forward);
    const end = ordered.end();
    var cells = ordered.start().cellIterator(.right_down, end);
    while (cells.next()) |pin| {
        if (pin.node == end.node and pin.y == end.y and pin.x > end.x) break;
        const cell = pin.rowAndCell().cell;
        if (!cell.hasText()) continue;
        if (cell.content_tag != .codepoint and cell.content_tag != .codepoint_grapheme) return null;
        const cp = cell.content.codepoint.data;
        if (cp == ' ' or cp == '\t') continue;
        const point = screen.pages.pointFromPin(.viewport, pin) orelse return null;
        if (point.viewport.x >= term.cols or point.viewport.y >= term.rows) return null;
        const hit = url_hover.detectAt(term, @intCast(point.viewport.x), @intCast(point.viewport.y)) orelse return null;
        if (!matchesWrappedUri(selected, hit.url())) return null;
        const joined = allocator.dupe(u8, hit.url()) catch return null;
        return .{ .text = joined, .owned = joined };
    }
    return null;
}

pub fn copyText(term: *vt.Terminal, sel: vt.Selection, selected: []const u8, allocator: std.mem.Allocator) CopyResult {
    const screen = term.screens.active;
    if (sel.rectangle or std.mem.indexOfScalar(u8, selected, 10) == null) return .{ .text = selected };
    const ordered = sel.ordered(screen, .forward);
    const end = ordered.end();
    var cells = ordered.start().cellIterator(.right_down, end);
    while (cells.next()) |pin| {
        if (pin.node == end.node and pin.y == end.y and pin.x > end.x) break;
        const page = pin.node.page();
        const cell = pin.rowAndCell().cell;
        if (!cell.hyperlink) continue;
        const id = page.lookupHyperlink(cell) orelse continue;
        const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
        if (matchesWrappedUri(selected, uri)) return .{ .text = uri };
    }
    return detectedWrappedUri(term, sel, selected, allocator) orelse .{ .text = selected };
}

test "selected plain URL copies the shared hover target in both drag directions" {
    const Session = @import("session.zig");
    var session: Session = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 40,
        .rows = 4,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    const first = "https://example.test/abcdefghijklmno";
    const url = first ++ "pqrst";
    session.feed("  " ++ first ++ "  \r\n            pqrst");
    const screen = session.term.screens.active;
    const start = screen.pages.pin(.{ .viewport = .{ .x = 2, .y = 0 } }).?;
    const end = screen.pages.pin(.{ .viewport = .{ .x = 16, .y = 1 } }).?;
    const hit = url_hover.detectAt(session.term, 14, 1) orelse return error.MissingUrl;
    try std.testing.expectEqualStrings(url, hit.url());
    for ([_]vt.Selection{ .init(start, end, false), .init(end, start, false) }) |selection| {
        const raw = try screen.selectionString(std.testing.allocator, .{ .sel = selection });
        defer std.testing.allocator.free(raw);
        const copied = copyText(session.term, selection, raw, std.testing.allocator);
        defer copied.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(hit.url(), copied.text);
    }
}
