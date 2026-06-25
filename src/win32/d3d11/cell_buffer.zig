//! Terminal → `shader.Cell` translation pipeline.
//!
//! Owns the per-frame loop that turns `vt.Terminal` state into one row of
//! `shader.Cell` at a time and uploads dirty rows to the GPU via the shadow
//! diff. Everything that produces a single cell (style/inverse/blink/wide,
//! URL hover highlight, selection lerp, cursor inversion, resize overlay)
//! is concentrated here — splitting these into separate "feature files"
//! would be shotgun surgery since they all converge on one `shader.Cell`.
//!
//! Also owns `shadow_cells` (the CPU shadow used for the per-row diff)
//! including its capacity policy.
//!
//! Output: a dirty-row range that the grid-RTV draw decision in `render()`
//! consumes to set the scissor rect; plus a `has_blink` flag the caller
//! uses to (re)arm `TIMER_TEXT_BLINK`.

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const vt = @import("vt");

const D3d11Renderer = @import("../d3d11.zig");
const types = @import("../types.zig");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const emoji = @import("emoji.zig");
const glyph_mod = @import("glyph.zig");
const com = @import("com.zig");
const sprite = @import("../sprite.zig");
const GlyphIndexCache = @import("../GlyphIndexCache.zig");

const shader = gpu.shader;
const Rgba8 = gpu.Rgba8;

// Defensive cap on per-frame columns. Sized to fit a stack `row_scratch`
// buffer below; `render.zig` already gates `total_cols` so this is just a
// localized safety net.
pub const max_shader_col: u32 = 4096;

// Only flip in Debug builds: release builds emit zero overhead, but
// renderer-side diagnostic counters always flush via `maybeLogDiag`.
const debug_stats_enabled = builtin.mode == .Debug;

const VisualCell = struct {
    codepoint: u21,
    grapheme: []const u21,
    bg: Rgba8,
    fg: Rgba8,
    attrs: u32,
    style_kind: GlyphIndexCache.Style,
    shape_candidate: bool,
};

const HighlightRange = struct { sx: u32, ex: u32 };
const SelRange = struct { sx: usize, ex: usize };

pub const BuildResult = struct {
    // Inclusive [min, max] over `screen_row` indices that produced an
    // UpdateSubresource this frame. null when no row changed — caller may
    // still need a full redraw if `grid_force_full` was set elsewhere.
    dirty_min_row: ?u32 = null,
    dirty_max_row: ?u32 = null,
    // True if at least one styled cell on screen has SGR blink. The caller
    // arms/cancels TIMER_TEXT_BLINK from this flag.
    has_blink: bool = false,
};

// Build the cell scratch row by row from terminal state and upload changed
// rows via the per-row shadow diff. The caller must have already:
//   * computed `shader_col`, `term_shader_row` from client size and metrics;
//   * called `glyph_mod.setupGlyphAtlas` and passed the result in;
//   * written the const buffer (this function does not touch it).
//
// On `cell_count == 0` the GPU buffer is still resized via
// `shader_cells.updateCount` so subsequent frames don't reuse stale
// allocations; the per-row loop is then skipped and an empty result is
// returned.
pub fn buildAndUpload(
    self: *D3d11Renderer,
    term: *vt.Terminal,
    shader_col: u32,
    term_shader_row: u32,
    tex_cell_count: gpu.CellXY,
    atlas: gpu.AtlasFrame,
    resizing: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
    url_highlight: ?types.UrlHighlight,
) BuildResult {
    const cell_count = shader_col * term_shader_row;
    const cells_recreated = self.shader_cells.updateCount(self.device, cell_count);
    if (cell_count == 0) return .{};

    const shadow_grown = ensureShadowCapacity(self, cell_count);
    // Resize overlay re-writes arbitrary rows after the main per-row
    // upload pass has already issued UpdateSubresource for them; rather
    // than backtracking, force-full when resizing so shadow == GPU at
    // the end of the main pass and the overlay sees a known state.
    const force_full = cells_recreated or shadow_grown or resizing;

    const glyph_cache = atlas.cache;
    const blank_glyph = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ' ', &.{}, .single, .regular);

    // Effective default fg/bg come from the terminal's dynamic colors
    // (seeded from the theme at tab creation, overridable live by OSC
    // 10/11), falling back to the module constants only if somehow unset.
    var eff_fg: u24 = if (term.colors.foreground.get()) |c| color.rgbToU24(c) else gpu.fallback_fg;
    var eff_bg: u24 = if (term.colors.background.get()) |c| color.rgbToU24(c) else gpu.fallback_bg;
    if (term.modes.get(.reverse_colors)) {
        const tmp = eff_fg;
        eff_fg = eff_bg;
        eff_bg = tmp;
    }
    const opacity_byte: u8 = @intFromFloat(@round(std.math.clamp(background_opacity, 0.0, 1.0) * 255.0));
    const bg_rgba: Rgba8 = .{
        .r = @intCast((eff_bg >> 16) & 0xFF),
        .g = @intCast((eff_bg >> 8) & 0xFF),
        .b = @intCast(eff_bg & 0xFF),
        .a = opacity_byte,
    };

    var result: BuildResult = .{};

    // Per-row CPU scratch; one row at a time stays in L1 while we both
    // build it and diff it against the shadow.
    var row_scratch: [max_shader_col]shader.Cell = undefined;
    const scratch = row_scratch[0..shader_col];
    const blank_cell: shader.Cell = .{
        .glyph_index = blank_glyph,
        .background = bg_rgba,
        .foreground = bg_rgba,
        .attrs = 0,
    };
    const blink_visible = @mod(@divFloor(std.time.milliTimestamp(), 500), 2) == 0;

    const screen = term.screens.active;
    const palette = &term.colors.palette.current;

    // Precompute selection bounds once per render. The per-cell loop used
    // to call `sel.contains` which walks the page linked list three times
    // per call (~36k traversals/frame at 200x60). The selection is
    // geometrically a contiguous range on each row, so we just need
    // top-left/bottom-right screen coords + the per-row x-range derived
    // from them (replicates the logic in vt.Selection.containedRowCached
    // without re-resolving pins).
    const SelBounds = struct {
        tl_y: usize,
        br_y: usize,
        tl_x: usize,
        br_x: usize,
        rectangle: bool,
        last_col: usize,
    };
    const sel_bounds: ?SelBounds = if (screen.selection) |sel| blk: {
        const tl_pin = sel.topLeft(screen);
        const br_pin = sel.bottomRight(screen);
        const tl = screen.pages.pointFromPin(.screen, tl_pin).?.screen;
        const br = screen.pages.pointFromPin(.screen, br_pin).?.screen;
        break :blk SelBounds{
            .tl_y = tl.y,
            .br_y = br.y,
            .tl_x = tl.x,
            .br_x = br.x,
            .rectangle = sel.rectangle,
            .last_col = screen.pages.cols - 1,
        };
    } else null;

    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var screen_row: u32 = 0;
    while (row_it.next()) |row_pin| {
        defer screen_row += 1;
        if (screen_row >= term_shader_row) break;

        const page = &row_pin.node.data;
        const page_cells = page.getCells(row_pin.rowAndCell().row);

        // URL hover underline range on this row (null if the row is outside
        // the URL's start..end span). Multi-row URLs cover full rows in the
        // middle and partial rows at the endpoints. Resolved once per row so
        // the cell loop only does two compares per cell.
        const url_row_range: ?HighlightRange = if (url_highlight) |u| blk_u: {
            if (screen_row < u.start_row or screen_row > u.end_row) break :blk_u null;
            const sx: u32 = if (screen_row == u.start_row) u.start_col else 0;
            const ex: u32 = if (screen_row == u.end_row) u.end_col else (shader_col - 1);
            break :blk_u HighlightRange{ .sx = sx, .ex = ex };
        } else null;

        // Per-row x-range of the selection. `null` when the row is outside
        // the selection entirely. One pointFromPin per row (~60 calls/frame)
        // instead of three per cell.
        const sel_row_range: ?SelRange = if (sel_bounds) |sb| range_blk: {
            const py = screen.pages.pointFromPin(.screen, row_pin).?.screen.y;
            if (py < sb.tl_y or py > sb.br_y) break :range_blk null;
            if (sb.rectangle) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.br_x };
            if (sb.tl_y == sb.br_y) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.br_x };
            if (py == sb.tl_y) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.last_col };
            if (py == sb.br_y) break :range_blk SelRange{ .sx = 0, .ex = sb.br_x };
            break :range_blk SelRange{ .sx = 0, .ex = sb.last_col };
        } else null;

        // Cursor inversion is applied inline (not in a separate post-pass)
        // so that wide CJK glyphs get BOTH halves flipped, not just the
        // left one.
        const cursor_visible = screen.viewportIsBottom() and term.modes.get(.cursor_visible);
        const cursor_on_row = cursor_visible and screen.cursor.y == screen_row;
        const cursor_bg_rgba = Rgba8.fromU24(if (term.colors.cursor.get()) |c| color.rgbToU24(c) else eff_fg);
        const cursor_fg_rgba = Rgba8.fromU24(cursor_text orelse eff_bg);

        var col: u32 = 0;
        var cell_i: usize = 0;
        while (cell_i < page_cells.len) {
            if (col >= shader_col) break;
            const cell = page_cells[cell_i];
            if (cell.wide == .spacer_tail) {
                // Already written by the .wide cell handler
                cell_i += 1;
                continue;
            }

            const visual = visualFromCell(
                self,
                page,
                page_cells,
                cell_i,
                col,
                eff_fg,
                eff_bg,
                bg_rgba,
                palette,
                blink_visible,
                url_row_range,
                sel_row_range,
                selection_bg,
                selection_fg,
                selection_fade,
                cursor_on_row,
                screen.cursor.x,
                cursor_bg_rgba,
                cursor_fg_rgba,
                &result,
            );

            if (cell.wide == .wide) {
                // One DirectWrite render for both halves; see generateWidePair.
                const pair = glyph_mod.generateWidePair(self, glyph_cache, tex_cell_count, visual.codepoint, visual.grapheme, visual.style_kind);
                scratch[col] = .{
                    .glyph_index = pair.left,
                    .background = visual.bg,
                    .foreground = visual.fg,
                    .attrs = visual.attrs,
                };
                col += 1;
                if (col < shader_col) {
                    scratch[col] = .{
                        .glyph_index = pair.right,
                        .background = visual.bg,
                        .foreground = visual.fg,
                        .attrs = visual.attrs,
                    };
                }
                col += 1;
                cell_i += 1;
                continue;
            }

            if (self.font_ligatures and visual.shape_candidate) {
                var run_text: [glyph_mod.max_ligature_run_cells]u8 = undefined;
                var run_visuals: [glyph_mod.max_ligature_run_cells]VisualCell = undefined;
                std.debug.assert(visual.codepoint <= std.math.maxInt(u8));
                run_text[0] = @intCast(visual.codepoint);
                run_visuals[0] = visual;
                var run_len: usize = 1;
                var j = cell_i + 1;
                var run_col = col + 1;
                while (j < page_cells.len and run_col < shader_col and run_len < glyph_mod.max_ligature_run_cells) {
                    const run_cell = page_cells[j];
                    if (run_cell.wide != .narrow) break;
                    const v = visualFromCell(
                        self,
                        page,
                        page_cells,
                        j,
                        run_col,
                        eff_fg,
                        eff_bg,
                        bg_rgba,
                        palette,
                        blink_visible,
                        url_row_range,
                        sel_row_range,
                        selection_bg,
                        selection_fg,
                        selection_fade,
                        cursor_on_row,
                        screen.cursor.x,
                        cursor_bg_rgba,
                        cursor_fg_rgba,
                        &result,
                    );
                    if (!v.shape_candidate or v.style_kind != visual.style_kind) break;
                    std.debug.assert(v.codepoint <= std.math.maxInt(u8));
                    run_text[run_len] = @intCast(v.codepoint);
                    run_visuals[run_len] = v;
                    run_len += 1;
                    j += 1;
                    run_col += 1;
                }
                if (run_len >= 2) {
                    if (glyph_mod.generateRun(self, glyph_cache, tex_cell_count, run_text[0..run_len], visual.style_kind)) |run| {
                        var k: usize = 0;
                        while (k < run_len) : (k += 1) {
                            scratch[col + @as(u32, @intCast(k))] = .{
                                .glyph_index = run.glyphs[k],
                                .background = run_visuals[k].bg,
                                .foreground = run_visuals[k].fg,
                                .attrs = run_visuals[k].attrs,
                            };
                        }
                        col += @intCast(run_len);
                        cell_i += run_len;
                        continue;
                    }
                }
            }

            // Space is ink-free, so its atlas slot is identical regardless
            // of bold/italic — reuse the per-frame blank_glyph instead of
            // hashing the cache for every interior space (prompt padding,
            // alignment gaps, bg_color_* cells which already normalize to
            // ' ' above). Trailing-blank and empty-row fills are handled by
            // the @memset paths below.
            const glyph_index = if (visual.codepoint == ' ' and visual.grapheme.len == 0)
                blank_glyph
            else
                glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, visual.codepoint, visual.grapheme, .single, visual.style_kind);
            scratch[col] = .{
                .glyph_index = glyph_index,
                .background = visual.bg,
                .foreground = visual.fg,
                .attrs = visual.attrs,
            };
            col += 1;
            cell_i += 1;
        }
        // Fill remaining columns with blanks
        if (col < shader_col) {
            @memset(scratch[col..shader_col], blank_cell);
        }

        const dst_row_offset = screen_row * shader_col;
        if (uploadCellRow(self, dst_row_offset, scratch, force_full)) {
            markDirty(&result, screen_row);
        }
    }
    // Fill remaining terminal rows with blanks. The row content is identical
    // across iterations so we build scratch once and let uploadCellRow's diff
    // skip any row whose shadow already matches.
    if (screen_row < term_shader_row) {
        @memset(scratch, blank_cell);
        while (screen_row < term_shader_row) : (screen_row += 1) {
            const dst_row_offset = screen_row * shader_col;
            if (uploadCellRow(self, dst_row_offset, scratch, force_full)) {
                markDirty(&result, screen_row);
            }
        }
    }

    // Resize overlay (e.g. "80x25") centered in the terminal region.
    // `force_full` above guarantees the shadow now mirrors GPU exactly, so
    // we can pull each overlaid row out of the shadow, apply the overlay
    // edits in-place, and re-upload — no need to recompute the row from
    // terminal state.
    if (resizing) {
        drawResizeOverlay(self, term, glyph_cache, tex_cell_count, shader_col, term_shader_row, scratch, &result);
    }

    return result;
}

fn visualFromCell(
    self: *D3d11Renderer,
    page: anytype,
    page_cells: anytype,
    cell_i: usize,
    col: u32,
    eff_fg: u24,
    eff_bg: u24,
    bg_rgba: Rgba8,
    palette: anytype,
    blink_visible: bool,
    url_row_range: ?HighlightRange,
    sel_row_range: ?SelRange,
    selection_bg: ?u24,
    selection_fg: ?u24,
    selection_fade: f32,
    cursor_on_row: bool,
    cursor_x: u32,
    cursor_bg_rgba: Rgba8,
    cursor_fg_rgba: Rgba8,
    result: *BuildResult,
) VisualCell {
    const cell = page_cells[cell_i];
    const raw_cp: u21 = switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.content.codepoint,
        .bg_color_palette, .bg_color_rgb => ' ',
    };
    const codepoint: u21 = if (raw_cp == 0) ' ' else raw_cp;
    const grapheme: []const u21 = if (cell.content_tag == .codepoint_grapheme)
        page.lookupGrapheme(&page_cells[cell_i]) orelse &.{}
    else
        &.{};

    var cell_fg: u24 = eff_fg;
    var cell_bg: u24 = eff_bg;
    var is_default_bg = true;
    var bold = false;
    var italic = false;
    var faint = false;
    var invisible = false;
    var attrs: u32 = 0;

    if (cell.style_id != 0) {
        const style = page.styles.get(page.memory, cell.style_id).*;
        cell_fg = color.resolveColor(style.fg_color, palette, eff_fg);
        cell_bg = color.resolveColor(style.bg_color, palette, eff_bg);
        bold = style.flags.bold;
        italic = style.flags.italic;
        faint = style.flags.faint;
        invisible = style.flags.invisible;
        if (style.flags.blink) {
            result.has_blink = true;
            if (!blink_visible) invisible = true;
        }
        attrs |= @as(u32, @intFromEnum(style.flags.underline)) & gpu.cell_attr_underline_mask;
        if (style.flags.strikethrough) attrs |= gpu.cell_attr_strikethrough;
        if (style.flags.overline) attrs |= gpu.cell_attr_overline;
        if (style.flags.inverse) {
            const tmp = cell_fg;
            cell_fg = cell_bg;
            cell_bg = tmp;
            is_default_bg = false;
        } else {
            is_default_bg = switch (style.bg_color) {
                .none => true,
                else => false,
            };
        }
    }

    switch (cell.content_tag) {
        .bg_color_palette => {
            cell_bg = color.rgbToU24(palette[cell.content.color_palette]);
            is_default_bg = false;
        },
        .bg_color_rgb => {
            const rgb = cell.content.color_rgb;
            cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
            is_default_bg = false;
        },
        else => {},
    }
    if (emoji.isColorGlyphRun(codepoint, grapheme)) attrs |= gpu.cell_attr_color_glyph;
    if (invisible) attrs |= gpu.cell_attr_invisible;

    if (url_row_range) |r| {
        if (col >= r.sx and col <= r.ex and (attrs & gpu.cell_attr_underline_mask) == 0) {
            attrs |= 1;
        }
    }

    var bg = if (is_default_bg) bg_rgba else Rgba8.fromU24(cell_bg);
    if (faint) cell_fg = color.dimColor(cell_fg);
    var fg = if (invisible) bg else Rgba8.fromU24(cell_fg);

    if (sel_row_range) |r| {
        if (col >= r.sx and col <= r.ex) {
            const orig_bg = bg;
            var target_bg = if (selection_bg) |s| Rgba8.fromU24(s) else fg;
            target_bg.a = 255;
            var target_fg = if (selection_fg) |s| Rgba8.fromU24(s) else orig_bg;
            target_fg.a = 255;
            bg = color.lerpRgba8(orig_bg, target_bg, selection_fade);
            fg = color.lerpRgba8(fg, target_fg, selection_fade);
        }
    }

    const cursor_hit = cursor_on_row and cursor_x == col;
    if (cursor_hit) {
        bg = cursor_bg_rgba;
        fg = cursor_fg_rgba;
    }

    const style_kind = self.effective_style[@intFromEnum(glyph_mod.styleFromFlags(bold, italic))];
    const shape_candidate = !cursor_hit and
        grapheme.len == 0 and
        (attrs & (gpu.cell_attr_color_glyph | gpu.cell_attr_invisible)) == 0 and
        isLigatureTrigger(codepoint) and
        !sprite.hasCodepoint(codepoint);

    return .{
        .codepoint = codepoint,
        .grapheme = grapheme,
        .bg = bg,
        .fg = fg,
        .attrs = attrs,
        .style_kind = style_kind,
        .shape_candidate = shape_candidate,
    };
}

fn isLigatureTrigger(cp: u21) bool {
    return switch (cp) {
        '=', '>', '<', '!', '-', '+', '*', '&', '|', '/', '\\', ':', '?', '.', '#', '%', '^', '~' => true,
        else => false,
    };
}

fn markDirty(result: *BuildResult, row: u32) void {
    if (result.dirty_min_row == null or row < result.dirty_min_row.?) result.dirty_min_row = row;
    if (result.dirty_max_row == null or row > result.dirty_max_row.?) result.dirty_max_row = row;
}

fn drawResizeOverlay(
    self: *D3d11Renderer,
    term: *vt.Terminal,
    glyph_cache: *@import("../GlyphIndexCache.zig"),
    tex_cell_count: gpu.CellXY,
    shader_col: u32,
    term_shader_row: u32,
    scratch: []shader.Cell,
    result: *BuildResult,
) void {
    const overlay_bg = Rgba8.fromU24(0x333333);
    const overlay_fg = Rgba8.fromU24(0xffffff);

    var text_buf: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{}x{}", .{ term.cols, term.rows }) catch unreachable;

    const text_len: u32 = @intCast(text.len);
    const pad: u32 = 2;
    const box_w = text_len + pad;
    const box_h: u32 = 3;
    const box_x = (shader_col -| box_w) / 2;
    const box_y = (term_shader_row -| box_h) / 2;

    const tx = box_x + (box_w -| text_len) / 2;
    const ty = box_y + 1;

    var by: u32 = box_y;
    while (by < box_y + box_h and by < term_shader_row) : (by += 1) {
        const dst_row_offset = by * shader_col;
        @memcpy(scratch, self.shadow_cells[dst_row_offset..][0..shader_col]);

        // Background box on this row.
        var bx: u32 = box_x;
        while (bx < box_x + box_w and bx < shader_col) : (bx += 1) {
            scratch[bx] = .{
                .glyph_index = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ' ', &.{}, .single, .regular),
                .background = overlay_bg,
                .foreground = overlay_fg,
                .attrs = 0,
            };
        }
        // Text on the middle row only.
        if (by == ty) {
            for (text, 0..) |ch, i| {
                const tcol = tx + @as(u32, @intCast(i));
                if (tcol < shader_col) {
                    scratch[tcol] = .{
                        .glyph_index = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ch, &.{}, .single, .regular),
                        .background = overlay_bg,
                        .foreground = overlay_fg,
                        .attrs = 0,
                    };
                }
            }
        }
        if (uploadCellRow(self, dst_row_offset, scratch, true)) {
            markDirty(result, by);
        }
    }
}

/// Grow `shadow_cells` to hold `count` entries. Returns true on grow so the
/// caller forces a full upload that frame (newly-allocated tail is undefined
/// and would otherwise alias a stale row's content). Shrinks are kept as-is:
/// the tail past `count` is never read.
pub fn ensureShadowCapacity(self: *D3d11Renderer, count: u32) bool {
    if (self.shadow_cells.len >= count) return false;
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = std.heap.page_allocator.alloc(shader.Cell, count) catch com.oom(error.OutOfMemory);
    return true;
}

/// Diff `scratch` against the shadow row at `row_start_cell`; if changed
/// (or `force_full`), push the row to the GPU via UpdateSubresource and
/// sync the shadow. `row_start_cell` is in cell units (not bytes). Returns
/// true iff the row was actually uploaded — the dirty-row tracking in
/// `buildAndUpload` uses this to size the scissor rect on the persistent
/// grid texture's draw.
pub fn uploadCellRow(
    self: *D3d11Renderer,
    row_start_cell: u32,
    scratch: []const shader.Cell,
    force_full: bool,
) bool {
    const shadow_row = self.shadow_cells[row_start_cell..][0..scratch.len];
    if (!force_full and std.mem.eql(
        u8,
        std.mem.sliceAsBytes(shadow_row),
        std.mem.sliceAsBytes(scratch),
    )) {
        if (comptime debug_stats_enabled) self.stats.rows_skipped += 1;
        self.diag_rows_skipped += 1;
        return false;
    }
    if (comptime debug_stats_enabled) self.stats.rows_uploaded += 1;
    self.diag_rows_uploaded += 1;
    const cell_bytes: u32 = @sizeOf(shader.Cell);
    const box: win32.D3D11_BOX = .{
        .left = row_start_cell * cell_bytes,
        .right = (row_start_cell + @as(u32, @intCast(scratch.len))) * cell_bytes,
        .top = 0,
        .bottom = 1,
        .front = 0,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.shader_cells.cell_buf.ID3D11Resource,
        0,
        &box,
        scratch.ptr,
        0,
        0,
    );
    @memcpy(shadow_row, scratch);
    return true;
}
