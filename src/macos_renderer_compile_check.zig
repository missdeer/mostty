const std = @import("std");

const CoreTextRenderer = @import("macos/core_text_renderer.zig");
const TerminalSession = @import("terminal/session.zig");

export fn mostty_macos_renderer_compile_check(raw_session: *anyopaque) void {
    const session: *TerminalSession = @ptrCast(@alignCast(raw_session));
    var renderer = CoreTextRenderer.init(.{
        .allocator = std.heap.page_allocator,
        .pixel_width = 640,
        .pixel_height = 480,
    }) catch return;
    defer renderer.deinit();

    renderer.resize(800, 600, 2) catch return;
    _ = renderer.gridSize();
    _ = renderer.render(session, .{ .col = 0, .row = 0 }) catch return;
}
