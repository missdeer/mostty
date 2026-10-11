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
