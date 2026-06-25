//! DirectWrite font configuration: text formats, fallback chains, custom
//! rendering parameters, and cell-size measurement.
//!
//! Pure DirectWrite plumbing — no D3D11 / D2D1 resource creation lives here.
//! Renderer owns the lifetimes of the four (regular/bold/italic/bold-italic)
//! text formats and matching fallbacks; this module only constructs them and
//! computes the effective style mapping.

const std = @import("std");
const win32 = @import("win32").everything;
const com = @import("com.zig");
const GlyphIndexCache = @import("../GlyphIndexCache.zig");

pub const FontConfig = struct {
    pub const StyleSpec = union(enum) {
        default,
        disabled,
        named: [*:0]const u16, // UTF-16 face name, caller-owned (same lifetime as families)
    };

    pub const CodepointMapEntry = struct {
        /// Inclusive range. `first == last` for a single-codepoint mapping.
        first: u32,
        last: u32,
        /// UTF-16 null-terminated family name. Caller-owned, same lifetime
        /// contract as `families` (renderer holds the pointer until next
        /// updateFont).
        family: [*:0]const u16,
    };

    pub const FontFeature = win32.DWRITE_FONT_FEATURE;

    /// First entry becomes the primary family; the rest are inserted at the
    /// front of the fallback chain. Empty -> use built-in defaults.
    families: []const [*:0]const u16 = &.{},
    /// Per-style primary family overrides. `null` -> inherit the regular
    /// primary (single-family-everywhere is the common case). The
    /// per-style fallback chain prepends THIS family in front of the regular
    /// chain, so user fallbacks still kick in for glyphs the style-specific
    /// family lacks (matches Ghostty's permissive behavior).
    family_bold: ?[*:0]const u16 = null,
    family_italic: ?[*:0]const u16 = null,
    family_bold_italic: ?[*:0]const u16 = null,
    /// When false for a style, AND the corresponding family lacks a real face
    /// matching that style, the renderer falls back to the regular text format
    /// for those cells (no DirectWrite synthesis). True (the default) lets
    /// DirectWrite synthesize via DWRITE_FONT_WEIGHT / DWRITE_FONT_STYLE.
    /// Known limitation: only the PRIMARY family of the style is checked;
    /// fallback faces inside the chain may still be synthesized per-glyph,
    /// which would require a shaping-pipeline-aware audit out of scope here.
    synthesize_bold: bool = true,
    synthesize_italic: bool = true,
    synthesize_bold_italic: bool = true,
    /// `font-style*` per-slot face pin. Index order matches GlyphIndexCache.Style.
    /// `.default` = use the style's natural weight/slant (NORMAL/NORMAL for
    /// regular, BOLD/NORMAL for bold, etc.) with DirectWrite synthesis as
    /// allowed by `synthesize_*`. `.disabled` = forbid using a real face for
    /// this style, collapsing the slot to regular when synthesis is off.
    /// `.named` = look up the named face in the chosen family (en-us name
    /// match, case-insensitive) and use its real weight/style/stretch.
    style_specs: [4]StyleSpec = .{ .default, .default, .default, .default },
    /// Font size in points. Null -> use built-in default.
    font_size_pt: ?f32 = null,
    /// OpenType feature settings applied through IDWriteTypography.
    font_features: []const FontFeature = &.{},
    /// Per-range forced font assignments. Applied at the head of the
    /// DirectWrite fallback chain (before the global family mapping), so for
    /// codepoints NOT covered by the preferred family the user-mapped family
    /// is picked first. They do NOT override the preferred family itself —
    /// DirectWrite consults the preferred family before any fallback, so if
    /// the primary covers the codepoint its glyph wins. Typical use is
    /// mapping emoji / icon ranges that the primary monospace font lacks.
    /// Overlapping user ranges resolve in declaration order (earlier wins).
    codepoint_maps: []const CodepointMapEntry = &.{},
    /// Tab-bar primary family. `null` -> inherit the regular primary. The tab
    /// bar always renders at regular weight; its fallback chain reuses the
    /// terminal `families`/`codepoint_maps` so CJK/emoji titles still resolve.
    tabbar_family: ?[*:0]const u16 = null,
    /// Tab-bar font size in points. `null` -> inherit `font_size_pt`.
    tabbar_font_size_pt: ?f32 = null,
};

// Font configuration (mirrors WezTerm config). Primary family, then ordered
// fallbacks: CJK -> Nerd Font icons -> Emoji. Missing families on the system
// are silently skipped by DirectWrite when resolving glyphs.
pub const default_primary_font_family: [*:0]const u16 = win32.L("Consolas");
pub const default_font_size_pt: f32 = 13.0;

pub const emoji_font_family: [*:0]const u16 = win32.L("Segoe UI Emoji");
const font_fallback_families = [_][*:0]const u16{
    emoji_font_family,
};

// Hard cap on user-supplied fallback families. Anything beyond is ignored;
// the chain is already long once you include the hardcoded CJK/icon/emoji
// fonts, and DirectWrite walks it linearly.
const max_user_fallbacks: usize = 32;

// Fallback families used by measureCellSize when the primary isn't installed.
// Picked to be common Windows monospace fonts so a sensible cell size is found
// even on minimal installs.
const measurement_fallbacks = blk: {
    @setEvalBranchQuota(4000);
    break :blk [_][*:0]const u16{
        win32.L("Cascadia Mono"),
        win32.L("Consolas"),
        win32.L("Courier New"),
    };
};

// Computes the font size to pass to CreateTextFormat. CreateTextFormat
// nominally takes DIPs (1/96 inch), and our config is in points (1/72 inch),
// so we convert pt -> DIPs (x 96/72) then apply DPI scaling for the monitor.
// Note: the staging render target runs in D2D1_UNIT_MODE_PIXELS, which makes
// the value we return coincide with physical pixels for our specific draw
// path. The name "Dips" reflects the API contract, not the eventual unit.
pub fn fontSizeDips(dpi: u32, font_size_pt_val: f32) f32 {
    return win32.scaleDpi(f32, font_size_pt_val * 96.0 / 72.0, dpi);
}

pub fn measureCellSize(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
) win32.SIZE {
    // Query the primary font face's canonical design metrics rather than
    // measuring a specific glyph via text layout. Some monospace fonts (e.g.
    // Rec Mono Casual) have a U+2588 advance that's wider than their ASCII
    // letters, which previously made cells too wide and stretched every letter
    // horizontally. Using designUnitsPerEm + advanceWidth from the font face
    // gives the true monospace advance, independent of which glyph we sample.
    var system_collection: *win32.IDWriteFontCollection = undefined;
    {
        const hr = dwrite_factory.GetSystemFontCollection(&system_collection, 0);
        if (hr < 0) com.fatalHr("GetSystemFontCollection", hr);
    }
    defer _ = system_collection.IUnknown.Release();

    var family_index: u32 = 0;
    var family_exists: win32.BOOL = 0;
    {
        const hr = system_collection.FindFamilyName(primary, &family_index, &family_exists);
        if (hr < 0) com.fatalHr("FindFamilyName", hr);
    }
    if (family_exists == 0) {
        std.log.warn("primary font family not installed; trying fallback monospace", .{});
        for (&measurement_fallbacks) |candidate| {
            const hr = system_collection.FindFamilyName(candidate, &family_index, &family_exists);
            if (hr >= 0 and family_exists != 0) break;
        }
        if (family_exists == 0) com.fatalHr("FindFamilyName (no monospace family found)", -1);
    }

    var family: *win32.IDWriteFontFamily = undefined;
    {
        const hr = system_collection.GetFontFamily(family_index, &family);
        if (hr < 0) com.fatalHr("GetFontFamily", hr);
    }
    defer _ = family.IUnknown.Release();

    var font: *win32.IDWriteFont = undefined;
    {
        const hr = family.GetFirstMatchingFont(.NORMAL, .NORMAL, .NORMAL, &font);
        if (hr < 0) com.fatalHr("GetFirstMatchingFont", hr);
    }
    defer _ = font.IUnknown.Release();

    var face: *win32.IDWriteFontFace = undefined;
    {
        const hr = font.CreateFontFace(&face);
        if (hr < 0) com.fatalHr("CreateFontFace", hr);
    }
    defer _ = face.IUnknown.Release();

    var font_metrics: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&font_metrics);

    // Sample 'M' for the advance (any ASCII letter works in a monospace font).
    const codepoint: u32 = 'M';
    var glyph_index: [1:0]u16 = .{0};
    {
        const hr = face.GetGlyphIndices(@ptrCast(&codepoint), 1, &glyph_index);
        if (hr < 0) com.fatalHr("GetGlyphIndices", hr);
    }
    var glyph_metrics: win32.DWRITE_GLYPH_METRICS = undefined;
    {
        const hr = face.GetDesignGlyphMetrics(&glyph_index, 1, @ptrCast(&glyph_metrics), 0);
        if (hr < 0) com.fatalHr("GetDesignGlyphMetrics", hr);
    }

    const font_size_dips = fontSizeDips(dpi, font_size_pt_val);
    const units_per_em: f32 = @floatFromInt(font_metrics.designUnitsPerEm);
    const design_to_dips = font_size_dips / units_per_em;

    const advance_dips = @as(f32, @floatFromInt(glyph_metrics.advanceWidth)) * design_to_dips;
    const ascent_dips = @as(f32, @floatFromInt(font_metrics.ascent)) * design_to_dips;
    const descent_dips = @as(f32, @floatFromInt(font_metrics.descent)) * design_to_dips;
    const line_gap_dips = @as(f32, @floatFromInt(font_metrics.lineGap)) * design_to_dips;
    const line_height_dips = ascent_dips + descent_dips + line_gap_dips;

    return .{
        .cx = @intFromFloat(@round(advance_dips)),
        .cy = @intFromFloat(@round(line_height_dips)),
    };
}

// Physical-pixel line height (ascent + descent + lineGap) of `primary` at
// `font_size_pt_val`, used to size the tab-bar band independently of the
// terminal cell. Mirrors measureCellSize's vertical metric (and its
// not-installed fallback search) but returns only the height. Returns 0 when no
// usable family is found so the caller can fall back to the terminal cell height.
pub fn measureTabBarLineHeight(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
) i32 {
    var system_collection: *win32.IDWriteFontCollection = undefined;
    if (dwrite_factory.GetSystemFontCollection(&system_collection, 0) < 0) return 0;
    defer _ = system_collection.IUnknown.Release();

    var family_index: u32 = 0;
    var family_exists: win32.BOOL = 0;
    _ = system_collection.FindFamilyName(primary, &family_index, &family_exists);
    if (family_exists == 0) {
        for (&measurement_fallbacks) |candidate| {
            if (system_collection.FindFamilyName(candidate, &family_index, &family_exists) >= 0 and family_exists != 0) break;
        }
        if (family_exists == 0) return 0;
    }

    var family: *win32.IDWriteFontFamily = undefined;
    if (system_collection.GetFontFamily(family_index, &family) < 0) return 0;
    defer _ = family.IUnknown.Release();

    var font: *win32.IDWriteFont = undefined;
    if (family.GetFirstMatchingFont(.NORMAL, .NORMAL, .NORMAL, &font) < 0) return 0;
    defer _ = font.IUnknown.Release();

    var face: *win32.IDWriteFontFace = undefined;
    if (font.CreateFontFace(&face) < 0) return 0;
    defer _ = face.IUnknown.Release();

    var fm: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&fm);

    const font_size_dips = fontSizeDips(dpi, font_size_pt_val);
    const units_per_em: f32 = @floatFromInt(fm.designUnitsPerEm);
    const design_to_dips = font_size_dips / units_per_em;
    const ascent_dips = @as(f32, @floatFromInt(fm.ascent)) * design_to_dips;
    const descent_dips = @as(f32, @floatFromInt(fm.descent)) * design_to_dips;
    const line_gap_dips = @as(f32, @floatFromInt(fm.lineGap)) * design_to_dips;
    return @intFromFloat(@round(ascent_dips + descent_dips + line_gap_dips));
}

fn createTextFormat(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    font_fallback: *win32.IDWriteFontFallback,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
    weight: win32.DWRITE_FONT_WEIGHT,
    slant: win32.DWRITE_FONT_STYLE,
    stretch: win32.DWRITE_FONT_STRETCH,
) *win32.IDWriteTextFormat {
    var text_format: *win32.IDWriteTextFormat = undefined;
    const hr = dwrite_factory.CreateTextFormat(
        primary,
        null,
        weight,
        slant,
        stretch,
        fontSizeDips(dpi, font_size_pt_val),
        win32.L(""),
        &text_format,
    );
    if (hr < 0) com.fatalHr("CreateTextFormat", hr);

    // Attach our custom fallback chain so CJK / Nerd Font / Emoji glyphs render.
    const text_format1 = com.queryInterface(text_format, win32.IDWriteTextFormat1);
    defer _ = text_format1.IUnknown.Release();
    const sfhr = text_format1.SetFontFallback(font_fallback);
    if (sfhr < 0) com.fatalHr("SetFontFallback", sfhr);

    // Single-glyph layouts must never wrap; we measure & scale to fit instead.
    const wwhr = text_format.SetWordWrapping(win32.DWRITE_WORD_WRAPPING_NO_WRAP);
    if (wwhr < 0) com.fatalHr("SetWordWrapping", wwhr);

    return text_format;
}

// Resolved face attributes used to drive CreateTextFormat for a named-face
// style spec. When a `font-style*` name doesn't match any face in the family,
// we keep the slot's natural attributes and emit a warning.
const FaceAttrs = struct {
    weight: win32.DWRITE_FONT_WEIGHT,
    slant: win32.DWRITE_FONT_STYLE,
    stretch: win32.DWRITE_FONT_STRETCH,
};

// Looks up a named face within `family` (system collection only). Match is
// case-insensitive against the en-us face name. Returns the face's real
// weight/slant/stretch on success, or null when family/face is missing.
// Known limitation: localized face names beyond en-us aren't matched — users
// running a non-English DirectWrite locale should still see their face
// surface under its en-us name (the canonical key the OS exposes).
fn resolveNamedFace(
    factory: *win32.IDWriteFactory,
    family: [*:0]const u16,
    name: [*:0]const u16,
) ?FaceAttrs {
    var collection: *win32.IDWriteFontCollection = undefined;
    if (factory.GetSystemFontCollection(&collection, 0) < 0) return null;
    defer _ = collection.IUnknown.Release();

    var idx: u32 = 0;
    var exists: win32.BOOL = 0;
    if (collection.FindFamilyName(family, &idx, &exists) < 0 or exists == 0) return null;

    var fam: *win32.IDWriteFontFamily = undefined;
    if (collection.GetFontFamily(idx, &fam) < 0) return null;
    defer _ = fam.IUnknown.Release();

    const wanted = std.mem.span(name);
    const count = fam.IDWriteFontList.GetFontCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var font: *win32.IDWriteFont = undefined;
        if (fam.IDWriteFontList.GetFont(i, &font) < 0) continue;
        defer _ = font.IUnknown.Release();
        // Skip simulated faces so a name like "Bold" doesn't bind to a
        // simulated bold of a regular file — defeats the purpose of pinning.
        if (!std.meta.eql(font.GetSimulations(), win32.DWRITE_FONT_SIMULATIONS_NONE)) continue;

        var names: *win32.IDWriteLocalizedStrings = undefined;
        if (font.GetFaceNames(&names) < 0) continue;
        defer _ = names.IUnknown.Release();

        // Look up the en-us index; fall through to index 0 if absent.
        var en_idx: u32 = 0;
        var en_found: win32.BOOL = 0;
        _ = names.FindLocaleName(win32.L("en-us"), &en_idx, &en_found);
        const which: u32 = if (en_found != 0) en_idx else 0;

        var len: u32 = 0;
        if (names.GetStringLength(which, &len) < 0 or len == 0) continue;
        var buf: [128:0]u16 = undefined;
        if (len + 1 > buf.len) continue;
        if (names.GetString(which, &buf, len + 1) < 0) continue;

        if (utf16EqlIgnoreAsciiCase(buf[0..len], wanted)) {
            return .{
                .weight = font.GetWeight(),
                .slant = font.GetStyle(),
                .stretch = font.GetStretch(),
            };
        }
    }
    return null;
}

// Case-insensitive only in the ASCII range; non-ASCII codepoints must match
// exactly (no Unicode case folding — that would need ICU/uucode). Common
// English face names ("Bold", "SemiBold", "Heavy") fold case correctly;
// non-ASCII face names still match when the user spells them exactly as
// stored in the en-us face name table.
fn utf16EqlIgnoreAsciiCase(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x > 0x7F or y > 0x7F) {
            if (x != y) return false;
        } else if (std.ascii.toLower(@intCast(x)) != std.ascii.toLower(@intCast(y))) {
            return false;
        }
    }
    return true;
}

// True if `family` (in the system font collection) has at least one font
// matching the requested weight/style criteria — i.e. a "real" face exists,
// no DirectWrite synthesis needed. Returns false if the family isn't
// installed at all (the renderer's existing measurement-fallback machinery
// will pick a different family at draw time anyway).
//
// Both axes are matched STRICTLY:
//   - When `match_bold` is true:  weight >= BOLD (700) required; else < BOLD.
//   - When `match_italic` is true: slant != NORMAL required; else == NORMAL.
// Both flags must match within a single font for `bold_italic`. The strict
// negative match matters: without `weight < BOLD` on the italic-only slot, a
// bold-italic face would be accepted as satisfying the "italic" slot — and
// likewise a bold-italic face would falsely satisfy the "bold" (upright) slot.
fn familyHasRealFace(
    factory: *win32.IDWriteFactory,
    family: [*:0]const u16,
    match_bold: bool,
    match_italic: bool,
) bool {
    var collection: *win32.IDWriteFontCollection = undefined;
    if (factory.GetSystemFontCollection(&collection, 0) < 0) return false;
    defer _ = collection.IUnknown.Release();

    var idx: u32 = 0;
    var exists: win32.BOOL = 0;
    if (collection.FindFamilyName(family, &idx, &exists) < 0 or exists == 0) return false;

    var fam: *win32.IDWriteFontFamily = undefined;
    if (collection.GetFontFamily(idx, &fam) < 0) return false;
    defer _ = fam.IUnknown.Release();

    const count = fam.IDWriteFontList.GetFontCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var font: *win32.IDWriteFont = undefined;
        if (fam.IDWriteFontList.GetFont(i, &font) < 0) continue;
        defer _ = font.IUnknown.Release();
        // Faces with DirectWrite simulations applied don't count as real:
        // a simulated bold face from a regular file is exactly what we're
        // trying to suppress.
        if (!std.meta.eql(font.GetSimulations(), win32.DWRITE_FONT_SIMULATIONS_NONE)) continue;
        const is_bold = @intFromEnum(font.GetWeight()) >= @intFromEnum(win32.DWRITE_FONT_WEIGHT_BOLD);
        const is_italic = font.GetStyle() != .NORMAL;
        if (is_bold == match_bold and is_italic == match_italic) return true;
    }
    return false;
}

// Map each requested style to its effective slot. A style slot collapses to
// .regular when:
//   - `font-style*` for the slot is `.disabled` (explicit user opt-out), OR
//   - `font-style*` is `.named` and the named face doesn't exist (no usable
//     real face was found, and synthesis is suppressed), OR
//   - synthesis is disabled AND the family has no real face matching the
//     slot's natural weight/slant criteria.
// `.named` with a successful resolution is treated as "real face exists"
// regardless of synthesize_X — the user explicitly pinned the face.
pub fn computeEffectiveStyle(
    factory: *win32.IDWriteFactory,
    regular_primary: [*:0]const u16,
    style_primaries: [3]?[*:0]const u16,
    synthesize: [3]bool,
    style_specs: [4]FontConfig.StyleSpec,
) [4]GlyphIndexCache.Style {
    var out: [4]GlyphIndexCache.Style = .{ .regular, .bold, .italic, .bold_italic };
    const slots = [_]struct { match_bold: bool, match_italic: bool, slot: usize }{
        .{ .match_bold = true, .match_italic = false, .slot = 1 },
        .{ .match_bold = false, .match_italic = true, .slot = 2 },
        .{ .match_bold = true, .match_italic = true, .slot = 3 },
    };
    for (slots, 0..) |s, ai| {
        const spec = style_specs[s.slot];
        // Explicit user opt-out always collapses, regardless of synthesis policy.
        if (spec == .disabled) {
            out[s.slot] = .regular;
            continue;
        }
        // `.named`: trust the user's pin — if the name resolved at format-build
        // time, the slot has a real face. We don't re-probe here.
        if (spec == .named) {
            const fam = style_primaries[ai] orelse regular_primary;
            if (resolveNamedFace(factory, fam, spec.named) == null) {
                // Name didn't match anything real. Treat like "no real face":
                // if user also forbids synthesis we MUST collapse, otherwise
                // keep the slot (DirectWrite will synthesize from natural).
                if (!synthesize[ai]) out[s.slot] = .regular;
            }
            continue;
        }
        // `.default`: legacy Step 2.3 rule.
        if (synthesize[ai]) continue;
        const fam = style_primaries[ai] orelse regular_primary;
        if (!familyHasRealFace(factory, fam, s.match_bold, s.match_italic)) {
            out[s.slot] = .regular;
        }
    }
    return out;
}

pub const TextFormatSet = struct {
    formats: [4]*win32.IDWriteTextFormat,
    fallbacks: [4]*win32.IDWriteFontFallback,
};

// Builds the four (regular, bold, italic, bold-italic) (text_format,
// fallback) pairs. Index MUST match GlyphIndexCache.Style ordinals.
// `style_primaries` carries optional per-style family overrides
// (font-family-bold/italic/bold-italic); when null the slot inherits the
// regular primary AND uses DirectWrite's synthetic bold/oblique for weight.
// `style_specs` overrides the natural weight/slant when the user pinned a
// specific face via `font-style*`.
pub fn createTextFormatSet(
    factory: *win32.IDWriteFactory2,
    dpi: u32,
    regular_primary: [*:0]const u16,
    style_primaries: [3]?[*:0]const u16, // bold, italic, bold-italic (indexes 1..3)
    style_specs: [4]FontConfig.StyleSpec,
    user_fallbacks: []const [*:0]const u16,
    codepoint_maps: []const FontConfig.CodepointMapEntry,
    font_size_pt_val: f32,
) TextFormatSet {
    const Slot = struct {
        primary: [*:0]const u16,
        style_primary: ?[*:0]const u16,
        weight: win32.DWRITE_FONT_WEIGHT,
        slant: win32.DWRITE_FONT_STYLE,
        stretch: win32.DWRITE_FONT_STRETCH,
    };
    var slots: [4]Slot = .{
        .{ .primary = regular_primary, .style_primary = null, .weight = .NORMAL, .slant = .NORMAL, .stretch = .NORMAL },
        .{ .primary = style_primaries[0] orelse regular_primary, .style_primary = style_primaries[0], .weight = .BOLD, .slant = .NORMAL, .stretch = .NORMAL },
        .{ .primary = style_primaries[1] orelse regular_primary, .style_primary = style_primaries[1], .weight = .NORMAL, .slant = .ITALIC, .stretch = .NORMAL },
        .{ .primary = style_primaries[2] orelse regular_primary, .style_primary = style_primaries[2], .weight = .BOLD, .slant = .ITALIC, .stretch = .NORMAL },
    };

    // Apply `font-style*` pins: a named face shifts the slot's CreateTextFormat
    // attributes to the face's real weight/slant/stretch (no synthesis).
    // `.disabled` is a no-op here — collapsing to regular happens later via
    // computeEffectiveStyle's "no real face" path. Missing names warn once.
    for (style_specs, 0..) |spec, i| {
        switch (spec) {
            .default, .disabled => {},
            .named => |name| {
                if (resolveNamedFace(&factory.IDWriteFactory, slots[i].primary, name)) |attrs| {
                    slots[i].weight = attrs.weight;
                    slots[i].slant = attrs.slant;
                    slots[i].stretch = attrs.stretch;
                } else {
                    std.log.warn("font-style: face not found in family; keeping natural attributes", .{});
                }
            },
        }
    }

    var formats: [4]*win32.IDWriteTextFormat = undefined;
    var fallbacks: [4]*win32.IDWriteFontFallback = undefined;
    for (slots, 0..) |s, i| {
        fallbacks[i] = buildFontFallback(factory, regular_primary, s.style_primary, user_fallbacks, codepoint_maps);
        formats[i] = createTextFormat(&factory.IDWriteFactory, dpi, fallbacks[i], s.primary, font_size_pt_val, s.weight, s.slant, s.stretch);
    }
    return .{ .formats = formats, .fallbacks = fallbacks };
}

pub fn releaseTextFormatSet(
    formats: *[4]*win32.IDWriteTextFormat,
    fallbacks: *[4]*win32.IDWriteFontFallback,
) void {
    for (formats) |tf| _ = tf.IUnknown.Release();
    for (fallbacks) |fb| _ = fb.IUnknown.Release();
}

pub const TabBarFormat = struct {
    format: *win32.IDWriteTextFormat,
    fallback: *win32.IDWriteFontFallback,
    // Ellipsis sign bound to `format`, built once here so the per-frame painter
    // doesn't recreate it. Null if creation failed (painter then hard-trims).
    trimming_sign: ?*win32.IDWriteInlineObject,
};

// Single regular-weight text format for tab-bar titles, drawn proportionally by
// the band painter. Fallback reuses the terminal's user fallbacks + codepoint
// maps so CJK / emoji titles still resolve when the primary lacks the glyph.
pub fn createTabBarTextFormat(
    factory: *win32.IDWriteFactory2,
    dpi: u32,
    primary: [*:0]const u16,
    user_fallbacks: []const [*:0]const u16,
    codepoint_maps: []const FontConfig.CodepointMapEntry,
    font_size_pt_val: f32,
) TabBarFormat {
    const fallback = buildFontFallback(factory, primary, null, user_fallbacks, codepoint_maps);
    const format = createTextFormat(&factory.IDWriteFactory, dpi, fallback, primary, font_size_pt_val, .NORMAL, .NORMAL, .NORMAL);
    var trimming_sign: ?*win32.IDWriteInlineObject = null;
    {
        var s: *win32.IDWriteInlineObject = undefined;
        if (factory.IDWriteFactory.CreateEllipsisTrimmingSign(format, &s) >= 0) trimming_sign = s;
    }
    return .{ .format = format, .fallback = fallback, .trimming_sign = trimming_sign };
}

pub fn releaseTabBarFormat(f: *TabBarFormat) void {
    if (f.trimming_sign) |s| _ = s.IUnknown.Release();
    _ = f.format.IUnknown.Release();
    _ = f.fallback.IUnknown.Release();
}

// Custom rendering parameters so the atlas is reproducible across machines
// and aligns with the shader's gamma 2.2 (`pow(c, 2.2)`) decode of the
// ClearType mask. `enhanced_contrast=0` removes D2D's non-invertible contrast
// curve so the stored mask is a predictable function of coverage; `RGB`
// stripe and `NATURAL_SYMMETRIC` rendering mode pick the standard subpixel
// layout and the best horizontal subpixel positioning (experimental —
// can fall back to `NATURAL` if vertical edges look soft on a given
// monitor). Gamma here MUST match the shader's `to_linear` exponent
// (currently 2.2) or text will look washed out / over-saturated.
pub fn buildRenderingParams(factory: *win32.IDWriteFactory) *win32.IDWriteRenderingParams {
    var params: *win32.IDWriteRenderingParams = undefined;
    const hr = factory.CreateCustomRenderingParams(
        2.2,
        0.0,
        1.0,
        win32.DWRITE_PIXEL_GEOMETRY_RGB,
        win32.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
        &params,
    );
    if (hr < 0) com.fatalHr("CreateCustomRenderingParams", hr);
    return params;
}

pub fn applyFontFeatures(
    dwrite_factory: *win32.IDWriteFactory,
    layout: *win32.IDWriteTextLayout,
    features: []const win32.DWRITE_FONT_FEATURE,
    utf16_len: u32,
) void {
    if (features.len == 0 or utf16_len == 0) return;
    var typography: *win32.IDWriteTypography = undefined;
    {
        const hr = dwrite_factory.CreateTypography(&typography);
        if (hr < 0) com.fatalHr("CreateTypography", hr);
    }
    defer _ = typography.IUnknown.Release();

    for (features) |feature| {
        const hr = typography.AddFontFeature(feature);
        if (hr < 0) com.fatalHr("AddFontFeature", hr);
    }
    const range = win32.DWRITE_TEXT_RANGE{
        .startPosition = 0,
        .length = utf16_len,
    };
    const hr = layout.SetTypography(typography, range);
    if (hr < 0) com.fatalHr("SetTypography", hr);
}

// Fallback object composition order (this is the order DirectWrite walks
// AFTER it has already failed to find the codepoint in the text format's
// preferred family — the preferred family is consulted before any fallback):
//   1. codepoint-map entries (range-specific)
//   2. style_primary (when set; e.g. font-family-bold)
//   3. regular_primary (the global primary family — keeps visual cohesion
//      when style-family is partial; matches Ghostty's permissive behavior)
//   4. user_fallbacks (font-family entries 2..N)
//   5. font_fallback_families (built-in: Emoji)
//   6. system fallback (CJK, etc.)
//
// `style_primary == null` means "this style inherits the regular primary",
// and step 2 is skipped — step 3 alone provides it.
fn buildFontFallback(
    factory: *win32.IDWriteFactory2,
    regular_primary: [*:0]const u16,
    style_primary: ?[*:0]const u16,
    user_fallbacks: []const [*:0]const u16,
    codepoint_maps: []const FontConfig.CodepointMapEntry,
) *win32.IDWriteFontFallback {
    var builder: *win32.IDWriteFontFallbackBuilder = undefined;
    {
        const hr = factory.CreateFontFallbackBuilder(&builder);
        if (hr < 0) com.fatalHr("CreateFontFallbackBuilder", hr);
    }
    defer _ = builder.IUnknown.Release();

    // Per-range forced mappings go in FIRST so within the FALLBACK lookup
    // they win over the global mapping below for the codepoints they cover.
    // Note: this only matters when DirectWrite has already decided the
    // preferred family doesn't cover the codepoint — the preferred family is
    // consulted before any fallback object, so codepoint-map is fallback-only,
    // not an override of the primary. Overlapping user ranges resolve in
    // declaration order (earlier wins) — same first-match rule.
    for (codepoint_maps) |entry| {
        const range = win32.DWRITE_UNICODE_RANGE{ .first = entry.first, .last = entry.last };
        const family_ptr: ?*const u16 = @ptrCast(entry.family);
        var family_arr = [_]?*const u16{family_ptr};
        const hr = builder.AddMapping(
            @ptrCast(&range),
            1,
            &family_arr,
            1,
            null,
            null,
            null,
            1.0,
        );
        if (hr < 0) com.fatalHr("AddMapping(codepoint-map)", hr);
    }

    // AddMapping takes a prioritized list of family names for a single Unicode
    // range, in order. Calling it once per family with the full range would
    // make only the first family ever match (DirectWrite picks the first
    // mapping whose range contains the codepoint, then walks its family list).
    // Layout: [style_primary?, regular_primary, user_fallbacks..., builtin...]
    const reserved_head: usize = 2; // style_primary + regular_primary slots
    var family_ptrs: [reserved_head + max_user_fallbacks + font_fallback_families.len]?*const u16 = undefined;
    var n: usize = 0;
    if (style_primary) |sp| {
        // Best-effort alias dedup: skip the slot only when the caller forwarded
        // the SAME pointer for both, which is how an unset style winds up here.
        // A user writing the same family TWICE (e.g. `font-family-bold = X`
        // matching the regular `font-family = X`) yields distinct allocations
        // and would NOT dedup — that's acceptable; DirectWrite just walks the
        // family twice. String compare would be more thorough but not worth
        // the cost for this corner.
        if (@intFromPtr(sp) != @intFromPtr(regular_primary)) {
            family_ptrs[n] = @ptrCast(sp);
            n += 1;
        }
    }
    family_ptrs[n] = @ptrCast(regular_primary);
    n += 1;

    const user_n = @min(user_fallbacks.len, max_user_fallbacks);
    if (user_fallbacks.len > max_user_fallbacks) {
        std.log.warn("config: dropping {d} extra font-family fallback(s) past cap {d}", .{
            user_fallbacks.len - max_user_fallbacks,
            max_user_fallbacks,
        });
    }
    for (user_fallbacks[0..user_n]) |family| {
        family_ptrs[n] = @ptrCast(family);
        n += 1;
    }
    for (font_fallback_families) |family| {
        family_ptrs[n] = @ptrCast(family);
        n += 1;
    }
    const full_range = win32.DWRITE_UNICODE_RANGE{ .first = 0, .last = 0x10FFFF };
    {
        const hr = builder.AddMapping(
            @ptrCast(&full_range),
            1,
            &family_ptrs,
            @intCast(n),
            null,
            null,
            null,
            1.0,
        );
        if (hr < 0) com.fatalHr("AddMapping", hr);
    }

    // Chain the system fallback so codepoints not covered above still resolve.
    {
        var system_fallback: *win32.IDWriteFontFallback = undefined;
        const hr = factory.GetSystemFontFallback(&system_fallback);
        if (hr < 0) com.fatalHr("GetSystemFontFallback", hr);
        defer _ = system_fallback.IUnknown.Release();
        const ahr = builder.AddMappings(system_fallback);
        if (ahr < 0) com.fatalHr("AddMappings", ahr);
    }

    var fallback: *win32.IDWriteFontFallback = undefined;
    {
        const hr = builder.CreateFontFallback(&fallback);
        if (hr < 0) com.fatalHr("CreateFontFallback", hr);
    }
    return fallback;
}
