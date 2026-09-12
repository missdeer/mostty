const CoreTextRenderer = @This();

const builtin = @import("builtin");
const std = @import("std");
const macos = @import("apple.zig");

const GridModel = @import("grid_model.zig");
const MetalBackend = @import("metal_backend.zig");
const KittyImages = @import("kitty_images.zig");
const BackgroundImage = @import("background_image.zig");
const ShapingCache = @import("shaping_cache.zig");
const TerminalSession = @import("../terminal/session.zig");
const Config = @import("../config.zig");
const url_hover = @import("../terminal/url_hover.zig");
const sprite = @import("../renderer/sprite.zig");
const cell_style = @import("../renderer/cell_style.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("CoreTextRenderer is macOS-only");
}

const graphics = macos.graphics;
const text = macos.text;
const foundation = macos.foundation;
const emoji_presentation = @import("../renderer/emoji.zig");
const font_policy = @import("../renderer/font_policy.zig");

pub const default_family = (Config{}).font_families[0];
pub const default_font_size = (Config{}).font_size_pt.?;

/// Font selection resolved from the config. An empty per-style family means
/// "synthesize this style from the regular face's symbolic traits".
pub const FontOptions = struct {
    family: []const u8 = default_family,
    fallback_families: []const []const u8 = &.{},
    family_bold: []const u8 = (Config{}).font_family_bold,
    family_italic: []const u8 = (Config{}).font_family_italic,
    family_bold_italic: []const u8 = (Config{}).font_family_bold_italic,
    emoji_families: []const []const u8 = &.{},
    styles: [4]Config.FontStyle = @splat(.default),
    synthetic: Config.SyntheticStyle = .{},
    features: []const Config.FontFeature = &.{},
    codepoint_maps: []const Config.CodepointMap = &.{},
    ligatures: bool = true,
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
    background_image: BackgroundImage.Options = .{},
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

/// The four style families and ordered fallbacks, owned by the renderer. Config strings live in an
/// arena that a hot-reload replaces, so the renderer cannot borrow them.
const FamilySet = struct {
    arena: std.heap.ArenaAllocator,
    names: [4][]const u8,
    fallbacks: []const []const u8,
    options: FontOptions,

    fn init(allocator: std.mem.Allocator, options: FontOptions) !FamilySet {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var owned = options;
        const names = [4][]const u8{
            try a.dupe(u8, if (options.family.len > 0) options.family else default_family),
            try a.dupe(u8, options.family_bold),
            try a.dupe(u8, options.family_italic),
            try a.dupe(u8, options.family_bold_italic),
        };
        owned.family = names[0];
        owned.family_bold = names[1];
        owned.family_italic = names[2];
        owned.family_bold_italic = names[3];
        const fallbacks = try a.alloc([]const u8, options.fallback_families.len);
        for (fallbacks, options.fallback_families) |*dst, src| dst.* = try a.dupe(u8, src);
        owned.fallback_families = fallbacks;
        const emojis = try a.alloc([]const u8, options.emoji_families.len);
        for (emojis, options.emoji_families) |*dst, src| dst.* = try a.dupe(u8, src);
        owned.emoji_families = emojis;
        for (&owned.styles) |*style| {
            if (style.* == .named) style.* = .{ .named = try a.dupe(u8, style.named) };
        }
        owned.features = try a.dupe(Config.FontFeature, options.features);
        const maps = try a.dupe(Config.CodepointMap, options.codepoint_maps);
        for (maps) |*map| map.family = try a.dupe(u8, map.family);
        owned.codepoint_maps = maps;
        return .{ .arena = arena, .names = names, .fallbacks = fallbacks, .options = owned };
    }

    fn deinit(self: *FamilySet) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const FontSet = struct {
    regular: *text.Font,
    bold: *text.Font,
    italic: *text.Font,
    bold_italic: *text.Font,
    emoji_font: *text.Font,
    synthetic: [4]text.FontSymbolicTraits,
    mapped: [][4]*text.Font,
    allocator: std.mem.Allocator,

    fn init(families: FamilySet, size: f32) !FontSet {
        // Font resources must outlive the temporary construction arena.
        const allocator = families.arena.child_allocator;
        const options = families.options;
        const primary = try firstAvailableFamily(families.names[0], families.fallbacks, default_family);
        var bases: [4]*text.Font = undefined;
        var initialized: usize = 0;
        defer for (bases[0..initialized]) |font| font.release();
        var synthetic: [4]text.FontSymbolicTraits = @splat(.{});
        const allowed = [4]bool{ false, options.synthetic.bold, options.synthetic.italic, options.synthetic.bold_italic };
        for (0..4) |i| {
            const family = if (i == 0 or families.names[i].len == 0)
                primary
            else
                try firstAvailableFamily(families.names[i], &.{}, primary);
            const traits: text.FontSymbolicTraits = .{ .bold = i == 1 or i == 3, .italic = i >= 2 };
            const spec = options.styles[i];
            const named = if (spec == .named) try text.Font.findFace(family, spec.named, traits, size) else null;
            if (spec == .named and named == null) std.log.warn("font-style: face '{s}' not found in '{s}'; keeping natural attributes", .{ spec.named, family });
            const real = named orelse if (spec == .default or i == 0)
                try text.Font.findFace(family, null, traits, size)
            else
                null;
            if (i != 0 and font_policy.useRegular(spec == .disabled, real != null, allowed[i])) {
                if (real) |font| font.release();
                bases[0].retain();
                bases[i] = bases[0];
            } else if (real) |font| {
                bases[i] = font;
            } else {
                const base = try createFont(family, size);
                defer base.release();
                bases[i] = copyWithTraits(base, traits.bold, traits.italic);
                const actual = bases[i].symbolicTraits();
                synthetic[i] = .{
                    .bold = allowed[i] and traits.bold and !actual.bold,
                    .italic = allowed[i] and traits.italic and !actual.italic,
                };
            }
            initialized += 1;
        }
        var cascades: [4]*text.Font = undefined;
        var cascade_count: usize = 0;
        errdefer for (cascades[0..cascade_count]) |font| font.release();
        for (bases, 0..) |font, i| {
            const cascade = try font.copyWithCascade(bases[0], families.fallbacks);
            defer cascade.release();
            cascades[i] = try cascade.copyWithFeatures(options.features);
            cascade_count += 1;
        }
        const emoji_names: []const []const u8 = if (options.emoji_families.len == 0) &.{"Apple Color Emoji"} else options.emoji_families;
        const emoji_primary = try firstAvailableFamily(emoji_names[0], emoji_names[1..], "Apple Color Emoji");
        const emoji_base = try createFont(emoji_primary, size);
        defer emoji_base.release();
        const emoji_cascade = try emoji_base.copyWithCascade(emoji_base, emoji_names[1..]);
        defer emoji_cascade.release();
        const emoji_font = try emoji_cascade.copyWithFeatures(options.features);
        errdefer emoji_font.release();

        const mapped = try allocator.alloc([4]*text.Font, options.codepoint_maps.len);
        errdefer allocator.free(mapped);
        var map_count: usize = 0;
        errdefer for (mapped[0..map_count]) |fonts| {
            for (fonts) |font| font.release();
        };
        for (options.codepoint_maps, mapped) |map, *fonts| {
            const fallback_names = try allocator.alloc([]const u8, families.fallbacks.len + 2);
            defer allocator.free(fallback_names);
            fallback_names[0] = map.family;
            fallback_names[1] = primary;
            @memcpy(fallback_names[2..], families.fallbacks);
            var count: usize = 0;
            errdefer for (fonts[0..count]) |font| font.release();
            for (bases, 0..) |base, i| {
                // Keep the primary face first; mappings are fallback-only.
                const cascade = try base.copyWithCascade(base, fallback_names);
                defer cascade.release();
                fonts[i] = try cascade.copyWithFeatures(options.features);
                count += 1;
            }
            map_count += 1;
        }
        return .{
            .regular = cascades[0],
            .bold = cascades[1],
            .italic = cascades[2],
            .bold_italic = cascades[3],
            .emoji_font = emoji_font,
            .synthetic = synthetic,
            .mapped = mapped,
            .allocator = allocator,
        };
    }

    fn deinit(self: *FontSet) void {
        for (self.mapped) |fonts| {
            for (fonts) |font| font.release();
        }
        self.allocator.free(self.mapped);
        self.emoji_font.release();
        self.bold_italic.release();
        self.italic.release();
        self.bold.release();
        self.regular.release();
        self.* = undefined;
    }

    fn styleIndex(style: GridModel.Style) usize {
        return @as(usize, @intFromBool(style.bold)) + 2 * @as(usize, @intFromBool(style.italic));
    }

    fn select(self: *const FontSet, style: GridModel.Style) *text.Font {
        return switch (styleIndex(style)) {
            1 => self.bold,
            2 => self.italic,
            3 => self.bold_italic,
            else => self.regular,
        };
    }

    fn selectCell(self: *const FontSet, options: FontOptions, cell: GridModel.Cell) *text.Font {
        if (emoji_presentation.shouldForceEmojiFont(cell.codepoint, cell.grapheme)) return self.emoji_font;
        for (options.codepoint_maps, self.mapped) |map, fonts| {
            if (cell.codepoint >= map.range_start and cell.codepoint <= map.range_end) return fonts[styleIndex(cell.style)];
        }
        return self.select(cell.style);
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
text_blink_on: bool = true,
/// Host-driven mouse selection in viewport coordinates; null when nothing is
/// selected.
selection: ?GridModel.Selection = null,
hovered_url: ?url_hover.Hit = null,
sprite_masks: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
shaping_cache: ShapingCache = .{},
kitty_images: KittyImages = .{},
background_image: BackgroundImage = .{},

pub fn init(options: Options) !CoreTextRenderer {
    if (options.font.size <= 0 or options.scale <= 0) return error.InvalidFontSize;
    if (options.pixel_width == 0 or options.pixel_height == 0) return error.InvalidDrawableSize;

    var families = try FamilySet.init(options.allocator, options.font);
    errdefer families.deinit();
    var fonts = try FontSet.init(families, options.font.size * options.scale);
    errdefer fonts.deinit();
    const metrics = try metricsForFont(fonts.regular);
    var metal = try MetalBackend.init();
    errdefer metal.deinit();
    try metal.resize(options.pixel_width, options.pixel_height);

    const pixel_count = try pixelBufferLength(options.pixel_width, options.pixel_height);
    const pixels = try options.allocator.alloc(u8, pixel_count);
    errdefer options.allocator.free(pixels);
    var background_image: BackgroundImage = .{};
    errdefer background_image.deinit(options.allocator);
    try background_image.reconfigure(options.allocator, std.Io.Threaded.global_single_threaded.io(), options.background_image);

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
        .background_image = background_image,
    };
}

pub fn deinit(self: *CoreTextRenderer) void {
    self.shaping_cache.deinit(self.allocator);
    self.background_image.deinit(self.allocator);
    self.kitty_images.deinit(self.allocator);
    self.clearSpriteMasks();
    self.sprite_masks.deinit(self.allocator);
    self.metal.deinit();
    self.allocator.free(self.pixels);
    self.fonts.deinit();
    self.families.deinit();
    self.* = undefined;
}

/// Adopt font settings from a reloaded config. Returns true when the cell
/// metrics changed, so the caller knows the grid must be re-derived. Rebuilds
/// everything before publishing so a failure leaves the current fonts intact.
pub fn reconfigure(self: *CoreTextRenderer, options: FontOptions) !bool {
    const size = if (options.size > 0) options.size else default_font_size;
    var families = try FamilySet.init(self.allocator, options);
    errdefer families.deinit();
    var fonts = try FontSet.init(families, size * self.scale);
    errdefer fonts.deinit();
    const metrics = try metricsForFont(fonts.regular);

    self.shaping_cache.clear();
    self.fonts.deinit();
    self.families.deinit();
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
        self.shaping_cache.clear();
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
    // Wallpaper is behind the translucent terminal background, matching the
    // shared config semantics. Explicit cell backgrounds cover both layers.
    self.background_image.draw(context, self.pixel_width, self.pixel_height);
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
    var cell_index: usize = 0;
    while (cell_index < frame.cells.len) {
        var draw_cell = frame.cells[cell_index];
        cell_index += 1;
        if (!cell_style.textVisible(draw_cell.style, self.text_blink_on) or
            draw_cell.codepoint == @import("vt").kitty.graphics.unicode.placeholder) continue;
        const font = self.fonts.selectCell(self.families.options, draw_cell);
        // Shape only contiguous programming symbols with identical paint.
        // Cursor/selection/style boundaries remain individual grid cells.
        var run: [63]u21 = undefined;
        var run_len: usize = 0;
        if (self.families.options.ligatures and ligatureCandidate(draw_cell, cursor)) {
            while (cell_index < frame.cells.len and run_len < run.len) {
                const next = frame.cells[cell_index];
                if (!ligatureCandidate(next, cursor) or next.row != draw_cell.row or
                    @as(usize, next.col) != @as(usize, draw_cell.col) + run_len + 1 or
                    !std.meta.eql(next.style, draw_cell.style) or
                    self.fonts.selectCell(self.families.options, next) != font) break;
                run[run_len] = next.codepoint;
                run_len += 1;
                cell_index += 1;
            }
            draw_cell.grapheme = run[0..run_len];
        }
        const x = @as(f64, @floatFromInt(@as(u32, draw_cell.col) * self.metrics.cell_width));
        const y = @as(f64, @floatFromInt(self.pixel_height - (@as(u32, draw_cell.row) + 1) * self.metrics.cell_height));
        const width = @as(f64, @floatFromInt((@as(u32, draw_cell.width) + @as(u32, @intCast(run_len))) * self.metrics.cell_width));
        const height = @as(f64, @floatFromInt(self.metrics.cell_height));

        if (draw_cell.grapheme.len == 0 and sprite.hasCodepoint(draw_cell.codepoint)) {
            try self.drawSprite(context, draw_cell, x, y);
            const baseline = y + font.getDescent() + @max(0, (height - font.getAscent() - font.getDescent()) / 2);
            drawDecorations(context, font, draw_cell.style, x, baseline, width);
            continue;
        }
        const synthetic = if (font == self.fonts.emoji_font) text.FontSymbolicTraits{} else self.fonts.synthetic[FontSet.styleIndex(draw_cell.style)];
        try drawCellText(self.allocator, &self.shaping_cache, context, font, draw_cell, x, y, width, self.metrics.cell_height, synthetic);
    }
    self.kitty_images.draw(context, .above_text, viewport, self.pixel_height);
}

fn ligatureCandidate(cell: GridModel.Cell, cursor: ?Cursor) bool {
    if (cursor) |cur| {
        if (cell.col == cur.col and cell.row == cur.row) return false;
    }
    return cell.width == 1 and cell.grapheme.len == 0 and font_policy.isLigatureTrigger(cell.codepoint);
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
    allocator: std.mem.Allocator,
    cache: *ShapingCache,
    context: *graphics.BitmapContext,
    base_font: *text.Font,
    cell: GridModel.Cell,
    x: f64,
    y: f64,
    cell_width: f64,
    cell_height: u32,
    synthetic: text.FontSymbolicTraits,
) !void {
    var character_buffer: [32]u16 = undefined;
    const capacity = try std.math.mul(usize, cell.grapheme.len + 1, 2);
    const characters = if (capacity <= character_buffer.len)
        &character_buffer
    else
        try allocator.alloc(u16, capacity);
    defer if (capacity > character_buffer.len) allocator.free(characters);
    var character_len: usize = 0;
    try appendCodepoint(characters, &character_len, cell.codepoint);
    for (cell.grapheme) |codepoint| {
        try appendCodepoint(characters, &character_len, codepoint);
    }

    const shaped = try cache.get(allocator, characters[0..character_len], base_font);
    defer shaped.deinit();
    const line = shaped.shape.line;
    const ascent = shaped.shape.ascent;
    const descent = shaped.shape.descent;
    const total_advance = shaped.shape.advance;
    const content_height = ascent + descent;
    const height: f64 = @floatFromInt(cell_height);
    // Fallback emoji metrics can exceed the monospace cell. Fit the shaped
    // cluster as a unit, preserving its aspect ratio and the VT column layout.
    const scale = @min(1, cell_width / @max(1, total_advance), height / @max(1, content_height));
    const baseline = y + descent * scale + @max(0, (height - content_height * scale) / 2);
    const pen_x = x + @max(0, (cell_width - total_advance * scale) / 2);
    const ctx = graphics.BitmapContext.context;
    {
        ctx.save(context);
        defer ctx.restore(context);
        ctx.clipToRect(context, graphics.Rect.init(x, y, cell_width, height));
        ctx.translate(context, pen_x, baseline);
        ctx.scale(context, scale, scale);
        if (synthetic.italic) ctx.concat(context, .{ .a = 1, .b = 0, .c = 0.2, .d = 1, .tx = 0, .ty = 0 });
        if (synthetic.bold) {
            ctx.setLineWidth(context, @max(0.5, content_height * 0.025));
            const color = cell.style.foreground;
            ctx.setRGBStrokeColor(context, @as(f64, @floatFromInt(color.r)) / 255, @as(f64, @floatFromInt(color.g)) / 255, @as(f64, @floatFromInt(color.b)) / 255, @as(f64, @floatFromInt(color.a)) / 255);
            ctx.setTextDrawingMode(context, .fill_stroke);
        }
        ctx.setTextPosition(context, 0, 0);
        setFill(context, cell.style.foreground);
        line.draw(context);
    }
    const decoration_baseline = y + base_font.getDescent() + @max(0, (height - base_font.getAscent() - base_font.getDescent()) / 2);
    drawDecorations(context, base_font, cell.style, x, decoration_baseline, cell_width);
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

fn firstAvailableFamily(primary: []const u8, fallbacks: []const []const u8, default: []const u8) ![]const u8 {
    if (try text.Font.findFace(primary, null, null, 0)) |font| {
        defer font.release();
        if (!font.hasUnsupportedColorFormat()) return primary;
        std.log.warn("font: '{s}' uses a color format CoreText cannot paint; trying fallback", .{primary});
    }
    for (fallbacks) |family| {
        if (try text.Font.findFace(family, null, null, 0)) |font| {
            defer font.release();
            if (!font.hasUnsupportedColorFormat()) return family;
        }
    }
    return default;
}

pub fn createTabbarFont(cfg: *const Config) !*text.Font {
    const fallbacks = if (cfg.font_families.len > 1) cfg.font_families[1..] else &.{};
    const primary = try firstAvailableFamily(if (cfg.font_families.len > 0) cfg.font_families[0] else default_family, fallbacks, default_family);
    const size = cfg.tabbar_font_size_pt orelse cfg.font_size_pt orelse default_font_size;
    const tabbar_primary = if (cfg.tabbar_font_family.len > 0) try firstAvailableFamily(cfg.tabbar_font_family, &.{}, primary) else primary;
    const base = try createFont(tabbar_primary, size);
    defer base.release();
    const regular = try createFont(primary, size);
    defer regular.release();
    return base.copyWithCascade(regular, fallbacks);
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
    const required: usize = if (codepoint <= 0xffff) 1 else 2;
    if (len.* > buffer.len or buffer.len - len.* < required) return error.GraphemeTooLong;
    len.* += emoji_presentation.encodeUtf16Codepoint(buffer[len.*..], codepoint);
}

fn pixelBufferLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidDrawableSize;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidDrawableSize;
}

test "CoreText resolves ordinary and wide glyphs" {
    var families = try FamilySet.init(std.testing.allocator, .{});
    defer families.deinit();
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

test "color emoji keep their presentation and fit their VT cell span" {
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
        .font = .{ .family = "Menlo", .size = 20 },
        .pixel_width = 320,
        .pixel_height = 120,
    });
    defer renderer.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        try renderer.resize(640, 240, scale);
        // Rich uses both supplementary-plane emoji and regional-indicator flags.
        // Include VS16, a skin tone and a ZWJ sequence to exercise shaping too.
        for ([_]struct { []const u8, bool }{
            .{ "👍", true },
            .{ "🍎", true },
            .{ "🐻", true },
            .{ "🥖", true },
            .{ "🚌", true },
            .{ "🇨🇳", true },
            .{ "❤️", true },
            .{ "👍🏽", true },
            .{ "👩‍💻", true },
            .{ "❤︎", false },
            .{ "A", false },
            .{ "界", false },
        }) |sample| {
            const emoji, const is_color = sample;
            session.feed("\x1b]10;#ffffff\x07\x1b]11;#000000\x07\x1b[0m\x1b[2J\x1b[H");
            session.feed(emoji);
            _ = try renderer.render(&session, null);
            const cw = renderer.metrics.cell_width;
            const ch = renderer.metrics.cell_height;
            var colored: usize = 0;
            var ink: usize = 0;
            var overflow: usize = 0;
            for (0..ch) |row| {
                for (0..4 * cw) |col| {
                    const pixel = renderer.pixels[(row * renderer.pixel_width + col) * 4 ..][0..4];
                    const brightest = @max(pixel[0], pixel[1], pixel[2]);
                    const darkest = @min(pixel[0], pixel[1], pixel[2]);
                    if (col < 2 * cw and brightest - darkest > 32) colored += 1;
                    if (col < 2 * cw and brightest > 32) ink += 1;
                    if (col >= 2 * cw and brightest > 32) overflow += 1;
                }
            }
            const presentation_matches = if (is_color) colored > 10 else colored == 0;
            std.testing.expect(presentation_matches and ink > 10 and overflow == 0) catch |err| {
                std.debug.print("emoji {s} at scale {d}: colored={d}, overflow={d}\n", .{ emoji, scale, colored, overflow });
                return err;
            };
            if (is_color) {
                const original = try std.testing.allocator.dupe(u8, renderer.pixels);
                defer std.testing.allocator.free(original);
                // SGR foreground colors must recolor text, not color emoji.
                session.feed("\x1b[H\x1b[38;2;0;255;0m");
                session.feed(emoji);
                _ = try renderer.render(&session, null);
                try std.testing.expectEqualSlices(u8, original, renderer.pixels);
            }
        }
    }
}

test "explicit Noto emoji chain renders color with Apple system fallback" {
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
        .font = .{ .emoji_families = &.{ "Noto Color Emoji", "Apple Color Emoji" }, .size = 24 },
        .pixel_width = 320,
        .pixel_height = 120,
    });
    defer renderer.deinit();
    session.feed("\x1b]11;#000000\x07👍");
    _ = try renderer.render(&session, null);
    var colored: usize = 0;
    var i: usize = 0;
    while (i < renderer.pixels.len) : (i += 4) {
        const p = renderer.pixels[i..][0..4];
        if (@max(p[0], p[1], p[2]) - @min(p[0], p[1], p[2]) > 32) colored += 1;
    }
    try std.testing.expect(colored > 10);
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
    defer derived.deinit();
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
    defer explicit.deinit();
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
    defer families.deinit();
    var fonts = try FontSet.init(families, 14);
    defer fonts.deinit();
    try std.testing.expect(fonts.bold != fonts.regular);
    try std.testing.expect(fonts.bold_italic != fonts.regular);
}

const FontSelectionTest = struct {
    extern "c" fn CTLineGetGlyphRuns(line: *text.Line) *anyopaque;
    extern "c" fn CFArrayGetCount(array: *anyopaque) c_long;
    extern "c" fn CFArrayGetValueAtIndex(array: *anyopaque, index: c_long) *anyopaque;
    extern "c" fn CTRunGetAttributes(run: *anyopaque) *anyopaque;
    extern "c" fn CFDictionaryGetValue(dictionary: *anyopaque, key: *anyopaque) ?*text.Font;
    extern "c" var kCTFontAttributeName: *anyopaque;
    extern "c" fn CTFontCopyFamilyName(font: *text.Font) *foundation.String;
    extern "c" fn CFEqual(lhs: *foundation.String, rhs: *foundation.String) bool;
    extern "c" fn CTFontCopyPostScriptName(font: *text.Font) *foundation.String;
    extern "c" fn CTLineGetGlyphCount(line: *text.Line) c_long;

    fn expectFace(font: *text.Font, expected_name: []const u8) !void {
        const actual = CTFontCopyPostScriptName(font);
        defer actual.release();
        const expected = try foundation.String.createWithBytes(expected_name, .utf8, false);
        defer expected.release();
        try std.testing.expect(CFEqual(actual, expected));
    }

    fn expectFamily(font: *text.Font, characters: []const u16, family: []const u8) !void {
        const line = try text.Line.create(characters, font);
        defer line.release();
        const runs = CTLineGetGlyphRuns(line);
        try std.testing.expectEqual(@as(c_long, 1), CFArrayGetCount(runs));
        const attributes = CTRunGetAttributes(CFArrayGetValueAtIndex(runs, 0));
        const selected = CFDictionaryGetValue(attributes, kCTFontAttributeName) orelse return error.MissingRunFont;
        const actual = CTFontCopyFamilyName(selected);
        defer actual.release();
        const expected = try foundation.String.createWithBytes(family, .utf8, false);
        defer expected.release();
        try std.testing.expect(CFEqual(actual, expected));
    }
};

test "configured fallback order reaches shaped glyphs across styles reloads and scales" {
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .font = .{ .family = "Menlo", .fallback_families = &.{ "Songti SC", "PingFang SC" } },
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer renderer.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        try renderer.resize(640, 192, scale);
        for ([_]*text.Font{ renderer.fonts.regular, renderer.fonts.bold, renderer.fonts.italic, renderer.fonts.bold_italic }) |font| {
            try FontSelectionTest.expectFamily(font, &.{'A'}, "Menlo");
            // Menlo has no CJK glyphs; the first configured covering font wins.
            try FontSelectionTest.expectFamily(font, &.{'中'}, "Songti SC");
            // A custom cascade must preserve system color-emoji fallback.
            try FontSelectionTest.expectFamily(font, &.{ 0xd83d, 0xdc4d }, "Apple Color Emoji");
        }
    }
    const metrics = renderer.metrics;
    // Config storage may be freed immediately after a reload. Resizing later
    // must rebuild from the renderer's owned copy of every fallback name.
    {
        var cfg = Config.parse(std.testing.allocator,
            \\font-family = Menlo, Missing Mostty Test Font, PingFang SC
            \\font-family = Songti SC
        , "fallback-test");
        defer cfg.deinit();
        try std.testing.expect(!try renderer.reconfigure(.{
            .family = cfg.font_families[0],
            .fallback_families = cfg.font_families[1..],
        }));
    }
    try std.testing.expectEqual(metrics, renderer.metrics);
    try FontSelectionTest.expectFamily(renderer.fonts.regular, &.{'中'}, "PingFang SC");
    try renderer.resize(320, 96, 1);
    try FontSelectionTest.expectFamily(renderer.fonts.regular, &.{'中'}, "PingFang SC");
    // A style-specific face lacking CJK must try the regular primary before
    // the remaining fallbacks, matching the terminal's font-family ordering.
    _ = try renderer.reconfigure(.{
        .family = "Songti SC",
        .family_bold = "Menlo",
        .fallback_families = &.{"PingFang SC"},
    });
    try FontSelectionTest.expectFamily(renderer.fonts.bold, &.{'A'}, "Menlo");
    try FontSelectionTest.expectFamily(renderer.fonts.bold, &.{'中'}, "Songti SC");
}

test "an empty family falls back to the platform default" {
    // A config that omits `font-family` must not produce an empty family name;
    // it resolves to the documented macOS default instead.
    var families = try FamilySet.init(std.testing.allocator, .{ .family = &.{} });
    defer families.deinit();
    try std.testing.expectEqualStrings(default_family, families.names[0]);
}

test "unavailable primary families advance through configured text and emoji chains" {
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 160,
        .font = .{ .family = "Missing Mostty Primary", .fallback_families = &.{ "Courier New", "Songti SC" }, .emoji_families = &.{ "Missing Mostty Emoji", "Apple Symbols", "Apple Color Emoji" } },
    });
    defer renderer.deinit();
    try FontSelectionTest.expectFamily(renderer.fonts.regular, &.{'A'}, "Courier New");
    try FontSelectionTest.expectFamily(renderer.fonts.regular, &.{'中'}, "Songti SC");
    // The configured first available emoji face wins for glyphs it provides.
    try FontSelectionTest.expectFamily(renderer.fonts.emoji_font, &.{0x2665}, "Apple Symbols");
    try FontSelectionTest.expectFamily(renderer.fonts.emoji_font, &.{ 0xd83d, 0xdc4d }, "Apple Color Emoji");
}

test "named faces disabled styles and synthetic policy survive reload and scale changes" {
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 160,
    });
    defer renderer.deinit();
    _ = try renderer.reconfigure(.{
        .family = "Menlo",
        .styles = .{ .{ .named = "bOlD" }, .disabled, .default, .default },
        .synthetic = .{ .bold = false, .italic = false, .bold_italic = false },
    });
    // A named regular face is honored, and an explicitly disabled bold slot
    // uses that chosen regular face, regardless of its physical weight.
    try FontSelectionTest.expectFace(renderer.fonts.regular, "Menlo-Bold");
    try FontSelectionTest.expectFace(renderer.fonts.bold, "Menlo-Bold");
    try FontSelectionTest.expectFace(renderer.fonts.italic, "Menlo-Italic");
    try FontSelectionTest.expectFace(renderer.fonts.bold_italic, "Menlo-BoldItalic");
    try renderer.resize(640, 320, 2);
    try FontSelectionTest.expectFace(renderer.fonts.regular, "Menlo-Bold");
    try FontSelectionTest.expectFace(renderer.fonts.italic, "Menlo-Italic");
    // Apple Symbols has no real bold/italic face. Suppressing synthesis must
    // choose the regular primary rather than an unrelated substitute family.
    _ = try renderer.reconfigure(.{
        .family = "Menlo",
        .family_bold = "Apple Symbols",
        .family_italic = "Apple Symbols",
        .synthetic = .{ .bold = false, .italic = false },
    });
    try FontSelectionTest.expectFace(renderer.fonts.bold, "Menlo-Regular");
    try FontSelectionTest.expectFace(renderer.fonts.italic, "Menlo-Regular");
    _ = try renderer.reconfigure(.{ .family = "Menlo", .family_bold = "Apple Symbols", .family_italic = "Apple Symbols" });
    try FontSelectionTest.expectFace(renderer.fonts.bold, "AppleSymbols");
    try std.testing.expect(renderer.fonts.synthetic[1].bold);
    try std.testing.expect(renderer.fonts.synthetic[2].italic);
}

test "codepoint maps are ordered fallback-only and emoji use a separate chain" {
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 160,
    });
    defer renderer.deinit();
    {
        var cfg = Config.parse(std.testing.allocator,
            \\font-family = Menlo, PingFang SC
            \\emoji-font-family = Missing Mostty Emoji, Apple Color Emoji
            \\font-codepoint-map = U+0041,U+4E2D=Songti SC
            \\font-codepoint-map = U+4E2D=PingFang SC
        , "font-map-test");
        defer cfg.deinit();
        _ = try renderer.reconfigure(.{
            .family = cfg.font_families[0],
            .fallback_families = cfg.font_families[1..],
            .emoji_families = cfg.emoji_font_families,
            .codepoint_maps = cfg.font_codepoint_maps,
        });
    }
    for ([_]f32{ 1, 2 }) |scale| {
        try renderer.resize(640, 320, scale);
        var cell: GridModel.Cell = .{ .col = 0, .row = 0, .width = 1, .codepoint = 'A', .grapheme = &.{}, .style = .{ .foreground = GridModel.DEFAULT_FOREGROUND, .background = GridModel.DEFAULT_BACKGROUND } };
        const options = renderer.families.options;
        try FontSelectionTest.expectFamily(renderer.fonts.selectCell(options, cell), &.{'A'}, "Menlo");
        cell.codepoint = '中';
        try FontSelectionTest.expectFamily(renderer.fonts.selectCell(options, cell), &.{'中'}, "Songti SC");
        cell.codepoint = '文';
        try FontSelectionTest.expectFamily(renderer.fonts.selectCell(options, cell), &.{'文'}, "PingFang SC");
        cell.codepoint = 0x1f44d;
        try std.testing.expect(renderer.fonts.selectCell(options, cell) == renderer.fonts.emoji_font);
        try FontSelectionTest.expectFamily(renderer.fonts.selectCell(options, cell), &.{ 0xd83d, 0xdc4d }, "Apple Color Emoji");
        cell.codepoint = 0x2764;
        cell.grapheme = &.{0xfe0e};
        try std.testing.expect(renderer.fonts.selectCell(options, cell) == renderer.fonts.regular);
        cell.grapheme = &.{0xfe0f};
        try std.testing.expect(renderer.fonts.selectCell(options, cell) == renderer.fonts.emoji_font);
    }
}

test "OpenType feature reload changes actual CoreText shaping" {
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 160,
    });
    defer renderer.deinit();
    for ([_]u32{ 0, 1 }) |value| {
        _ = try renderer.reconfigure(.{
            .family = "Menlo",
            .features = &.{.{ .tag = 0x6167696c, .value = value }},
        });
        for ([_]f32{ 1, 2 }) |scale| {
            try renderer.resize(640, 320, scale);
            const shaped = try renderer.shaping_cache.get(std.testing.allocator, &.{ 'f', 'i' }, renderer.fonts.regular);
            defer shaped.deinit();
            const line = shaped.shape.line;
            try std.testing.expectEqual(@as(c_long, if (value == 0) 2 else 1), FontSelectionTest.CTLineGetGlyphCount(line));
        }
    }
}

test "shaping cache preserves pixels Unicode font identity and dynamic color" {
    const allocator = std.testing.allocator;
    const font = try createFont("Menlo", 20);
    defer font.release();
    const large = try createFont("Menlo", 30);
    defer large.release();
    var cache: ShapingCache = .{};
    defer cache.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, cache.get(failing.allocator(), &.{'A'}, font));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.len);
    var pixels: [128 * 64 * 4]u8 = @splat(0);
    const space = try graphics.ColorSpace.createDeviceRGB();
    defer space.release();
    const context = try graphics.BitmapContext.create(&pixels, 128, 64, 8, 128 * 4, space, @intFromEnum(graphics.ImageAlphaInfo.premultiplied_last));
    defer graphics.Context.release(context);
    const samples = [_][]const u16{
        &.{'A'},                                      &.{ 'f', 'i' },       &.{ 'a', 0x301 },
        &.{'界'},
        &.{ 0xd83d, 0xdc69, 0x200d, 0xd83d, 0xdcbb }, &.{ 0x2764, 0xfe0e }, &.{ 0x2764, 0xfe0f },
    };
    for ([_]*text.Font{ font, large }) |face| {
        for (samples) |characters| {
            const first = try cache.get(allocator, characters, face);
            defer first.deinit();
            // A cache hit needs no allocator, even after an allocation failure.
            const hit = try cache.get(failing.allocator(), characters, face);
            defer hit.deinit();
            try std.testing.expectEqual(first.shape.line, hit.shape.line);
            const fresh = try ShapingCache.Shape.create(characters, face);
            defer fresh.line.release();
            try std.testing.expectEqual(fresh.advance, hit.shape.advance);
            for ([_]GridModel.Rgba{ .{ .r = 255, .g = 0, .b = 0 }, .{ .r = 0, .g = 255, .b = 0 } }) |color| {
                graphics.Context.clearRect(context, graphics.Rect.init(0, 0, 128, 64));
                graphics.Context.setTextPosition(context, 0, 16);
                setFill(context, color);
                fresh.line.draw(context);
                const expected = pixels;
                try std.testing.expect(!std.mem.allEqual(u8, &expected, 0));
                if (characters.len == 1 and characters[0] == 'A') {
                    var colored = false;
                    var offset: usize = 0;
                    while (offset < expected.len) : (offset += 4) {
                        if (expected[offset + 3] == 0) continue;
                        colored = true;
                        try std.testing.expectEqual(@as(u8, 0), expected[offset + if (color.r == 255) @as(usize, 1) else 0]);
                    }
                    try std.testing.expect(colored);
                }
                graphics.Context.clearRect(context, graphics.Rect.init(0, 0, 128, 64));
                graphics.Context.setTextPosition(context, 0, 16);
                setFill(context, color);
                hit.shape.line.draw(context);
                try std.testing.expectEqualSlices(u8, &expected, &pixels);
            }
        }
    }
    // More distinct keys than slots forces collisions and eviction. Equality
    // must check the complete text, and evicted shapes must remain reproducible.
    for (0..ShapingCache.capacity + 1) |i| {
        const characters = [_]u16{ 'A', @intCast(0x3000 + i) };
        const result = try cache.get(allocator, &characters, font);
        defer result.deinit();
        const fresh = try ShapingCache.Shape.create(&characters, font);
        defer fresh.line.release();
        try std.testing.expectEqual(fresh.advance, result.shape.advance);
        try std.testing.expectEqual(FontSelectionTest.CTLineGetGlyphCount(fresh.line), FontSelectionTest.CTLineGetGlyphCount(result.shape.line));
    }
    try std.testing.expectEqual(ShapingCache.capacity, cache.entries.len);
    const long = [_]u16{'a'} ** 129;
    const uncached = try cache.get(allocator, &long, font);
    defer uncached.deinit();
    try std.testing.expect(uncached.owned);
    cache.clear();
    for (cache.entries) |entry| try std.testing.expect(entry == null);
}

test "shaping cache clears only when replacement fonts are published" {
    const allocator = std.testing.allocator;
    var renderer = try CoreTextRenderer.init(.{ .allocator = allocator, .pixel_width = 320, .pixel_height = 160 });
    defer renderer.deinit();
    const original = try renderer.shaping_cache.get(allocator, &.{'A'}, renderer.fonts.regular);
    defer original.deinit();
    try renderer.resize(400, 160, renderer.scale);
    const resized = try renderer.shaping_cache.get(allocator, &.{'A'}, renderer.fonts.regular);
    defer resized.deinit();
    try std.testing.expectEqual(original.shape.line, resized.shape.line);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    renderer.allocator = failing.allocator();
    defer renderer.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, renderer.reconfigure(.{ .size = 24 }));
    const retained = try renderer.shaping_cache.get(allocator, &.{'A'}, renderer.fonts.regular);
    defer retained.deinit();
    try std.testing.expectEqual(original.shape.line, retained.shape.line);
    try std.testing.expectError(error.OutOfMemory, renderer.resize(400, 160, 2));
    renderer.allocator = allocator;
    _ = try renderer.reconfigure(.{ .size = 24 });
    for (renderer.shaping_cache.entries) |entry| try std.testing.expect(entry == null);
    const reloaded = try renderer.shaping_cache.get(allocator, &.{'A'}, renderer.fonts.regular);
    defer reloaded.deinit();
    try renderer.resize(400, 160, 2);
    for (renderer.shaping_cache.entries) |entry| try std.testing.expect(entry == null);
}

test "UTF16 append checks remaining space before shared encoding" {
    var buffer: [3]u16 = undefined;
    var len: usize = 0;
    try appendCodepoint(&buffer, &len, 'A');
    try std.testing.expectError(error.GraphemeTooLong, appendCodepoint(buffer[0..2], &len, 0x1f600));
    try std.testing.expectEqual(@as(usize, 1), len);
    try appendCodepoint(&buffer, &len, 0x1f600);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xde00 }, &buffer);
    try std.testing.expectError(error.GraphemeTooLong, appendCodepoint(&buffer, &len, 'B'));
}

test "tabbar font inherits terminal settings and keeps the configured fallback chain" {
    var cfg = Config.parse(std.testing.allocator,
        \\font-family = Menlo, Songti SC, PingFang SC
        \\font-size = 18
    , "tabbar-test");
    defer cfg.deinit();
    const inherited = try createTabbarFont(&cfg);
    defer inherited.release();
    try FontSelectionTest.expectFamily(inherited, &.{'A'}, "Menlo");
    try FontSelectionTest.expectFamily(inherited, &.{'中'}, "Songti SC");
    cfg.tabbar_font_family = "Courier New";
    cfg.tabbar_font_size_pt = 30;
    const explicit = try createTabbarFont(&cfg);
    defer explicit.release();
    try FontSelectionTest.expectFamily(explicit, &.{'A'}, "Courier New");
    try FontSelectionTest.expectFamily(explicit, &.{'中'}, "Songti SC");
    try std.testing.expect(explicit.getAscent() > inherited.getAscent());
}

test "wallpaper pixels respect position repeat opacity and explicit terminal backgrounds" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 8,
        .rows = 3,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    session.feed("\x1b]11;#000000\x07\x1b[48;2;0;0;255m \x1b[0m");
    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 160,
        .pixel_height = 120,
        .paint = .{ .background_alpha = 128 },
    });
    defer renderer.deinit();
    renderer.background_image.image = try graphics.Image.createRgba(&.{ 255, 0, 0, 255 }, 1, 1);
    // The first cell's explicit blue background is opaque; the wallpaper
    // shows red through the default black background in the next cell.
    try renderer.background_image.reconfigure(std.testing.allocator, std.testing.io, .{ .fit = .stretch });
    _ = try renderer.render(&session, null);
    const first = renderer.pixels[0..4];
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, first);
    const next_offset = @as(usize, renderer.metrics.cell_width) * 4;
    const next = renderer.pixels[next_offset..][0..4];
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 127, 255 }, next);
    // Repeated renders must not compound the translucent fill.
    const saved = try std.testing.allocator.dupe(u8, renderer.pixels);
    defer std.testing.allocator.free(saved);
    _ = try renderer.render(&session, null);
    try std.testing.expectEqualSlices(u8, saved, renderer.pixels);
    try renderer.background_image.reconfigure(std.testing.allocator, std.testing.io, .{ .fit = .none, .position = .bottom_right });
    _ = try renderer.render(&session, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 128 }, renderer.pixels[next_offset..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 127, 255 }, renderer.pixels[renderer.pixels.len - 4 ..]);
    try renderer.background_image.reconfigure(std.testing.allocator, std.testing.io, .{ .fit = .none, .repeat = true });
    _ = try renderer.render(&session, null);
    try std.testing.expectEqualSlices(u8, saved, renderer.pixels);
    try renderer.background_image.reconfigure(std.testing.allocator, std.testing.io, .{ .opacity = 0, .fit = .stretch });
    _ = try renderer.render(&session, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 128 }, renderer.pixels[next_offset..][0..4]);
}

test "programming run shaping toggles live and respects cursor and style boundaries" {
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
        .pixel_width = 320,
        .pixel_height = 160,
        .font = .{ .family = "Times", .size = 24, .ligatures = false },
    });
    defer renderer.deinit();
    // A proportional font makes grouped shaping observably different even on
    // machines without a programming-ligature font installed.
    for ([_][]const u8{ "->", "-\x1b[1m>" }) |sample| {
        session.feed("\x1b[0m\x1b[2J\x1b[H");
        session.feed(sample);
        for ([_]?Cursor{ null, .{ .col = 0, .row = 0 } }) |cursor| {
            _ = try renderer.reconfigure(.{ .family = "Times", .size = 24, .ligatures = false });
            _ = try renderer.render(&session, cursor);
            const unjoined = try std.testing.allocator.dupe(u8, renderer.pixels);
            defer std.testing.allocator.free(unjoined);
            _ = try renderer.reconfigure(.{ .family = "Times", .size = 24, .ligatures = true });
            _ = try renderer.render(&session, cursor);
            const should_join = cursor == null and std.mem.eql(u8, sample, "->");
            try std.testing.expectEqual(should_join, !std.mem.eql(u8, unjoined, renderer.pixels));
        }
    }
}
