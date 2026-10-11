test "runtime benchmark native unchanged font configuration" {
    const B = @import("../runtime_bench_support.zig");
    var counted = std.testing.FailingAllocator.init(B.allocator(), .{});
    const options = fontOptions(config());
    var renderer = try CoreTextRenderer.init(.{ .allocator = counted.allocator(), .pixel_width = 640, .pixel_height = 400, .font = options });
    defer renderer.deinit();
    const original_metrics = renderer.metrics;
    for (0..B.warmup + B.samples) |sample| {
        const allocations = counted.allocations;
        const start = B.now();
        for (0..32) |_| {
            _ = try renderer.reconfigure(options);
            try std.testing.expectEqualDeep(original_metrics, renderer.metrics);
            std.mem.doNotOptimizeAway(&renderer);
        }
        B.emit("macos_font_config", sample, B.now() - start, 32, renderer.metrics.cell_width * 1000 + renderer.metrics.cell_height, counted.allocations - allocations, counted.allocated_bytes - counted.freed_bytes, 32);
    }
}
