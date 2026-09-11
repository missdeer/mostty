pub const TerminalSession = @import("terminal/Session.zig");
pub const PtySession = @import("macos/PtySession.zig");
pub const GridModel = @import("macos/GridModel.zig");
pub const CoreTextRenderer = @import("macos/CoreTextRenderer.zig");
pub const capi = @import("macos/capi.zig");

test {
    _ = @import("macos/KittyTests.zig");
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
