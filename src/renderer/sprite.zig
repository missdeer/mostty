//! Procedural drawing for tile-design codepoints (Block Elements, Box
//! Drawing, Braille, Powerline, Geometric Shapes, Legacy Computing). Mirrors
//! ghostty's sprite face so block-art content (Claude Code logo, TUI
//! borders, progress bars) tiles seamlessly regardless of the user's font.
//!
//! The drawing code lives under `src/vendor/ghostty-sprite/` and is invoked
//! via the comptime range table built below. We rasterize into an alpha-8
//! z2d surface. macOS consumes linear alpha; Windows gamma-encodes it into
//! BGRA for the shader's ClearType-coverage decode (`pow(c, 2.2)`).

const std = @import("std");
const sprite_font = @import("../vendor/ghostty-sprite/font/main.zig");

pub const Metrics = sprite_font.Metrics;
const Canvas = sprite_font.sprite.Canvas;

/// Build a reasonable sprite Metrics from just cell dimensions. Used because
/// mostty doesn't otherwise track per-face typographic metrics; the sprite
/// drawing code only really depends on these values for stroke thickness and
/// underline placement, neither of which is critical for the block / box
/// elements that drive the visible bug.
pub fn buildMetrics(cell_w: u32, cell_h: u32) Metrics {
    const thickness: u32 = @max(1, cell_h / 14);
    // Approximate baseline at ~80% of cell height (cell_baseline is
    // measured from the bottom, so descent ≈ cell_h * 0.2).
    const baseline: u32 = @max(thickness, cell_h / 5);
    const ascent: u32 = cell_h - baseline;
    return .{
        .cell_width = cell_w,
        .cell_height = cell_h,
        .cell_baseline = baseline,
        .underline_position = ascent + thickness,
        .underline_thickness = thickness,
        .strikethrough_position = cell_h / 2,
        .strikethrough_thickness = thickness,
        .overline_position = 0,
        .overline_thickness = thickness,
        .box_thickness = thickness,
        .cursor_thickness = 1,
        .cursor_height = cell_h,
    };
}

const DrawFnError = std.mem.Allocator.Error || error{
    InvalidCharacter,
    PathError,
    FillError,
    StrokeError,
    MathError,
    OutOfMemory,
};

/// Same signature as ghostty's draw functions. Kept loose (anyerror) here
/// because the underlying z2d errors leak through individual draw modules.
const DrawFn = fn (
    cp: u32,
    canvas: *Canvas,
    width: u32,
    height: u32,
    metrics: Metrics,
) anyerror!void;

const Range = struct {
    min: u21,
    max: u21,
    draw: *const DrawFn,
};

/// Comptime-collected codepoint ranges from each `draw<HEX>` /
/// `draw<HEX>_<HEX>` function. Mirrors the logic in ghostty's
/// src/font/sprite/Face.zig — verbatim approach so future ghostty updates
/// flow through naturally.
const ranges: []const Range = blk: {
    @setEvalBranchQuota(1_000_000);

    const structs = [_]type{
        @import("../vendor/ghostty-sprite/font/sprite/draw/block.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/box.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/braille.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/branch.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/geometric_shapes.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/powerline.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/symbols_for_legacy_computing.zig"),
        @import("../vendor/ghostty-sprite/font/sprite/draw/symbols_for_legacy_computing_supplement.zig"),
    };

    var count: usize = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, "draw")) continue;
            count += 1;
        }
    }

    var r: [count]Range = undefined;
    var i: usize = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decl_names) |name| {
            if (!std.mem.startsWith(u8, name, "draw")) continue;
            const sep = std.mem.indexOfScalar(u8, name, '_') orelse name.len;
            const min = std.fmt.parseInt(u21, name[4..sep], 16) catch unreachable;
            const max = if (sep == name.len) min else std.fmt.parseInt(u21, name[sep + 1 ..], 16) catch unreachable;
            r[i] = .{ .min = min, .max = max, .draw = &@field(s, name) };
            i += 1;
        }
    }

    // Sort ascending by min for fast linear / future binary-search dispatch.
    std.mem.sortUnstable(Range, &r, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.min < b.min;
        }
    }.lt);

    // Catch range overlaps at comptime so future ghostty syncs that
    // introduce conflicting draw functions don't silently corrupt dispatch.
    var prev_max: u21 = 0;
    var first = true;
    for (r) |n| {
        if (!first and n.min <= prev_max) {
            @compileError(std.fmt.comptimePrint(
                "sprite codepoint range overlap: U+{X} <= U+{X}",
                .{ n.min, prev_max },
            ));
        }
        first = false;
        prev_max = n.max;
    }

    const fixed = r;
    break :blk &fixed;
};

/// True if `cp` is in mostty's sprite range and will be drawn procedurally.
pub fn hasCodepoint(cp: u21) bool {
    return getDrawFn(cp) != null;
}

/// True if `cp` is an EAW=Ambiguous symbol (Geometric Shapes / Misc
/// Symbols / Dingbats: ●✶★◆❄❤ etc.) that the DirectWrite glyph path should
/// render with center alignment + ink-bounds best-fit so it appears as a
/// round, properly-sized glyph inside its single cell — instead of getting
/// horizontally squashed to a thin ellipse by the default `.single`
/// scale-down. Sprite-face codepoints are excluded since they already
/// render pixel-perfect via the procedural path.
///
/// On Windows fallback fonts (LXGW Mono etc.) these codepoints have ~1 em
/// natural advance, which doesn't fit the narrow cs.x without help; the
/// uniform-scale + centered layout matches what WezTerm and other
/// per-cell terminals produce.
pub fn isAmbiguousOverflow(cp: u21) bool {
    const in_range = (cp >= 0x25A0 and cp <= 0x25FF) // Geometric Shapes
        or (cp >= 0x2600 and cp <= 0x26FF) // Miscellaneous Symbols
        or (cp >= 0x2700 and cp <= 0x27BF); // Dingbats
    if (!in_range) return false;
    // Sprite face takes priority — those codepoints render pixel-perfect
    // at cs.x and don't need the DirectWrite center-fit treatment.
    return !hasCodepoint(cp);
}

fn getDrawFn(cp: u21) ?*const DrawFn {
    inline for (ranges) |range| {
        if (cp >= range.min and cp <= range.max) return range.draw;
    }
    return null;
}

/// Render the sprite for `cp` into `out_bgra` (length must be at least
/// `cell_w * cell_h * 4`, BGRA8 row-major). Returns false if `cp` is not in
/// the sprite range. The alpha is gamma-2.2 encoded and replicated into B,
/// G, R; A is set to 255/opaque to match the DirectWrite-path atlas
/// contract (the d3d11 shader does not sample the atlas alpha channel).
///
/// `cell_w` is the destination cell width (cs.x for `.single` /
/// `.wide_left` halves; for wide glyphs the caller renders twice with the
/// appropriate half offset, same as the DirectWrite path). `cell_h` is the
/// cell height. `metrics.cell_width` / `cell_height` should match.
pub fn render(
    alloc: std.mem.Allocator,
    cp: u21,
    cell_w: u32,
    cell_h: u32,
    metrics: Metrics,
    out_bgra: []u8,
) !bool {
    return renderPixels(.atlas_bgra, alloc, cp, cell_w, cell_h, metrics, out_bgra);
}

/// Linear alpha-8 coverage, row-major from the top-left of the full cell.
pub fn renderAlpha(
    alloc: std.mem.Allocator,
    cp: u21,
    cell_w: u32,
    cell_h: u32,
    metrics: Metrics,
    out_alpha: []u8,
) !bool {
    return renderPixels(.alpha, alloc, cp, cell_w, cell_h, metrics, out_alpha);
}

fn renderPixels(
    comptime format: enum { atlas_bgra, alpha },
    alloc: std.mem.Allocator,
    cp: u21,
    cell_w: u32,
    cell_h: u32,
    metrics: Metrics,
    output: []u8,
) !bool {
    const draw = getDrawFn(cp) orelse return false;

    // Padding mirrors ghostty's renderGlyph (cell/4 each side). Lets draw
    // functions overshoot cell bounds — those pixels are dropped when we
    // extract the cell region below. Required by some box-drawing diagonals.
    const padding_x: u32 = cell_w / 4;
    const padding_y: u32 = cell_h / 4;

    var canvas = try Canvas.init(alloc, cell_w, cell_h, padding_x, padding_y);
    defer canvas.deinit();

    try draw(@intCast(cp), &canvas, cell_w, cell_h, metrics);

    // Extract the cell rectangle (padding_x .. padding_x + cell_w,
    // padding_y .. padding_y + cell_h) from the canvas's alpha-8 buffer
    // and gamma-encode while replicating into BGRA.
    const buf = std.mem.sliceAsBytes(canvas.sfc.image_surface_alpha8.buf);
    const stride: u32 = @intCast(canvas.sfc.getWidth());
    const channels = if (format == .alpha) 1 else 4;
    std.debug.assert(output.len >= cell_w * cell_h * channels);

    var y: u32 = 0;
    while (y < cell_h) : (y += 1) {
        const src_row = (padding_y + y) * stride + padding_x;
        const dst_row = y * cell_w * channels;
        var x: u32 = 0;
        while (x < cell_w) : (x += 1) {
            if (format == .alpha) {
                output[dst_row + x] = buf[src_row + x];
                continue;
            }
            // Gamma-encode linear coverage so the shader's pow(c, 2.2)
            // decode recovers the original linear value. Must stay in
            // lock-step with terminal.hlsl's to_linear exponent and
            // DirectWrite's CreateCustomRenderingParams gamma.
            const encoded = gamma_lut[buf[src_row + x]];
            const dst = dst_row + x * 4;
            output[dst + 0] = encoded; // B
            output[dst + 1] = encoded; // G
            output[dst + 2] = encoded; // R
            output[dst + 3] = 255; // A: opaque to match the DirectWrite-path atlas contract
        }
    }

    return true;
}

// pow(c/255, 1/2.2)*255, comptime-baked. Inverse of terminal.hlsl's
// to_linear (gamma 2.2) decode. Endpoints 0/255 are exact by construction.
const gamma_lut: [256]u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var lut: [256]u8 = undefined;
    for (&lut, 0..) |*slot, i| {
        const lf: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        const ef = std.math.pow(f32, lf, 1.0 / 2.2);
        slot.* = @intFromFloat(@round(ef * 255.0));
    }
    break :blk lut;
};

test "linear masks and Windows atlas coverage agree for every sprite family" {
    const width = 13;
    const height = 25;
    const metrics = buildMetrics(width, height);
    var alpha: [width * height]u8 = undefined;
    var atlas: [width * height * 4]u8 = undefined;
    for ([_]u21{ 0x2580, 0x253c, 0x28ff, 0xe0b0, 0x25e2, 0x1fb00 }) |cp| {
        try std.testing.expect(try renderAlpha(std.testing.allocator, cp, width, height, metrics, &alpha));
        try std.testing.expect(try render(std.testing.allocator, cp, width, height, metrics, &atlas));
        try std.testing.expect(std.mem.indexOfNone(u8, &alpha, &.{0}) != null);
        for (alpha, 0..) |coverage, i| {
            // Windows' shader decodes gamma 2.2; macOS must receive linear coverage.
            const decoded = std.math.pow(f32, @as(f32, @floatFromInt(atlas[i * 4])) / 255, 2.2) * 255;
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(coverage)), decoded, 1.2);
            try std.testing.expectEqual(atlas[i * 4], atlas[i * 4 + 1]);
            try std.testing.expectEqual(atlas[i * 4], atlas[i * 4 + 2]);
            try std.testing.expectEqual(@as(u8, 255), atlas[i * 4 + 3]);
        }
    }
    try std.testing.expect(!try renderAlpha(std.testing.allocator, 'A', width, height, metrics, &alpha));
}
