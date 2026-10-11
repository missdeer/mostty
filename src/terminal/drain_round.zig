//! UI-thread continuation round. Elapsed time is supplied by the host clock;
//! a feed is indivisible, so the deadline is necessarily a soft bound.
const std = @import("std");
const Round = @This();

pub const budget_us: u64 = 8_000;
count: usize,
visited: usize = 0,
cursor: usize,

pub fn init(count: usize, cursor: usize) Round {
    return .{ .count = count, .cursor = if (count == 0) 0 else cursor % count };
}

pub const Turn = struct { index: usize, budget: u64 };

pub fn next(self: *Round, elapsed_us: u64) ?Turn {
    if (self.visited == self.count or elapsed_us >= budget_us) return null;
    const index = self.cursor;
    self.cursor = (index + 1) % self.count;
    self.visited += 1;
    // Keep the original single-pane throughput budget; share it among up to
    // four panes, then rotate the starting pane across timer dispatches.
    const quantum = budget_us / @as(u64, @intCast(@min(self.count, 4)));
    return .{ .index = index, .budget = @min(quantum, budget_us - elapsed_us) };
}

test "continuation deadline is window-wide and every backlogged pane progresses" {
    var served: [16]usize = @splat(0);
    var cursor: usize = 0;
    for (0..4) |_| {
        var round = Round.init(served.len, cursor);
        var elapsed: u64 = 0;
        while (round.next(elapsed)) |turn| {
            served[turn.index] += 1;
            elapsed += turn.budget;
        }
        try std.testing.expectEqual(budget_us, elapsed);
        try std.testing.expectEqual(@as(usize, 4), round.visited);
        cursor = round.cursor;
    }
    for (served) |count| try std.testing.expectEqual(@as(usize, 1), count);
}

test "empty, removed panes and slow indivisible feed cannot extend a round" {
    var empty = Round.init(0, 9);
    try std.testing.expect(empty.next(0) == null);
    var single = Round.init(1, 15);
    try std.testing.expectEqual(budget_us, single.next(0).?.budget);
    try std.testing.expect(single.next(1) == null);
    var shrunk = Round.init(3, 15);
    try std.testing.expectEqual(@as(usize, 0), shrunk.next(0).?.index);
    try std.testing.expect(shrunk.next(budget_us + 1000) == null);
    try std.testing.expectEqual(@as(usize, 1), shrunk.cursor);
    var late = Round.init(4, 0);
    try std.testing.expectEqual(@as(u64, 1), late.next(budget_us - 1).?.budget);
}
