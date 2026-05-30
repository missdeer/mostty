//! Color math used by the per-cell loop: palette resolution, gamma-aware
//! faint dimming, and premultiplied-alpha-safe selection fades.

const std = @import("std");
const vt = @import("vt");
const gpu = @import("gpu.zig");

const Rgba8 = gpu.Rgba8;

pub fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette, default: u24) u24 {
    return switch (c) {
        .none => default,
        .palette => |idx| rgbToU24(palette[idx]),
        .rgb => |rgb| rgbToU24(rgb),
    };
}

pub fn rgbToU24(rgb: vt.color.RGB) u24 {
    return @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
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

pub fn lerpRgba8(a: Rgba8, b: Rgba8, t: f32) Rgba8 {
    return .{
        .r = lerpU8(a.r, b.r, t),
        .g = lerpU8(a.g, b.g, t),
        .b = lerpU8(a.b, b.b, t),
        .a = lerpU8(a.a, b.a, t),
    };
}

pub fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(af + (bf - af) * t);
}
