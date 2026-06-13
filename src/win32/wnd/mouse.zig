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
const url_hover = @import("../url_hover.zig");
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

fn clearUrlHover(window: *state.Window) void {
    // Invalidate the cell-level throttle too so the next mouse move re-runs
    // detection rather than short-circuiting on a stale cache.
    window.hover_cell = null;
    if (window.hovered_url == null) return;
    window.hovered_url = null;
    window.requestRender();
}

// Resolve client-area (mouse_x, mouse_y) to a viewport (col, row) on the active
// tab. Returns null when the point is above the tab bar, left of the grid, or
// outside the terminal's columns/rows.
fn cellAtClient(window: *state.Window, mouse_x: i32, mouse_y: i32) ?struct { col: u16, row: u16 } {
    const cs = global.renderer.cell_size;
    const tbh = global.renderer.tab_bar_height;
    const grid_y = mouse_y - tbh;
    if (grid_y < 0 or mouse_x < 0) return null;
    const tab = window.active();
    const col_i = @divTrunc(mouse_x, cs.cx);
    const row_i = @divTrunc(grid_y, cs.cy);
    const cols_i: i32 = @intCast(tab.term.cols);
    const rows_i: i32 = @intCast(tab.term.rows);
    if (col_i >= cols_i or row_i >= rows_i) return null;
    return .{ .col = @intCast(col_i), .row = @intCast(row_i) };
}

// Recompute the URL under the mouse for the active tab. Updates window state
// (and requests a render) only when the resolved hit differs from the cached
// one, so steady mouse movement inside a known URL doesn't churn the renderer.
//
// Cell-level throttle: WM_MOUSEMOVE fires per pixel; sub-cell motion can't
// change which terminal cell is under the cursor, so we skip detectAt entirely
// when the mouse stays in the same grid cell on the same tab.
fn updateUrlHover(window: *state.Window, _: win32.HWND, mouse_x: i32, mouse_y: i32) void {
    const cell = cellAtClient(window, mouse_x, mouse_y) orelse {
        clearUrlHover(window);
        window.hover_cell = null;
        return;
    };
    const tab = window.active();
    if (window.hover_cell) |hc| {
        if (hc.tab_id == tab.id and hc.col == cell.col and hc.row == cell.row) return;
    }
    window.hover_cell = .{ .tab_id = tab.id, .col = cell.col, .row = cell.row };
    const new_hit = url_hover.detectAt(tab.term, cell.col, cell.row);
    if (new_hit) |h| {
        if (window.hovered_url) |cur| {
            if (cur.tab_id == tab.id and cur.hit.eql(&h)) return;
        }
        window.hovered_url = .{ .tab_id = tab.id, .hit = h };
        window.requestRender();
    } else {
        clearUrlHover(window);
    }
}

// True when the mouse (in client coordinates) currently sits on the linkified
// URL's underlined cells. Used by the WM_SETCURSOR hand-cursor decision.
fn mouseIsOverUrl(window: *state.Window, mouse_x: i32, mouse_y: i32) bool {
    const h = window.hovered_url orelse return false;
    if (h.tab_id != window.active().id) return false;
    const cell = cellAtClient(window, mouse_x, mouse_y) orelse return false;
    const cols: u16 = std.math.cast(u16, window.active().term.cols) orelse return false;
    if (cols == 0) return false;
    return h.hit.contains(cell.row, cell.col, cols - 1);
}

fn openUrl(hwnd: win32.HWND, url: []const u8) bool {
    var stack_buf: [url_hover.MAX_URL_LEN * 2 + 2]u16 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&stack_buf));
    const url_w = util.utf16ZAllocConst(fba.allocator(), url) catch {
        std.log.err("url_hover: utf16 alloc failed for url len={d}", .{url.len});
        return false;
    };
    const result = win32.ShellExecuteW(
        hwnd,
        win32.L("open"),
        url_w,
        null,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    );
    const code = if (result) |hr| @intFromPtr(hr) else 0;
    if (code <= 32) {
        std.log.err("url_hover: ShellExecuteW failed, code={d}", .{code});
        return false;
    }
    return true;
}

// Re-detects the URL at the given client-coords on the active tab. Used by
// the double-click handler because the first click of the dblclk pair sets
// mouse_capture = .selecting, and any sub-pixel mouse motion between the
// down/up/dblclk events clears window.hovered_url through the capture branch.
fn detectUrlAtClient(window: *state.Window, mouse_x: i32, mouse_y: i32) ?url_hover.Hit {
    const cell = cellAtClient(window, mouse_x, mouse_y) orelse return null;
    return url_hover.detectAt(window.active().term, cell.col, cell.row);
}

// Re-runs URL detection at the cached hover cell against the CURRENT viewport
// contents. Called from the render path before reading window.hovered_url so a
// single hook covers every state-change that triggers a repaint — PTY output,
// keyboard-driven viewport snap-back, resize, config reload, etc. — without
// scattering invalidation calls across handlers.
//
// Updates window.hovered_url in place but does NOT call window.requestRender:
// the caller is already mid-render and would just queue a redundant frame.
pub fn revalidateHoverForActiveTab(window: *state.Window) void {
    const hc = window.hover_cell orelse return;
    const tab = window.active();
    if (hc.tab_id != tab.id) return;
    const cols: u16 = std.math.cast(u16, tab.term.cols) orelse return;
    const rows: u16 = std.math.cast(u16, tab.term.rows) orelse return;
    if (hc.col >= cols or hc.row >= rows) {
        // Resize shrunk the grid past the cached cell; drop everything.
        window.hovered_url = null;
        window.hover_cell = null;
        return;
    }
    const new_hit = url_hover.detectAt(tab.term, hc.col, hc.row);
    if (new_hit) |h| {
        if (window.hovered_url) |cur| {
            if (cur.tab_id == tab.id and cur.hit.eql(&h)) return;
        }
        window.hovered_url = .{ .tab_id = tab.id, .hit = h };
    } else if (window.hovered_url != null) {
        window.hovered_url = null;
    }
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
        // Entering capture: drop any URL underline so a click-and-hold doesn't
        // leave a stale highlight visible until the user moves the mouse.
        clearUrlHover(window);
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
            clearUrlHover(window);
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
            clearUrlHover(window);
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

// Wide CJK character occupies two cells: a primary cell with the codepoint
// and a spacer_tail cell to its right whose codepoint is 0. Ghostty's
// Screen.selectWord short-circuits on the spacer_tail because hasText() is
// false there, which collapses any CJK-word selection down to a single
// character. This is a spacer-aware reimplementation: spacer_tail (and the
// soft-wrap spacer_head) are treated as continuation cells, not as word
// boundaries, so consecutive CJK ideographs select as one word.
fn selectWordCJK(pin: vt.Pin, boundary_codepoints: []const u21) ?vt.Selection {
    const start_cell = pin.rowAndCell().cell;
    if (!start_cell.hasText()) return null;

    const expect_boundary = std.mem.indexOfScalar(
        u21,
        boundary_codepoints,
        start_cell.content.codepoint,
    ) != null;

    const end: vt.Pin = end: {
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;
            const last_col = p.x == p.node.data.size.cols - 1;

            // spacer_tail is the right half of a wide char on the current row;
            // it travels with the primary, so include it in `prev` so the
            // selection's end pin can sit on it (the formatter skips spacers
            // after emitting the primary, so copy text comes out clean).
            //
            // spacer_head is end-of-row filler reserved for a wide char that
            // wrapped to the NEXT row. Visually it belongs to the wrapped
            // character, not to the current word. If we advanced `prev` onto
            // it and the next-row character turned out to be a boundary,
            // `selectionString`'s unwrap would expand end-on-spacer_head to
            // (next row, col 0), pulling that boundary char into the copy.
            // So skip spacer_head WITHOUT updating prev.
            switch (cell.wide) {
                .spacer_tail => {
                    if (last_col and !rac.row.wrap) break :end p;
                    prev = p;
                    continue;
                },
                .spacer_head => {
                    if (last_col and !rac.row.wrap) break :end prev;
                    continue;
                },
                .narrow, .wide => {},
            }

            if (!cell.hasText()) break :end prev;

            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint,
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;

            if (last_col and !rac.row.wrap) break :end p;

            prev = p;
        }
        break :end prev;
    };

    const start: vt.Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // Backwards crossing into the previous row's last column: if that
            // row isn't wrapped to ours, stop. Matches ghostty selectWord.
            if (p.x == p.node.data.size.cols - 1 and !rac.row.wrap) break :start prev;

            // spacer_tail belongs to the wide char to its LEFT, which the
            // backward walk hasn't visited yet. Skip without updating prev so
            // that if the wide primary turns out to be a boundary, start
            // doesn't land on the spacer (formatter expands start-on-tail to
            // include the boundary char). Mirror of forward's spacer_head.
            //
            // spacer_head sits at the end of the previous row before our
            // wrapped wide character. The primary on the current row is
            // already in `prev`, so advancing prev onto spacer_head is safe:
            // formatter unwraps start-on-head back to (next row, col 0) =
            // that same primary, so the start pin doesn't shift.
            switch (cell.wide) {
                .spacer_tail => continue,
                .spacer_head => {
                    prev = p;
                    continue;
                },
                .narrow, .wide => {},
            }

            if (!cell.hasText()) break :start prev;

            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint,
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;

            prev = p;
        }
        break :start prev;
    };

    return vt.Selection.init(start, end, false);
}

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

    // Hovered URL: a double-click on the underlined cells opens the link via
    // ShellExecuteW instead of selecting the word. Re-detect against the
    // click position rather than reading window.hovered_url — the first
    // click of the double-click sets mouse_capture = .selecting which the
    // intervening WM_MOUSEMOVE clears the cached hover through.
    // Shift-double-click falls through to the normal word-selection path
    // so the user can still copy the URL text.
    if (!util.isShiftDown()) {
        if (detectUrlAtClient(window, mouse_x, mouse_y)) |h| {
            if (openUrl(hwnd, h.url())) {
                // Drop the .selecting capture set by the preceding LBUTTONDOWN
                // and the lingering selection so the URL stays visually a link,
                // not a selection.
                if (window.mouse_capture == .selecting) {
                    window.mouse_capture = .none;
                    _ = win32.ReleaseCapture();
                }
                window.active().term.screens.active.clearSelection();
                window.requestRender();
                return 0;
            }
        }
    }

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

    // selectWordCJK returns null on an empty cell. Fall back to a single-cell
    // selection in that case so the click still feels responsive.
    const sel = selectWordCJK(pin, &WORD_BOUNDARIES) orelse vt.Selection.init(pin, pin, false);
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
    // Don't clearUrlHover here. The mouse hasn't moved, so hover_cell still
    // points at the cell physically under the cursor. The render-path
    // revalidation in renderWindow will re-detect against whatever scrolled
    // into that cell on the next paint — smooth highlight updates during a
    // wheel scroll without forcing the user to wiggle the mouse.
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
        clearUrlHover(window);
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
        clearUrlHover(window);
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

    if (reportMotion(window, hwnd, mouse_x, mouse_y, true)) {
        clearUrlHover(window);
        return 0;
    }

    const in_scrollbar = mouse_x >= grid_w;
    if (in_scrollbar != window.mouse_in_scrollbar) {
        window.mouse_in_scrollbar = in_scrollbar;
        window.requestRender();
    }

    if (in_scrollbar) {
        clearUrlHover(window);
    } else {
        updateUrlHover(window, hwnd, mouse_x, mouse_y);
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
    clearUrlHover(window);
    return 0;
}

// Hand cursor when the mouse sits on a linkified URL. Returns null for any
// other situation so DefWindowProc falls back to the WNDCLASS arrow.
pub fn onSetCursor(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    // Hit-test code from LOWORD(lparam). Only the client-area code should
    // trigger the hand — over the non-client border we want the resize/etc
    // cursors that Windows picks.
    const hit_code: u16 = @truncate(@as(usize, @bitCast(lparam)));
    if (hit_code != win32.HTCLIENT) return null;
    const window = global_mod.windowFromHwnd(hwnd);
    var pt: win32.POINT = undefined;
    if (0 == win32.GetCursorPos(&pt)) return null;
    if (0 == win32.ScreenToClient(hwnd, &pt)) return null;
    if (!mouseIsOverUrl(window, pt.x, pt.y)) return null;
    _ = win32.SetCursor(win32.LoadCursorW(null, win32.IDC_HAND));
    return 1;
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
