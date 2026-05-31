const std = @import("std");
const win32 = @import("win32").everything;

const state = @import("state.zig");
const types = @import("types.zig");

// Single-tool tracking tooltip: (hwnd, uId) identifies the tool. uId is opaque
// since TTF_IDISHWND is not set.
const TOOL_ID: usize = 1;
// Pixel offset of the tooltip from the cursor's hotspot so it doesn't sit
// directly under the mouse.
const CURSOR_OFFSET_X: i32 = 16;
const CURSOR_OFFSET_Y: i32 = 20;

fn makeLparamXY(x: i32, y: i32) win32.LPARAM {
    const xc: i32 = @max(-32768, @min(32767, x));
    const yc: i32 = @max(-32768, @min(32767, y));
    const xu: u16 = @bitCast(@as(i16, @intCast(xc)));
    const yu: u16 = @bitCast(@as(i16, @intCast(yc)));
    const packed_u32: u32 = @as(u32, xu) | (@as(u32, yu) << 16);
    return @bitCast(@as(usize, packed_u32));
}

fn baseToolInfo(window: *state.Window) win32.TTTOOLINFOW {
    var ti = std.mem.zeroes(win32.TTTOOLINFOW);
    ti.cbSize = @sizeOf(win32.TTTOOLINFOW);
    ti.hwnd = window.hwnd;
    ti.uId = TOOL_ID;
    return ti;
}

pub fn create(window: *state.Window) void {
    const popup_bits: u32 = @bitCast(win32.WS_POPUP);
    const style: win32.WINDOW_STYLE = @bitCast(popup_bits | win32.TTS_ALWAYSTIP);
    const tt = win32.CreateWindowExW(
        .{},
        win32.L("tooltips_class32"),
        null,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        window.hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse {
        std.log.warn("tooltip: CreateWindowExW failed, error={f}", .{win32.GetLastError()});
        return;
    };

    window.tooltip_text_buf[0] = 0;

    var ti = baseToolInfo(window);
    ti.uFlags = .{ .TRACK = 1, .ABSOLUTE = 1 };
    ti.lpszText = @ptrCast(&window.tooltip_text_buf[0]);
    const ti_lparam: win32.LPARAM = @bitCast(@intFromPtr(&ti));
    _ = win32.SendMessageW(tt, win32.TTM_ADDTOOLW, 0, ti_lparam);
    _ = win32.SendMessageW(tt, win32.TTM_SETMAXTIPWIDTH, 0, 600);

    window.tooltip_hwnd = tt;
}

pub fn destroy(window: *state.Window) void {
    if (window.tooltip_hwnd) |h| {
        _ = win32.DestroyWindow(h);
        window.tooltip_hwnd = null;
    }
    window.tooltip_active = false;
    window.tooltip_tab_id = null;
}

fn writeTooltipText(window: *state.Window, tab: *state.Tab) void {
    const buf = &window.tooltip_text_buf;
    const cap = buf.len - 1; // reserve sentinel

    var written: usize = 0;
    const title_u8 = tab.title_buf[0..tab.title_len];
    if (title_u8.len == 0) {
        const idx = window.findIndexById(tab.id) orelse 0;
        var s_buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&s_buf, "tab {d}", .{idx + 1}) catch s_buf[0..0];
        const need = std.unicode.calcUtf16LeLen(s) catch s.len;
        const lim = @min(need, cap);
        written = std.unicode.utf8ToUtf16Le(buf[0..lim], s) catch 0;
    } else {
        // Shrink the source UTF-8 byte-by-byte until the UTF-16 conversion
        // fits the buffer without splitting a codepoint.
        var src_end: usize = title_u8.len;
        while (src_end > 0) {
            const need = std.unicode.calcUtf16LeLen(title_u8[0..src_end]) catch {
                src_end -= 1;
                continue;
            };
            if (need <= cap) {
                written = std.unicode.utf8ToUtf16Le(buf[0..need], title_u8[0..src_end]) catch 0;
                break;
            }
            src_end -= 1;
        }
    }
    buf[written] = 0;
}

pub fn showForTab(
    window: *state.Window,
    tab: *state.Tab,
    client_x: i32,
    client_y: i32,
) void {
    const tt = window.tooltip_hwnd orelse return;

    if (window.tooltip_tab_id != tab.id) {
        writeTooltipText(window, tab);
        var ti = baseToolInfo(window);
        ti.lpszText = @ptrCast(&window.tooltip_text_buf[0]);
        const ti_lparam: win32.LPARAM = @bitCast(@intFromPtr(&ti));
        _ = win32.SendMessageW(tt, win32.TTM_UPDATETIPTEXTW, 0, ti_lparam);
        window.tooltip_tab_id = tab.id;
    }

    var pt: win32.POINT = .{
        .x = client_x + CURSOR_OFFSET_X,
        .y = client_y + CURSOR_OFFSET_Y,
    };
    _ = win32.ClientToScreen(window.hwnd, &pt);
    _ = win32.SendMessageW(tt, win32.TTM_TRACKPOSITION, 0, makeLparamXY(pt.x, pt.y));

    if (!window.tooltip_active) {
        var ti = baseToolInfo(window);
        const ti_lparam: win32.LPARAM = @bitCast(@intFromPtr(&ti));
        _ = win32.SendMessageW(tt, win32.TTM_TRACKACTIVATE, 1, ti_lparam);
        window.tooltip_active = true;
    }
}

/// Re-emit text for the tab that the tooltip is currently displaying. No-op
/// if the tooltip isn't showing or is showing a different tab. Called from
/// the title-changed callback so a live tooltip doesn't show stale text.
pub fn refreshIfShowing(window: *state.Window, tab: *state.Tab) void {
    const tt = window.tooltip_hwnd orelse return;
    if (!window.tooltip_active) return;
    if (window.tooltip_tab_id != tab.id) return;
    writeTooltipText(window, tab);
    var ti = baseToolInfo(window);
    ti.lpszText = @ptrCast(&window.tooltip_text_buf[0]);
    const ti_lparam: win32.LPARAM = @bitCast(@intFromPtr(&ti));
    _ = win32.SendMessageW(tt, win32.TTM_UPDATETIPTEXTW, 0, ti_lparam);
}

pub fn hide(window: *state.Window) void {
    const tt = window.tooltip_hwnd orelse return;
    if (!window.tooltip_active) return;
    var ti = baseToolInfo(window);
    const ti_lparam: win32.LPARAM = @bitCast(@intFromPtr(&ti));
    _ = win32.SendMessageW(tt, win32.TTM_TRACKACTIVATE, 0, ti_lparam);
    window.tooltip_active = false;
    window.tooltip_tab_id = null;
}

pub fn hitTabIndex(hit: types.TabHit) ?usize {
    return switch (hit) {
        .activate => |i| i,
        .close => |i| i,
        .none, .new_tab => null,
    };
}
