//! Converts the shared VT screen into macOS renderer cells.
//!
//! This module deliberately contains no CoreText or Metal code. It is the
//! stable, testable boundary between terminal state and the platform renderer:
//! cell geometry and SGR colors are resolved once, then the macOS renderer can
//! rasterize the resulting frame without reimplementing VT semantics.

const std = @import("std");
const vt = @import("vt");
const TerminalSession = @import("../terminal/Session.zig");
const Config = @import("../Config.zig");
const cell_style = @import("../renderer/cell_style.zig");
const url_hover = @import("../terminal/url_hover.zig");

pub const Rgba = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn fromRgb(r: u8, g: u8, b: u8) Rgba {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,

    pub fn gridSize(self: Metrics, pixel_width: u32, pixel_height: u32) Size {
        return .{
            .cols = if (self.cell_width == 0) 0 else pixel_width / self.cell_width,
            .rows = if (self.cell_height == 0) 0 else pixel_height / self.cell_height,
        };
    }
};

pub const Size = struct {
    cols: u32,
    rows: u32,
};

pub const Style = struct {
    foreground: Rgba,
    background: Rgba,
    default_background: bool = true,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    invisible: bool = false,
    underline: u8 = 0,
    strikethrough: bool = false,
    overline: bool = false,
};

pub const Cell = struct {
    col: u16,
    row: u16,
    width: u8,
    codepoint: u21,
    grapheme: []const u21,
    style: Style,
};

/// Inclusive linear selection over viewport coordinates. Endpoints arrive in
/// click order, so every consumer must go through `normalized` first.
pub const Selection = struct {
    start_col: u16,
    start_row: u16,
    end_col: u16,
    end_row: u16,

    pub fn normalized(self: Selection) Selection {
        const reversed = self.end_row < self.start_row or
            (self.end_row == self.start_row and self.end_col < self.start_col);
        if (!reversed) return self;
        return .{
            .start_col = self.end_col,
            .start_row = self.end_row,
            .end_col = self.start_col,
            .end_row = self.start_row,
        };
    }

    /// Whether a cell spanning `width` columns from `col` intersects the range.
    /// Width matters: a double-width glyph occupies two columns but is stored
    /// under its leading one, so testing that column alone would leave a CJK
    /// glyph unhighlighted when the drag started on its trailing half.
    fn overlaps(self: Selection, col: u16, row: u16, width: u8) bool {
        if (row < self.start_row or row > self.end_row) return false;
        if (row == self.start_row and col + width - 1 < self.start_col) return false;
        if (row == self.end_row and col > self.end_col) return false;
        return true;
    }
};

/// Recolors selected cells. Mirrors the Windows renderer: an unset
/// `selection-background` / `selection-foreground` degrades to inverse video, so
/// the highlight stays legible against any theme.
const SelectionPaint = struct {
    range: ?Selection,
    foreground: ?Rgba,
    background: ?Rgba,

    fn apply(self: SelectionPaint, style: *Style, col: u16, row: u16, width: u8) void {
        const range = self.range orelse return;
        if (!range.overlaps(col, row, width)) return;
        const original_background = style.background;
        style.background = self.background orelse style.foreground;
        style.foreground = self.foreground orelse original_background;
        style.background.a = 255;
        style.default_background = false;
        style.foreground.a = 255;
    }
};

pub const Options = struct {
    metrics: Metrics,
    pixel_width: u32,
    pixel_height: u32,
    /// Alpha for cells that keep the terminal's default background, letting a
    /// translucent window composite what is behind it. Cells with an explicit
    /// background stay opaque so highlighted regions remain readable, matching
    /// the Windows renderer.
    background_alpha: u8 = alphaFromOpacity((Config{}).background_opacity),
    selection: ?Selection = null,
    hovered_url: ?*const url_hover.Hit = null,
    selection_foreground: ?Rgba = optionalRgba((Config{}).theme.selection_foreground),
    selection_background: ?Rgba = optionalRgba((Config{}).theme.selection_background),
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    cols: u32,
    rows: u32,
    pixel_width: u32,
    pixel_height: u32,
    background: Rgba,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const DEFAULT_FOREGROUND = fromRgb(Config.u24ToRgb((Config{}).theme.foreground));
pub const DEFAULT_BACKGROUND = fromRgb(Config.u24ToRgb((Config{}).theme.background));

pub fn alphaFromOpacity(opacity: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255));
}

pub fn optionalRgba(value: ?u24) ?Rgba {
    return fromRgb(Config.u24ToRgb(value orelse return null));
}

pub fn build(
    allocator: std.mem.Allocator,
    term: *vt.Terminal,
    options: Options,
) !Frame {
    const metrics = options.metrics;
    if (metrics.cell_width == 0 or metrics.cell_height == 0) return error.InvalidMetrics;

    const pixel_width = options.pixel_width;
    const pixel_height = options.pixel_height;
    const grid = metrics.gridSize(pixel_width, pixel_height);
    const cols = @min(grid.cols, @as(u32, @intCast(term.cols)));
    const rows = @min(grid.rows, @as(u32, @intCast(term.rows)));
    const foreground = if (term.colors.foreground.get()) |color| fromRgb(color) else DEFAULT_FOREGROUND;
    var background = if (term.colors.background.get()) |color| fromRgb(color) else DEFAULT_BACKGROUND;
    background.a = options.background_alpha;
    const selection: SelectionPaint = .{
        .range = if (options.selection) |range| range.normalized() else null,
        .foreground = options.selection_foreground,
        .background = options.selection_background,
    };

    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    errdefer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, @as(usize, cols) * rows);

    const screen = term.screens.active;
    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var row: u32 = 0;
    while (row_it.next()) |row_pin| {
        if (row >= rows) break;
        const page = row_pin.node.page();
        const page_cells = page.getCells(row_pin.rowAndCell().row);
        var col: u32 = 0;
        var cell_i: usize = 0;
        while (col < cols and cell_i < page_cells.len) {
            const raw = page_cells[cell_i];
            if (raw.wide == .spacer_tail) {
                col += 1;
                cell_i += 1;
                continue;
            }

            const width: u8 = if (raw.wide == .wide and col + 1 < cols) 2 else 1;
            var style = styleForCell(raw, page, foreground, background, term);
            if (options.hovered_url) |hit| {
                if (hit.contains(@intCast(row), @intCast(col), @intCast(cols - 1))) {
                    if (style.underline == 0) style.underline = 1;
                }
            }
            selection.apply(&style, @intCast(col), @intCast(row), width);
            try cells.append(allocator, .{
                .col = @intCast(col),
                .row = @intCast(row),
                .width = width,
                .codepoint = if (raw.content_tag == .codepoint or raw.content_tag == .codepoint_grapheme)
                    (if (raw.content.codepoint.data == 0) ' ' else raw.content.codepoint.data)
                else
                    ' ',
                .grapheme = if (raw.content_tag == .codepoint_grapheme)
                    (page.lookupGrapheme(&page_cells[cell_i]) orelse &.{})
                else
                    &.{},
                .style = style,
            });

            col += width;
            cell_i += 1;
        }
        try appendBlanks(allocator, &cells, row, col, cols, foreground, background, selection);
        row += 1;
    }

    while (row < rows) : (row += 1) {
        try appendBlanks(allocator, &cells, row, 0, cols, foreground, background, selection);
    }

    return .{
        .allocator = allocator,
        .cells = try cells.toOwnedSlice(allocator),
        .cols = cols,
        .rows = rows,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
        .background = background,
    };
}

fn appendBlanks(
    allocator: std.mem.Allocator,
    cells: *std.ArrayListUnmanaged(Cell),
    row: u32,
    start_col: u32,
    cols: u32,
    foreground: Rgba,
    background: Rgba,
    selection: SelectionPaint,
) !void {
    var col = start_col;
    while (col < cols) : (col += 1) {
        var style = Style{ .foreground = foreground, .background = background };
        selection.apply(&style, @intCast(col), @intCast(row), 1);
        try cells.append(allocator, .{
            .col = @intCast(col),
            .row = @intCast(row),
            .width = 1,
            .codepoint = ' ',
            .grapheme = &.{},
            .style = style,
        });
    }
}

fn styleForCell(
    cell: anytype,
    page: anytype,
    foreground: Rgba,
    background: Rgba,
    term: *vt.Terminal,
) Style {
    const resolved = cell_style.forCell(cell, page, &term.colors.palette.current, cell_style.rgbToU24(.{ .r = foreground.r, .g = foreground.g, .b = foreground.b }), cell_style.rgbToU24(.{ .r = background.r, .g = background.g, .b = background.b }));
    var result: Style = .{
        .foreground = fromRgb(Config.u24ToRgb(resolved.foreground)),
        .background = fromRgb(Config.u24ToRgb(resolved.background)),
        .default_background = resolved.default_background,
        .bold = resolved.flags.bold,
        .italic = resolved.flags.italic,
        .faint = resolved.flags.faint,
        .invisible = resolved.flags.invisible,
        .underline = @intFromEnum(resolved.flags.underline),
        .strikethrough = resolved.flags.strikethrough,
        .overline = resolved.flags.overline,
    };
    if (result.faint) {
        result.foreground.r /= 2;
        result.foreground.g /= 2;
        result.foreground.b /= 2;
    }
    result.background.a = if (resolved.default_background) background.a else 255;
    result.foreground.a = 255;
    if (result.invisible) result.foreground = result.background;
    return result;
}

fn fromRgb(rgb: anytype) Rgba {
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

test "grid model preserves ordinary, wide, and styled VT cells" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 8,
        .rows = 2,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();

    session.feed("A界\x1b[1;3;4;38;2;10;20;30;48;2;40;50;60mB");
    var frame = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 72,
        .pixel_height = 36,
    });
    defer frame.deinit();

    var found_wide = false;
    var found_styled = false;
    for (frame.cells) |cell| {
        if (cell.codepoint == '界') {
            found_wide = true;
            try std.testing.expectEqual(@as(u8, 2), cell.width);
            try std.testing.expectEqual(@as(u16, 1), cell.col);
        }
        if (cell.codepoint == 'B') {
            found_styled = true;
            try std.testing.expect(cell.style.bold);
            try std.testing.expect(cell.style.italic);
            try std.testing.expectEqual(@as(u8, 1), cell.style.underline);
            try std.testing.expectEqual(Rgba.fromRgb(10, 20, 30), cell.style.foreground);
            try std.testing.expectEqual(Rgba.fromRgb(40, 50, 60), cell.style.background);
        }
    }
    try std.testing.expect(found_wide);
    try std.testing.expect(found_styled);
}

test "URL hover underlines only detected cells across a soft wrap" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try testSession(&session, &context, 12, 3);
    defer session.deinit();
    const url = "https://example.test/a";
    session.feed("See " ++ url ++ " end");
    const hit = url_hover.detectAt(session.term, 3, 1) orelse return error.MissingUrl;
    try std.testing.expectEqualStrings(url, hit.url());
    var hovered = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 108,
        .pixel_height = 54,
        .hovered_url = &hit,
    });
    defer hovered.deinit();
    var plain = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 108,
        .pixel_height = 54,
    });
    defer plain.deinit();
    for (hovered.cells, plain.cells, 0..) |cell, original, index| {
        const inside_url = index >= "See ".len and index < "See ".len + url.len;
        try std.testing.expectEqual(@as(u8, if (inside_url) 1 else 0), cell.style.underline);
        try std.testing.expectEqual(@as(u8, 0), original.style.underline);
    }
    try std.testing.expect(url_hover.detectAt(session.term, 0, 0) == null);
}

test "unset terminal colors use Config defaults in the rendered grid" {
    const defaults: Config = .{};
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try testSession(&session, &context, 4, 2);
    defer session.deinit();
    session.term.colors.foreground = .unset;
    session.term.colors.background = .unset;
    var frame = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 36,
        .pixel_height = 36,
    });
    defer frame.deinit();
    var background = fromRgb(Config.u24ToRgb(defaults.theme.background));
    background.a = alphaFromOpacity(defaults.background_opacity);
    try std.testing.expectEqual(background, frame.background);
    try std.testing.expectEqual(background, frame.cells[0].style.background);
    try std.testing.expectEqual(fromRgb(Config.u24ToRgb(defaults.theme.foreground)), frame.cells[0].style.foreground);
}

test "grid model recomputes visible grid after a pixel resize" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();

    var frame = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 27,
        .pixel_height = 36,
    });
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 3), frame.cols);
    try std.testing.expectEqual(@as(u32, 2), frame.rows);
    try std.testing.expectEqual(@as(usize, 6), frame.cells.len);
}

fn testSession(session: *TerminalSession, context: *u8, cols: u16, rows: u16) !void {
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = cols,
        .rows = rows,
        .hooks = .{ .context = context },
    });
}

fn findCell(frame: Frame, col: u16, row: u16) Cell {
    for (frame.cells) |cell| {
        if (cell.col == col and cell.row == row) return cell;
    }
    unreachable;
}

test "selection recolors the selected span and degrades to inverse video" {
    // MOSTTY-58: selection highlight must follow selection-background /
    // selection-foreground. The business rule when either key is unset is
    // inverse video (Windows parity), not an arbitrary tint — so an unconfigured
    // selection must land on exactly the cell's own colors, swapped.
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try testSession(&session, &context, 4, 2);
    defer session.deinit();
    session.feed("\x1b[38;2;10;20;30;48;2;40;50;60mAB");

    const geometry = Options{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 36,
        .pixel_height = 36,
    };
    const range = Selection{ .start_col = 0, .start_row = 0, .end_col = 1, .end_row = 0 };

    var inverse = try build(std.testing.allocator, session.term, .{
        .metrics = geometry.metrics,
        .pixel_width = geometry.pixel_width,
        .pixel_height = geometry.pixel_height,
        .selection = range,
    });
    defer inverse.deinit();
    const inverted = findCell(inverse, 0, 0);
    try std.testing.expectEqual(Rgba.fromRgb(10, 20, 30), inverted.style.background);
    try std.testing.expectEqual(Rgba.fromRgb(40, 50, 60), inverted.style.foreground);
    // Outside the range the cell is untouched: unwritten trailing cells keep the
    // terminal default background rather than the active SGR one.
    const untouched = findCell(inverse, 2, 0);
    var background = DEFAULT_BACKGROUND;
    background.a = geometry.background_alpha;
    try std.testing.expectEqual(background, untouched.style.background);

    var themed = try build(std.testing.allocator, session.term, .{
        .metrics = geometry.metrics,
        .pixel_width = geometry.pixel_width,
        .pixel_height = geometry.pixel_height,
        .selection = range,
        .selection_foreground = Rgba.fromRgb(1, 2, 3),
        .selection_background = Rgba.fromRgb(4, 5, 6),
    });
    defer themed.deinit();
    const painted = findCell(themed, 1, 0);
    try std.testing.expectEqual(Rgba.fromRgb(4, 5, 6), painted.style.background);
    try std.testing.expectEqual(Rgba.fromRgb(1, 2, 3), painted.style.foreground);
}

test "selection endpoints normalize regardless of drag direction" {
    // Endpoints arrive in click order, so a bottom-up drag must select the same
    // cells as the equivalent top-down one.
    const forward = Selection{ .start_col = 1, .start_row = 0, .end_col = 2, .end_row = 1 };
    const backward = Selection{ .start_col = 2, .start_row = 1, .end_col = 1, .end_row = 0 };
    try std.testing.expectEqual(forward, backward.normalized());
    try std.testing.expectEqual(forward, forward.normalized());

    const range = forward.normalized();
    try std.testing.expect(!range.overlaps(0, 0, 1));
    try std.testing.expect(range.overlaps(1, 0, 1));
    try std.testing.expect(range.overlaps(3, 0, 1));
    try std.testing.expect(range.overlaps(2, 1, 1));
    try std.testing.expect(!range.overlaps(3, 1, 1));
}

test "a double-width glyph is selected from either of its two columns" {
    // A wide glyph is stored under its leading column but occupies two. Dragging
    // from its trailing half must still highlight it, which is what the removed
    // column-range overlay used to do for free.
    const range = (Selection{ .start_col = 2, .start_row = 0, .end_col = 4, .end_row = 0 }).normalized();
    // Leading column 1, trailing column 2: the trailing half is in range.
    try std.testing.expect(range.overlaps(1, 0, 2));
    // The same cell as single-width would fall outside.
    try std.testing.expect(!range.overlaps(1, 0, 1));
    // A wide glyph starting past the end stays unselected.
    try std.testing.expect(!range.overlaps(5, 0, 2));
}

test "background alpha applies only to default-background cells" {
    // background-opacity must let the desktop through the terminal's own
    // background while cells the app explicitly colored stay opaque, otherwise
    // highlighted regions would wash out.
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try testSession(&session, &context, 4, 1);
    defer session.deinit();
    session.feed("A\x1b[48;2;40;50;60mB");

    var frame = try build(std.testing.allocator, session.term, .{
        .metrics = .{ .cell_width = 9, .cell_height = 18 },
        .pixel_width = 36,
        .pixel_height = 18,
        .background_alpha = 128,
    });
    defer frame.deinit();

    try std.testing.expectEqual(@as(u8, 128), frame.background.a);
    try std.testing.expectEqual(@as(u8, 128), findCell(frame, 0, 0).style.background.a);
    try std.testing.expectEqual(@as(u8, 255), findCell(frame, 1, 0).style.background.a);
    // Trailing blanks keep the terminal default background, so they stay translucent.
    try std.testing.expectEqual(@as(u8, 128), findCell(frame, 3, 0).style.background.a);
    // Glyphs must never inherit the window transparency.
    try std.testing.expectEqual(@as(u8, 255), findCell(frame, 0, 0).style.foreground.a);
}
