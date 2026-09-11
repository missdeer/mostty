const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../config.zig");
const Renderer = @import("renderer.zig");
const diag = @import("diag.zig");
const icons_mod = @import("icons.zig");
const state = @import("state.zig");

pub const global = struct {
    pub var icons: icons_mod.Icons = undefined;
    pub var renderer: Renderer = undefined;
    pub var window: ?state.Window = null;
    pub var gpa: std.heap.DebugAllocator(.{}) = .init;
    pub var config: Config = .{};
};

pub fn windowFromHwnd(hwnd: win32.HWND) *state.Window {
    std.debug.assert(hwnd == global.window.?.hwnd or global.window.?.paneFromHwnd(hwnd) != null);
    return &global.window.?;
}

pub fn inputPane(hwnd: win32.HWND) *state.Pane {
    return global.window.?.paneFromHwnd(hwnd).?;
}

pub fn tabBarHeight(hwnd: win32.HWND) i32 {
    return if (global.window != null and hwnd == global.window.?.hwnd) global.renderer.common.tab_bar_height else 0;
}

pub fn flushMessages() void {
    var msg: win32.MSG = undefined;
    while (true) {
        const result = win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE);
        if (result < 0) win32.panicWin32("PeekMessage", win32.GetLastError());
        if (result == 0) break;
        if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
        _ = win32.TranslateMessage(&msg);
        const dispatch_start_ms = if (diag.isEnabled()) win32.GetTickCount64() else 0;
        _ = win32.DispatchMessageW(&msg);
        if (diag.isEnabled()) {
            const elapsed = win32.GetTickCount64() -| dispatch_start_ms;
            if (elapsed >= 100) {
                std.log.info("message dispatch: msg=0x{x} elapsed_ms={}", .{ msg.message, elapsed });
            }
        }
    }
}

pub fn onWmQuit(wparam: win32.WPARAM) noreturn {
    if (std.math.cast(u32, wparam)) |exit_code| {
        std.log.info("quit {}", .{exit_code});
        win32.ExitProcess(exit_code);
    }
    std.log.info("quit {} (0xffffffff)", .{wparam});
    win32.ExitProcess(0xffffffff);
}
