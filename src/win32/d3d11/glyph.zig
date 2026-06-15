//! Per-frame atlas setup and glyph rasterization. Methods take the parent
//! `D3d11Renderer` because they touch many of its fields (cell size, atlas
//! texture, staging textures, glyph cache, DirectWrite + D2D factories).

const std = @import("std");
const win32 = @import("win32").everything;
const com = @import("com.zig");
const gpu = @import("gpu.zig");
const emoji = @import("emoji.zig");
const sprite = @import("../sprite.zig");
const GlyphIndexCache = @import("../GlyphIndexCache.zig");
const font = @import("font.zig");

const D3d11Renderer = @import("../d3d11.zig");
const CellXY = gpu.CellXY;

// Frame-invariant glyph atlas setup. Call once per render() so the
// per-cell generateGlyph path does only the cache lookup + miss work.
// Recreates the cache if the cell size changed or the atlas texture
// was reallocated.
pub fn setupGlyphAtlas(self: *D3d11Renderer) gpu.AtlasFrame {
    const cs = self.cell_size_xy;
    const tex_cell_count = gpu.getTextureMaxCellCount(cs);
    const tex_total: u32 = @as(u32, tex_cell_count.x) * @as(u32, tex_cell_count.y);

    const tex_pixel: CellXY = .{
        .x = tex_cell_count.x * cs.x,
        .y = tex_cell_count.y * cs.y,
    };
    const tex_retained = self.glyph_texture.updateSize(self.device, tex_pixel);

    const cache_valid = if (self.glyph_cache_cell_size) |s| s.eql(cs) else false;
    self.glyph_cache_cell_size = cs;

    if (!tex_retained or !cache_valid) {
        if (self.glyph_cache) |*c| {
            c.deinit(self.glyph_cache_arena.allocator());
            _ = self.glyph_cache_arena.reset(.retain_capacity);
            self.glyph_cache = null;
        }
        // Glyph cache reset → atlas slot assignments will change; any
        // already-baked grid texture pixels referencing the old slots are
        // stale. Force a full grid redraw next render to be safe even
        // though current callers (font/DPI reload, tex-size change) also
        // perturb the GridConfigSnapshot. Maintains the design invariant:
        // every glyph_cache reset path sets grid_force_full.
        self.grid_force_full = true;
    }

    if (self.glyph_cache == null) {
        self.glyph_cache = GlyphIndexCache.init(
            self.glyph_cache_arena.allocator(),
            tex_total,
        ) catch com.oom(error.OutOfMemory);
    }

    const cache = &self.glyph_cache.?;
    cache.beginFrame();
    return .{ .cache = cache, .tex_cell_count = tex_cell_count };
}

pub fn generateGlyph(
    self: *D3d11Renderer,
    cache: *GlyphIndexCache,
    tex_cell_count: CellXY,
    codepoint: u21,
    grapheme: []const u21,
    half: GlyphIndexCache.Half,
    style: GlyphIndexCache.Style,
) u32 {
    const cs = self.cell_size_xy;
    const key = GlyphIndexCache.Key.init(codepoint, grapheme, half, style);

    switch (cache.reserve(self.glyph_cache_arena.allocator(), key) catch com.oom(error.OutOfMemory)) {
        .newly_reserved => |reserved| {
            const pos = gpu.cellPosFromIndex(reserved.index, tex_cell_count.x);
            const coord: CellXY = .{ .x = cs.x * pos.x, .y = cs.y * pos.y };

            // Sprite fast path: tile-design codepoints (Block Elements, Box
            // Drawing, Braille, Powerline, Geometric Shapes, Legacy Computing)
            // are rendered procedurally by ghostty's sprite drawing code so
            // they tile seamlessly regardless of the font's natural advance.
            // Block elements out of a font would get squashed by the narrow-
            // Latin cell width and break Claude Code's block-art logo.
            //
            // Render failures must NOT silently return — the reserved atlas
            // slot would otherwise display stale pixels from the evicted
            // glyph. OOM is fatal; any other error falls through to the
            // DirectWrite path so we render *something* into the slot.
            sprite_path: {
                if (grapheme.len != 0 or !sprite.hasCodepoint(codepoint)) break :sprite_path;
                uploadSpriteToAtlas(self, codepoint, half, coord) catch |err| switch (err) {
                    error.OutOfMemory => com.oom(error.OutOfMemory),
                    else => {
                        std.log.warn("sprite render U+{X} failed ({s}); falling back to DirectWrite", .{ codepoint, @errorName(err) });
                        break :sprite_path;
                    },
                };
                return reserved.index;
            }

            const staging = renderGlyphToStaging(self, codepoint, grapheme, style, half != .single);
            const src_left: u32 = if (half == .wide_right) cs.x else 0;
            copyStagingHalfToAtlas(self, staging, src_left, coord);
            return reserved.index;
        },
        .already_reserved => |index| return index,
    }
}

// Reserve and populate both halves of a wide glyph using a single raster.
// Calling generateGlyph separately for wide_left / wide_right would run the
// underlying renderer (DirectWrite CreateTextLayout+DrawTextLayout, or
// sprite.render) twice with identical pixels — only the half copied out
// differs. One render + up-to-two copies cuts the first-paint cost for CJK,
// emoji, and sprite wide tiles when either half is uncached.
pub fn generateWidePair(
    self: *D3d11Renderer,
    cache: *GlyphIndexCache,
    tex_cell_count: CellXY,
    codepoint: u21,
    grapheme: []const u21,
    style: GlyphIndexCache.Style,
) struct { left: u32, right: u32 } {
    const cs = self.cell_size_xy;
    const arena = self.glyph_cache_arena.allocator();
    // Reserve left first. The unconditional `cache.touch(left_index)` below
    // is load-bearing: `reserve`'s per-frame dampening can skip moveToBack
    // for a hit whose slot was already promoted earlier this frame, so left
    // may sit near the LRU front. Without the touch, the upcoming right
    // reserve's miss path would evict `self.front` and could clobber left's
    // own slot, leaving left_index pointing at right's pixels.
    const left_res = cache.reserve(arena, .init(codepoint, grapheme, .wide_left, style)) catch com.oom(error.OutOfMemory);
    const left_index = switch (left_res) {
        .newly_reserved => |r| r.index,
        .already_reserved => |idx| idx,
    };
    const left_miss = switch (left_res) {
        .newly_reserved => true,
        .already_reserved => false,
    };
    cache.touch(left_index);

    const right_res = cache.reserve(arena, .init(codepoint, grapheme, .wide_right, style)) catch com.oom(error.OutOfMemory);
    const right_index = switch (right_res) {
        .newly_reserved => |r| r.index,
        .already_reserved => |idx| idx,
    };
    const right_miss = switch (right_res) {
        .newly_reserved => true,
        .already_reserved => false,
    };

    if (!left_miss and !right_miss) return .{ .left = left_index, .right = right_index };

    // Sprite fast path: render the full 2*cs.x tile once, upload missing
    // halves. Failure modes mirror generateGlyph: OOM fatal, other errors
    // fall through to DirectWrite so the reserved slots still receive
    // pixels (otherwise stale evictee bytes would show).
    if (grapheme.len == 0 and sprite.hasCodepoint(codepoint)) {
        const left_arg: ?u32 = if (left_miss) left_index else null;
        const right_arg: ?u32 = if (right_miss) right_index else null;
        uploadSpriteWidePairToAtlas(self, codepoint, tex_cell_count, left_arg, right_arg) catch |err| switch (err) {
            error.OutOfMemory => com.oom(error.OutOfMemory),
            else => {
                std.log.warn("sprite render U+{X} failed ({s}); falling back to DirectWrite", .{ codepoint, @errorName(err) });
                const staging = renderGlyphToStaging(self, codepoint, grapheme, style, true);
                if (left_miss) {
                    const pos = gpu.cellPosFromIndex(left_index, tex_cell_count.x);
                    copyStagingHalfToAtlas(self, staging, 0, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
                }
                if (right_miss) {
                    const pos = gpu.cellPosFromIndex(right_index, tex_cell_count.x);
                    copyStagingHalfToAtlas(self, staging, cs.x, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
                }
            },
        };
        return .{ .left = left_index, .right = right_index };
    }

    const staging = renderGlyphToStaging(self, codepoint, grapheme, style, true);
    if (left_miss) {
        const pos = gpu.cellPosFromIndex(left_index, tex_cell_count.x);
        copyStagingHalfToAtlas(self, staging, 0, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }
    if (right_miss) {
        const pos = gpu.cellPosFromIndex(right_index, tex_cell_count.x);
        copyStagingHalfToAtlas(self, staging, cs.x, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }

    return .{ .left = left_index, .right = right_index };
}

// Render `codepoint` into the staging texture. The staging is always 2 cells
// wide; single glyphs occupy [0, cs.x), wide glyphs occupy the full width.
// Returns the staging so the caller can copy the half(ves) it needs.
fn renderGlyphToStaging(
    self: *D3d11Renderer,
    codepoint: u21,
    grapheme: []const u21,
    style: GlyphIndexCache.Style,
    is_wide: bool,
) *gpu.StagingTexture.Cached {
    const cs = self.cell_size_xy;
    const staging_size: CellXY = .{ .x = cs.x * 2, .y = cs.y };
    const is_color_glyph = emoji.isColorGlyphRun(codepoint, grapheme);
    const staging = self.staging_texture.getOrCreate(
        self.device,
        self.d2d_factory,
        staging_size,
        if (is_color_glyph) .color else .mask,
    );

    // Typical grapheme runs fit in a handful of u16s; only ZWJ-heavy
    // sequences (e.g. family-emoji) approach a dozen. Page-allocator per
    // cache miss was burning a 4 KB page for ~24 bytes; the stack path
    // covers the realistic worst case, and the heap fallback keeps the
    // contract for pathological inputs.
    const utf16_len_max = (1 + grapheme.len) * 2;
    var utf16_stack: [64]u16 = undefined;
    var utf16_heap: ?[]u16 = null;
    defer if (utf16_heap) |buf| std.heap.page_allocator.free(buf);
    const utf16_buf: []u16 = if (utf16_len_max <= utf16_stack.len)
        utf16_stack[0..utf16_len_max]
    else blk: {
        const buf = std.heap.page_allocator.alloc(u16, utf16_len_max) catch com.oom(error.OutOfMemory);
        utf16_heap = buf;
        break :blk buf;
    };
    const utf16_len = emoji.encodeUtf16Run(utf16_buf, codepoint, grapheme);

    const target_width: f32 = @floatFromInt(
        if (is_wide) cs.x * @as(u16, 2) else cs.x,
    );
    const cs_y_f: f32 = @floatFromInt(cs.y);

    // Ambiguous EAW symbols (● ✶ ★ etc. outside the sprite range) render in
    // a single cell with ink-bounds best-fit + center alignment + center-
    // anchored uniform scale. This produces round (not squashed) symbols of
    // consistent size within a row, matching WezTerm's per-cell layout where
    // every ● looks the same regardless of what surrounds it.
    const is_ambiguous_symbol = sprite.isAmbiguousOverflow(codepoint);

    // IDWriteTextLayout lets us measure the rendered ink before drawing.
    // Style index picks bold / italic / bold-italic text formats; these
    // share the regular family today and differ only by synthetic
    // weight/oblique applied by DirectWrite.
    const text_format = self.text_formats[@intFromEnum(style)];
    var layout: *win32.IDWriteTextLayout = undefined;
    {
        const hr = self.dwrite_factory.IDWriteFactory.CreateTextLayout(
            @ptrCast(utf16_buf[0..utf16_len].ptr),
            @intCast(utf16_len),
            text_format,
            target_width,
            cs_y_f,
            &layout,
        );
        if (hr < 0) com.fatalHr("CreateTextLayout", hr);
    }
    defer _ = layout.IUnknown.Release();

    if (emoji.shouldForceEmojiFont(codepoint, grapheme)) {
        const range = win32.DWRITE_TEXT_RANGE{
            .startPosition = 0,
            .length = @intCast(utf16_len),
        };
        const hr = layout.SetFontFamilyName(font.emoji_font_family, range);
        if (hr < 0) com.fatalHr("SetFontFamilyName(emoji)", hr);
    }

    // For ambiguous symbols, center the glyph in its single cell so the
    // center-anchored scale transform expands uniformly around the cell
    // centre. Alignment must be set BEFORE measuring so the overhang values
    // reflect the centered layout.
    if (is_ambiguous_symbol) {
        const ahr = layout.IDWriteTextFormat.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
        if (ahr < 0) com.fatalHr("SetTextAlignment", ahr);
        const pahr = layout.IDWriteTextFormat.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        if (pahr < 0) com.fatalHr("SetParagraphAlignment", pahr);
    }

    var m: win32.DWRITE_TEXT_METRICS = undefined;
    {
        const hr = layout.GetMetrics(&m);
        if (hr < 0) com.fatalHr("GetMetrics", hr);
    }
    var oh: win32.DWRITE_OVERHANG_METRICS = undefined;
    {
        const hr = layout.GetOverhangMetrics(&oh);
        if (hr < 0) com.fatalHr("GetOverhangMetrics", hr);
    }

    // Two scale policies share the rendering setup below:
    //
    //   * Non-ambiguous (CJK real wide, Latin, fallback narrow glyphs
    //     in a single cell): only scale DOWN when natural advance
    //     exceeds the target cell width. fit_width captures advance +
    //     right ink overhang so CLIP doesn't chop overhanging strokes.
    //
    //   * Ambiguous symbols (●✶★ etc.): ink-box best-fit within the
    //     single cell, allow scale > 1 to enlarge narrow naturals so
    //     the glyph fills the cell instead of sitting tiny and
    //     left-aligned. Cap at SCALE_CAP = 2.0 so a 1-pixel glyph
    //     can't blow up into a giant blur.
    const SCALE_CAP: f32 = 2.0;
    const content_right = m.left + @max(m.width, m.widthIncludingTrailingWhitespace);
    const overhang_right = m.layoutWidth + @max(0.0, oh.right);
    const fit_width = @max(content_right, overhang_right);

    // Ink bounds via raw (signed) overhangs against the layout box;
    // negative overhang = ink inset from box edge. Same formula works
    // for LEFT and CENTER alignment because overhangs adjust to the
    // text's position within the box.
    const ink_w = m.layoutWidth + oh.left + oh.right;
    const ink_h = m.layoutHeight + oh.top + oh.bottom;
    const ink_ok = ink_w > 0 and ink_h > 0 and std.math.isFinite(ink_w) and std.math.isFinite(ink_h);

    const raw_scale: f32 = if (is_ambiguous_symbol) blk: {
        if (!ink_ok) break :blk 1.0;
        const sw = target_width / ink_w;
        const sh = cs_y_f / ink_h;
        break :blk @min(@min(sw, sh), SCALE_CAP);
    } else if (fit_width > target_width and fit_width > 0)
        target_width / fit_width
    else
        1.0;
    // Snap near-unity to 1.0 to skip a no-op transform.
    const need_scale = @abs(raw_scale - 1.0) > 0.001;
    const scale: f32 = if (need_scale) raw_scale else 1.0;

    if (need_scale and !is_ambiguous_symbol) {
        // Non-ambiguous scale-down path: expand the layout box so the
        // CLIP boundary == fit_width pre-scale, becoming target_width
        // post-scale. Ambiguous-symbol path leaves the layout box at
        // the original target_width because center alignment + center
        // anchor handle positioning without box expansion.
        const hr = layout.SetMaxWidth(fit_width);
        if (hr < 0) com.fatalHr("SetMaxWidth", hr);
    }

    // Invariant: every render starts from identity transform & CLEARTYPE.
    // The staging RT is reused across cache misses, so leaking state
    // between calls would corrupt subsequent glyphs.
    const identity: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
        .m11 = 1,
        .m12 = 0,
        .m21 = 0,
        .m22 = 1,
        .dx = 0,
        .dy = 0,
    } } };
    staging.render_target.SetTransform(&identity);
    if (!is_color_glyph) staging.render_target.SetTextRenderingParams(self.rendering_params);
    staging.render_target.SetTextAntialiasMode(if (is_color_glyph) .GRAYSCALE else .CLEARTYPE);
    staging.render_target.BeginDraw();
    {
        // Mask glyphs are white-on-opaque-black so RGB stores coverage.
        // Color glyphs need transparent premultiplied staging so RGBA stores
        // the actual emoji bitmap for shader-side composition.
        const color: win32.D2D_COLOR_F = if (is_color_glyph)
            .{ .r = 0, .g = 0, .b = 0, .a = 0 }
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 1 };
        staging.render_target.Clear(&color);
    }

    if (need_scale and !is_color_glyph) {
        // ClearType subpixel hinting assumes 1:1 horizontal mapping;
        // any fractional scale would produce colored fringes. Grayscale
        // antialiasing has no subpixel directionality.
        staging.render_target.SetTextAntialiasMode(.GRAYSCALE);

        // Three anchor strategies, chosen by glyph context:
        //   ambiguous symbol  → center anchor (cell centre stays fixed
        //     so round shapes like ● stay visually centered)
        //   single, non-ambiguous → horizontal-only (m22 = 1, dy = 0)
        //     preserves vertical fill so non-sprite tile-design glyphs
        //     (rare math / line-drawing chars outside the sprite face)
        //     still touch the top and bottom of the cell.
        //   wide, non-ambiguous → uniform + baseline anchor (CJK /
        //     emoji) so the scaled glyph shares a baseline with
        //     un-scaled Latin in adjacent cells.
        const scale_mat: win32.D2D_MATRIX_3X2_F = if (is_ambiguous_symbol) blk: {
            const cx = target_width / 2.0;
            const cy = cs_y_f / 2.0;
            break :blk .{ .Anonymous = .{ .Anonymous1 = .{
                .m11 = scale,
                .m12 = 0,
                .m21 = 0,
                .m22 = scale,
                .dx = cx * (1.0 - scale),
                .dy = cy * (1.0 - scale),
            } } };
        } else if (!is_wide) .{
            .Anonymous = .{ .Anonymous1 = .{
                .m11 = scale,
                .m12 = 0,
                .m21 = 0,
                .m22 = 1,
                .dx = 0,
                .dy = 0,
            } },
        } else blk: {
            var lm: [1]win32.DWRITE_LINE_METRICS = undefined;
            var line_count: u32 = 0;
            const lhr = layout.GetLineMetrics(&lm, 1, &line_count);
            if (lhr < 0) com.fatalHr("GetLineMetrics", lhr);
            const baseline: f32 = if (line_count >= 1) lm[0].baseline else 0;
            break :blk .{ .Anonymous = .{ .Anonymous1 = .{
                .m11 = scale,
                .m12 = 0,
                .m21 = 0,
                .m22 = scale,
                .dx = 0,
                .dy = baseline * (1.0 - scale),
            } } };
        };
        staging.render_target.SetTransform(&scale_mat);
    }

    // CLIP boundary semantics:
    //   non-ambiguous → CLIP at the (expanded) layout box, which the
    //                   scale-down transform shrinks back to target_w.
    //   ambiguous     → no CLIP. With scale > 1 + center alignment
    //                   the scaled ink may briefly extend past the
    //                   layout box; the staging texture acts as the
    //                   natural drawing bound.
    const draw_options: win32.D2D1_DRAW_TEXT_OPTIONS = if (is_ambiguous_symbol)
        .{} // no options
    else
        win32.D2D1_DRAW_TEXT_OPTIONS_CLIP;
    var color_draw_options = draw_options;
    if (is_color_glyph) color_draw_options.ENABLE_COLOR_FONT = 1;
    staging.render_target.DrawTextLayout(
        .{ .x = 0, .y = 0 },
        layout,
        &staging.white_brush.ID2D1Brush,
        color_draw_options,
    );

    // Reset before EndDraw so the next cache-miss starts clean.
    staging.render_target.SetTransform(&identity);
    if (need_scale and !is_color_glyph) staging.render_target.SetTextAntialiasMode(.CLEARTYPE);

    var tag1: u64 = undefined;
    var tag2: u64 = undefined;
    const ehr = staging.render_target.EndDraw(&tag1, &tag2);
    if (ehr < 0) com.fatalHr("EndDraw", ehr);

    return staging;
}

fn copyStagingHalfToAtlas(
    self: *D3d11Renderer,
    staging: *gpu.StagingTexture.Cached,
    src_left: u32,
    dst_coord: CellXY,
) void {
    const cs = self.cell_size_xy;
    const box: win32.D3D11_BOX = .{
        .left = src_left,
        .top = 0,
        .front = 0,
        .right = src_left + cs.x,
        .bottom = cs.y,
        .back = 1,
    };
    self.context.CopySubresourceRegion(
        &self.glyph_texture.obj.?.ID3D11Resource,
        0,
        dst_coord.x,
        dst_coord.y,
        0,
        &staging.texture.ID3D11Resource,
        0,
        &box,
    );
}

// Render a sprite (Block Elements / Box Drawing / Braille / Powerline /
// Geometric Shapes / Legacy Computing) into a CPU BGRA buffer, then copy
// the half indicated by `key.half` directly into the atlas slot at `coord`.
//
// Wide sprites are rasterized full-width (2*cs.x) once and the appropriate
// half is uploaded; matches the same .wide_left / .wide_right split used by
// the DirectWrite path.
fn uploadSpriteToAtlas(
    self: *D3d11Renderer,
    codepoint: u21,
    half: GlyphIndexCache.Half,
    coord: CellXY,
) !void {
    const cs = self.cell_size_xy;
    const sprite_cell_w: u32 = if (half != .single) @as(u32, cs.x) * 2 else cs.x;
    const sprite_cell_h: u32 = cs.y;

    var scratch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const arena_alloc = scratch_arena.allocator();

    const scratch = try arena_alloc.alloc(u8, sprite_cell_w * sprite_cell_h * 4);
    const metrics = sprite.buildMetrics(sprite_cell_w, sprite_cell_h);
    // Errors propagate so the dispatch site can fall back to DirectWrite for
    // any non-OOM failure. hasCodepoint already gated entry, so a false
    // return from render would mean ranges/dispatch disagree — unreachable.
    const rendered = try sprite.render(arena_alloc, codepoint, sprite_cell_w, sprite_cell_h, metrics, scratch);
    std.debug.assert(rendered);

    // Pick the half-cell slice of the scratch buffer that corresponds to
    // this atlas slot. The source row pitch stays sprite_cell_w*4 so
    // UpdateSubresource walks the full row and only copies cs.x*4 bytes per
    // row starting at the offset we pass via src pointer arithmetic.
    const src_offset_x: u32 = if (half == .wide_right) cs.x else 0;
    const src_row_pitch: u32 = sprite_cell_w * 4;
    const src_ptr: [*]const u8 = scratch.ptr + (src_offset_x * 4);

    const dst_box: win32.D3D11_BOX = .{
        .left = coord.x,
        .top = coord.y,
        .front = 0,
        .right = coord.x + cs.x,
        .bottom = coord.y + cs.y,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.glyph_texture.obj.?.ID3D11Resource,
        0,
        &dst_box,
        @ptrCast(src_ptr),
        src_row_pitch,
        0,
    );
}

// Wide-pair sprite upload: rasterize the full 2*cs.x tile once into scratch,
// then upload one or both halves to the atlas slots identified by
// left_cell_index / right_cell_index. Either may be null to skip that half
// (cache-hit case). Mirrors uploadSpriteToAtlas's allocator + error contract:
// OOM propagates as OutOfMemory; other sprite.render failures propagate so
// the caller can fall back to DirectWrite without leaving stale slot pixels.
fn uploadSpriteWidePairToAtlas(
    self: *D3d11Renderer,
    codepoint: u21,
    tex_cell_count: CellXY,
    left_cell_index: ?u32,
    right_cell_index: ?u32,
) !void {
    std.debug.assert(left_cell_index != null or right_cell_index != null);
    const cs = self.cell_size_xy;
    const sprite_cell_w: u32 = @as(u32, cs.x) * 2;
    const sprite_cell_h: u32 = cs.y;

    var scratch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const arena_alloc = scratch_arena.allocator();

    const scratch = try arena_alloc.alloc(u8, sprite_cell_w * sprite_cell_h * 4);
    const metrics = sprite.buildMetrics(sprite_cell_w, sprite_cell_h);
    const rendered = try sprite.render(arena_alloc, codepoint, sprite_cell_w, sprite_cell_h, metrics, scratch);
    std.debug.assert(rendered);

    const src_row_pitch: u32 = sprite_cell_w * 4;
    if (left_cell_index) |idx| {
        const pos = gpu.cellPosFromIndex(idx, tex_cell_count.x);
        uploadAtlasHalfFromScratch(self, scratch.ptr, src_row_pitch, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }
    if (right_cell_index) |idx| {
        const pos = gpu.cellPosFromIndex(idx, tex_cell_count.x);
        const src_ptr: [*]const u8 = scratch.ptr + (@as(u32, cs.x) * 4);
        uploadAtlasHalfFromScratch(self, src_ptr, src_row_pitch, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }
}

fn uploadAtlasHalfFromScratch(
    self: *D3d11Renderer,
    src_ptr: [*]const u8,
    src_row_pitch: u32,
    dst_coord: CellXY,
) void {
    const cs = self.cell_size_xy;
    const dst_box: win32.D3D11_BOX = .{
        .left = dst_coord.x,
        .top = dst_coord.y,
        .front = 0,
        .right = dst_coord.x + cs.x,
        .bottom = dst_coord.y + cs.y,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.glyph_texture.obj.?.ID3D11Resource,
        0,
        &dst_box,
        @ptrCast(src_ptr),
        src_row_pitch,
        0,
    );
}

// Ordinal MUST match GlyphIndexCache.Style. Kept here (not in
// GlyphIndexCache) because flags->style is a renderer-layer mapping, while
// the enum itself is a pure cache-key concern.
pub fn styleFromFlags(bold: bool, italic: bool) GlyphIndexCache.Style {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}
