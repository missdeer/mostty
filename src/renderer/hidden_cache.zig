//! Shared visibility policy. This never owns terminal state or GPU resources.
const HiddenCache = @This();
const std = @import("std");
pub const grace_ms: u32 = 30_000;
pub const State = enum { active, warm, trimmed };
state: State = .active,
hidden_since_ms: u64 = 0,

pub fn setVisible(self: *HiddenCache, visible: bool, now_ms: u64) void {
    if (visible) {
        self.state = .active;
    } else if (self.state == .active) {
        self.state = .warm;
        self.hidden_since_ms = now_ms;
    }
}

pub fn remaining(self: *const HiddenCache, now_ms: u64) ?u32 {
    if (self.state != .warm) return null;
    return @intCast(@as(u64, grace_ms) -| (now_ms -| self.hidden_since_ms));
}

pub fn trimDue(self: *HiddenCache, now_ms: u64) bool {
    if ((self.remaining(now_ms) orelse return false) != 0) return false;
    self.state = .trimmed;
    return true;
}

test "quick switches retain caches, hidden activity does not reset grace, and trim is idempotent" {
    var cache: HiddenCache = .{};
    cache.setVisible(false, 100);
    cache.setVisible(false, 1000);
    try std.testing.expectEqual(@as(?u32, 29_100), cache.remaining(1000));
    cache.setVisible(true, 2000);
    try std.testing.expect(!cache.trimDue(100_000)); // stale timer after restore
    cache.setVisible(false, 200_000);
    try std.testing.expect(!cache.trimDue(229_999));
    try std.testing.expect(cache.trimDue(230_000));
    try std.testing.expect(!cache.trimDue(240_000));
    try std.testing.expectEqual(State.trimmed, cache.state);
    cache.setVisible(true, 250_000);
    try std.testing.expectEqual(State.active, cache.state);
    cache.setVisible(false, 260_000);
    try std.testing.expectEqual(@as(?u32, grace_ms), cache.remaining(260_000));
}
