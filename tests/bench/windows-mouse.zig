var runtime_bench_hover_probes: usize = 0;
fn runtimeBenchDetect(term: *vt.Terminal, col: u16, row: u16) ?url_hover.Hit {
    runtime_bench_hover_probes += 1;
    return url_hover.detectAt(term, col, row);
}

test "runtime benchmark native negative hover" {
    const B = @import("../../runtime_bench_support.zig");
    const hwnd = win32.CreateWindowExW(.{}, win32.L("STATIC"), win32.L("hover-benchmark"), .{}, 0, 0, 960, 640, null, null, null, null) orelse return error.CreateWindowFailed;
    defer _ = win32.DestroyWindow(hwnd);
    global.window = .{ .hwnd = hwnd };
    defer global.window = null;
    global.renderer.common.cell_size = .{ .cx = 8, .cy = 16 };
    global.renderer.common.tab_bar_height = 0;
    defer global.renderer = undefined;
    const window = &global.window.?;
    defer window.panes.deinit(B.allocator());
    var pane: state.Pane = .{ .id = 1, .hwnd = hwnd, .tab = undefined, .child_process = undefined, .session = undefined, .term = undefined };
    try pane.session.init(.{ .io = std.testing.io, .terminal_allocator = B.allocator(), .stream_allocator = B.allocator(), .cols = 120, .rows = 40, .hooks = .{ .context = &pane } });
    defer pane.session.deinit();
    pane.term = pane.session.term;
    try window.panes.append(B.allocator(), &pane);
    pane.session.feed("a" ** 4096);
    for (0..B.warmup + B.samples) |sample| {
        clearUrlHover(window);
        runtime_bench_hover_probes = 0;
        const start = B.now();
        for (0..10000) |_| updateUrlHover(window, hwnd, 16, 8);
        const ns = B.now() - start;
        try std.testing.expect(window.hovered_url == null);
        B.emit("windows_hover", sample, ns, 10000, 0, 0, 0, runtime_bench_hover_probes);
    }
}
