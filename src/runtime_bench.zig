//! Identical source is overlaid on both compared revisions by tests/bench.
const std = @import("std");
const B = @import("runtime_bench_support.zig");
const Session = @import("terminal/session.zig");
const Grid = @import("macos/grid_model.zig");
const Key = @import("win32/glyph_index_cache.zig").Key;

test "runtime benchmark ligature keys" {
    var text: [32]u8 = undefined;
    for (&text, 0..) |*ch, i| ch.* = @intCast('a' + i % 26);
    for (0..B.warmup + B.samples) |sample| {
        var checksum: u64 = 0;
        const start = B.now();
        for (0..5000) |iteration| {
            text[0] = @intCast('a' + iteration % 26);
            std.mem.doNotOptimizeAway(&text);
            // Adapter mirrors generateRun: only the new revision has offset
            // derivation. Both construct exactly the same 32 cache keys.
            const base = Key.initRun(&text, 0, .regular);
            for (0..text.len) |offset| {
                const key = if (@hasDecl(Key, "atRunOffset")) base.atRunOffset(@intCast(offset)) else Key.initRun(&text, @intCast(offset), .regular);
                std.mem.doNotOptimizeAway(key);
                checksum +%= key.hash_a ^ key.hash_b ^ key.run_offset;
            }
        }
        B.emit("ligature_keys", sample, B.now() - start, 5000 * text.len, checksum, 0, 0, 5000 * @as(usize, if (@hasDecl(Key, "atRunOffset")) 1 else text.len));
    }
}

test "runtime benchmark viewport frame storage" {
    var session: Session = undefined;
    var context: u8 = 0;
    try session.init(.{ .io = std.testing.io, .terminal_allocator = B.allocator(), .stream_allocator = B.allocator(), .cols = 120, .rows = 40, .hooks = .{ .context = &context } });
    defer session.deinit();
    for (0..40) |_| session.feed("ascii -> === 界 e\u{301} 👍 \x1b[31mstyled\x1b[0m\r\n");
    var counted = std.testing.FailingAllocator.init(B.allocator(), .{});
    var cells: std.ArrayListUnmanaged(Grid.Cell) = .empty;
    defer cells.deinit(counted.allocator());
    const options: Grid.Options = .{ .metrics = .{ .cell_width = 8, .cell_height = 16 }, .pixel_width = 960, .pixel_height = 640 };
    for (0..B.warmup + B.samples) |sample| {
        var checksum: u64 = 0;
        const allocations = counted.allocations;
        const start = B.now();
        for (0..100) |_| {
            var frame = if (@hasDecl(Grid, "buildRetained")) try Grid.buildRetained(counted.allocator(), &cells, session.term, options) else try Grid.build(counted.allocator(), session.term, options);
            defer frame.deinit();
            try std.testing.expectEqual(@as(u32, 120), frame.cols);
            try std.testing.expectEqual(@as(u32, 40), frame.rows);
            for (frame.cells) |cell| {
                checksum +%= cell.codepoint;
                checksum +%= cell.style.foreground.r;
                std.mem.doNotOptimizeAway(cell);
            }
        }
        B.emit("viewport_frames", sample, B.now() - start, 100 * 120 * 40, checksum, counted.allocations - allocations, counted.allocated_bytes - counted.freed_bytes, 100);
    }
}

test "runtime benchmark multipart scratch throughput and retention" {
    for (0..B.warmup + B.samples) |sample| {
        var counted = std.testing.FailingAllocator.init(B.allocator(), .{});
        var context: u8 = 0;
        var session: Session = undefined;
        try session.init(.{ .io = std.testing.io, .terminal_allocator = B.allocator(), .stream_allocator = counted.allocator(), .cols = 80, .rows = 24, .hooks = .{ .context = &context } });
        defer session.deinit();
        const part = [_]u8{'A'} ** 4096;
        const allocations = counted.allocations;
        const start = B.now();
        for (0..4) |_| {
            session.feed("\x1b]1337;MultipartFile=inline=1\x07\x1b]1337;FilePart=");
            for (0..257) |_| session.feed(&part);
            session.feed("\x07\x1b]1337;MultipartFile=inline=1;width=2px\x07");
            try std.testing.expectEqualStrings("inline=1;width=2px:", session.images.transfer.items);
        }
        const elapsed = B.now() - start;
        const checksum = std.hash.Wyhash.hash(0, session.images.transfer.items);
        B.emit("multipart_scratch", sample, elapsed, 4 * 257 * part.len, checksum, counted.allocations - allocations, session.images.transfer.capacity + session.images.payload.capacity, 4);
    }
}
