test "runtime benchmark native multi-pane continuation" {
    try runtimeBenchDrain(128 * 1024);
    try runtimeBenchDrain(1024 * 1024);
}

fn runtimeBenchDrain(comptime byte_count: usize) !void {
    const B = @import("../../runtime_bench_support.zig");
    const bytes = try B.allocator().alloc(u8, byte_count);
    defer B.allocator().free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = switch (i % 80) {
        78 => '\r',
        79 => '\n',
        else => @intCast('a' + i % 26),
    };
    const hwnd = win32.CreateWindowExW(.{}, win32.L("STATIC"), win32.L("drain-benchmark"), .{}, 0, 0, 1, 1, null, null, null, null) orelse return error.CreateWindowFailed;
    defer _ = win32.DestroyWindow(hwnd);
    for (0..B.warmup + B.samples) |sample| {
        global.window = .{ .hwnd = hwnd };
        defer global.window = null;
        const window = &global.window.?;
        defer window.panes.deinit(B.allocator());
        defer _ = win32.KillTimer(hwnd, types.TIMER_PTY_DRAIN);
        var panes: [8]Tab = undefined;
        var initialized: usize = 0;
        defer for (panes[0..initialized]) |*pane| {
            pane.session.deinit();
            pane.pty_ring.deinit(B.allocator());
        };
        for (&panes, 0..) |*pane, i| {
            pane.* = .{ .id = @intCast(i + 1), .tab = undefined, .child_process = undefined, .session = undefined, .term = undefined };
            pane.pty_ring = try @import("../pty_ring.zig").PtyRing.init(B.allocator(), &pane.reader_stop);
            pane.session.init(.{ .io = std.testing.io, .terminal_allocator = B.allocator(), .stream_allocator = B.allocator(), .cols = 80, .rows = 24, .hooks = .{ .context = pane } }) catch |err| {
                pane.pty_ring.deinit(B.allocator());
                return err;
            };
            pane.term = pane.session.term;
            initialized += 1;
            try window.panes.append(B.allocator(), pane);
            try std.testing.expect(pane.pty_ring.write(bytes));
            pane.pty_ring.posted.store(true, .release);
        }
        var rounds: usize = 0;
        var progressed: [8]bool = @splat(false);
        var all_progress_round: usize = 0;
        var all_progress_ns: i96 = 0;
        var dispatch_times: [10000]i96 = undefined;
        const start = B.now();
        while (true) {
            const dispatch = B.now();
            drainPendingPtyTabs();
            dispatch_times[rounds] = B.now() - dispatch;
            rounds += 1;
            var pending = false;
            for (&panes, 0..) |*pane, i| {
                pending = pending or pane.pty_ring.hasData();
                progressed[i] = progressed[i] or pane.pty_ring.tail.load(.acquire) != 0;
            }
            if (all_progress_round == 0 and std.mem.allEqual(bool, &progressed, true)) {
                all_progress_round = rounds;
                all_progress_ns = B.now() - start;
            }
            if (!pending) break;
            try std.testing.expect(rounds < 10000);
        }
        const elapsed = B.now() - start;
        var checksum: u64 = 0;
        for (&panes) |*pane| {
            try std.testing.expectEqual(bytes.len, pane.pty_ring.tail.load(.acquire));
            const output = try pane.term.plainString(B.allocator());
            defer B.allocator().free(output);
            checksum +%= std.hash.Wyhash.hash(0, output);
        }
        try std.testing.expect(all_progress_round > 0);
        for (dispatch_times[0..rounds], 0..) |ns, index| B.emitWithIndex(if (byte_count == 128 * 1024) "windows_dispatch" else "windows_saturated_dispatch", sample, ns, 1, 0, 0, 0, 1, index);
        B.emit(if (byte_count == 128 * 1024) "windows_all_panes_progress" else "windows_saturated_all_panes_progress", sample, all_progress_ns, panes.len, 0, 0, 0, all_progress_round);
        B.emit(if (byte_count == 128 * 1024) "windows_output_total" else "windows_saturated_output_total", sample, elapsed, bytes.len * panes.len, checksum, 0, 0, rounds);
    }
}
