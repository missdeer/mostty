//! Font / DPI lifecycle subroutine shared by `init`, `updateDpi`, and
//! `updateFont`. Each of those callers used to inline 60+ lines of
//! "rebuild text formats + tab-bar format + cell metrics + tab_bar_height
//! + invalidate glyph cache + grid_force_full" with the same field-write
//! order and the same release-then-rebuild pattern.
//!
//! Two intermediate shapes capture the symmetry:
//!   * `Effective`  — what `init`/`updateFont` derives from a fresh
//!     `FontConfig`, and what `updateDpi` snapshots from current renderer
//!     state. DPI is intentionally NOT in here: at a given DPI the same
//!     `Effective` produces the same formats.
//!   * `BuiltFormats` — text formats + tab-bar format + cell metrics, the
//!     bundle that gets assigned onto the renderer struct.

const std = @import("std");
const win32 = @import("win32").everything;
const D3d11Renderer = @import("../d3d11.zig");
const font_mod = @import("font.zig");
const gpu = @import("gpu.zig");
const GlyphIndexCache = @import("../GlyphIndexCache.zig");

const FontConfig = font_mod.FontConfig;

pub const Effective = struct {
    primary: [*:0]const u16,
    user_fallbacks: []const [*:0]const u16,
    font_size_pt: f32,
    style_primaries: [3]?[*:0]const u16,
    style_specs: [4]FontConfig.StyleSpec,
    style: [4]GlyphIndexCache.Style,
    codepoint_maps: []const FontConfig.CodepointMapEntry,
    tabbar_primary: [*:0]const u16,
    tabbar_font_size_pt: f32,
};

pub const BuiltFormats = struct {
    text_formats: [4]*win32.IDWriteTextFormat,
    font_fallbacks: [4]*win32.IDWriteFontFallback,
    tabbar_format: *win32.IDWriteTextFormat,
    tabbar_fallback: *win32.IDWriteFontFallback,
    tabbar_trimming_sign: ?*win32.IDWriteInlineObject,
    cell_size: win32.SIZE,
    cell_size_xy: gpu.CellXY,
    tab_bar_height: i32,
};

// Derive `Effective` from a fresh `FontConfig`. Used by `init` and
// `updateFont`. `computeEffectiveStyle` requires the DWrite factory because
// it probes installed face families to decide style fallback.
pub fn deriveFromConfig(
    dwrite_factory: *win32.IDWriteFactory2,
    font_config: FontConfig,
) Effective {
    const primary: [*:0]const u16 = if (font_config.families.len > 0)
        font_config.families[0]
    else
        font_mod.default_primary_font_family;
    const user_fallbacks: []const [*:0]const u16 = if (font_config.families.len > 1)
        font_config.families[1..]
    else
        &.{};
    const font_size_pt: f32 = font_config.font_size_pt orelse font_mod.default_font_size_pt;
    const style_primaries: [3]?[*:0]const u16 = .{
        font_config.family_bold,
        font_config.family_italic,
        font_config.family_bold_italic,
    };
    const synthesize: [3]bool = .{
        font_config.synthesize_bold,
        font_config.synthesize_italic,
        font_config.synthesize_bold_italic,
    };
    const style = font_mod.computeEffectiveStyle(
        &dwrite_factory.IDWriteFactory,
        primary,
        style_primaries,
        synthesize,
        font_config.style_specs,
    );
    const tabbar_primary = font_config.tabbar_family orelse primary;
    const tabbar_size = font_config.tabbar_font_size_pt orelse font_size_pt;
    return .{
        .primary = primary,
        .user_fallbacks = user_fallbacks,
        .font_size_pt = font_size_pt,
        .style_primaries = style_primaries,
        .style_specs = font_config.style_specs,
        .style = style,
        .codepoint_maps = font_config.codepoint_maps,
        .tabbar_primary = tabbar_primary,
        .tabbar_font_size_pt = tabbar_size,
    };
}

// Snapshot `Effective` from current renderer state. Used by `updateDpi`,
// where the font config is unchanged but DPI-dependent formats and metrics
// must be rebuilt.
pub fn snapshotFromRenderer(self: *D3d11Renderer) Effective {
    return .{
        .primary = self.effective_primary,
        .user_fallbacks = self.effective_user_fallbacks,
        .font_size_pt = self.font_size_pt,
        .style_primaries = self.effective_style_primaries,
        .style_specs = self.effective_style_specs,
        .style = self.effective_style,
        .codepoint_maps = self.effective_codepoint_maps,
        .tabbar_primary = self.effective_tabbar_primary,
        .tabbar_font_size_pt = self.tabbar_font_size_pt,
    };
}

// Build the full bundle of text formats + tab-bar format + cell metrics at
// `dpi` from `eff`. Pure construction — caller is responsible for releasing
// any previously-held formats.
pub fn buildFormats(
    dwrite_factory: *win32.IDWriteFactory2,
    dpi: u32,
    eff: Effective,
) BuiltFormats {
    const set = font_mod.createTextFormatSet(
        dwrite_factory,
        dpi,
        eff.primary,
        eff.style_primaries,
        eff.style_specs,
        eff.user_fallbacks,
        eff.codepoint_maps,
        eff.font_size_pt,
    );

    const cell_size = font_mod.measureCellSize(
        &dwrite_factory.IDWriteFactory,
        dpi,
        eff.primary,
        eff.font_size_pt,
    );
    const cell_size_xy: gpu.CellXY = .{
        .x = @intCast(cell_size.cx),
        .y = @intCast(cell_size.cy),
    };

    const tabbar = font_mod.createTabBarTextFormat(
        dwrite_factory,
        dpi,
        eff.tabbar_primary,
        eff.user_fallbacks,
        eff.codepoint_maps,
        eff.tabbar_font_size_pt,
    );
    const tab_bar_h = computeTabBarHeight(
        dwrite_factory,
        dpi,
        eff.tabbar_primary,
        eff.tabbar_font_size_pt,
        cell_size_xy.y,
    );

    return .{
        .text_formats = set.formats,
        .font_fallbacks = set.fallbacks,
        .tabbar_format = tabbar.format,
        .tabbar_fallback = tabbar.fallback,
        .tabbar_trimming_sign = tabbar.trimming_sign,
        .cell_size = cell_size,
        .cell_size_xy = cell_size_xy,
        .tab_bar_height = tab_bar_h,
    };
}

// Release previously-held formats, build new ones at `dpi` from `eff`, then
// assign every dependent field on `self`. Also drops the glyph cache (its
// rasterized pixels are stale) and sets `grid_force_full` (already-baked
// grid-texture pixels are stale even if the per-row shadow diff would
// otherwise skip them).
//
// Shared subroutine for `updateDpi` and `updateFont`. Both end up needing
// the same sequence; the only difference is where `eff` comes from.
pub fn rebuildAndAssign(self: *D3d11Renderer, dpi: u32, eff: Effective) void {
    font_mod.releaseTextFormatSet(&self.text_formats, &self.font_fallbacks);
    var old_tabbar: font_mod.TabBarFormat = .{
        .format = self.tabbar_text_format,
        .fallback = self.tabbar_fallback,
        .trimming_sign = self.tabbar_trimming_sign,
    };
    font_mod.releaseTabBarFormat(&old_tabbar);

    const fmts = buildFormats(self.dwrite_factory, dpi, eff);

    self.text_formats = fmts.text_formats;
    self.font_fallbacks = fmts.font_fallbacks;
    self.tabbar_text_format = fmts.tabbar_format;
    self.tabbar_fallback = fmts.tabbar_fallback;
    self.tabbar_trimming_sign = fmts.tabbar_trimming_sign;
    self.cell_size = fmts.cell_size;
    self.cell_size_xy = fmts.cell_size_xy;
    self.tab_bar_height = fmts.tab_bar_height;

    self.dpi = dpi;
    self.font_size_pt = eff.font_size_pt;
    self.effective_primary = eff.primary;
    self.effective_style_primaries = eff.style_primaries;
    self.effective_style_specs = eff.style_specs;
    self.effective_style = eff.style;
    self.effective_user_fallbacks = eff.user_fallbacks;
    self.effective_codepoint_maps = eff.codepoint_maps;
    self.effective_tabbar_primary = eff.tabbar_primary;
    self.tabbar_font_size_pt = eff.tabbar_font_size_pt;

    invalidateGlyphCache(self);
    self.grid_force_full = true;
}

// Drop the glyph atlas LRU and reset the arena that backs it. Called after
// any font/DPI change so glyphs re-rasterize at the new face/size.
pub fn invalidateGlyphCache(self: *D3d11Renderer) void {
    // Bump before tearing down: in-flight raster jobs captured the old
    // cache_gen at submit time; applyGlyphResult will reject them before
    // they land in the new atlas (font/DPI change resizes cells, so a
    // stale upload would write past slot boundaries).
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
}

// Band height = tab-bar font line height (or terminal cell height when the
// family isn't installed) + symmetric vertical padding so glyphs aren't
// cramped against the window edge / terminal. Kept in physical pixels.
pub fn computeTabBarHeight(
    dwrite_factory: *win32.IDWriteFactory2,
    dpi: u32,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
    fallback_cy: i32,
) i32 {
    const lh = font_mod.measureTabBarLineHeight(&dwrite_factory.IDWriteFactory, dpi, primary, font_size_pt_val);
    const base = if (lh > 0) lh else fallback_cy;
    const pad: i32 = @intFromFloat(@round(win32.scaleDpi(f32, 4.0, dpi)));
    return base + pad;
}
