//! xterm special-key encoding; native event mapping stays with the host.
const std = @import("std");

pub const Key = enum(u32) {
    up = 0,
    down = 1,
    right = 2,
    left = 3,
    home = 4,
    end = 5,
    page_up = 6,
    page_down = 7,
    insert = 8,
    delete = 9,
    enter = 10,
    tab = 11,
    backspace = 12,
    escape = 13,
    f1 = 14,
    f2 = 15,
    f3 = 16,
    f4 = 17,
    f5 = 18,
    f6 = 19,
    f7 = 20,
    f8 = 21,
    f9 = 22,
    f10 = 23,
    f11 = 24,
    f12 = 25,
    _,
};

pub const mod_shift: u32 = 1;
pub const mod_alt: u32 = 2;
pub const mod_ctrl: u32 = 4;

/// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl. Returns 1 when no
/// modifiers are active (meaning "omit the modifier").
fn xtermModifier(mods: u32) u8 {
    var value: u8 = 1;
    if (mods & mod_shift != 0) value += 1;
    if (mods & mod_alt != 0) value += 2;
    if (mods & mod_ctrl != 0) value += 4;
    return value;
}

pub fn encodeKey(key: Key, mods: u32, app_cursor: bool, stack: *[16]u8) []const u8 {
    const m = xtermModifier(mods);
    return switch (key) {
        .up => cursor(stack, 'A', m, app_cursor),
        .down => cursor(stack, 'B', m, app_cursor),
        .right => cursor(stack, 'C', m, app_cursor),
        .left => cursor(stack, 'D', m, app_cursor),
        .home => cursor(stack, 'H', m, app_cursor),
        .end => cursor(stack, 'F', m, app_cursor),
        .insert => tilde(stack, 2, m),
        .delete => tilde(stack, 3, m),
        .page_up => tilde(stack, 5, m),
        .page_down => tilde(stack, 6, m),
        .f1 => func(stack, 'P', m),
        .f2 => func(stack, 'Q', m),
        .f3 => func(stack, 'R', m),
        .f4 => func(stack, 'S', m),
        .f5 => tilde(stack, 15, m),
        .f6 => tilde(stack, 17, m),
        .f7 => tilde(stack, 18, m),
        .f8 => tilde(stack, 19, m),
        .f9 => tilde(stack, 20, m),
        .f10 => tilde(stack, 21, m),
        .f11 => tilde(stack, 23, m),
        .f12 => tilde(stack, 24, m),
        .enter => "\r",
        .tab => if (mods & mod_shift != 0) "\x1b[Z" else "\t",
        .backspace => "\x7f",
        .escape => "\x1b",
        _ => "",
    };
}

/// Arrow / home / end keys. Application mode (no modifiers) uses SS3 (ESC O x);
/// with modifiers or in normal mode, CSI is used, adding `1;m` when modified.
fn cursor(stack: *[16]u8, final: u8, m: u8, app_cursor: bool) []const u8 {
    if (m == 1) {
        if (app_cursor) {
            stack[0] = 0x1b;
            stack[1] = 'O';
            stack[2] = final;
            return stack[0..3];
        }
        stack[0] = 0x1b;
        stack[1] = '[';
        stack[2] = final;
        return stack[0..3];
    }
    return std.fmt.bufPrint(stack, "\x1b[1;{d}{c}", .{ m, final }) catch stack[0..0];
}

/// CSI `n ~` keys (insert/delete/page/F5+), adding `;m` when modified.
fn tilde(stack: *[16]u8, n: u8, m: u8) []const u8 {
    if (m == 1) return std.fmt.bufPrint(stack, "\x1b[{d}~", .{n}) catch stack[0..0];
    return std.fmt.bufPrint(stack, "\x1b[{d};{d}~", .{ n, m }) catch stack[0..0];
}

/// F1-F4: SS3 (ESC O x) when unmodified, CSI `1;m x` when modified.
fn func(stack: *[16]u8, final: u8, m: u8) []const u8 {
    if (m == 1) {
        stack[0] = 0x1b;
        stack[1] = 'O';
        stack[2] = final;
        return stack[0..3];
    }
    return std.fmt.bufPrint(stack, "\x1b[1;{d}{c}", .{ m, final }) catch stack[0..0];
}

test "encodeKey emits normal and application cursor sequences" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encodeKey(.up, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1bOA", encodeKey(.up, 0, true, &stack));
    try std.testing.expectEqualStrings("\x1b[C", encodeKey(.right, 0, false, &stack));
}

test "encodeKey encodes modifiers with the xterm parameter" {
    var stack: [16]u8 = undefined;
    // Shift+Right => CSI 1;2 C, even in application mode (modifier forces CSI).
    try std.testing.expectEqualStrings("\x1b[1;2C", encodeKey(.right, mod_shift, true, &stack));
    // Ctrl+Up => CSI 1;5 A
    try std.testing.expectEqualStrings("\x1b[1;5A", encodeKey(.up, mod_ctrl, false, &stack));
    // Alt+Shift+Left => modifier 1 + shift(1) + alt(2) = 4 => CSI 1;4 D
    try std.testing.expectEqualStrings("\x1b[1;4D", encodeKey(.left, mod_shift | mod_alt, false, &stack));
}

test "encodeKey encodes tilde and function keys" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[3~", encodeKey(.delete, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[5;5~", encodeKey(.page_up, mod_ctrl, false, &stack));
    try std.testing.expectEqualStrings("\x1bOP", encodeKey(.f1, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[15~", encodeKey(.f5, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[24;2~", encodeKey(.f12, mod_shift, false, &stack));
}

test "encodeKey encodes control keys and shift-tab" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\r", encodeKey(.enter, 0, false, &stack));
    try std.testing.expectEqualStrings("\x7f", encodeKey(.backspace, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b", encodeKey(.escape, 0, false, &stack));
    try std.testing.expectEqualStrings("\t", encodeKey(.tab, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[Z", encodeKey(.tab, mod_shift, false, &stack));
}
