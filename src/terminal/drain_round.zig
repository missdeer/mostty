//! UI-thread continuation round. Elapsed time is supplied by the host clock;
//! a feed is indivisible, so the deadline is necessarily a soft bound.
const std = @import("std");
const Round = @This();

pub const budget_us: u64 = 8_000;
count: usize,
visited: usize = 0,
cursor: usize,
quantum: u64,

pub fn init(count: usize, cursor: usize, backlogged: usize) Round {
    return .{
        .count = count,
        .cursor = if (count == 0) 0 else cursor % count,
        .quantum = budget_us / @as(u64, @intCast(std.math.clamp(backlogged, 1, 4))),
    };
}

pub const Turn = struct { index: usize, budget: u64 };

pub fn next(self: *Round, elapsed_us: u64) ?Turn {
    if (self.visited == self.count or elapsed_us >= budget_us) return null;
    const index = self.cursor;
    self.cursor = (index + 1) % self.count;
    self.visited += 1;
    // Keep the original single-pane throughput budget; share it among up to
    // four panes, then rotate the starting pane across timer dispatches.
    return .{ .index = index, .budget = @min(self.quantum, budget_us - elapsed_us) };
}

/// Called after an empty observation. The StoreLoad barrier and second read
/// close the producer race; true means this consumer owns the replacement wake.
pub fn clearAndRecheck(ring: anytype) bool {
    ring.posted.store(false, .seq_cst);
    if (!ring.hasData()) return false;
    return !ring.posted.swap(true, .acq_rel);
}

test "clear and recheck never loses a producer edge or duplicates its wake" {
    const Ring = struct {
        posted: std.atomic.Value(bool) = .init(true),
        data: bool = false,
        race_after_clear: bool = false,
        producer_wakes: usize = 0,
        fn produce(self: *@This()) void {
            self.data = true;
            if (!self.posted.swap(true, .acq_rel)) self.producer_wakes += 1;
        }
        pub fn hasData(self: *@This()) bool {
            if (self.race_after_clear) self.produce();
            return self.data;
        }
    };
    var before: Ring = .{};
    // Producer writes after the caller observed empty, before the clear.
    before.produce();
    try std.testing.expectEqual(@as(usize, 0), before.producer_wakes);
    try std.testing.expect(clearAndRecheck(&before));
    try std.testing.expect(before.posted.load(.acquire));
    var after: Ring = .{ .race_after_clear = true };
    try std.testing.expect(!clearAndRecheck(&after));
    try std.testing.expectEqual(@as(usize, 1), after.producer_wakes);
    try std.testing.expect(after.posted.load(.acquire));
    var later: Ring = .{};
    try std.testing.expect(!clearAndRecheck(&later));
    try std.testing.expect(!later.posted.load(.acquire));
    later.produce();
    try std.testing.expectEqual(@as(usize, 1), later.producer_wakes);
}

test "continuation deadline is window-wide and every backlogged pane progresses" {
    var served: [16]usize = @splat(0);
    var cursor: usize = 0;
    for (0..4) |_| {
        var round = Round.init(served.len, cursor, served.len);
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
    var empty = Round.init(0, 9, 0);
    try std.testing.expect(empty.next(0) == null);
    var single = Round.init(1, 15, 1);
    try std.testing.expectEqual(budget_us, single.next(0).?.budget);
    try std.testing.expect(single.next(1) == null);
    var shrunk = Round.init(3, 15, 3);
    try std.testing.expectEqual(@as(usize, 0), shrunk.next(0).?.index);
    try std.testing.expect(shrunk.next(budget_us + 1000) == null);
    try std.testing.expectEqual(@as(usize, 1), shrunk.cursor);
    var late = Round.init(4, 0, 4);
    try std.testing.expectEqual(@as(u64, 1), late.next(budget_us - 1).?.budget);
}

test "idle panes do not reduce the active producer's throughput quantum" {
    var round = Round.init(16, 0, 1);
    for (0..15) |_| _ = round.next(0).?; // empty panes consume no feed budget
    try std.testing.expectEqual(budget_us, round.next(0).?.budget);
    try std.testing.expect(round.next(budget_us) == null);
}
