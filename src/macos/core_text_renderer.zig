const CoreTextRenderer = @This();

const builtin = @import("builtin");
const std = @import("std");
const macos = @import("apple.zig");

const GridModel = @import("grid_model.zig");
const MetalBackend = @import("metal_backend.zig");
const KittyImages = @import("kitty_images.zig");
const TerminalSession = @import("../terminal/session.zig");
const Config = @import("../config.zig");
const url_hover = @import("../terminal/url_hover.zig");
const sprite = @import("../renderer/sprite.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("CoreTextRenderer is macOS-only");
}

const graphics = macos.graphics;
const text = macos.text;
const foundation = macos.foundation;

pub const default_family = (Config{}).font_families[0];
pub const default_font_size = (Config{}).font_size_pt.?;

/// Font selection resolved from the config. An empty per-style family means
/// "synthesize this style from the regular face's symbolic traits".
pub const FontOptions = struct {
    family: []const u8 = default_family,
    family_bold: []const u8 = (Config{}).font_family_bold,
    family_italic: []const u8 = (Config{}).font_family_italic,
    family_bold_italic: []const u8 = (Config{}).font_family_bold_italic,
    size: f32 = default_font_size,
};

/// Window-level paint settings the host changes at runtime (config reload, and
/// mouse-driven selection). A null color means "invert the cell", which is what
/// the corresponding config key degrades to when unset.
pub const Paint = struct {
    background_alpha: u8 = GridModel.alphaFromOpacity((Config{}).background_opacity),
    selection_foreground: ?GridModel.Rgba = GridModel.optionalRgba((Config{}).theme.selection_foreground),
    selection_background: ?GridModel.Rgba = GridModel.optionalRgba((Config{}).theme.selection_background),
    // `cursor-color` is not here: it is seeded into the terminal's dynamic
    // colors so a running app can override it with OSC 12, and is read from
    // there at draw time. `cursor-text` has no such VT counterpart.
    cursor_text: ?GridModel.Rgba = GridModel.optionalRgba((Config{}).theme.cursor_text),
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    font: FontOptions = .{},
    paint: Paint = .{},
    scale: f32 = 1,
    pixel_width: u32,
    pixel_height: u32,
};

pub const RenderResult = struct {
    cols: u32,
    rows: u32,
    texture: *anyopaque,
};

/// Grid position (viewport-relative) of the block cursor to draw as inverse
/// video. Rendering the cursor here keeps it pixel-aligned with the glyphs.
pub const Cursor = struct {
    col: u16,
    row: u16,
};

/// The four style families, owned by the renderer. Config strings live in an
/// arena that a hot-reload replaces, so the renderer cannot borrow them.
const FamilySet = struct {
    // [regular, bold, italic, bold_italic]. Entries after the first may be empty.
    names: [4][]const u8 = @splat(&.{}),

    fn init(allocator: std.mem.Allocator, options: FontOptions) !FamilySet {
        var result: FamilySet = .{};
        errdefer result.deinit(allocator);
        const sources = [4][]const u8{
            if (options.family.len > 0) options.family else default_family,
            options.family_bold,
            options.family_italic,
            options.family_bold_italic,
        };
        for (&result.names, sources) |*name, source| name.* = try allocator.dupe(u8, source);
        return result;
    }

    fn deinit(self: *FamilySet, allocator: std.mem.Allocator) void {
        for (&self.names) |*name| {
            allocator.free(name.*);
            name.* = &.{};
        }
    }
};

const FontSet = struct {
    regular: *text.Font,
    bold: *text.Font,
    italic: *text.Font,
    bold_italic: *text.Font,

    fn init(families: FamilySet, size: f32) !FontSet {
        const regular = try createFont(families.names[0], size);
        errdefer regular.release();
        const bold = try styledFont(regular, families.names[1], size, true, false);
        errdefer bold.release();
        const italic = try styledFont(regular, families.names[2], size, false, true);
        errdefer italic.release();
        const bold_italic = try styledFont(regular, families.names[3], size, true, true);
        errdefer bold_italic.release();
        return .{
            .regular = regular,
            .bold = bold,
            .italic = italic,
            .bold_italic = bold_italic,
        };
    }

    fn deinit(self: *FontSet) void {
        self.bold_italic.release();
        self.italic.release();
        self.bold.release();
        self.regular.release();
        self.* = undefined;
    }

    fn select(self: *const FontSet, style: GridModel.Style) *text.Font {
        if (style.bold and style.italic) return self.bold_italic;
        if (style.bold) return self.bold;
        if (style.italic) return self.italic;
        return self.regular;
    }
};

allocator: std.mem.Allocator,
families: FamilySet,
font_size: f32,
scale: f32,
fonts: FontSet,
metrics: GridModel.Metrics,
pixel_width: u32,
pixel_height: u32,
pixels: []u8,
metal: MetalBackend,
paint: Paint,
/// Host-driven mouse selection in viewport coordinates; null when nothing is
/// selected.
selection: ?GridModel.Selection = null,
hovered_url: ?url_hover.Hit = null,
sprite_masks: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
kitty_images: KittyImages = .{},

pub fn init(options: Options) !CoreTextRenderer {
    if (options.font.size <= 0 or options.scale <= 0) return error.InvalidFontSize;
    if (options.pixel_width == 0 or options.pixel_height == 0) return error.InvalidDrawableSize;

    var families = try FamilySet.init(options.allocator, options.font);
    errdefer families.deinit(options.allocator);
    var fonts = try FontSet.init(families, options.font.size * options.scale);
    errdefer fonts.deinit();
    const metrics = try metricsForFont(fonts.regular);
    var metal = try MetalBackend.init();
    errdefer metal.deinit();
    try metal.resize(options.pixel_width, options.pixel_height);

    const pixel_count = try pixelBufferLength(options.pixel_width, options.pixel_height);
    const pixels = try options.allocator.alloc(u8, pixel_count);
    errdefer options.allocator.free(pixels);

    return .{
        .allocator = options.allocator,
        .families = families,
        .font_size = options.font.size,
        .scale = options.scale,
        .fonts = fonts,
        .metrics = metrics,
        .pixel_width = options.pixel_width,
        .pixel_height = options.pixel_height,
        .pixels = pixels,
        .metal = metal,
        .paint = options.paint,
    };
}

pub fn deinit(self: *CoreTextRenderer) void {
    self.kitty_images.deinit(self.allocator);
    self.clearSpriteMasks();
    self.sprite_masks.deinit(self.allocator);
    self.metal.deinit();
    self.allocator.free(self.pixels);
    self.fonts.deinit();
    self.families.deinit(self.allocator);
    self.* = undefined;
}

/// Adopt font settings from a reloaded config. Returns true when the cell
/// metrics changed, so the caller knows the grid must be re-derived. Rebuilds
/// everything before publishing so a failure leaves the current fonts intact.
pub fn reconfigure(self: *CoreTextRenderer, options: FontOptions) !bool {
    const size = if (options.size > 0) options.size else default_font_size;
    var families = try FamilySet.init(self.allocator, options);
    errdefer families.deinit(self.allocator);
    var fonts = try FontSet.init(families, size * self.scale);
    errdefer fonts.deinit();
    const metrics = try metricsForFont(fonts.regular);

    self.fonts.deinit();
    self.families.deinit(self.allocator);
    self.fonts = fonts;
    self.families = families;
    self.font_size = size;
    const changed = !std.meta.eql(self.metrics, metrics);
    if (changed) self.clearSpriteMasks();
    self.metrics = metrics;
    return changed;
}

pub fn resize(self: *CoreTextRenderer, pixel_width: u32, pixel_height: u32, scale: f32) !void {
    if (pixel_width == 0 or pixel_height == 0) return error.InvalidDrawableSize;
    if (scale <= 0) return error.InvalidFontSize;
    if (self.pixel_width == pixel_width and self.pixel_height == pixel_height and self.scale == scale) return;

    var replacement_fonts: ?FontSet = null;
    var replacement_metrics = self.metrics;
    if (self.scale != scale) {
        replacement_fonts = try FontSet.init(self.families, self.font_size * scale);
        errdefer if (replacement_fonts) |*fonts| fonts.deinit();
        replacement_metrics = try metricsForFont(replacement_fonts.?.regular);
    }

    const replacement = try self.allocator.alloc(u8, try pixelBufferLength(pixel_width, pixel_height));
    errdefer self.allocator.free(replacement);
    try self.metal.resize(pixel_width, pixel_height);

    self.allocator.free(self.pixels);
    self.pixels = replacement;
    if (replacement_fonts) |fonts| {
        self.fonts.deinit();
        self.fonts = fonts;
    }
    if (!std.meta.eql(self.metrics, replacement_metrics)) self.clearSpriteMasks();
    self.metrics = replacement_metrics;
    self.scale = scale;
    self.pixel_width = pixel_width;
    self.pixel_height = pixel_height;
}

/// Drawable height minus the reserved bottom gutter. Rows are laid out from the
/// top of the drawable, so holding back one cell row keeps the last text row
/// clear of the window's rounded bottom corners, which otherwise clip the
/// leading glyph of that row.
pub fn contentHeight(self: *const CoreTextRenderer) u32 {
    return self.pixel_height -| self.metrics.cell_height;
}

pub fn gridSize(self: *const CoreTextRenderer) GridModel.Size {
    return self.metrics.gridSize(self.pixel_width, self.contentHeight());
}

pub fn render(self: *CoreTextRenderer, session: *TerminalSession, cursor: ?Cursor) !RenderResult {
    session.syncPixelSize(self.metrics.cell_width, self.metrics.cell_height);
    try self.kitty_images.sync(self.allocator, session.term);
    var frame = try GridModel.build(self.allocator, session.term, .{
        .metrics = self.metrics,
        .pixel_width = self.pixel_width,
        .pixel_height = self.contentHeight(),
        .background_alpha = self.paint.background_alpha,
        .selection = self.selection,
        .hovered_url = if (self.hovered_url) |*hit| hit else null,
        .selection_foreground = self.paint.selection_foreground,
        .selection_background = self.paint.selection_background,
    });
    defer frame.deinit();

    // The cursor block follows the terminal's dynamic cursor color, which the
    // config seeds and a running app can retarget with OSC 12. Null means the
    // theme set none, so the block inverts the cell instead.
    const cursor_color: ?GridModel.Rgba = if (session.term.colors.cursor.get()) |color|
        GridModel.Rgba.fromRgb(color.r, color.g, color.b)
    else
        null;
    try self.rasterize(&frame, cursor, cursor_color);
    try self.metal.render(self.pixels);
    return .{
        .cols = frame.cols,
        .rows = frame.rows,
        .texture = self.metal.texture() orelse return error.DrawableNotConfigured,
    };
}

fn rasterize(
    self: *CoreTextRenderer,
    frame: *const GridModel.Frame,
    cursor: ?Cursor,
    cursor_color: ?GridModel.Rgba,
) !void {
    const color_space = try graphics.ColorSpace.createDeviceRGB();
    defer color_space.release();
    const bitmap_info = @intFromEnum(graphics.BitmapInfo.byte_order_32_little) |
        @intFromEnum(graphics.ImageAlphaInfo.premultiplied_first);
    const context = try graphics.BitmapContext.create(
        self.pixels,
        self.pixel_width,
        self.pixel_height,
        8,
        @as(usize, self.pixel_width) * 4,
        color_space,
        bitmap_info,
    );
    defer graphics.BitmapContext.context.release(context);

    const ctx = graphics.BitmapContext.context;
    ctx.setAllowsAntialiasing(context, true);
    ctx.setShouldAntialias(context, true);
    ctx.setShouldSmoothFonts(context, true);
    ctx.setTextDrawingMode(context, .fill);
    ctx.setTextMatrix(context, graphics.AffineTransform.identity());
    // The pixel buffer is reused across frames, so a translucent background
    // would blend with the previous frame instead of replacing it.
    const drawable = graphics.Rect.init(0, 0, self.pixel_width, self.pixel_height);
    ctx.clearRect(context, drawable);
    setFill(context, frame.background);
    ctx.fillRect(context, drawable);

    const viewport = graphics.Rect.init(0, self.pixel_height - frame.rows * self.metrics.cell_height, frame.cols * self.metrics.cell_width, frame.rows * self.metrics.cell_height);
    self.kitty_images.draw(context, .below_background, viewport, self.pixel_height);
    for (frame.cells) |*draw_cell| {
        // The cursor block is drawn into the cell itself, which keeps it aligned
        // with the glyph grid. `cursor-color` / `cursor-text` win when set;
        // otherwise it falls back to inverse video. Either way it is an explicit
        // highlight, so it stays opaque regardless of window opacity.
        if (cursor) |cur| {
            if (draw_cell.col == cur.col and draw_cell.row == cur.row) {
                const background = draw_cell.style.background;
                draw_cell.style.background = cursor_color orelse draw_cell.style.foreground;
                draw_cell.style.foreground = self.paint.cursor_text orelse background;
                draw_cell.style.foreground.a = 255;
                draw_cell.style.background.a = 255;
                draw_cell.style.default_background = false;
            }
        }

        if (draw_cell.style.default_background) continue;
        const x = @as(f64, @floatFromInt(@as(u32, draw_cell.col) * self.metrics.cell_width));
        const y = @as(f64, @floatFromInt(self.pixel_height - (@as(u32, draw_cell.row) + 1) * self.metrics.cell_height));
        const width = @as(f64, @floatFromInt(@as(u32, draw_cell.width) * self.metrics.cell_width));
        const height = @as(f64, @floatFromInt(self.metrics.cell_height));
        const rect = graphics.Rect.init(x, y, width, height);
        // A translucent fill blends with what the drawable-wide background just
        // painted, which would compound the alpha; clear the cell first so its
        // own alpha is what reaches the compositor.
        if (draw_cell.style.background.a != 255) ctx.clearRect(context, rect);
        setFill(context, draw_cell.style.background);
        ctx.fillRect(context, rect);
    }
    self.kitty_images.draw(context, .below_text, viewport, self.pixel_height);
    for (frame.cells) |draw_cell| {
        if (draw_cell.style.invisible or draw_cell.codepoint == @import("vt").kitty.graphics.unicode.placeholder) continue;
        const x = @as(f64, @floatFromInt(@as(u32, draw_cell.col) * self.metrics.cell_width));
        const y = @as(f64, @floatFromInt(self.pixel_height - (@as(u32, draw_cell.row) + 1) * self.metrics.cell_height));
        const width = @as(f64, @floatFromInt(@as(u32, draw_cell.width) * self.metrics.cell_width));
        const height = @as(f64, @floatFromInt(self.metrics.cell_height));

        const font = self.fonts.select(draw_cell.style);
        if (draw_cell.grapheme.len == 0 and sprite.hasCodepoint(draw_cell.codepoint)) {
            try self.drawSprite(context, draw_cell, x, y);
            const baseline = y + font.getDescent() + @max(0, (height - font.getAscent() - font.getDescent()) / 2);
            drawDecorations(context, font, draw_cell.style, x, baseline, width);
            continue;
        }
        try drawCellText(context, font, draw_cell, x, y, width, self.metrics.cell_height);
    }
    self.kitty_images.draw(context, .above_text, viewport, self.pixel_height);
}

fn clearSpriteMasks(self: *CoreTextRenderer) void {
    var masks = self.sprite_masks.valueIterator();
    while (masks.next()) |mask| self.allocator.free(mask.*);
    self.sprite_masks.clearRetainingCapacity();
}

fn drawSprite(self: *CoreTextRenderer, context: *graphics.BitmapContext, cell: GridModel.Cell, x: f64, y: f64) !void {
    const width = @as(u32, cell.width) * self.metrics.cell_width;
    const height = self.metrics.cell_height;
    const key = @as(u32, cell.codepoint) | (@as(u32, cell.width) << 21);
    const mask = self.sprite_masks.get(key) orelse blk: {
        const mask = try self.allocator.alloc(u8, @as(usize, width) * height);
        errdefer self.allocator.free(mask);
        const rendered = try sprite.renderAlpha(self.allocator, cell.codepoint, width, height, sprite.buildMetrics(width, height), mask);
        std.debug.assert(rendered);
        try self.sprite_masks.put(self.allocator, key, mask);
        break :blk mask;
    };
    // Equal-coverage runs preserve the rasterizer's exact pixel edges and
    // antialiasing without resampling or creating a CoreGraphics image per cell.
    for (0..height) |row| {
        var col: usize = 0;
        while (col < width) {
            const coverage = mask[row * width + col];
            const start = col;
            col += 1;
            while (col < width and mask[row * width + col] == coverage) : (col += 1) {}
            if (coverage == 0) continue;
            var color = cell.style.foreground;
            color.a = @intCast((@as(u16, color.a) * coverage + 127) / 255);
            setFill(context, color);
            graphics.BitmapContext.context.fillRect(context, graphics.Rect.init(
                x + @as(f64, @floatFromInt(start)),
                y + @as(f64, @floatFromInt(height - row - 1)),
                @floatFromInt(col - start),
                1,
            ));
        }
    }
}

fn drawCellText(
    context: *graphics.BitmapContext,
    base_font: *text.Font,
    cell: GridModel.Cell,
    x: f64,
    y: f64,
    cell_width: f64,
    cell_height: u32,
) !void {
    var characters: [32]u16 = undefined;
    var character_len: usize = 0;
    try appendCodepoint(&characters, &character_len, cell.codepoint);
    for (cell.grapheme) |codepoint| {
        if (character_len + 2 > characters.len) break;
        try appendCodepoint(&characters, &character_len, codepoint);
    }

    var fallback: ?*text.Font = null;
    var font = base_font;
    var glyphs: [32]graphics.Glyph = @splat(0);
    if (!font.getGlyphsForCharacters(characters[0..character_len], glyphs[0..character_len])) {
        const string = try foundation.String.createWithCharacters(characters[0..character_len]);
        defer string.release();
        fallback = font.createForString(string, foundation.Range.init(0, character_len));
        if (fallback) |resolved| {
            font = resolved;
            _ = font.getGlyphsForCharacters(characters[0..character_len], glyphs[0..character_len]);
        }
    }
    defer if (fallback) |resolved| resolved.release();

    var advances: [32]graphics.Size = undefined;
    const total_advance = font.getAdvancesForGlyphs(
        .horizontal,
        glyphs[0..character_len],
        advances[0..character_len],
    );
    const ascent = font.getAscent();
    const descent = font.getDescent();
    const content_height = ascent + descent;
    // `y` is the cell's bottom edge in the bottom-left-origin CoreGraphics
    // context, so the baseline sits `descent` above it (plus half the leading to
    // center). Using ascent here would push glyphs up out of their cell.
    const baseline = y + descent + @max(0, (@as(f64, @floatFromInt(cell_height)) - content_height) / 2);
    var pen_x = x + @max(0, (cell_width - total_advance) / 2);
    var positions: [32]graphics.Point = undefined;
    for (positions[0..character_len], advances[0..character_len]) |*position, advance| {
        position.* = .{ .x = pen_x, .y = baseline };
        pen_x += advance.width;
    }

    setFill(context, cell.style.foreground);
    font.drawGlyphs(glyphs[0..character_len], positions[0..character_len], context);
    drawDecorations(context, font, cell.style, x, baseline, cell_width);
}

fn drawDecorations(
    context: *graphics.BitmapContext,
    font: *text.Font,
    style: GridModel.Style,
    x: f64,
    baseline: f64,
    width: f64,
) void {
    const ctx = graphics.BitmapContext.context;
    const thickness = @max(1, font.getUnderlineThickness());
    setFill(context, style.foreground);
    if (style.underline != 0) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getUnderlinePosition(), width, thickness));
    }
    if (style.strikethrough) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getXHeight() / 2, width, thickness));
    }
    if (style.overline) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getAscent() - thickness, width, thickness));
    }
}

fn setFill(context: *graphics.BitmapContext, color: GridModel.Rgba) void {
    graphics.BitmapContext.context.setRGBFillColor(
        context,
        @as(f64, @floatFromInt(color.r)) / 255,
        @as(f64, @floatFromInt(color.g)) / 255,
        @as(f64, @floatFromInt(color.b)) / 255,
        @as(f64, @floatFromInt(color.a)) / 255,
    );
}

fn createFont(family: []const u8, size: f32) !*text.Font {
    const name = try foundation.String.createWithBytes(family, .utf8, false);
    defer name.release();
    const descriptor = try text.FontDescriptor.createWithNameAndSize(name, size);
    defer descriptor.release();
    return try text.Font.createWithFontDescriptor(descriptor, size);
}

// An explicit `font-family-<style>` chooses the family; otherwise the style
// inherits the regular one. Either way the style's traits are applied on top, so
// `font-family-bold = Menlo` still renders bold rather than the regular face.
fn styledFont(regular: *text.Font, family: []const u8, size: f32, bold: bool, italic: bool) !*text.Font {
    if (family.len == 0) return copyWithTraits(regular, bold, italic);
    const base = try createFont(family, size);
    defer base.release();
    return copyWithTraits(base, bold, italic);
}

fn copyWithTraits(base: *text.Font, bold: bool, italic: bool) *text.Font {
    const traits = text.FontSymbolicTraits{ .bold = bold, .italic = italic };
    if (base.copyWithSymbolicTraits(traits)) |font| return font;
    base.retain();
    return base;
}

fn metricsForFont(font: *text.Font) !GridModel.Metrics {
    var glyph: [1]graphics.Glyph = .{0};
    if (!font.getGlyphsForCharacters(&[_]u16{'M'}, &glyph)) return error.FontHasNoCellGlyph;
    var advance: [1]graphics.Size = undefined;
    _ = font.getAdvancesForGlyphs(.horizontal, &glyph, &advance);
    const width = @max(1, @as(u32, @intFromFloat(@ceil(advance[0].width))));
    const height_value = font.getAscent() + font.getDescent() + font.getLeading();
    const height = @max(1, @as(u32, @intFromFloat(@ceil(height_value))));
    return .{ .cell_width = width, .cell_height = height };
}

fn appendCodepoint(buffer: []u16, len: *usize, codepoint: u21) !void {
    if (codepoint <= 0xffff) {
        if (len.* == buffer.len) return error.GraphemeTooLong;
        buffer[len.*] = @intCast(codepoint);
        len.* += 1;
        return;
    }
    if (len.* + 2 > buffer.len) return error.GraphemeTooLong;
    const value = @as(u32, codepoint) - 0x10000;
    buffer[len.*] = @intCast(0xd800 + (value >> 10));
    buffer[len.* + 1] = @intCast(0xdc00 + (value & 0x3ff));
    len.* += 2;
}

fn pixelBufferLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidDrawableSize;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidDrawableSize;
}

test "CoreText resolves ordinary and wide glyphs" {
    var families = try FamilySet.init(std.testing.allocator, .{});
    defer families.deinit(std.testing.allocator);
    var fonts = try FontSet.init(families, 14);
    defer fonts.deinit();
    var ordinary_glyph: [1]graphics.Glyph = .{0};
    try std.testing.expect(fonts.regular.getGlyphsForCharacters(&[_]u16{'A'}, &ordinary_glyph));
    try std.testing.expect(ordinary_glyph[0] != 0);

    const wide_characters = [_]u16{'界'};
    const wide_string = try foundation.String.createWithCharacters(&wide_characters);
    defer wide_string.release();
    const wide_font = fonts.regular.createForString(wide_string, foundation.Range.init(0, 1)) orelse
        return error.FontHasNoWideGlyphFallback;
    defer wide_font.release();
    var wide_glyph: [1]graphics.Glyph = .{0};
    try std.testing.expect(wide_font.getGlyphsForCharacters(&wide_characters, &wide_glyph));
    try std.testing.expect(wide_glyph[0] != 0);
    const metrics = try metricsForFont(fonts.regular);
    try std.testing.expect(metrics.cell_width > 0);
    try std.testing.expect(metrics.cell_height > 0);
}

test "CoreText and Metal render a resized styled terminal frame" {
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
    session.feed("A界\x1b[1;3;4;31;44mB");

    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer renderer.deinit();
    try renderer.resize(360, 108, 1);

    // The grid must stop a full cell short of the drawable's bottom edge, so the
    // window's rounded corners never clip the last row's leading glyph.
    const grid = renderer.gridSize();
    try std.testing.expect(grid.rows > 0);
    try std.testing.expect(
        renderer.pixel_height - grid.rows * renderer.metrics.cell_height >= renderer.metrics.cell_height,
    );

    const result = try renderer.render(&session, .{ .col = 0, .row = 0 });
    try std.testing.expect(result.cols > 0);
    try std.testing.expect(result.rows > 0);
    try std.testing.expect(@intFromPtr(result.texture) != 0);
}

test "background-opacity survives into the rasterized pixels" {
    // The compositor can only show through what the rasterizer produces, so the
    // configured alpha has to reach the pixel buffer. The buffer is BGRA with
    // premultiplied alpha, so byte 3 of each pixel is the alpha channel.
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

    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .paint = .{ .background_alpha = 89 },
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer renderer.deinit();
    _ = try renderer.render(&session, null);

    var translucent_pixels: usize = 0;
    var index: usize = 3;
    while (index < renderer.pixels.len) : (index += 4) {
        if (renderer.pixels[index] == 89) translucent_pixels += 1;
    }
    try std.testing.expect(translucent_pixels > 0);

    // The same frame at full opacity must leave nothing translucent, otherwise
    // the assertion above would pass for the wrong reason.
    try std.testing.expect(try renderer.reconfigure(.{}) == false);
    renderer.paint.background_alpha = 255;
    _ = try renderer.render(&session, null);
    index = 3;
    while (index < renderer.pixels.len) : (index += 4) {
        try std.testing.expectEqual(@as(u8, 255), renderer.pixels[index]);
    }
}

test "box strokes meet every cell edge across fonts and backing scales" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 4,
        .rows = 3,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    session.feed("\x1b[38;2;255;255;255;48;2;0;0;0m\u{2500}\u{2500}\r\n\u{2502}\r\n\u{2502}");
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 400,
        .pixel_height = 300,
    });
    defer renderer.deinit();
    for ([_][]const u8{ "Menlo", "Courier New" }) |family| {
        for ([_]f32{ 11, 19 }) |size| {
            _ = try renderer.reconfigure(.{ .family = family, .size = size });
            for ([_]f32{ 1, 2 }) |scale| {
                try renderer.resize(400, 300, scale);
                _ = try renderer.render(&session, null);
                const cw = renderer.metrics.cell_width;
                const ch = renderer.metrics.cell_height;
                // Every column of the joined horizontal stroke must contain ink.
                for (0..2 * cw) |x| {
                    var ink: u8 = 0;
                    for (0..ch) |y| ink = @max(ink, renderer.pixels[(y * renderer.pixel_width + x) * 4]);
                    try std.testing.expect(ink > 127);
                }
                // Vertical strokes must reach both the top and bottom of each cell.
                for (ch..3 * ch) |y| {
                    var ink: u8 = 0;
                    for (0..cw) |x| ink = @max(ink, renderer.pixels[(y * renderer.pixel_width + x) * 4]);
                    try std.testing.expect(ink > 127);
                }
            }
        }
    }
}

test "sprites preserve orientation, colors, selection and metric changes" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 12,
        .rows = 2,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    session.feed("\x1b]11;#0000ff\x07\x1b[38;2;255;0;0m\u{2580}\u{2588}\u{2500}\u{28ff}\u{e0b0}\u{25e2}\u{1fb00}");
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 640,
        .pixel_height = 200,
        .paint = .{ .background_alpha = 128 },
    });
    defer renderer.deinit();
    _ = try renderer.render(&session, null);
    const cw = renderer.metrics.cell_width;
    const ch = renderer.metrics.cell_height;
    const upper = (ch / 4 * renderer.pixel_width + cw / 2) * 4;
    const lower = (3 * ch / 4 * renderer.pixel_width + cw / 2) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, renderer.pixels[upper..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, renderer.pixels[lower..][0..4]);
    try std.testing.expectEqual(@as(u32, 7), renderer.sprite_masks.count());
    // Recoloring reuses geometry but must adopt the current selection colors.
    renderer.selection = .{ .start_col = 0, .end_col = 0, .start_row = 0, .end_row = 0 };
    renderer.paint.selection_foreground = .{ .r = 0, .g = 255, .b = 0 };
    renderer.paint.selection_background = .{ .r = 255, .g = 255, .b = 0 };
    _ = try renderer.render(&session, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, renderer.pixels[upper..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255, 255 }, renderer.pixels[lower..][0..4]);
    try std.testing.expectEqual(@as(u32, 7), renderer.sprite_masks.count());

    _ = try renderer.reconfigure(.{ .size = 24 });
    try std.testing.expectEqual(@as(u32, 0), renderer.sprite_masks.count());
    _ = try renderer.render(&session, null);
    const mask = renderer.sprite_masks.get(0x2580 | (1 << 21)).?;
    try std.testing.expectEqual(renderer.metrics.cell_width * renderer.metrics.cell_height, mask.len);
    try renderer.resize(640, 300, 2);
    try std.testing.expectEqual(@as(u32, 0), renderer.sprite_masks.count());
    _ = try renderer.render(&session, null);
    try std.testing.expect(renderer.sprite_masks.count() > 0);
}

test "font-size drives the cell metrics, and reconfigure adopts a new size" {
    // MOSTTY-58: `font-size` must reach the renderer rather than a hard-coded
    // literal. The observable consequence of a larger point size is a larger
    // cell, which is what the grid geometry is derived from.
    var small = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .font = .{ .size = 10 },
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer small.deinit();
    var large = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .font = .{ .size = 24 },
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer large.deinit();
    try std.testing.expect(large.metrics.cell_width > small.metrics.cell_width);
    try std.testing.expect(large.metrics.cell_height > small.metrics.cell_height);

    // A hot-reload to the larger size must land on exactly the same metrics as
    // starting there, and must report the change so the grid gets re-derived.
    try std.testing.expect(try small.reconfigure(.{ .size = 24 }));
    try std.testing.expectEqual(large.metrics, small.metrics);
    try std.testing.expectEqual(@as(f32, 24), small.font_size);
    // Re-applying an unchanged config must not claim the grid moved.
    try std.testing.expect(!try small.reconfigure(.{ .size = 24 }));
}

test "an unset per-style family synthesizes from the regular face" {
    // `font-family-bold` is optional: leaving it empty must still yield a usable
    // bold face (synthesized), while setting it must be honored.
    var derived = try FamilySet.init(std.testing.allocator, .{ .family = "Menlo" });
    defer derived.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Menlo", derived.names[0]);
    try std.testing.expectEqual(@as(usize, 0), derived.names[1].len);
    var derived_fonts = try FontSet.init(derived, 14);
    defer derived_fonts.deinit();
    try std.testing.expect(derived_fonts.select(.{
        .foreground = GridModel.DEFAULT_FOREGROUND,
        .background = GridModel.DEFAULT_BACKGROUND,
        .bold = true,
    }) != derived_fonts.regular);

    var explicit = try FamilySet.init(std.testing.allocator, .{
        .family = "Menlo",
        .family_bold = "Courier New",
    });
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Courier New", explicit.names[1]);
    var explicit_fonts = try FontSet.init(explicit, 14);
    defer explicit_fonts.deinit();
    try std.testing.expect(explicit_fonts.bold != explicit_fonts.regular);
}

test "an explicit per-style family still carries that style's traits" {
    // `font-family-bold = Menlo` names a family, not a face. Creating it
    // verbatim would render bold text in the regular weight, so the bold trait
    // must still be applied on top of the chosen family.
    var families = try FamilySet.init(std.testing.allocator, .{
        .family = "Menlo",
        .family_bold = "Menlo",
    });
    defer families.deinit(std.testing.allocator);
    var fonts = try FontSet.init(families, 14);
    defer fonts.deinit();
    try std.testing.expect(fonts.bold != fonts.regular);
    try std.testing.expect(fonts.bold_italic != fonts.regular);
}

test "an empty family falls back to the platform default" {
    // A config that omits `font-family` must not produce an empty family name;
    // it resolves to the documented macOS default instead.
    var families = try FamilySet.init(std.testing.allocator, .{ .family = &.{} });
    defer families.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(default_family, families.names[0]);
}
