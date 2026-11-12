//! Vulkan upload admission limits use actual VkMemoryAllocateInfo byte counts.
const std = @import("std");
pub const active_bytes: usize = 16 * 1024 * 1024;
pub const active_tasks: usize = 128;
pub const batch_tasks: usize = 64;
pub const batch_bytes: usize = 4 * 1024 * 1024;
pub const pool_bytes: usize = 8 * 1024 * 1024;
pub const pool_tasks: usize = 64;
pub const pool_buffer_bytes: usize = 256 * 1024;
// Oversized transfers are exclusive and never retained in the common pool.
pub const single_bytes: usize = 1024 * 1024 * 1024;

pub fn capacity(bytes: usize) error{InvalidSize}!usize {
    if (bytes == 0 or bytes > single_bytes) return error.InvalidSize;
    if (bytes > pool_buffer_bytes) return bytes;
    return std.math.ceilPowerOfTwo(usize, @max(4096, bytes)) catch error.InvalidSize;
}

pub fn mustDrain(live_bytes: usize, tasks: usize, allocation_bytes: usize) bool {
    return tasks >= active_tasks or allocation_bytes > active_bytes -| live_bytes;
}

test "upload bounds prevent unbounded GPU-lag queues and isolate large transfers" {
    try std.testing.expectEqual(@as(usize, 4096), try capacity(800));
    try std.testing.expectEqual(@as(usize, 8192), try capacity(5000));
    try std.testing.expectEqual(pool_buffer_bytes + 1, try capacity(pool_buffer_bytes + 1));
    try std.testing.expectError(error.InvalidSize, capacity(0));
    try std.testing.expectError(error.InvalidSize, capacity(single_bytes + 1));
    try std.testing.expect(!mustDrain(active_bytes - 4096, active_tasks - 1, 4096));
    try std.testing.expect(mustDrain(active_bytes, 1, 4096));
    try std.testing.expect(mustDrain(0, active_tasks, 4096));
    try std.testing.expect(mustDrain(0, 0, active_bytes + 1));
    try std.testing.expect(mustDrain(active_bytes + 1, 1, 4096));
}
