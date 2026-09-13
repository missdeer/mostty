//! Color math used by the per-cell loop: palette resolution and gamma-aware
//! faint dimming.

const std = @import("std");

pub const rgbToU24 = @import("../../renderer/cell_style.zig").rgbToU24;

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
