pub const TerminalSession = @import("terminal/session.zig");
pub const PtySession = @import("macos/pty_session.zig");
pub const GridModel = @import("macos/grid_model.zig");
pub const CoreTextRenderer = @import("macos/core_text_renderer.zig");
pub const capi = @import("macos/capi.zig");

test {
    _ = @import("macos/kitty_tests.zig");
}

comptime {
    _ = @sizeOf(TerminalSession);
    _ = @sizeOf(PtySession);
    _ = @sizeOf(GridModel.Frame);
    _ = @sizeOf(CoreTextRenderer);
    // Force the C-ABI exports to be analyzed and kept in the static library.
    _ = capi;
    _ = @import("layout_capi.zig");
}
