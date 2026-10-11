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

/// Retire through the caller's real resource destructor, then compact only
/// when at least half the storage is dead. `head` also protects teardown from
/// releasing a resource a second time.
pub fn collect(comptime T: type, items: *[]T, head: *usize, completed: u64, context: anytype, comptime release: anytype) void {
    const count = ready(items.*[head.*..], completed).count;
    for (items.*[head.*..][0..count]) |*item| release(context, item);
    head.* += count;
    const remaining = items.len - head.*;
    if (head.* >= remaining) {
        std.mem.copyForwards(T, items.*[0..remaining], items.*[head.*..]);
        items.*.len = remaining;
        head.* = 0;
    }
}

test "resource retirement compacts, appends, and tears down exactly once" {
    const Entry = struct { completion: u64, id: usize };
    const Context = struct {
        released: [8]usize = @splat(0),
        fn release(self: *@This(), item: *Entry) void {
            self.released[item.id] += 1;
            // Match destructors which poison their source after releasing it.
            item.* = undefined;
        }
    };
    var storage: [8]Entry = undefined;
    for (&storage, 0..) |*item, i| item.* = .{ .completion = i + 1, .id = i };
    var items: []Entry = storage[0..6];
    var head: usize = 0;
    var context: Context = .{};
    collect(Entry, &items, &head, 1, &context, Context.release);
    try std.testing.expectEqual(@as(usize, 1), head);
    collect(Entry, &items, &head, 1, &context, Context.release);
    try std.testing.expectEqual(@as(usize, 1), context.released[0]);
    collect(Entry, &items, &head, 3, &context, Context.release);
    try std.testing.expectEqual(@as(usize, 0), head);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    for (items, 3..) |item, id| try std.testing.expectEqual(id, item.id);
    items = storage[0..5];
    items[3] = .{ .completion = 7, .id = 6 };
    items[4] = .{ .completion = 8, .id = 7 };
    collect(Entry, &items, &head, 4, &context, Context.release);
    // Device-idle teardown releases only the remaining suffix.
    for (items[head..]) |*item| Context.release(&context, item);
    for (context.released) |count| try std.testing.expectEqual(@as(usize, 1), count);
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
