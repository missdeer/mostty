const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const d3d11 = @import("../d3d11.zig");
const global_mod = @import("../global.zig");
const launcher = @import("../launcher.zig");
const mouse_report = @import("../mouse_report.zig");
const paste = @import("../paste.zig");
const state = @import("../state.zig");
const tab_bar = @import("../tab_bar.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const tooltip = @import("../tooltip.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const window_geom = @import("../window_geom.zig");

const global = global_mod.global;

const TerminalMouse = struct {
    pos: mouse_report.Pos,
    grid: mouse_report.Grid,
    in_grid: bool,
};

fn terminalMouse(tab: *state.Tab, hwnd: win32.HWND, mouse_x: i32, mouse_y: i32) TerminalMouse {
    const cs = global.renderer.cell_size;
    const tbh = global.renderer.tab_bar_height;
    const client_size = win32.getClientSize(hwnd);
    const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, sb_px);
    const grid_h = @max(0, client_size.cy - tbh);
    const grid_mouse_y = mouse_y - tbh;
    return .{
        .pos = .{ .x = mouse_x, .y = grid_mouse_y },
        .grid = .{
            .cols = @intCast(tab.term.cols),
            .rows = @intCast(tab.term.rows),
            .cell_width = cs.cx,
            .cell_height = cs.cy,
        },
        .in_grid = mouse_y >= tbh and mouse_x >= 0 and mouse_x < grid_w and grid_mouse_y >= 0 and grid_mouse_y < grid_h,
    };
}

fn capturedMouseReportTab(window: *state.Window) ?*state.Tab {
    const tab_id = window.mouse_report_tab_id orelse return null;
    return window.findById(tab_id);
}

fn clearMouseReportCapture(window: *state.Window) void {
    window.mouse_capture = .none;
    window.mouse_report_tab_id = null;
    _ = win32.ReleaseCapture();
}

// Resolve the tab that mouse reports apply to. A captured drag stays pinned
// to its press-time tab; if that tab was closed mid-drag, clear the stale
// capture and drop the current report rather than retargeting it to the
// (now-unrelated) active tab.
fn mouseReportTab(window: *state.Window) ?*state.Tab {
    if (window.mouse_capture == .mouse_report) {
        if (capturedMouseReportTab(window)) |t| return t;
        clearMouseReportCapture(window);
        return null;
    }
    return window.active();
}

fn currentMods() mouse_report.Mods {
    return .{
        .shift = util.isShiftDown(),
        .alt = util.isAltDown(),
        .ctrl = util.isCtrlDown(),
    };
}

fn currentPressedButton() ?mouse_report.Button {
    if (win32.GetKeyState(@intFromEnum(win32.VK_LBUTTON)) < 0) return .left;
    if (win32.GetKeyState(@intFromEnum(win32.VK_MBUTTON)) < 0) return .middle;
    if (win32.GetKeyState(@intFromEnum(win32.VK_RBUTTON)) < 0) return .right;
    return null;
}

fn anyButtonPressed() bool {
    return currentPressedButton() != null;
}

fn sendMouseReport(tab: *state.Tab, event: mouse_report.Event, grid: mouse_report.Grid) bool {
    var data: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    mouse_report.encode(&writer, event, .{
        .event = tab.term.flags.mouse_event,
        .format = tab.term.flags.mouse_format,
        .grid = grid,
        .any_button_pressed = anyButtonPressed() or event.action == .press,
        .last_cell = &tab.mouse_last_cell,
    }) catch |e| {
        std.log.err("encode mouse report failed: {s}", .{@errorName(e)});
        return true;
    };
    const bytes = writer.buffered();
    if (bytes.len == 0) return false;
    tab_mgmt.writeToPty(tab, bytes);
    return true;
}

fn reportButtonDown(
    window: *state.Window,
    hwnd: win32.HWND,
    mouse_x: i32,
    mouse_y: i32,
    button: mouse_report.Button,
) bool {
    const tab = mouseReportTab(window) orelse return false;
    if (!mouse_report.enabled(tab.term)) return false;
    const tm = terminalMouse(tab, hwnd, mouse_x, mouse_y);
    if (!tm.in_grid) return false;
    _ = sendMouseReport(tab, .{
        .action = .press,
        .button = button,
        .mods = currentMods(),
        .pos = tm.pos,
    }, tm.grid);
    if (window.mouse_capture != .mouse_report) {
        window.mouse_capture = .mouse_report;
        window.mouse_report_tab_id = tab.id;
        _ = win32.SetCapture(hwnd);
    }
    return true;
}

// Only emit a release if a press was captured to mouse_report state. Avoids
// orphan releases when the press fell through to scrollbar/selection or
// shift-bypass paths. Only releases the Win32 capture when no other tracked
// button is still down.
fn reportButtonUp(
    window: *state.Window,
    hwnd: win32.HWND,
    mouse_x: i32,
    mouse_y: i32,
    button: mouse_report.Button,
) bool {
    if (window.mouse_capture != .mouse_report) return false;
    const tab = capturedMouseReportTab(window) orelse {
        clearMouseReportCapture(window);
        return true;
    };
    const tm = terminalMouse(tab, hwnd, mouse_x, mouse_y);
    _ = sendMouseReport(tab, .{
        .action = .release,
        .button = button,
        .mods = currentMods(),
        .pos = tm.pos,
    }, tm.grid);
    if (!anyButtonPressed()) clearMouseReportCapture(window);
    return true;
}

fn reportMotion(window: *state.Window, hwnd: win32.HWND, mouse_x: i32, mouse_y: i32, require_grid: bool) bool {
    const tab = mouseReportTab(window) orelse return false;
    if (!mouse_report.enabled(tab.term)) return false;
    const tm = terminalMouse(tab, hwnd, mouse_x, mouse_y);
    if (require_grid and !tm.in_grid) return false;
    return sendMouseReport(tab, .{
        .action = .motion,
        .button = currentPressedButton(),
        .mods = currentMods(),
        .pos = tm.pos,
    }, tm.grid);
}

pub fn onLButtonDown(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const cs = global.renderer.cell_size;
    const tbh = global.renderer.tab_bar_height;
    const client_size = win32.getClientSize(hwnd);
    const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, sb_px);

    // Tab bar gets first dibs on a fresh click.
    if (mouse_y < tbh) {
        tooltip.hide(window);
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        switch (hit) {
            .none => {},
            .activate => |idx| tab_mgmt.switchToTab(window, idx),
            .close => |idx| {
                if (idx >= window.tabs.items.len) return 0;
                tab_mgmt.confirmAndCloseTab(window, window.tabs.items[idx].id);
            },
            .new_tab => tab_mgmt.newTab(window),
        }
        return 0;
    }

    // Shift bypasses mouse reporting so the user can still select text in
    // TUIs that grab the mouse (xterm convention; matches ghostty).
    if (!util.isShiftDown() and reportButtonDown(window, hwnd, mouse_x, mouse_y, .left)) return 0;

    // Below tab bar: existing scrollbar / selection logic with y offset.
    const grid_mouse_y = mouse_y - tbh;
    if (mouse_x >= grid_w) {
        const screen = window.active().term.screens.active;
        const sb = screen.pages.scrollbar();
        if (sb.total > sb.len) {
            const win_h: f32 = @floatFromInt(client_size.cy - tbh);
            const min_track_height: f32 = 20.0;
            const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
            const max_offset = sb.total - sb.len;
            const track_y = @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);
            const mouse_yf: f32 = @floatFromInt(grid_mouse_y);

            if (mouse_yf >= track_y and mouse_yf < track_y + track_height) {
                window.mouse_capture = .scrollbar_drag;
                window.scrollbar_drag_offset = mouse_yf - track_y;
            } else {
                window.mouse_capture = .scrollbar_drag;
                window.scrollbar_drag_offset = track_height / 2.0;
                window_geom.scrollbarDragTo(window.active(), mouse_yf - track_height / 2.0, win_h, track_height);
            }
            _ = win32.SetCapture(hwnd);
            window.requestRender();
        }
    } else {
        const screen = window.active().term.screens.active;
        window.selection_fade = 0;
        _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
        const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
        const row: usize = @intCast(@divTrunc(@max(grid_mouse_y, 0), cs.cy));
        if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
            screen.clearSelection();
            const sel = vt.Selection.init(pin, pin, false);
            screen.select(sel) catch util.oom(error.OutOfMemory);
            window.mouse_capture = .selecting;
            _ = win32.SetCapture(hwnd);
            window.requestRender();
        }
    }
    return 0;
}

// Default word-boundary codepoints. Conservative on purpose: dots, slashes,
// dashes, underscores, '$' and ':' stay non-boundary so URLs, file paths,
// and shell variables (`https://x/y`, `$HOME`, `key:value` literals) select
// as a single token. '@' IS a boundary so shell prompts like
// `user@host MINGW64 /path` split as user / host / MINGW64 / path
// (matches xterm/ghostty default — trade-off: `user@example.com` and
// scoped npm packages split too).
//
// CJK punctuation block: without these, an entire Chinese/Japanese sentence
// would select as one "word" because the CJK ideographs themselves are
// non-boundary. We include the fullwidth analogues of the ASCII boundaries
// plus the ideographic comma/period/quotation brackets so a Chinese sentence
// double-click selects a phrase, not the whole line.
const WORD_BOUNDARIES = [_]u21{
    0,      ' ',    '\t',   '\'',   '"',    '`',    '|',    ';',
    ',',    '(',    ')',    '[',    ']',    '{',    '}',    '<',
    '>',    '@',    0x2502, // '│' TUI pane separator
    // CJK / fullwidth punctuation
    0x3000, // 　 ideographic space
    0x3001, // 、 ideographic comma
    0x3002, // 。 ideographic full stop
    0x3008, 0x3009, // 〈〉
    0x300A, 0x300B, // 《》
    0x300C, 0x300D, // 「」
    0x300E, 0x300F, // 『』
    0x3010, 0x3011, // 【】
    0xFF01, // ！
    0xFF08, 0xFF09, // （）
    0xFF0C, // ，
    0xFF1A, // ：
    0xFF1B, // ；
    0xFF1F, // ？
    0x2018, 0x2019, // '' smart single quotes
    0x201C, 0x201D, // "" smart double quotes
    0x00B7, // · Latin middle dot (Chinese names: 奥利弗·特威斯特)
    0x30FB, // ・ katakana middle dot (Japanese lists / loanword separators)
};

pub fn onLButtonDblClk(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const tbh = global.renderer.tab_bar_height;
    const cs = global.renderer.cell_size;
    const client_size = win32.getClientSize(hwnd);
    const sb_px = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| @as(i32, sb_px);

    // CS_DBLCLKS replaces the second WM_LBUTTONDOWN of a fast double-click
    // with WM_LBUTTONDBLCLK. Outside the grid (tab bar / scrollbar) word
    // selection is meaningless, but silently dropping the event would lose
    // the second tab activation / scrollbar jump. Delegate to onLButtonDown
    // so the user-visible behavior matches the no-DBLCLKS baseline there.
    if (mouse_y < tbh or mouse_x >= grid_w) return onLButtonDown(hwnd, wparam, lparam);

    // Mouse-reporting TUIs expect a real button press for the second click;
    // WM_LBUTTONDBLCLK arrives in place of WM_LBUTTONDOWN, so without this
    // forwarding the application would see only one of the two clicks.
    // Shift bypasses reporting (same convention as the single-click path).
    if (!util.isShiftDown() and reportButtonDown(window, hwnd, mouse_x, mouse_y, .left)) return 0;

    const grid_mouse_y = mouse_y - tbh;
    const screen = window.active().term.screens.active;
    const col: usize = @intCast(@divTrunc(@max(mouse_x, 0), cs.cx));
    const row: usize = @intCast(@divTrunc(@max(grid_mouse_y, 0), cs.cy));
    var pin = screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }) orelse return 0;

    // Wide CJK chars occupy two columns: a primary cell holding the codepoint
    // and a spacer_tail to its right whose codepoint is 0. A click on the
    // right half lands on the spacer_tail, where selectWord short-circuits
    // (hasText() is false) — without this we'd fall back to a single-cell
    // selection on the spacer. Step one column left to hit the real cell.
    if (pin.rowAndCell().cell.wide == .spacer_tail and pin.x > 0) {
        pin.x -= 1;
    }

    // selectWord returns null on an empty cell. Fall back to a single-cell
    // selection in that case so the click still feels responsive.
    const sel = screen.selectWord(pin, &WORD_BOUNDARIES) orelse vt.Selection.init(pin, pin, false);
    screen.clearSelection();
    screen.select(sel) catch util.oom(error.OutOfMemory);

    // Cancel any in-progress fade from the prior single-click release so the
    // freshly-expanded selection doesn't immediately start dimming.
    window.selection_fade = 0;
    _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);

    // Re-capture so the upcoming WM_LBUTTONUP runs the .selecting branch and
    // copies the word to the clipboard — same exit path as a normal drag.
    window.mouse_capture = .selecting;
    _ = win32.SetCapture(hwnd);
    window.requestRender();
    return 0;
}

pub fn onLButtonUp(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    if (reportButtonUp(window, hwnd, mouse_x, mouse_y, .left)) return 0;
    switch (window.mouse_capture) {
        .none => {},
        .scrollbar_drag => {
            window.mouse_capture = .none;
            _ = win32.ReleaseCapture();
            window.requestRender();
        },
        .selecting => {
            window.mouse_capture = .none;
            _ = win32.ReleaseCapture();
            const screen = window.active().term.screens.active;
            if (screen.selection) |sel| {
                const alloc = global.gpa.allocator();
                const text = screen.selectionString(alloc, .{ .sel = sel }) catch util.oom(error.OutOfMemory);
                defer alloc.free(text);
                if (text.len > 0) {
                    paste.copyToClipboard(hwnd, text);
                }
                window.selection_fade = 1.0;
                _ = win32.SetTimer(hwnd, types.TIMER_SELECTION_FADE, 16, null);
            }
        },
        .mouse_report => unreachable,
    }
    return 0;
}

pub fn onMouseWheel(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const delta: i16 = @bitCast(win32.hiword(wparam));
    // Resolve the wheel target up front: a captured mouse_report drag pins
    // ALL wheel handling — both the report and the local-scroll fallback —
    // to the press-time tab. Without this, a wheel outside the grid or a
    // captured tab whose mouse mode was disabled mid-drag would leak input
    // into window.active().
    const captured = window.mouse_capture == .mouse_report;
    const tab = if (captured) mouseReportTab(window) orelse return 0 else window.active();
    if (!util.isShiftDown() and mouse_report.enabled(tab.term)) {
        var pt: win32.POINT = .{ .x = win32.xFromLparam(lparam), .y = win32.yFromLparam(lparam) };
        _ = win32.ScreenToClient(hwnd, &pt);
        const tm = terminalMouse(tab, hwnd, pt.x, pt.y);
        if (tm.in_grid) {
            _ = sendMouseReport(tab, .{
                .action = .press,
                .button = if (delta > 0) .wheel_up else .wheel_down,
                .mods = currentMods(),
                .pos = tm.pos,
            }, tm.grid);
            return 0;
        }
    }
    // WM_MOUSEWHEEL delta is a multiple of WHEEL_DELTA (120) for classic
    // mice (one notch = 120), but hi-res wheels and precision touchpads
    // emit many messages with small deltas per physical notch. Accumulate
    // until we cross a notch boundary so scroll speed matches the wheel,
    // not the message rate.
    const WHEEL_DELTA: i32 = 120;
    // Reset on direction reversal: a stale sub-notch residual in the
    // opposite direction would otherwise cancel part of the new flick
    // and swallow a notch the user physically produced.
    if ((delta > 0 and window.wheel_accum < 0) or (delta < 0 and window.wheel_accum > 0)) {
        window.wheel_accum = 0;
    }
    window.wheel_accum += @as(i32, delta);
    const notches = @divTrunc(window.wheel_accum, WHEEL_DELTA);
    if (notches == 0) return 0;
    window.wheel_accum -= notches * WHEEL_DELTA;
    const scroll_lines: isize = -@as(isize, notches) * 3;
    const screen = tab.term.screens.active;
    screen.scroll(.{ .delta_row = scroll_lines });
    window.requestRender();
    return 0;
}

pub fn onMouseMove(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    if (!window.tracking_mouse) {
        var tme = win32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
            .dwFlags = win32.TME_LEAVE,
            .hwndTrack = hwnd,
            .dwHoverTime = 0,
        };
        _ = win32.TrackMouseEvent(&tme);
        window.tracking_mouse = true;
    }
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const cs = global.renderer.cell_size;
    const tbh = global.renderer.tab_bar_height;
    const client_size = win32.getClientSize(hwnd);
    const grid_w = client_size.cx -| @as(i32, d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd)));

    // Capture in progress takes priority over tab-bar hover.
    if (window.mouse_capture != .none) {
        tooltip.hide(window);
        const grid_mouse_y = mouse_y - tbh;
        switch (window.mouse_capture) {
            .none => {},
            .scrollbar_drag => {
                const win_h: f32 = @floatFromInt(client_size.cy - tbh);
                const sb = window.active().term.screens.active.pages.scrollbar();
                const min_track_height: f32 = 20.0;
                const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
                window_geom.scrollbarDragTo(window.active(), @as(f32, @floatFromInt(grid_mouse_y)) - window.scrollbar_drag_offset, win_h, track_height);
                window.requestRender();
            },
            .selecting => {
                const screen = window.active().term.screens.active;
                const clamped_x: i32 = @max(0, @min(mouse_x, grid_w - 1));
                const clamped_y: i32 = @max(0, @min(grid_mouse_y, client_size.cy - tbh - 1));
                const col: usize = @intCast(@divTrunc(clamped_x, cs.cx));
                const row: usize = @intCast(@divTrunc(clamped_y, cs.cy));
                if (screen.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } })) |pin| {
                    if (screen.selection) |*sel| {
                        sel.endPtr().* = pin;
                        window.requestRender();
                    }
                }
            },
            .mouse_report => {
                _ = reportMotion(window, hwnd, mouse_x, mouse_y, false);
                if (!anyButtonPressed()) clearMouseReportCapture(window);
            },
        }
        return 0;
    }

    // Tab bar hover
    if (mouse_y < tbh) {
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        if (!util.hitEql(window.tab_bar_hover, hit)) {
            window.tab_bar_hover = if (hit == .none) null else hit;
            window.requestRender();
        }
        if (window.mouse_in_scrollbar) {
            window.mouse_in_scrollbar = false;
            window.requestRender();
        }
        if (tooltip.hitTabIndex(hit)) |idx| {
            if (idx < window.tabs.items.len) {
                tooltip.showForTab(window, window.tabs.items[idx], mouse_x, mouse_y);
            } else {
                tooltip.hide(window);
            }
        } else {
            tooltip.hide(window);
        }
        return 0;
    } else if (window.tab_bar_hover != null) {
        window.tab_bar_hover = null;
        window.requestRender();
    }
    tooltip.hide(window);

    if (reportMotion(window, hwnd, mouse_x, mouse_y, true)) return 0;

    const in_scrollbar = mouse_x >= grid_w;
    if (in_scrollbar != window.mouse_in_scrollbar) {
        window.mouse_in_scrollbar = in_scrollbar;
        window.requestRender();
    }
    return 0;
}

// Hide the tab-bar tooltip when this window loses focus (Alt+Tab, popup menu
// activation, another app coming to front). Without this the tracking tooltip
// stays visible on top of whatever the user just switched to.
pub fn onKillFocus(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    tooltip.hide(global_mod.windowFromHwnd(hwnd));
    return null;
}

pub fn onMouseLeave(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    window.tracking_mouse = false;
    if (window.mouse_in_scrollbar) {
        window.mouse_in_scrollbar = false;
        window.requestRender();
    }
    if (window.tab_bar_hover != null) {
        window.tab_bar_hover = null;
        window.requestRender();
    }
    tooltip.hide(window);
    return 0;
}

pub fn onRButtonDown(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    const cs = global.renderer.cell_size;
    if (mouse_y < global.renderer.tab_bar_height) {
        tooltip.hide(window);
        const cell_count = window_geom.computeGridCellCount(hwnd, cs);
        const hit = tab_bar.hitTestTabBar(window, cell_count.col, mouse_x, cs.cx);
        if (hit == .new_tab) {
            launcher.showLauncherMenu(window, mouse_x, mouse_y);
        }
        return 0;
    }
    if (!util.isShiftDown() and reportButtonDown(window, hwnd, mouse_x, mouse_y, .right)) return 0;
    paste.pasteClipboard(hwnd, window.active());
    return 0;
}

pub fn onRButtonUp(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    _ = reportButtonUp(window, hwnd, mouse_x, mouse_y, .right);
    return 0;
}

pub fn onMButtonDown(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    if (!util.isShiftDown()) _ = reportButtonDown(window, hwnd, mouse_x, mouse_y, .middle);
    return 0;
}

pub fn onMButtonUp(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const mouse_x: i32 = win32.xFromLparam(lparam);
    const mouse_y: i32 = win32.yFromLparam(lparam);
    _ = reportButtonUp(window, hwnd, mouse_x, mouse_y, .middle);
    return 0;
}
