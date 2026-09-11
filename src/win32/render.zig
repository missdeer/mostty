const win32 = @import("win32").everything;
const std = @import("std");

const global_mod = @import("global.zig");
const Renderer = @import("renderer.zig");
const mouse = @import("wnd/mouse.zig");
const state = @import("state.zig");
const tab_bar = @import("tab_bar.zig");
const types = @import("types.zig");

const Window = state.Window;
const global = global_mod.global;

pub fn renderWindow(window: *Window) void {
    if (window.confirming_renderer_fallback or window.tabs.items.len == 0 or window.layout_updating) return;

    // Revalidate cached URL hover against current viewport contents. Anything
    // that asked for a repaint (PTY data, resize, keyboard-driven viewport
    // scroll-snap, config reload) automatically refreshes the highlight here;
    // no need to scatter clear/revalidate calls across every state mutation.
    // Cost is one detectAt per frame only when hover_cell is set, capped at
    // the render-throttle rate.
    mouse.revalidateHoverForActiveTab(window);

    const cs = global.renderer.common.cell_size;
    const total_cols: usize = @intCast(@divTrunc(@max(0, win32.getClientSize(window.hwnd).cx), cs.cx));
    var tab_buf: [types.MAX_TABS]types.TabDrawInfo = undefined;
    const tabbar = tab_bar.buildTabBarDraw(window, total_cols, &tab_buf);
    const theme = &global.config.theme;
    // Only forward the URL highlight if it belongs to the active tab — a tab
    // switch keeps Window.hovered_url around until the next mouse move clears
    // or refreshes it, and we don't want one tab's hover to underline cells
    // on another's grid.
    const url_hl: ?types.UrlHighlight = blk: {
        const h = window.hovered_url orelse break :blk null;
        if (h.tab_id != window.active().id) break :blk null;
        break :blk types.UrlHighlight{
            .start_row = h.hit.start_row,
            .start_col = h.hit.start_col,
            .end_row = h.hit.end_row,
            .end_col = h.hit.end_col,
        };
    };
    if (@import("pane_native.zig").supported()) {
        var pane_rects: [types.MAX_PANES]win32.RECT = undefined;
        var pane_rect_count: usize = 0;
        for (window.panes.items) |pane| {
            if (pane.tab != window.activeTab()) continue;
            const r = pane.tab.layout.paneRect(pane.id) orelse continue;
            pane_rects[pane_rect_count] = .{ .left = @intFromFloat(@round(r.x)), .top = @intFromFloat(@round(r.y)), .right = @intFromFloat(@round(r.x + r.width)), .bottom = @intFromFloat(@round(r.y + r.height)) };
            pane_rect_count += 1;
        }
        global.renderer.backend.?.d3d11.renderChrome(window.hwnd, window.active().term, tabbar, theme.background, global.config.background_opacity, window.remote_session, pane_rects[0..pane_rect_count]);
        for (window.panes.items) |pane| {
            if (pane.closing or pane.tab != window.activeTab() or pane.tab.layout.paneRect(pane.id) == null) continue;
            @import("pane_native.zig").syncSurface(pane);
            const highlight: ?types.UrlHighlight = if (window.hovered_url) |h| blk: {
                if (h.tab_id != pane.id) break :blk null;
                break :blk .{ .start_row = h.hit.start_row, .start_col = h.hit.start_col, .end_row = h.hit.end_row, .end_col = h.hit.end_col };
            } else null;
            const captured = win32.GetCapture() == pane.hwnd;
            pane.renderer.?.render(pane.hwnd.?, pane.id, pane.term, .{ .tabs = &.{}, .new_tab_col = null, .new_tab_hovered = false }, window.resizing, window.mouse_in_scrollbar and window.hover_pane_id == pane.id, if (captured and window.mouse_capture == .selecting) 1.0 else pane.selection_fade, theme.cursor_text, theme.selection_background, theme.selection_foreground, global.config.background_opacity, window.remote_session, highlight);
            _ = win32.ValidateRect(pane.hwnd.?, null);
        }
        return;
    }
    if (global.renderer.render(
        window.hwnd,
        window.active().id,
        window.active().term,
        tabbar,
        window.resizing,
        window.mouse_in_scrollbar,
        if (window.mouse_capture == .selecting) 1.0 else window.active().selection_fade,
        theme.cursor_text,
        theme.selection_background,
        theme.selection_foreground,
        global.config.background_opacity,
        window.remote_session,
        url_hl,
    )) |failure| {
        std.log.err(
            "renderer: {s} runtime failure while {s} ({s})",
            .{ failure.backendName(), failure.operationDescription(), failure.codeName() },
        );
        if (global.renderer.recoverVulkan(window.hwnd, global.config.gpu)) {
            std.log.warn("renderer: rebuilt {s} after a runtime failure", .{failure.backendName()});
            _ = win32.InvalidateRect(window.hwnd, null, 0);
            return;
        }
        window.confirming_renderer_fallback = true;
        const accepted = Renderer.confirmRuntimeFallback(window.hwnd, failure);
        if (!accepted) {
            window.confirming_renderer_fallback = false;
            _ = win32.DestroyWindow(window.hwnd);
            return;
        }
        global.renderer.fallbackToD3d11(global.config.gpu) catch |err| {
            std.log.err(
                "renderer: d3d11 fallback from {s} failed ({s}): {s}",
                .{ failure.backendName(), @errorName(err), Renderer.d3d11InitErrorDescription(err) },
            );
            Renderer.reportD3d11Unavailable(window.hwnd, err);
            // Leave paint suppression armed while the current WM_PAINT
            // unwinds, then let the normal message loop process the quit.
            win32.PostQuitMessage(1);
            return;
        };
        window.confirming_renderer_fallback = false;
        global.config.renderer = .d3d11;
        @import("pane_native.zig").reflow(window);
        global.renderer.reloadBackgroundImage(global.gpa.allocator(), &global.config, window.hwnd);
        std.log.warn("renderer: user accepted runtime fallback from {s} to d3d11", .{failure.backendName()});
        _ = win32.InvalidateRect(window.hwnd, null, 0);
    }
}

// Pixel position of the top-left of the active tab's cursor cell, including
// the tab-bar band offset at the top.
pub fn caretPixelPos(hwnd: win32.HWND) ?win32.POINT {
    const window = global_mod.windowFromHwnd(hwnd);
    const pane = window.paneFromHwnd(hwnd) orelse return null;
    const screen = pane.term.screens.active;
    const cs = global.renderer.common.cell_size;
    const x: i32 = @as(i32, @intCast(screen.cursor.x)) * cs.cx;
    const y: i32 = @as(i32, @intCast(screen.cursor.y)) * cs.cy + global_mod.tabBarHeight(hwnd);
    return .{ .x = x, .y = y };
}
