//! Font decisions shared by native text backends.
const std = @import("std");

pub fn useRegular(disabled: bool, has_real_face: bool, allow_synthetic: bool) bool {
    return disabled or (!has_real_face and !allow_synthetic);
}

pub fn isLigatureTrigger(cp: u21) bool {
    return switch (cp) {
        '=', '>', '<', '!', '-', '+', '*', '&', '|', '/', '\\', ':', '?', '.', '#', '%', '^', '~' => true,
        else => false,
    };
}

test "explicit opt-out wins and real faces survive disabled synthesis" {
    try std.testing.expect(useRegular(true, true, true));
    try std.testing.expect(!useRegular(false, true, false));
    try std.testing.expect(useRegular(false, false, false));
    try std.testing.expect(!useRegular(false, false, true));
}
