test "runtime benchmark production cached ligature runs" {
    const B = @import("../../runtime_bench_support.zig");
    const Cache = @import("../glyph_index_cache.zig");
    var fixture: @import("run_cache_fixture.zig") = .{};
    try fixture.init(B.allocator(), .regular);
    defer fixture.deinit();
    for (0..B.warmup + B.samples) |sample| {
        Cache.test_run_hash_calls = 0;
        var checksum: u64 = 0;
        const start = B.now();
        for (0..5000) |iteration| checksum +%= try fixture.run(iteration);
        B.emit("windows_ligature_runs", sample, B.now() - start, 5000 * 32, checksum, 0, 0, Cache.test_run_hash_calls);
    }
}
