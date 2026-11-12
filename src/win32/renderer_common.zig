const RendererCommon = @This();

const win32 = @import("win32").everything;
const types = @import("types.zig");

cell_size: win32.SIZE,
tab_bar_height: i32,
font_ligatures: bool,
remote_or_software_adapter: bool,
// Zero identifies the main surface; panes use their never-reused pane ID.
surface_id: u32 = 0,
focused: bool = true,
// Whether TIMER_TEXT_BLINK is currently armed. Every backend re-derives the
// desired state from `build.has_blink` on every frame; without this the
// renderer issues a SetTimer or KillTimer syscall per frame forever.
blink_timer_armed: bool = false,
// Only a successfully presented pane can reuse its displayed contents.
pane_present_valid: bool = false,
pane_present_size: [2]u32 = .{ 0, 0 },
glyph_atlas_budget_bytes: u32 = 64 * 1024 * 1024,
atlas_growths: u64 = 0,
glyph_retry: bool = false,

pub fn beginPaneSubmission(self: *RendererCommon, width: u32, height: u32, changed: bool) bool {
    if (self.surface_id == 0) return true;
    if (!changed and self.pane_present_valid and
        self.pane_present_size[0] == width and self.pane_present_size[1] == height) return false;
    // Dirty rows have already updated the shadow. Keep retrying if presentation
    // is deferred or fails even when the next comparison finds identical cells.
    self.pane_present_valid = false;
    return true;
}

pub fn notePanePresented(self: *RendererCommon, width: u32, height: u32) void {
    self.pane_present_size = .{ width, height };
    self.pane_present_valid = true;
}

test "unchanged panes skip submission only after success and retain repaint and retry obligations" {
    const std = @import("std");
    var common: RendererCommon = .{ .cell_size = .{ .cx = 8, .cy = 16 }, .tab_bar_height = 0, .font_ligatures = true, .remote_or_software_adapter = false, .surface_id = 1 };
    // First paint and deferred/failed submissions must retry even after the
    // cell shadow has caught up with the terminal.
    try std.testing.expect(common.beginPaneSubmission(320, 200, false));
    try std.testing.expect(common.beginPaneSubmission(320, 200, false));
    common.notePanePresented(320, 200);
    for (0..1000) |_| try std.testing.expect(!common.beginPaneSubmission(320, 200, false));
    // A content, glyph, paint or image change requires a new successful frame.
    try std.testing.expect(common.beginPaneSubmission(320, 200, true));
    try std.testing.expect(common.beginPaneSubmission(320, 200, false));
    common.notePanePresented(320, 200);
    // Pixel-only resizes matter even when the terminal's row/column counts
    // stay the same. Returning to the old size is another change.
    try std.testing.expect(common.beginPaneSubmission(321, 200, false));
    common.notePanePresented(321, 200);
    try std.testing.expect(common.beginPaneSubmission(320, 200, false));
    common.notePanePresented(320, 200);
    try std.testing.expect(common.beginPaneSubmission(320, 201, false));
    common.notePanePresented(320, 201);
    // Exposure invalidates presentation independently of terminal content.
    common.pane_present_valid = false;
    try std.testing.expect(common.beginPaneSubmission(320, 201, false));
    common.notePanePresented(320, 201);
    try std.testing.expect(!common.beginPaneSubmission(320, 201, false));
    // Chrome has independent title/tab/hover state and retains its own path.
    common.surface_id = 0;
    try std.testing.expect(common.beginPaneSubmission(320, 201, false));
}

// Arm or cancel the SGR-blink timer only on a state change.
pub fn syncBlinkTimer(self: *RendererCommon, hwnd: win32.HWND, want: bool) void {
    if (want == self.blink_timer_armed) return;
    if (want) {
        // Only mark armed once SetTimer succeeds: the early-out above would
        // otherwise suppress every later retry, leaving blinking text frozen
        // in its current phase once the window goes idle.
        if (win32.SetTimer(hwnd, types.TIMER_TEXT_BLINK, 250, null) == 0) return;
    } else {
        _ = win32.KillTimer(hwnd, types.TIMER_TEXT_BLINK);
    }
    self.blink_timer_armed = want;
}

test "blink timer can rearm after pane suspension and redundant suspension is inert" {
    const std = @import("std");
    const hwnd = win32.CreateWindowExW(.{}, win32.L("STATIC"), win32.L("blink-test"), .{}, 0, 0, 1, 1, null, null, null, null) orelse return error.CreateWindowFailed;
    defer _ = win32.DestroyWindow(hwnd);
    var common: RendererCommon = .{ .cell_size = .{ .cx = 8, .cy = 16 }, .tab_bar_height = 0, .font_ligatures = true, .remote_or_software_adapter = false };
    common.syncBlinkTimer(hwnd, true);
    try std.testing.expect(common.blink_timer_armed);
    // reflow uses this same transition before SW_HIDE; restored rendering
    // must be able to arm again, using the existing wall-clock blink phase.
    common.syncBlinkTimer(hwnd, false);
    common.syncBlinkTimer(hwnd, false);
    try std.testing.expect(!common.blink_timer_armed);
    try std.testing.expectEqual(@as(win32.BOOL, 0), win32.KillTimer(hwnd, types.TIMER_TEXT_BLINK));
    common.syncBlinkTimer(hwnd, true);
    try std.testing.expect(common.blink_timer_armed);
    common.syncBlinkTimer(hwnd, false);
}
