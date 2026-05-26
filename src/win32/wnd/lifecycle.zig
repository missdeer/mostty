const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const types = @import("../types.zig");

const TabId = types.TabId;
const global = global_mod.global;

pub fn onCreate(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    std.debug.assert(global.window == null);
    global.window = .{ .hwnd = hwnd };
    const window = &global.window.?;
    tab_mgmt.newTab(window);
    return 0;
}

pub fn onClose(_: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (global.window) |*window| {
        if (window.confirming_close) return 0;
        window.confirming_close = true;
        defer window.confirming_close = false;
        if (!tab_mgmt.confirmYesNo(
            window.hwnd,
            win32.L("Close window and all tabs?"),
            win32.L("Mite"),
        )) return 0;
        tab_mgmt.destroyAllTabs(window);
    } else {
        win32.PostQuitMessage(0);
    }
    return 0;
}

pub fn onDestroy(_: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (global.window) |*window| {
        tab_mgmt.destroyAllTabs(window);
    } else {
        win32.PostQuitMessage(0);
    }
    return 0;
}

pub fn onAppCloseTab(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const tab_id: TabId = @intCast(wparam);
    const tab = window.findById(tab_id) orelse return 0;
    tab_mgmt.destroyTab(window, tab);
    return 0;
}
