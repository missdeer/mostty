//! Resolve VT cell colors and attributes before native paint effects.
const vt = @import("vt");
const std = @import("std");

pub const Resolved = struct {
    foreground: u24,
    background: u24,
    default_background: bool,
    flags: @FieldType(vt.Style, "flags"),
};

/// Accepts VT flags or a renderer's resolved style with blink/invisible fields.
/// Hosts supply the blink phase; backgrounds remain visible in either phase.
pub fn textVisible(flags: anytype, blink_on: bool) bool {
    return !flags.invisible and (!flags.blink or blink_on);
}

pub fn rgbToU24(rgb: anytype) u24 {
    return @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
}

pub fn resolveColor(color: vt.Style.Color, palette: *const vt.color.Palette, fallback: u24) u24 {
    return switch (color) {
        .none => fallback,
        .palette => |index| rgbToU24(palette[index]),
        .rgb => |rgb| rgbToU24(rgb),
    };
}

pub fn resolve(style: vt.Style, palette: *const vt.color.Palette, foreground: u24, background: u24) Resolved {
    var result: Resolved = .{
        .foreground = resolveColor(style.fg_color, palette, foreground),
        .background = resolveColor(style.bg_color, palette, background),
        .default_background = style.bg_color == .none and !style.flags.inverse,
        .flags = style.flags,
    };
    if (style.flags.inverse) std.mem.swap(u24, &result.foreground, &result.background);
    return result;
}

pub fn forCell(cell: anytype, page: anytype, palette: *const vt.color.Palette, foreground: u24, background: u24) Resolved {
    const style: vt.Style = if (cell.style_id != 0) page.styles.get(page.memory, cell.style_id).* else .{};
    var result = resolve(style, palette, foreground, background);
    switch (cell.content_tag) {
        .bg_color_palette => {
            result.background = rgbToU24(palette[cell.content.color_palette.data]);
            result.default_background = false;
        },
        .bg_color_rgb => {
            result.background = rgbToU24(cell.content.color_rgb);
            result.default_background = false;
        },
        else => {},
    }
    return result;
}

test "SGR visibility keeps ordinary text steady and invisible text hidden across blink phases" {
    for ([_]bool{ false, true }) |phase| {
        try std.testing.expect(textVisible((vt.Style{}).flags, phase));
        try std.testing.expectEqual(phase, textVisible((vt.Style{ .flags = .{ .blink = true } }).flags, phase));
        for ([_]bool{ false, true }) |blink| {
            const style: vt.Style = .{ .flags = .{ .invisible = true, .blink = blink } };
            try std.testing.expect(!textVisible(style.flags, phase));
        }
    }
}

test "default backgrounds remain translucent candidates while explicit and inverse colors do not" {
    var palette: vt.color.Palette = undefined;
    palette[1] = .{ .r = 10, .g = 20, .b = 30 };
    const defaults = resolve(.{}, &palette, 0x112233, 0x445566);
    try std.testing.expect(defaults.default_background);
    try std.testing.expectEqual(@as(u24, 0x112233), defaults.foreground);
    const explicit = resolve(.{ .bg_color = .{ .palette = 1 } }, &palette, 0, 0);
    try std.testing.expect(!explicit.default_background);
    try std.testing.expectEqual(@as(u24, 0x0a141e), explicit.background);
    const inverse = resolve(.{ .flags = .{ .inverse = true, .faint = true, .blink = true } }, &palette, 0x112233, 0x445566);
    try std.testing.expect(!inverse.default_background);
    try std.testing.expectEqual(@as(u24, 0x445566), inverse.foreground);
    try std.testing.expectEqual(@as(u24, 0x112233), inverse.background);
    try std.testing.expect(inverse.flags.faint and inverse.flags.blink);
}
