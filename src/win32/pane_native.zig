const std = @import("std");
const win32 = @import("win32").everything;
const state = @import("state.zig");
const types = @import("types.zig");
const global_mod = @import("global.zig");
const global = global_mod.global;
const Renderer = @import("Renderer.zig");
const tab_mgmt = @import("tab_mgmt.zig");
const geom = @import("window_geom.zig");
const dispatch = @import("wnd/dispatch.zig");
const Error = @import("error.zig").Error;

var class_registered = false;
const class_name = win32.L("MosttyPane");

pub fn supported() bool {
    return global.renderer.supportsPanes();
}

fn create(window: *state.Window, pane: *state.Pane) void {
    if (!class_registered) {
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .DBLCLKS = 1 },
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_IBEAM),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&wc) == 0) win32.panicWin32("RegisterClassExW(pane)", win32.GetLastError());
        class_registered = true;
    }
    pane.common = global.renderer.common;
    pane.common.surface_id = pane.id;
    pane.common.tab_bar_height = 0;
    pane.common.blink_timer_armed = false;
    pane.renderer = global.renderer.initPaneSurface(&pane.common) catch |err| {
        pane.closing = true;
        std.log.err("cannot create pane {} for {s}: {s}", .{ pane.id, @tagName(global.renderer.configured_backend), @errorName(err) });
        _ = win32.MessageBoxW(window.hwnd, win32.L("The selected renderer could not create this pane. Its session will close; the renderer has not been changed."), win32.L("Mostty pane unavailable"), .{ .ICONHAND = 1 });
        _ = win32.PostMessageW(window.hwnd, types.WM_APP_CLOSE_PANE, pane.id, 0);
        return;
    };
    if (pane.renderer == null) std.debug.panic("selected renderer cannot create a pane surface", .{});
    pane.hwnd = win32.CreateWindowExW(
        .{ .NOREDIRECTIONBITMAP = 1 },
        class_name,
        win32.L("Mostty terminal pane"),
        .{ .CHILD = 1, .CLIPSIBLINGS = 1 },
        0,
        0,
        1,
        1,
        window.hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse win32.panicWin32("CreateWindowExW(pane)", win32.GetLastError());
    _ = win32.ImmAssociateContextEx(pane.hwnd.?, null, win32.IACE_DEFAULT);
    win32.DragAcceptFiles(pane.hwnd.?, 1);
    _ = win32.ChangeWindowMessageFilterEx(pane.hwnd.?, win32.WM_DROPFILES, win32.MSGFLT_ALLOW, null);
    _ = win32.ChangeWindowMessageFilterEx(pane.hwnd.?, 0x0049, win32.MSGFLT_ALLOW, null);
}

pub fn destroy(window: *state.Window, pane: *state.Pane) void {
    if (pane.hwnd) |hwnd| {
        if (win32.GetCapture() == hwnd) {
            window.mouse_capture = .none;
            window.mouse_report_tab_id = null;
            window.capture_pane_id = null;
            _ = win32.ReleaseCapture();
        }
        if (pane.renderer) |*renderer| renderer.deinit();
        pane.renderer = null;
        _ = win32.DestroyWindow(hwnd);
        pane.hwnd = null;
    }
}

fn resizePane(window: *state.Window, pane: *state.Pane, size: types.GridPos) void {
    if (pane.closing) return;
    if (pane.term.cols != size.col or pane.term.rows != size.row) {
        pane.session.resize(size.col, size.row) catch |err| std.debug.panic("resize terminal: {s}", .{@errorName(err)});
        var failure: Error = undefined;
        pane.child_process.resize(&failure, size) catch |err| switch (err) {
            error.Closed => {
                pane.closing = true;
                _ = win32.PostMessageW(window.hwnd, types.WM_APP_CLOSE_PANE, pane.id, 0);
            },
            error.Error => std.debug.panic("{f}", .{failure}),
        };
    }
    tab_mgmt.syncTerminalPixelSize(pane);
    if (@import("diag.zig").isEnabled()) std.log.info("pane size: id={} hwnd={} vt={}x{} cell={}x{}", .{ pane.id, if (pane.hwnd) |h| @intFromPtr(h) else 0, pane.term.cols, pane.term.rows, global.renderer.common.cell_size.cx, global.renderer.common.cell_size.cy });
}

pub fn reflow(window: *state.Window) void {
    if (window.layout_updating or win32.IsIconic(window.hwnd) != 0) return;
    window.layout_updating = true;
    defer window.layout_updating = false;
    const cs = global.renderer.common.cell_size;
    if (!supported()) {
        for (window.panes.items) |pane| resizePane(window, pane, geom.computeGridCellCount(window.hwnd, cs));
        return;
    }
    const size = win32.getClientSize(window.hwnd);
    const band = global.renderer.common.tab_bar_height;
    const dpi = win32.dpiFromHwnd(window.hwnd);
    const gap: f64 = @max(4, @as(f64, @floatFromInt(dpi)) * 4 / 96);
    const minimum: state.SplitLayout.Size = .{
        .width = @floatFromInt(cs.cx * 12 + @as(i32, Renderer.scrollbarWidth(dpi))),
        .height = @floatFromInt(cs.cy * 2),
    };
    for (window.tabs.items) |tab| {
        tab.layout.setBounds(.{ .x = 0, .y = @floatFromInt(band), .width = @floatFromInt(@max(0, size.cx)), .height = @floatFromInt(@max(0, size.cy - band)) }, minimum, gap) catch unreachable;
    }
    for (window.panes.items) |pane| {
        if (pane.closing) continue;
        if (pane.hwnd == null) create(window, pane);
        if (pane.closing) continue;
        syncSurface(pane);
        const rect = pane.tab.layout.paneRect(pane.id);
        if (rect) |r| {
            const x: i32 = @intFromFloat(@round(r.x));
            const y: i32 = @intFromFloat(@round(r.y));
            const width: i32 = @as(i32, @intFromFloat(@round(r.x + r.width))) - x;
            const height: i32 = @as(i32, @intFromFloat(@round(r.y + r.height))) - y;
            _ = win32.SetWindowPos(pane.hwnd.?, null, x, y, width, height, .{ .NOZORDER = 1, .NOACTIVATE = 1 });
            resizePane(window, pane, geom.computeGridCellCount(pane.hwnd.?, cs));
        }
        const visible = window.tabs.items.len > 0 and pane.tab == window.activeTab() and rect != null;
        _ = win32.ShowWindow(pane.hwnd.?, if (visible) win32.SW_SHOWNA else win32.SW_HIDE);
    }
    window.requestRender();
}

pub fn syncSurface(pane: *state.Pane) void {
    pane.renderer.?.sync(&global.renderer, pane.tab.layout.active == pane.id);
}

pub fn focusActive(window: *state.Window) void {
    if (window.tabs.items.len == 0) return;
    const hwnd = window.active().hwnd orelse window.hwnd;
    if (win32.GetFocus() != hwnd) _ = win32.SetFocus(hwnd);
}

pub fn focusPane(window: *state.Window, pane: *state.Pane) void {
    if (pane.closing or pane.tab != window.activeTab()) return;
    if (pane.tab.layout.active != pane.id) {
        _ = pane.tab.layout.focus(pane.id);
        window.onActiveChanged();
    }
    focusActive(window);
}

pub fn focusDirection(window: *state.Window, direction: state.SplitLayout.Direction) void {
    if (window.tabs.items.len == 0) return;
    if (window.activeTab().layout.focusDirection(direction)) {
        reflow(window);
        window.onActiveChanged();
        focusActive(window);
    }
}

pub fn toggleMaximize(window: *state.Window) void {
    if (window.tabs.items.len == 0) return;
    window.activeTab().layout.toggleMaximize();
    reflow(window);
    focusActive(window);
}

// Only the main window's exposed divider regions reach this handler.
pub fn mainMessage(window: *state.Window, msg: u32, wp: win32.WPARAM, lp: win32.LPARAM) ?win32.LRESULT {
    if (!supported() or window.tabs.items.len == 0) return null;
    if (msg == win32.WM_GETMINMAXINFO) {
        const minimum = window.activeTab().layout.minimumSize();
        const inset = @import("util.zig").getClientInset(win32.dpiFromHwnd(window.hwnd));
        const outer: win32.SIZE = .{
            .cx = @as(i32, @intFromFloat(@ceil(minimum.width))) + inset.cx,
            .cy = @as(i32, @intFromFloat(@ceil(minimum.height))) + global.renderer.common.tab_bar_height + inset.cy,
        };
        const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
        info.ptMinTrackSize.x = @max(info.ptMinTrackSize.x, outer.cx);
        info.ptMinTrackSize.y = @max(info.ptMinTrackSize.y, outer.cy);
        return 0;
    }
    if (msg == win32.WM_SETFOCUS) {
        focusActive(window);
        return 0;
    }
    if (msg == win32.WM_CAPTURECHANGED or msg == win32.WM_CANCELMODE) window.divider_drag = null;
    const x: f64 = @floatFromInt(win32.xFromLparam(lp));
    const y: f64 = @floatFromInt(win32.yFromLparam(lp));
    if (msg == win32.WM_LBUTTONDOWN) {
        const tab = window.activeTab();
        if (tab.layout.hitDivider(x, y)) |hit| {
            window.divider_drag = .{ .tab_id = tab.id, .split_id = hit.id, .axis = hit.axis, .offset = if (hit.axis == .columns) x - hit.rect.x else y - hit.rect.y };
            _ = win32.SetCapture(window.hwnd);
            return 0;
        }
    }
    if (window.divider_drag) |drag| {
        if (msg == win32.WM_MOUSEMOVE) {
            if (window.findTabIndexById(drag.tab_id)) |i| {
                if (window.tabs.items[i].layout.drag(drag.split_id, (if (drag.axis == .columns) x else y) - drag.offset)) reflow(window);
            }
            return 0;
        }
        if (msg == win32.WM_LBUTTONUP) {
            window.divider_drag = null;
            _ = win32.ReleaseCapture();
            return 0;
        }
    }
    if (msg == win32.WM_SETCURSOR and @as(u16, @truncate(@as(usize, @bitCast(lp)))) == win32.HTCLIENT) {
        if (window.divider_drag) |drag| {
            _ = win32.SetCursor(win32.LoadCursorW(null, if (drag.axis == .columns) win32.IDC_SIZEWE else win32.IDC_SIZENS));
            return 1;
        }
        var p: win32.POINT = undefined;
        if (win32.GetCursorPos(&p) != 0 and win32.ScreenToClient(window.hwnd, &p) != 0) {
            if (window.activeTab().layout.hitDivider(@floatFromInt(p.x), @floatFromInt(p.y))) |hit| {
                _ = win32.SetCursor(win32.LoadCursorW(null, if (hit.axis == .columns) win32.IDC_SIZEWE else win32.IDC_SIZENS));
                return 1;
            }
        }
    }
    if (y >= @as(f64, @floatFromInt(global.renderer.common.tab_bar_height))) switch (msg) {
        win32.WM_MOUSEMOVE, win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP, win32.WM_LBUTTONDBLCLK, win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP, win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => return 0,
        else => {},
    };
    _ = wp;
    return null;
}

fn wndProc(hwnd: win32.HWND, msg: u32, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const window = if (global.window) |*w| w else return win32.DefWindowProcW(hwnd, msg, wp, lp);
    const pane = window.paneFromHwnd(hwnd) orelse return win32.DefWindowProcW(hwnd, msg, wp, lp);
    if (pane.closing) return win32.DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        win32.WM_PAINT => {
            _, var ps = win32.beginPaint(hwnd);
            win32.endPaint(hwnd, &ps);
            if (!window.layout_updating) window.requestRender();
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_CAPTURECHANGED => {
            if (window.capture_pane_id == pane.id) {
                window.capture_pane_id = null;
                window.mouse_capture = .none;
                window.mouse_report_tab_id = null;
            }
            return 0;
        },
        win32.WM_SETFOCUS => {
            focusPane(window, pane);
            return 0;
        },
        win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN => focusPane(window, pane),
        win32.WM_CREATE, win32.WM_DESTROY, win32.WM_NCDESTROY, win32.WM_WINDOWPOSCHANGED, win32.WM_SIZE => return win32.DefWindowProcW(hwnd, msg, wp, lp),
        win32.WM_CLOSE => {
            _ = win32.PostMessageW(window.hwnd, types.WM_APP_CLOSE_PANE, pane.id, 0);
            return 0;
        },
        else => {},
    }
    if (dispatch.handlerFor(msg)) |handler| {
        if (handler(hwnd, wp, lp)) |result| return result;
    }
    return win32.DefWindowProcW(hwnd, msg, wp, lp);
}
