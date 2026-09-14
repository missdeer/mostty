//! Color math used by the per-cell loop: palette resolution, gamma-aware faint
//! dimming, and the background clear colors that have to land on the same bytes
//! the grid shader writes.

const std = @import("std");
const vt = @import("vt");

const gpu = @import("gpu.zig");

pub const rgbToU24 = @import("../../renderer/cell_style.zig").rgbToU24;

// The effective default colors for one terminal. OSC 10/11 retarget these at
// runtime and DECSCNM swaps them, so the theme is only the seed — anything that
// has to agree with the grid's default cells (the tab-bar band, which sits
// flush against them) must resolve them the same way the cell loop does.
pub fn effectiveColors(term: anytype) struct { fg: u24, bg: u24 } {
    const fg: u24 = if (term.colors.foreground.get()) |c| rgbToU24(c) else gpu.fallback_fg;
    const bg: u24 = if (term.colors.background.get()) |c| rgbToU24(c) else gpu.fallback_bg;
    if (term.modes.get(.reverse_colors)) return .{ .fg = bg, .bg = fg };
    return .{ .fg = fg, .bg = bg };
}

// `to_linear` from terminal.hlsl. The shader uses this polynomial rather than a
// real sRGB decode, so every CPU-side path that has to produce bytes matching a
// shader-drawn pixel must use the same approximation, not std.math.pow(c, 2.2).
fn toLinear(c: f32) f32 {
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

fn encodeSrgb(linear: f32) f32 {
    if (linear <= 0.0031308) return linear * 12.92;
    return 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
}

// Default-background clear color in linear premultiplied form, for the sRGB
// render targets the backends clear directly (the hardware encodes on store).
// Alpha is byte-quantized here because the grid carries opacity as a cell byte;
// skipping that would leave the chrome a quantization step off the grid.
pub fn linearBackground(background: u24, opacity: f32) [4]f32 {
    const alpha = @round(std.math.clamp(opacity, 0, 1) * 255) / 255;
    return .{
        toLinear(@as(f32, @floatFromInt((background >> 16) & 0xFF)) / 255) * alpha,
        toLinear(@as(f32, @floatFromInt((background >> 8) & 0xFF)) / 255) * alpha,
        toLinear(@as(f32, @floatFromInt(background & 0xFF)) / 255) * alpha,
        alpha,
    };
}

// The same color already sRGB-encoded, for the UNORM surfaces the tab-bar band
// is drawn into — those store floats verbatim, so the encode the grid's sRGB
// target does in hardware has to happen here instead.
pub fn encodedBackground(background: u24, opacity: f32) [4]f32 {
    var result = linearBackground(background, opacity);
    for (result[0..3]) |*channel| channel.* = encodeSrgb(channel.*);
    return result;
}

test "default colors follow the terminal, not the configured theme" {
    // The tab-bar band and the window chrome both sit flush against the grid's
    // default cells, so they resolve their color here rather than from the
    // config — a theme read would desync the moment an app moves the terminal
    // off it, which config.rebaseTerminal deliberately lets happen.
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 4, .rows = 2 });
    defer term.deinit(alloc);

    try std.testing.expectEqual(gpu.fallback_bg, effectiveColors(&term).bg);
    try std.testing.expectEqual(gpu.fallback_fg, effectiveColors(&term).fg);

    // OSC 11 / OSC 10.
    term.colors.background = .init(.{ .r = 0x28, .g = 0x2c, .b = 0x34 });
    term.colors.foreground = .init(.{ .r = 0xab, .g = 0xb2, .b = 0xbf });
    try std.testing.expectEqual(@as(u24, 0x282c34), effectiveColors(&term).bg);
    try std.testing.expectEqual(@as(u24, 0xabb2bf), effectiveColors(&term).fg);

    // DECSCNM swaps what "default background" means for the whole screen.
    term.modes.set(.reverse_colors, true);
    try std.testing.expectEqual(@as(u24, 0xabb2bf), effectiveColors(&term).bg);
    try std.testing.expectEqual(@as(u24, 0x282c34), effectiveColors(&term).fg);
}

test "band and chrome clears differ only by the sRGB encode" {
    const linear = linearBackground(0x1e1e2e, 0.8);
    const encoded = encodedBackground(0x1e1e2e, 0.8);
    try std.testing.expectEqual(linear[3], encoded[3]);
    for (linear[0..3], encoded[0..3]) |l, e| try std.testing.expectApproxEqAbs(encodeSrgb(l), e, 0.00001);
}

test "band clear keeps bright translucent pixels above their alpha" {
    // A premultiplied-in-linear color, once sRGB-encoded, legitimately exceeds
    // its own alpha. D2D's Clear takes straight color and premultiplies, so it
    // can never express this — hence the raw surface clear. Clamping RGB to
    // alpha here would darken the band and put the seam back.
    const translucent = encodedBackground(0xffffff, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), translucent[3], 0.00001);
    try std.testing.expect(translucent[0] > translucent[3]);

    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, encodedBackground(0xffffff, 0));
    for (encodedBackground(0xffffff, 1)) |channel| try std.testing.expectApproxEqAbs(@as(f32, 1), channel, 0.00001);
}

test "opacity is quantized to the byte the grid stores per cell" {
    // cell_buffer packs opacity into a u8; a clear that kept full float
    // precision would land one step off the cells it has to blend against.
    const cell_byte: f32 = @round(0.94 * 255.0) / 255.0;
    try std.testing.expectEqual(cell_byte, linearBackground(0x1e1e2e, 0.94)[3]);
}

// SGR faint: halve perceived luminance. The shader decodes via pow(c, 2.2),
// so a sRGB c/2 byte-domain divide would land at ~21% linear — far too dark.
// Halve in linear space and re-encode, baked into a 256-entry LUT.
const faint_lut: [256]u8 = blk: {
    @setEvalBranchQuota(4_000_000);
    var lut: [256]u8 = undefined;
    for (&lut, 0..) |*slot, i| {
        const srgb: f32 = @as(f32, @floatFromInt(i)) / 255.0;
        const linear = std.math.pow(f32, srgb, 2.2);
        const dim_linear = linear * 0.5;
        const dim_srgb = std.math.pow(f32, dim_linear, 1.0 / 2.2);
        slot.* = @intFromFloat(@round(dim_srgb * 255.0));
    }
    break :blk lut;
};

pub fn dimColor(c: u24) u24 {
    const r = faint_lut[(c >> 16) & 0xFF];
    const g = faint_lut[(c >> 8) & 0xFF];
    const b = faint_lut[c & 0xFF];
    return @as(u24, r) << 16 | @as(u24, g) << 8 | b;
}
