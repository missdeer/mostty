const win32 = @import("win32").everything;
const std = @import("std");

const global_mod = @import("global.zig");
const Renderer = @import("Renderer.zig");
const mouse = @import("wnd/mouse.zig");
const state = @import("state.zig");
const tab_bar = @import("tab_bar.zig");
const types = @import("types.zig");

const Window = state.Window;
const global = global_mod.global;

pub fn renderWindow(window: *Window) void {
    if (window.confirming_renderer_fallback) return;

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
    if (global.renderer.render(
        window.hwnd,
        window.active().id,
        window.active().term,
        tabbar,
        window.resizing,
        window.mouse_in_scrollbar,
        if (window.mouse_capture == .selecting) 1.0 else window.selection_fade,
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
        global.renderer.reloadBackgroundImage(global.gpa.allocator(), &global.config, window.hwnd);
        std.log.warn("renderer: user accepted runtime fallback from {s} to d3d11", .{failure.backendName()});
        _ = win32.InvalidateRect(window.hwnd, null, 0);
    }
}

// Pixel position of the top-left of the active tab's cursor cell, including
// the tab-bar band offset at the top.
pub fn caretPixelPos(window: *Window) ?win32.POINT {
    if (window.tabs.items.len == 0) return null;
    const screen = window.active().term.screens.active;
    const cs = global.renderer.common.cell_size;
    const x: i32 = @as(i32, @intCast(screen.cursor.x)) * cs.cx;
    const y: i32 = @as(i32, @intCast(screen.cursor.y)) * cs.cy + global.renderer.common.tab_bar_height;
    return .{ .x = x, .y = y };
}
