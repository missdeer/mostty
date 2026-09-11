const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const types = @import("types.zig");
const cp_mod = @import("child_process.zig");
const pty_ring_mod = @import("pty_ring.zig");
const url_hover = @import("../terminal/url_hover.zig");
const TerminalSession = @import("../terminal/Session.zig");

const TabId = types.TabId;
const TabHit = types.TabHit;
const MouseCapture = types.MouseCapture;
const WindowBounds = types.WindowBounds;
const ChildProcess = cp_mod.ChildProcess;

pub const SplitLayout = @import("../SplitLayout.zig");

pub const Tab = struct {
    id: TabId,
    window: *Window,
    layout: SplitLayout,
    closing: bool = false,

    pub fn active(self: *Tab) *Pane {
        return self.window.findById(self.layout.active.?).?;
    }
};

pub const Pane = struct {
    tab: *Tab,
    hwnd: ?win32.HWND = null,
    common: @import("RendererCommon.zig") = undefined,
    renderer: ?@import("d3d11.zig") = null,
    font_generation: u32 = 0,
    selection_fade: f32 = 0,
    wheel_accum: i32 = 0,
    id: TabId,
    child_process: ChildProcess,
    session: TerminalSession,
    // Borrowed alias into session for the renderer and interaction paths.
    term: *vt.Terminal,
    mouse_last_cell: ?vt.Coordinate = null,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    // UTF-16 high surrogate carried across two WM_CHAR calls. Per-tab
    // because keyboard shortcuts can switch tabs between the high and
    // low surrogate arriving.
    high_surrogate: ?u16 = null,
    // Set to true when close is initiated; further reader-thread
    // messages targeted at this tab id are dropped (but the handler
    // still returns the magic result so the reader's assertion holds).
    closing: bool = false,
    // Atomic stop flag read by the reader thread at every loop iteration
    // and after waking from a full-ring wait. Set together with CancelIoEx
    // and SetEvent(pty_ring.wake_event) in the close sequence.
    reader_stop: std.atomic.Value(bool) = .init(false),
    // SPSC byte ring between the reader thread (producer) and the UI
    // thread (consumer). Initialized in newTab before the reader spawns
    // and deinit'd in destroyTab AFTER thread.join — the reader holds
    // `&tab.pty_ring`, which is stable because Tab is heap-allocated and
    // never moves.
    pty_ring: pty_ring_mod.PtyRing = undefined,
    // Input method (keyboard layout / IME) this tab should use, remembered
    // across tab switches (MOSTTY-44). Seeded at tab creation with the system
    // default input language and updated on WM_INPUTLANGCHANGE while this tab is
    // active; reapplied when the tab becomes active again. null only during
    // teardown (no active tab) or if the OS query failed. Process-memory only.
    input_layout: ?win32.HKL = null,
};

pub const Window = struct {
    hwnd: win32.HWND,
    dwm_redirected: bool = false,
    bounds: ?WindowBounds = null,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    // Borrowed registry for HWND, PTY wake-up and process-exit routing.
    panes: std.ArrayListUnmanaged(*Pane) = .empty,
    layout_updating: bool = false,
    divider_drag: ?struct { tab_id: TabId, split_id: SplitLayout.SplitId, offset: f64, axis: SplitLayout.Axis } = null,
    active_index: usize = 0,
    next_pane_id: TabId = 1,
    // window-scope interaction state
    tracking_mouse: bool = false,
    tracking_hwnd: ?win32.HWND = null,
    hover_pane_id: ?types.TabId = null,
    mouse_in_scrollbar: bool = false,
    mouse_capture: MouseCapture = .none,
    // Tab id captured at mouse_report press time. Mouse reports during the
    // captured drag write to this tab even if the user Ctrl+Tabs the active
    // tab mid-drag; null when no mouse-report capture is in flight.
    mouse_report_tab_id: ?TabId = null,
    capture_pane_id: ?TabId = null,
    scrollbar_drag_offset: f32 = 0,
    // Accumulates sub-notch WM_MOUSEWHEEL deltas for the local-scroll path.
    // Hi-res wheels / precision touchpads deliver many messages with small
    // deltas per physical notch; without accumulation each message would
    // scroll a full step and the viewport would race.
    resizing: bool = false,
    tab_bar_hover: ?TabHit = null,
    // Native Win32 tooltip control for tab-bar hover; null if creation failed.
    // Owned by this Window — destroyed in WM_DESTROY.
    tooltip_hwnd: ?win32.HWND = null,
    // Whether the tooltip is currently in the activated/visible state. Tracked
    // separately so we only send TTM_TRACKACTIVATE on transitions.
    tooltip_active: bool = false,
    // Tab id the tooltip currently displays text for; null if no text set yet
    // or the displayed tab was closed. Used to skip redundant text updates as
    // the mouse moves inside the same tab cell.
    tooltip_tab_id: ?TabId = null,
    // Persistent UTF-16 backing for the tooltip text. Its address is passed
    // to the tooltip control via TTM_UPDATETIPTEXTW, so the buffer must live
    // for the tooltip's lifetime.
    tooltip_text_buf: [512]u16 = undefined,
    // True while a close-confirmation MessageBox is up. The modal pumps
    // messages, so a second WM_CLOSE (e.g. Alt+F4 hammering) or another
    // tab-bar 'x' click could otherwise stack a nested dialog.
    confirming_close: bool = false,
    // True while the renderer-fallback MessageBox is up. That modal pumps
    // messages too, and a dead GPU keeps failing every repaint it pumps, so
    // without this the prompt would recursively stack on itself.
    confirming_renderer_fallback: bool = false,
    // Coalesce paint requests: PTY data arrives in small chunks and each
    // chunk currently asks for a redraw. Without this, bursty output
    // (`find /`, `cat large.log`) submits one InvalidateRect syscall per
    // chunk; Windows still coalesces them into one WM_PAINT, but the
    // duplicate syscalls cost real CPU and contend on the message queue.
    // Flag is set on the first request after a paint and cleared inside
    // WM_PAINT before render() so events fired *during* render still
    // schedule a follow-up frame.
    render_pending: bool = false,
    render_timer_armed: bool = false,
    pty_drain_timer_armed: bool = false,
    last_render_tick_ms: u64 = 0,
    render_interval_ms: u32 = 16,
    remote_session: bool = false,
    diag_last_tick_ms: u64 = 0,
    diag_pty_bytes: u64 = 0,
    diag_renders: u64 = 0,
    // QPC microseconds accumulated by paint.zig's renderWindow timing wrap.
    // Reset every 1s flush along with diag_renders. busy_us / 10_000 = busy %.
    diag_render_us: u64 = 0,
    // Worst single-frame render duration in the current 1s window. Useful for
    // spotting tail latency hidden by the average (e.g. resize / hot-reload
    // spikes vs steady-state cost).
    diag_render_max_us: u64 = 0,
    // System-menu "Theme" cascading submenu. Owned by the system menu once
    // attached, so Windows destroys it with the parent — no manual cleanup.
    // Items are rebuilt on each WM_INITMENUPOPUP.
    theme_submenu: ?win32.HMENU = null,
    // Set while the window is in fullscreen: original GWL_STYLE bits and
    // WINDOWPLACEMENT captured at enter time. Both being non-null is the
    // canonical "we're fullscreen" predicate; restoring clears them.
    fullscreen_saved_style: ?u32 = null,
    fullscreen_saved_placement: ?win32.WINDOWPLACEMENT = null,
    // Name of the theme currently applied in this session (gpa-owned). Seeded
    // from the parsed config's `theme = X`, replaced when the user picks a
    // theme through the submenu, and resynced from the config on hot-reload.
    // Null when no theme is active.
    active_theme_name: ?[]u8 = null,
    // Currently linkified URL under the mouse, in viewport coordinates. Tab id
    // is captured so a tab switch doesn't leak the hover onto another tab's
    // grid. The hit itself carries the multi-row viewport range.
    hovered_url: ?HoveredUrl = null,
    // Last (col, row, tab) the URL hover detection looked at. Set on every
    // WM_MOUSEMOVE that hits a grid cell and cleared whenever hovered_url is
    // invalidated. Lets updateUrlHover short-circuit when the mouse stays
    // inside the same cell — avoids the detectAt cost on sub-cell motion.
    hover_cell: ?HoverCell = null,

    pub const HoveredUrl = struct {
        tab_id: TabId,
        hit: url_hover.Hit,
    };

    pub const HoverCell = struct {
        tab_id: TabId,
        col: u16,
        row: u16,
    };

    pub fn activeTab(self: *Window) *Tab {
        return self.tabs.items[self.active_index];
    }

    pub fn active(self: *Window) *Pane {
        return self.activeTab().active();
    }

    pub fn paneFromHwnd(self: *Window, hwnd: win32.HWND) ?*Pane {
        for (self.panes.items) |pane| if (pane.hwnd == hwnd) return pane;
        return if (hwnd == self.hwnd and self.tabs.items.len > 0) self.active() else null;
    }

    pub fn requestRender(self: *Window) void {
        if (self.render_pending) return;
        self.render_pending = true;
        self.scheduleRender();
    }

    // Re-evaluates the active frame interval from the config caps and the
    // current SM_REMOTESESSION reading, picking remote when either the system
    // metric says we're under a remote session or the boot-time adapter probe
    // flagged the GPU as remote/software (WARP, Basic Render, etc).
    // Called from onCreate, on WM_WTSSESSION_CHANGE, and after config reload.
    // If a frame timer was armed at the previous interval, it is cancelled so
    // the next requestRender re-arms with the new value; render_pending stays
    // true so the in-flight request isn't lost.
    pub fn applyRenderInterval(
        self: *Window,
        local_ms: u32,
        remote_ms: u32,
        remote_or_software_adapter: bool,
    ) void {
        const remote_session = win32.GetSystemMetrics(win32.SM_REMOTESESSION) != 0;
        self.remote_session = remote_session;
        const new_interval = if (remote_or_software_adapter or remote_session) remote_ms else local_ms;
        if (new_interval == self.render_interval_ms) return;
        std.log.info(
            "render frame interval: {} ms -> {} ms (remote_session={}, remote_or_software_adapter={})",
            .{ self.render_interval_ms, new_interval, remote_session, remote_or_software_adapter },
        );
        self.render_interval_ms = new_interval;
        if (self.render_timer_armed) {
            _ = win32.KillTimer(self.hwnd, types.TIMER_RENDER_FRAME);
            self.render_timer_armed = false;
            if (self.render_pending) win32.invalidateHwnd(self.hwnd);
        }
    }

    pub fn scheduleRender(self: *Window) void {
        const now = win32.GetTickCount64();
        const elapsed = now -| self.last_render_tick_ms;
        if (elapsed >= self.render_interval_ms) {
            win32.invalidateHwnd(self.hwnd);
            return;
        }
        if (self.render_timer_armed) return;
        const delay: u32 = @max(1, self.render_interval_ms - @as(u32, @intCast(elapsed)));
        // If SetTimer fails we MUST NOT mark the timer armed: render_pending
        // is already true and nothing else clears it, so a phantom timer
        // would freeze the renderer until external repaint. Fall back to an
        // immediate invalidate — the budget is already exhausted anyway.
        if (win32.SetTimer(self.hwnd, types.TIMER_RENDER_FRAME, delay, null) == 0) {
            win32.invalidateHwnd(self.hwnd);
            return;
        }
        self.render_timer_armed = true;
    }

    pub fn noteRender(self: *Window) void {
        const now = win32.GetTickCount64();
        self.last_render_tick_ms = now;
        self.diag_renders += 1;
        self.logDiagnostics(now);
    }

    // Hot path: WM_APP_CHILD_PROCESS_DATA fires on every PTY chunk. Keep this
    // a single field bump; the diagnostic flush only happens on noteRender,
    // which is naturally rate-limited by the render throttle.
    pub fn notePtyBytes(self: *Window, len: u32) void {
        self.diag_pty_bytes += len;
    }

    fn logDiagnostics(self: *Window, now: u64) void {
        if (self.diag_last_tick_ms == 0) {
            self.diag_last_tick_ms = now;
            return;
        }
        const elapsed = now - self.diag_last_tick_ms;
        if (elapsed < 1000) return;
        // Guard the divide: the boot sentinel and any future "reset before
        // reapply" path could leave render_interval_ms == 0 in principle;
        // cheaper to be defensive here than to audit every call site.
        const fps_cap: u32 = if (self.render_interval_ms > 0) @divTrunc(1000, self.render_interval_ms) else 0;
        // Convert to whole + tenths-of-ms without floating-point formatting.
        const busy_ms_x10 = self.diag_render_us / 100;
        std.log.info(
            "render stats: {} fps cap, {} render(s)/s, busy {}.{:0>1} ms/s, max {} us, {} PTY byte(s)/s",
            .{
                fps_cap,
                self.diag_renders,
                busy_ms_x10 / 10,
                busy_ms_x10 % 10,
                self.diag_render_max_us,
                self.diag_pty_bytes,
            },
        );
        self.diag_last_tick_ms = now;
        self.diag_renders = 0;
        self.diag_pty_bytes = 0;
        self.diag_render_us = 0;
        self.diag_render_max_us = 0;
    }

    pub fn findById(self: *Window, id: TabId) ?*Pane {
        for (self.panes.items) |t| if (t.id == id) return t;
        return null;
    }

    pub fn findTabIndexById(self: *Window, id: TabId) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    // Remember the input method the user just switched to on the active tab
    // so switching away and back restores it. No-op during teardown when no
    // tab is active. (MOSTTY-44)
    pub fn recordActiveInputLayout(self: *Window, hkl: ?win32.HKL) void {
        if (self.tabs.items.len == 0) return;
        self.active().input_layout = hkl;
    }

    // The input method to restore for the current tab: the layout it recorded
    // (seeded at creation, updated on WM_INPUTLANGCHANGE). null only during
    // teardown when no tab is active. (MOSTTY-44)
    pub fn activeInputLayout(self: *Window) ?win32.HKL {
        if (self.tabs.items.len == 0) return null;
        return self.active().input_layout;
    }

    fn applyActiveInputLayout(self: *Window) void {
        const hkl = self.activeInputLayout() orelse return;
        // Skip when the target already matches the OS layout. Re-posting the
        // current HKL is not harmless for CJK IMEs: the HKL encodes only the
        // input *language*, not the conversion mode, so re-activating it resets
        // the IME to its default (e.g. Chinese) mode — an unwanted flip when the
        // tab is already on that layout. (MOSTTY-44)
        if (hkl == win32.GetKeyboardLayout(0)) return;
        // Ask the OS to activate this tab's input method the documented way:
        // posting WM_INPUTLANGCHANGEREQUEST to our own window lets DefWindowProcW
        // (and TSF) perform the switch. ActivateKeyboardLayout's flag set has no
        // plain "just activate this HKL" value, so it is the wrong tool here.
        _ = win32.PostMessageW(
            self.active().hwnd orelse self.hwnd,
            win32.WM_INPUTLANGCHANGEREQUEST,
            0,
            @bitCast(@intFromPtr(hkl)),
        );
    }

    pub fn onActiveChanged(self: *Window) void {
        const pane = self.active();
        pane.selection_fade = 0;
        if (pane.hwnd) |hwnd| _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
        // A URL hover belongs to a specific tab — switching tabs makes the
        // cached cell coordinates point at unrelated content. Drop both the
        // hover and the cell throttle so the next mouse move re-evaluates
        // against the new tab.
        self.hovered_url = null;
        self.hover_cell = null;
        // Switch to the input method this tab recorded (seeded at creation with
        // the system default, updated as the user switches), unless the OS is
        // already on it. (MOSTTY-44)
        self.applyActiveInputLayout();
        self.requestRender();
    }
};

// The system default input language (Language Bar "default input method"), used
// to seed every new tab so a fresh tab starts on the default keyboard regardless
// of what the previously active tab was using (MOSTTY-44). Read into a zeroed
// usize first because SPI_GETDEFAULTINPUTLANG writes only a DWORD-sized HKL;
// widening from a pointer-sized var would leave its high bytes uninitialized.
pub fn systemDefaultInputLayout() ?win32.HKL {
    var raw: usize = 0;
    if (win32.SystemParametersInfoW(win32.SPI_GETDEFAULTINPUTLANG, 0, @ptrCast(&raw), .{}) == 0) return null;
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

// QueryPerformanceCounter wrappers for short-interval (sub-ms) render timing.
// GetTickCount64 is 15.6 ms resolution by default — useless for a 1–10 ms
// render. QPF returns a system-wide constant, so the cached frequency only
// needs to be written once; using std.atomic.Value with monotonic ordering
// makes the lazy init safe even if a future call site invokes qpcNow from
// a non-UI thread (today only paint handlers call it, but the cost of being
// defensive is one atomic load per render).
var qpc_freq_hz: std.atomic.Value(u64) = .init(0);

pub fn qpcNow() u64 {
    var c: win32.LARGE_INTEGER = undefined;
    _ = win32.QueryPerformanceCounter(&c);
    return @bitCast(c.QuadPart);
}

pub fn qpcUsSince(prev: u64) u64 {
    var freq = qpc_freq_hz.load(.monotonic);
    if (freq == 0) {
        var f: win32.LARGE_INTEGER = undefined;
        _ = win32.QueryPerformanceFrequency(&f);
        freq = @bitCast(f.QuadPart);
        qpc_freq_hz.store(freq, .monotonic);
    }
    const now = qpcNow();
    if (now <= prev or freq == 0) return 0;
    return (now - prev) * 1_000_000 / freq;
}

// MOSTTY-44 business rules: each tab is seeded with the system default input
// language at creation, WM_INPUTLANGCHANGE updates the active tab's record, and
// one tab's choice never bleeds into another. These exercise the record/resolve
// seam that the WM_INPUTLANGCHANGE handler and onActiveChanged drive; fake HKLs
// stand in for real keyboard-layout handles since only pointer identity matters
// here. The seeding (systemDefaultInputLayout) and the "skip the switch when the
// target already matches the OS layout" guard both call the OS and are not
// covered here.
fn testWindow() Window {
    return .{ .hwnd = undefined };
}

fn addTestTab(window: *Window, tab: *Tab, pane: *Pane, id: TabId, hkl: win32.HKL) !void {
    const allocator = std.testing.allocator;
    tab.* = .{ .id = id, .window = window, .layout = try SplitLayout.init(allocator, id) };
    pane.* = undefined;
    pane.id = id;
    pane.tab = tab;
    pane.hwnd = null;
    pane.input_layout = hkl;
    try window.tabs.append(allocator, tab);
    try window.panes.append(allocator, pane);
}

fn deinitTestTabs(window: *Window) void {
    for (window.tabs.items) |tab| tab.layout.deinit();
    window.tabs.deinit(std.testing.allocator);
    window.panes.deinit(std.testing.allocator);
}

test "a tab resolves to the layout it was seeded with at creation" {
    const seeded: win32.HKL = @ptrFromInt(0x0409);
    var tab: Tab = undefined;
    var pane: Pane = undefined;
    var window = testWindow();
    defer deinitTestTabs(&window);
    try addTestTab(&window, &tab, &pane, 1, seeded);
    try std.testing.expectEqual(seeded, window.activeInputLayout());
}

test "recording a layout on the active pane is what later resolves" {
    const english: win32.HKL = @ptrFromInt(0x0409);
    const chinese: win32.HKL = @ptrFromInt(0x0804);
    var tab: Tab = undefined;
    var pane: Pane = undefined;
    var window = testWindow();
    defer deinitTestTabs(&window);
    try addTestTab(&window, &tab, &pane, 1, english);
    window.recordActiveInputLayout(chinese);
    try std.testing.expectEqual(chinese, window.activeInputLayout());
}

test "panes retain independent input methods across pane and tab switches" {
    const english: win32.HKL = @ptrFromInt(0x0409);
    const chinese: win32.HKL = @ptrFromInt(0x0804);
    var tab_a: Tab = undefined;
    var tab_b: Tab = undefined;
    var pane_a: Pane = undefined;
    var pane_b: Pane = undefined;
    var pane_c: Pane = undefined;
    var window = testWindow();
    defer deinitTestTabs(&window);
    try addTestTab(&window, &tab_a, &pane_a, 1, english);
    try addTestTab(&window, &tab_b, &pane_b, 2, english);
    window.recordActiveInputLayout(chinese);
    try tab_a.layout.setBounds(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{ .width = 1, .height = 1 }, 1);
    try tab_a.layout.split(1, 3, .columns);
    pane_c = undefined;
    pane_c.id = 3;
    pane_c.tab = &tab_a;
    pane_c.input_layout = english;
    try window.panes.append(std.testing.allocator, &pane_c);
    try std.testing.expectEqual(english, window.activeInputLayout());
    try std.testing.expect(tab_a.layout.focus(1));
    try std.testing.expectEqual(chinese, window.activeInputLayout());
    window.active_index = 1;
    try std.testing.expectEqual(english, window.activeInputLayout());
    window.active_index = 0;
    try std.testing.expectEqual(chinese, window.activeInputLayout());
}

test "HWND and asynchronous IDs resolve their owning pane without moving focus" {
    const english: win32.HKL = @ptrFromInt(0x0409);
    var tab_a: Tab = undefined;
    var tab_b: Tab = undefined;
    var pane_a: Pane = undefined;
    var pane_b: Pane = undefined;
    var window = testWindow();
    window.hwnd = @ptrFromInt(100);
    defer deinitTestTabs(&window);
    try addTestTab(&window, &tab_a, &pane_a, 1, english);
    try addTestTab(&window, &tab_b, &pane_b, 2, english);
    pane_a.hwnd = @ptrFromInt(101);
    pane_b.hwnd = @ptrFromInt(102);
    try std.testing.expectEqual(&pane_b, window.paneFromHwnd(pane_b.hwnd.?).?);
    try std.testing.expectEqual(&pane_a, window.active());
    _ = window.panes.orderedRemove(1);
    try std.testing.expectEqual(@as(?*Pane, null), window.findById(2));
    try std.testing.expectEqual(@as(?*Pane, null), window.paneFromHwnd(pane_b.hwnd.?));
    try std.testing.expectEqual(&pane_a, window.active());
}
