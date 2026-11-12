//! Atlas capacity policy, independent of GPU resource ownership.
const std = @import("std");

pub fn rows(columns: u32, max_rows: u32, cell_bytes: u32, visible_cells: u32, budget_bytes: u32, previous_slots: u32, pressure: bool) u16 {
    // One frame must fit even when every cell is a distinct glyph. Include
    // the blank placeholder and speculative ligature-run reservations.
    const minimum = @min(max_rows, @max(2, std.math.divCeil(u32, visible_cells +| 17, columns) catch unreachable));
    const limit = @min(max_rows, @max(minimum, budget_bytes / cell_bytes / columns));
    const initial = @max(minimum, std.math.divCeil(u32, 1024, columns) catch unreachable);
    const previous = previous_slots / columns;
    const desired = if (previous == 0) initial else if (pressure) previous *| 2 else previous;
    return @intCast(@min(limit, @max(minimum, desired)));
}

test "cold atlas is small, pressure grows to budget, viewport is a correctness floor" {
    const columns = 409;
    const cold = rows(columns, 204, 800, 3000, 64 * 1024 * 1024, 0, false);
    try std.testing.expectEqual(@as(u16, 8), cold);
    try std.testing.expectEqual(@as(u16, 16), rows(columns, 204, 800, 3000, 64 * 1024 * 1024, columns * cold, true));
    try std.testing.expectEqual(@as(u16, 12), rows(columns, 204, 800, 3000, 4 * 1024 * 1024, columns * 8, true));
    try std.testing.expectEqual(@as(u16, 8), rows(columns, 204, 800, 3000, 1, 0, false));
    try std.testing.expectEqual(@as(u16, 204), rows(columns, 204, 800, std.math.maxInt(u32), std.math.maxInt(u32), 0, true));
}
