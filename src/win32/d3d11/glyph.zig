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
const glyph_worker = @import("glyph_worker.zig");

const D3d11Renderer = @import("../d3d11.zig");
const CellXY = gpu.CellXY;
pub const max_ligature_run_cells = glyph_worker.max_run_cells;

pub const RunGlyphs = struct {
    glyphs: [max_ligature_run_cells]u32,
    len: u8,
};

const RunPending = struct {
    index: u32,
    slot_gen: u32,
    key: GlyphIndexCache.Key,
    offset: u8,
};

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
        // Bump BEFORE deinit so any in-flight raster results targeting the
        // old atlas slots are rejected by applyGlyphResult's cache_gen guard
        // — even if the new cache happens to reuse the same slot index for
        // a different key.
        self.cache_gen +%= 1;
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
    const arena = self.glyph_cache_arena.allocator();

    // U+0020 single regular IS the placeholder returned for in-flight rasters
    // of other glyphs. It must reach the atlas synchronously — going through
    // the async worker would mean "we don't have a placeholder yet because
    // we ARE the placeholder still being computed". One sync raster per
    // cache lifetime; after that it's a pure cache hit.
    const is_blank = codepoint == ' ' and grapheme.len == 0 and half == .single and style == .regular;

    switch (cache.reserve(arena, key) catch com.oom(error.OutOfMemory)) {
        .ready => |idx| return idx,
        .already_pending => {
            if (is_blank) {
                // Unreachable in practice: the .newly_reserved_pending branch
                // below sync-rasters + markReady for the blank glyph before
                // returning, so the next reserve of ' ' hits .ready.
                std.debug.assert(false);
                return 0;
            }
            return blankGlyphSlot(self, cache, tex_cell_count);
        },
        .no_slot => {
            if (is_blank) {
                // Cache fully saturated with pendings on the very first frame
                // before the blank glyph could land. The renderer's other
                // codepaths can't proceed without a blank slot; bail to slot 0
                // and let next frame's drained queue try again.
                return 0;
            }
            return blankGlyphSlot(self, cache, tex_cell_count);
        },
        .newly_reserved_pending => |reserved| {
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
                std.debug.assert(cache.markReady(reserved.index, reserved.slot_gen, key));
                return reserved.index;
            }

            // Sync DirectWrite path for: (1) the placeholder glyph itself
            // (`is_blank`), to break the chicken-and-egg with the async
            // placeholder strategy; (2) any glyph at all when the raster
            // worker failed to spawn, so the renderer still produces
            // correct pixels (just on the UI thread, like pre-Stage-C).
            if (is_blank or !self.glyph_worker_started) {
                const staging = renderGlyphToStaging(self, codepoint, grapheme, style, false);
                copyStagingHalfToAtlas(self, staging, 0, coord);
                std.debug.assert(cache.markReady(reserved.index, reserved.slot_gen, key));
                return reserved.index;
            }

            if (submitRasterJob(self, key, codepoint, grapheme, reserved.index, reserved.slot_gen, style)) {
                return blankGlyphSlot(self, cache, tex_cell_count);
            }
            // Queue rejected (worker saturated): roll back the slot and
            // placeholder. Next frame's row diff retries this codepoint —
            // if the queue has drained by then the raster lands a frame later.
            cache.unreserve(reserved.index, reserved.slot_gen);
            return blankGlyphSlot(self, cache, tex_cell_count);
        },
    }
}

fn blankGlyphSlot(self: *D3d11Renderer, cache: *GlyphIndexCache, tex_cell_count: CellXY) u32 {
    return generateGlyph(self, cache, tex_cell_count, ' ', &.{}, .single, .regular);
}

// Build a heap-owned RasterJob and hand it to the worker. AddRefs the COM
// objects the worker needs (the worker Releases them after the raster, or in
// `RasterJob.destroy` if the queue rejects); dupes the grapheme onto the
// worker's gpa so it survives the UI-thread arena reset.
fn submitRasterJob(
    self: *D3d11Renderer,
    key: GlyphIndexCache.Key,
    codepoint: u21,
    grapheme: []const u21,
    slot: u32,
    slot_gen: u32,
    style: GlyphIndexCache.Style,
) bool {
    const gpa = self.glyph_worker.gpa;
    const job = gpa.create(glyph_worker.RasterJob) catch return false;
    const grapheme_dup: []u21 = if (grapheme.len == 0)
        &.{}
    else
        gpa.dupe(u21, grapheme) catch {
            gpa.destroy(job);
            return false;
        };
    const text_format = self.text_formats[@intFromEnum(style)];
    _ = text_format.IUnknown.AddRef();
    _ = self.rendering_params.IUnknown.AddRef();
    job.* = .{
        .key = key,
        .codepoint = codepoint,
        .grapheme = grapheme_dup,
        .run_text = &.{},
        .run_slot_count = 0,
        .is_wide = false,
        .is_color = emoji.isColorGlyphRun(codepoint, grapheme),
        .is_ambiguous = sprite.isAmbiguousOverflow(codepoint),
        .slot = slot,
        .slot_gen = slot_gen,
        .cache_gen = self.cache_gen,
        .cs = self.cell_size_xy,
        .text_format = text_format,
        .rendering_params = self.rendering_params,
    };
    if (!self.glyph_worker.submit(job)) {
        // submit() didn't consume the job — destroy locally. `destroy`
        // Releases the COM refs and frees the dupe, mirroring the worker's
        // own success-path cleanup.
        job.destroy(gpa);
        return false;
    }
    return true;
}

pub fn generateRun(
    self: *D3d11Renderer,
    cache: *GlyphIndexCache,
    tex_cell_count: CellXY,
    text: []const u8,
    style: GlyphIndexCache.Style,
) ?RunGlyphs {
    if (text.len < 2 or text.len > max_ligature_run_cells) return null;
    if (!self.glyph_worker_started) return null;

    const arena = self.glyph_cache_arena.allocator();
    const blank = blankGlyphSlot(self, cache, tex_cell_count);
    var out: RunGlyphs = .{
        .glyphs = undefined,
        .len = @intCast(text.len),
    };
    @memset(out.glyphs[0..text.len], blank);

    var pending: [max_ligature_run_cells]RunPending = undefined;
    var pending_count: usize = 0;
    var saw_new = false;

    for (text, 0..) |_, i| {
        const offset: u8 = @intCast(i);
        const key = GlyphIndexCache.Key.initRun(text, offset, style);
        const res = cache.reserve(arena, key) catch com.oom(error.OutOfMemory);
        switch (res) {
            .ready => |idx| out.glyphs[i] = idx,
            .already_pending => {},
            .newly_reserved_pending => |r| {
                saw_new = true;
                pending[pending_count] = .{
                    .index = r.index,
                    .slot_gen = r.slot_gen,
                    .key = key,
                    .offset = offset,
                };
                pending_count += 1;
            },
            .no_slot => {
                rollbackRunReservations(cache, pending[0..pending_count]);
                return null;
            },
        }
    }

    if (!saw_new) return out;

    if (submitRunRasterJob(self, text, style, pending[0..pending_count])) {
        return out;
    }
    rollbackRunReservations(cache, pending[0..pending_count]);
    return null;
}

fn rollbackRunReservations(cache: *GlyphIndexCache, pending: []const RunPending) void {
    var i = pending.len;
    while (i > 0) {
        i -= 1;
        cache.unreserve(pending[i].index, pending[i].slot_gen);
    }
}

fn submitRunRasterJob(
    self: *D3d11Renderer,
    text: []const u8,
    style: GlyphIndexCache.Style,
    pending: []const RunPending,
) bool {
    if (pending.len == 0 or pending.len > max_ligature_run_cells) return false;
    const gpa = self.glyph_worker.gpa;
    const job = gpa.create(glyph_worker.RasterJob) catch return false;
    const run_dup = gpa.dupe(u8, text) catch {
        gpa.destroy(job);
        return false;
    };

    const text_format = self.text_formats[@intFromEnum(style)];
    _ = text_format.IUnknown.AddRef();
    _ = self.rendering_params.IUnknown.AddRef();

    var run_slots: [max_ligature_run_cells]glyph_worker.RunSlot = undefined;
    for (pending, 0..) |p, i| {
        run_slots[i] = .{
            .offset = p.offset,
            .slot = p.index,
            .slot_gen = p.slot_gen,
            .key = p.key,
        };
    }

    job.* = .{
        .key = pending[0].key,
        .codepoint = 0,
        .grapheme = &.{},
        .run_text = run_dup,
        .run_slots = run_slots,
        .run_slot_count = @intCast(pending.len),
        .is_wide = false,
        .is_color = false,
        .is_ambiguous = false,
        .slot = pending[0].index,
        .slot_gen = pending[0].slot_gen,
        .cache_gen = self.cache_gen,
        .cs = self.cell_size_xy,
        .text_format = text_format,
        .rendering_params = self.rendering_params,
    };
    if (!self.glyph_worker.submit(job)) {
        job.destroy(gpa);
        return false;
    }
    return true;
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
    // Wide-pair stays fully synchronous: one DirectWrite raster fills both
    // halves, so there's no win to splitting them across the worker. The
    // touch + reserve dance below mirrors the pre-async version; with the
    // new state machine we additionally track `slot_gen` for each newly
    // reserved half so we can mark them ready after the synchronous raster
    // (otherwise the slots would stay pending forever and the LRU victim
    // search would skip them on the next miss).

    const Half = struct {
        index: u32,
        slot_gen: ?u32 = null, // present iff this half just transitioned to pending
    };

    const left_res = cache.reserve(arena, .init(codepoint, grapheme, .wide_left, style)) catch com.oom(error.OutOfMemory);
    const left: Half = switch (left_res) {
        .ready => |idx| .{ .index = idx },
        .newly_reserved_pending => |r| .{ .index = r.index, .slot_gen = r.slot_gen },
        // Pending wide_left is unreachable in Stage 1 (no async wide path),
        // but defend: the slot exists and its pixels will eventually arrive.
        .already_pending => |idx| .{ .index = idx },
        .no_slot => return .{
            .left = blankGlyphSlot(self, cache, tex_cell_count),
            .right = blankGlyphSlot(self, cache, tex_cell_count),
        },
    };
    // Force-promote the left slot. `reserve`'s per-frame dampening can leave a
    // hit near the LRU front, and the upcoming right-miss eviction would then
    // clobber left's own slot, leaving left_index pointing at right's pixels.
    cache.touch(left.index);

    const right_res = cache.reserve(arena, .init(codepoint, grapheme, .wide_right, style)) catch com.oom(error.OutOfMemory);
    const right: Half = switch (right_res) {
        .ready => |idx| .{ .index = idx },
        .newly_reserved_pending => |r| .{ .index = r.index, .slot_gen = r.slot_gen },
        .already_pending => |idx| .{ .index = idx },
        .no_slot => {
            // Left was already taken; if we leave it pending the slot
            // leaks forever (wide pair is sync, no async result will
            // arrive to mark it ready, and the LRU victim search will
            // keep skipping it). Roll left back to empty before bailing.
            if (left.slot_gen) |g| cache.unreserve(left.index, g);
            return .{
                .left = blankGlyphSlot(self, cache, tex_cell_count),
                .right = blankGlyphSlot(self, cache, tex_cell_count),
            };
        },
    };

    const left_miss = left.slot_gen != null;
    const right_miss = right.slot_gen != null;
    if (!left_miss and !right_miss) return .{ .left = left.index, .right = right.index };

    // Sprite fast path: render the full 2*cs.x tile once, upload missing
    // halves. Failure modes mirror generateGlyph: OOM fatal, other errors
    // fall through to DirectWrite so the reserved slots still receive
    // pixels (otherwise stale evictee bytes would show).
    if (grapheme.len == 0 and sprite.hasCodepoint(codepoint)) {
        const left_arg: ?u32 = if (left_miss) left.index else null;
        const right_arg: ?u32 = if (right_miss) right.index else null;
        uploadSpriteWidePairToAtlas(self, codepoint, tex_cell_count, left_arg, right_arg) catch |err| switch (err) {
            error.OutOfMemory => com.oom(error.OutOfMemory),
            else => {
                std.log.warn("sprite render U+{X} failed ({s}); falling back to DirectWrite", .{ codepoint, @errorName(err) });
                const staging = renderGlyphToStaging(self, codepoint, grapheme, style, true);
                if (left_miss) {
                    const pos = gpu.cellPosFromIndex(left.index, tex_cell_count.x);
                    copyStagingHalfToAtlas(self, staging, 0, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
                }
                if (right_miss) {
                    const pos = gpu.cellPosFromIndex(right.index, tex_cell_count.x);
                    copyStagingHalfToAtlas(self, staging, cs.x, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
                }
            },
        };
        markPairReady(cache, codepoint, grapheme, style, left, right);
        return .{ .left = left.index, .right = right.index };
    }

    const staging = renderGlyphToStaging(self, codepoint, grapheme, style, true);
    if (left_miss) {
        const pos = gpu.cellPosFromIndex(left.index, tex_cell_count.x);
        copyStagingHalfToAtlas(self, staging, 0, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }
    if (right_miss) {
        const pos = gpu.cellPosFromIndex(right.index, tex_cell_count.x);
        copyStagingHalfToAtlas(self, staging, cs.x, .{ .x = cs.x * pos.x, .y = cs.y * pos.y });
    }

    markPairReady(cache, codepoint, grapheme, style, left, right);
    return .{ .left = left.index, .right = right.index };
}

// Clear pending on the halves that we just synchronously rasterized. Halves
// that were already ready carry `slot_gen == null` and are skipped.
fn markPairReady(
    cache: *GlyphIndexCache,
    codepoint: u21,
    grapheme: []const u21,
    style: GlyphIndexCache.Style,
    left: anytype,
    right: anytype,
) void {
    if (left.slot_gen) |g| {
        const key: GlyphIndexCache.Key = .init(codepoint, grapheme, .wide_left, style);
        std.debug.assert(cache.markReady(left.index, g, key));
    }
    if (right.slot_gen) |g| {
        const key: GlyphIndexCache.Key = .init(codepoint, grapheme, .wide_right, style);
        std.debug.assert(cache.markReady(right.index, g, key));
    }
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
