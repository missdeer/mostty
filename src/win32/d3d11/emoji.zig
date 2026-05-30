//! Emoji presentation detection and UTF-16 encoding for glyph runs.
//!
//! Used by the glyph rasterizer to decide whether a (codepoint, grapheme)
//! pair should render through the color-emoji staging path (premultiplied
//! alpha + GRAYSCALE AA + ENABLE_COLOR_FONT) or the standard ClearType mask
//! path, and whether DirectWrite's family resolution should be forced to
//! Segoe UI Emoji to honor VS16 / keycap sequences.

const std = @import("std");

pub const variation_selector_text: u21 = 0xFE0E;
pub const variation_selector_emoji: u21 = 0xFE0F;
pub const combining_enclosing_keycap: u21 = 0x20E3;

pub fn isColorGlyphRun(first: u21, rest: []const u21) bool {
    if (hasTextPresentationSelector(rest)) return false;
    if (shouldForceEmojiFont(first, rest)) return true;
    if (isColorGlyphCodepoint(first)) return true;
    for (rest) |cp| {
        if (isColorGlyphCodepoint(cp)) return true;
    }
    return false;
}

// Unicode `Emoji_Presentation=Yes` codepoints: those that default to color
// emoji presentation without needing VS16. Codepoints with Emoji=Yes but
// Emoji_Presentation=No (♠ ♥ ☀ ☎ ...) are intentionally excluded — they
// stay text by default, and only opt in via VS16 (handled separately).
fn isColorGlyphCodepoint(cp: u21) bool {
    return switch (cp) {
        0x231A, 0x231B,
        0x23E9...0x23EC, 0x23F0, 0x23F3,
        0x25FD, 0x25FE,
        0x2614, 0x2615,
        0x2648...0x2653,
        0x267F, 0x2693,
        0x26A1,
        0x26AA, 0x26AB,
        0x26BD, 0x26BE,
        0x26C4, 0x26C5,
        0x26CE, 0x26D4,
        0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD,
        0x2705,
        0x270A, 0x270B,
        0x2728, 0x274C, 0x274E,
        0x2753...0x2755, 0x2757,
        0x2795...0x2797, 0x27B0, 0x27BF,
        0x2B1B, 0x2B1C, 0x2B50, 0x2B55,
        0x1F004, 0x1F0CF,
        0x1F18E, 0x1F191...0x1F19A,
        0x1F1E6...0x1F1FF,
        0x1F201, 0x1F21A, 0x1F22F,
        0x1F232...0x1F236, 0x1F238...0x1F23A,
        0x1F250, 0x1F251,
        0x1F300...0x1F320,
        0x1F32D...0x1F335,
        0x1F337...0x1F37C, 0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0, 0x1F3F4, 0x1F3F8...0x1F43E,
        0x1F440, 0x1F442...0x1F4FC, 0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E, 0x1F550...0x1F567,
        0x1F57A,
        0x1F595, 0x1F596,
        0x1F5A4,
        0x1F5FB...0x1F64F,
        0x1F680...0x1F6C5, 0x1F6CC,
        0x1F6D0...0x1F6D2, 0x1F6D5...0x1F6D7, 0x1F6DC...0x1F6DF,
        0x1F6EB, 0x1F6EC,
        0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB, 0x1F7F0,
        0x1F90C...0x1F93A, 0x1F93C...0x1F945,
        0x1F947...0x1F9FF,
        0x1FA70...0x1FA7C, 0x1FA80...0x1FA89, 0x1FA8F...0x1FAC6,
        0x1FACE...0x1FADC, 0x1FADF...0x1FAE9, 0x1FAF0...0x1FAF8,
        => true,
        else => false,
    };
}

pub fn shouldForceEmojiFont(first: u21, rest: []const u21) bool {
    if (hasTextPresentationSelector(rest)) return false;
    return hasEmojiPresentationSelector(rest) or isEmojiKeycapRun(first, rest);
}

fn hasEmojiPresentationSelector(rest: []const u21) bool {
    for (rest) |cp| {
        if (cp == variation_selector_emoji) return true;
    }
    return false;
}

fn hasTextPresentationSelector(rest: []const u21) bool {
    for (rest) |cp| {
        if (cp == variation_selector_text) return true;
    }
    return false;
}

fn isEmojiKeycapRun(first: u21, rest: []const u21) bool {
    if (!isKeycapBase(first)) return false;
    return (rest.len == 1 and rest[0] == combining_enclosing_keycap) or
        (rest.len == 2 and rest[0] == variation_selector_emoji and rest[1] == combining_enclosing_keycap);
}

fn isKeycapBase(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or cp == '#' or cp == '*';
}

pub fn encodeUtf16Run(out: []u16, first: u21, rest: []const u21) usize {
    var len: usize = 0;
    len += encodeUtf16Codepoint(out[len..], first);
    for (rest) |cp| {
        len += encodeUtf16Codepoint(out[len..], cp);
    }
    return len;
}

pub fn encodeUtf16Codepoint(out: []u16, cp: u21) usize {
    if (cp <= 0xFFFF) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = @as(u32, cp) - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

test "emoji presentation forces emoji font only for explicit emoji runs" {
    try std.testing.expect(!shouldForceEmojiFont(0x2600, &[_]u21{}));
    try std.testing.expect(shouldForceEmojiFont(0x2600, &[_]u21{variation_selector_emoji}));
    try std.testing.expect(!shouldForceEmojiFont(0x2600, &[_]u21{variation_selector_text}));
    try std.testing.expect(!shouldForceEmojiFont(0x2665, &[_]u21{}));
    try std.testing.expect(shouldForceEmojiFont(0x2665, &[_]u21{variation_selector_emoji}));
}

test "emoji color detection includes keycaps and respects text presentation" {
    try std.testing.expect(isColorGlyphRun('0', &[_]u21{ variation_selector_emoji, combining_enclosing_keycap }));
    try std.testing.expect(isColorGlyphRun('#', &[_]u21{combining_enclosing_keycap}));
    try std.testing.expect(!isColorGlyphRun('0', &[_]u21{}));
    try std.testing.expect(!isColorGlyphRun(0x2600, &[_]u21{variation_selector_text}));
}
