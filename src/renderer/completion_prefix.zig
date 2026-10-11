const std = @import("std");

/// Entries must be appended in submission order to the same timeline.
pub fn ready(items: anytype, completed: u64) struct { count: usize, examined: usize } {
    var count: usize = 0;
    for (items) |item| {
        if (item.completion > completed) return .{ .count = count, .examined = count + 1 };
        count += 1;
    }
    return .{ .count = count, .examined = count };
}

test "a stalled timeline checks only the first upload and never retires later resources" {
    const Entry = struct { completion: u64 };
    var entries: [1024]Entry = undefined;
    for (&entries, 1..) |*item, value| item.* = .{ .completion = value };
    var examined: usize = 0;
    for (0..1024) |_| {
        const result = ready(&entries, 0);
        try std.testing.expectEqual(@as(usize, 0), result.count);
        examined += result.examined;
    }
    try std.testing.expectEqual(@as(usize, 1024), examined);
    try std.testing.expectEqual(@as(usize, 512), ready(&entries, 512).count);
    try std.testing.expectEqual(@as(usize, 1024), ready(&entries, 1024).count);
    try std.testing.expectEqual(@as(usize, 0), ready(entries[0..0], 1024).examined);
}
