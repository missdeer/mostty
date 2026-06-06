const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const tooltip = @import("../tooltip.zig");
const types = @import("../types.zig");

const TabId = types.TabId;
const global = global_mod.global;

pub fn onCreate(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    std.debug.assert(global.window == null);
    global.window = .{ .hwnd = hwnd };
    const window = &global.window.?;
    // Boot the renderer at whatever cadence the current session deserves, then
    // keep it in sync by subscribing to WTS session-change notifications so
    // an RDP connect/disconnect after launch toggles the cap dynamically.
    // Sentinel 0 forces applyRenderInterval to log the initial value (its
    // no-op check is "new == current", which would otherwise skip the log
    // when the local config matches the struct default).
    window.render_interval_ms = 0;
    window.applyRenderInterval(
        global.config.render_interval_local_ms,
        global.config.render_interval_remote_ms,
        global.renderer.remote_or_software_adapter,
    );
    if (win32.WTSRegisterSessionNotification(hwnd, win32.NOTIFY_FOR_THIS_SESSION) == 0) {
        std.log.warn("WTSRegisterSessionNotification failed; render interval will not adapt to RDP connect/disconnect", .{});
    }
    if (win32.GetSystemMenu(hwnd, win32.FALSE)) |menu| {
        _ = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null);
        if (win32.CreatePopupMenu()) |sub| {
            window.theme_submenu = sub;
            // Cast HMENU to the uintptr id slot AppendMenuW expects for MF_POPUP.
            const sub_id: usize = @intFromPtr(sub);
            _ = win32.AppendMenuW(menu, win32.MF_POPUP, sub_id, win32.L("Theme"));
        }
        _ = win32.AppendMenuW(menu, win32.MF_STRING, types.IDM_OPEN_SETTINGS, win32.L("Open Settings File..."));
    }
    if (global.config.theme_name) |name| {
        const gpa = global.gpa.allocator();
        window.active_theme_name = gpa.dupe(u8, name) catch null;
    }
    tooltip.create(window);
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
            win32.L("Mostty"),
        )) return 0;
        tab_mgmt.destroyAllTabs(window);
    } else {
        win32.PostQuitMessage(0);
    }
    return 0;
}

pub fn onDestroy(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (global.window) |*window| {
        // Paired with the registration in onCreate. Best-effort; if it failed
        // at register time the unregister is a harmless no-op.
        _ = win32.WTSUnRegisterSessionNotification(hwnd);
        tooltip.destroy(window);
        tab_mgmt.destroyAllTabs(window);
        if (window.active_theme_name) |s| {
            global.gpa.allocator().free(s);
            window.active_theme_name = null;
        }
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
