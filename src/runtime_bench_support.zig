//! Only imported by the opt-in benchmark harness, never by application code.
const std = @import("std");
pub const warmup = 3;
pub const samples = 15;
pub fn allocator() std.mem.Allocator {
    const root = @import("root");
    return if (@hasDecl(root, "runtimeBenchAllocator")) root.runtimeBenchAllocator() else std.heap.smp_allocator;
}
pub fn now() i96 {
    return std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
}
pub fn emit(name: []const u8, sample: usize, ns: i96, units: usize, checksum: u64, allocations: usize, retained: usize, calls: usize) void {
    emitWithIndex(name, sample, ns, units, checksum, allocations, retained, calls, 0);
}
pub fn emitWithIndex(name: []const u8, sample: usize, ns: i96, units: usize, checksum: u64, allocations: usize, retained: usize, calls: usize, dispatch: usize) void {
    std.mem.doNotOptimizeAway(checksum);
    if (sample < warmup) return;
    std.debug.print("\nBENCH {{\"case\":\"{s}\",\"sample\":{d},\"ns\":{d},\"units\":{d},\"checksum\":{d},\"allocations\":{d},\"retained_bytes\":{d},\"calls\":{d},\"dispatch\":{d}}}\n", .{ name, sample - warmup, ns, units, checksum, allocations, retained, calls, dispatch });
}
