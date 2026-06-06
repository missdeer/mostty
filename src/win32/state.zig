const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const types = @import("types.zig");
const cp_mod = @import("child_process.zig");
const vt_stream_mod = @import("vt_stream.zig");

const TabId = types.TabId;
const TabHit = types.TabHit;
const MouseCapture = types.MouseCapture;
const WindowBounds = types.WindowBounds;
const ChildProcess = cp_mod.ChildProcess;

pub const Tab = struct {
    id: TabId,
    child_process: ChildProcess,
    term: *vt.Terminal,
    term_arena: std.heap.ArenaAllocator,
    vt_stream: vt_stream_mod.Stream,
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
    // Atomic stop flag read by the reader thread after each SendMessage.
    // Set together with CancelIoEx in the close sequence.
    reader_stop: std.atomic.Value(bool) = .init(false),
};

pub const Window = struct {
    hwnd: win32.HWND,
    bounds: ?WindowBounds = null,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    active_index: usize = 0,
    next_tab_id: TabId = 1,
    // window-scope interaction state
    tracking_mouse: bool = false,
    mouse_in_scrollbar: bool = false,
    selection_fade: f32 = 0,
    mouse_capture: MouseCapture = .none,
    // Tab id captured at mouse_report press time. Mouse reports during the
    // captured drag write to this tab even if the user Ctrl+Tabs the active
    // tab mid-drag; null when no mouse-report capture is in flight.
    mouse_report_tab_id: ?TabId = null,
    scrollbar_drag_offset: f32 = 0,
    // Accumulates sub-notch WM_MOUSEWHEEL deltas for the local-scroll path.
    // Hi-res wheels / precision touchpads deliver many messages with small
    // deltas per physical notch; without accumulation each message would
    // scroll a full step and the viewport would race.
    wheel_accum: i32 = 0,
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
    last_render_tick_ms: u64 = 0,
    render_interval_ms: u32 = 16,
    diag_last_tick_ms: u64 = 0,
    diag_pty_bytes: u64 = 0,
    diag_renders: u64 = 0,
    // System-menu "Theme" cascading submenu. Owned by the system menu once
    // attached, so Windows destroys it with the parent — no manual cleanup.
    // Items are rebuilt on each WM_INITMENUPOPUP.
    theme_submenu: ?win32.HMENU = null,
    // Name of the theme currently applied in this session (gpa-owned). Seeded
    // from the parsed config's `theme = X`, replaced when the user picks a
    // theme through the submenu, and resynced from the config on hot-reload.
    // Null when no theme is active.
    active_theme_name: ?[]u8 = null,

    pub fn active(self: *Window) *Tab {
        return self.tabs.items[self.active_index];
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
        std.log.info(
            "render stats: {} fps cap, {} render(s)/s, {} PTY byte(s)/s",
            .{ fps_cap, self.diag_renders, self.diag_pty_bytes },
        );
        self.diag_last_tick_ms = now;
        self.diag_renders = 0;
        self.diag_pty_bytes = 0;
    }

    pub fn findById(self: *Window, id: TabId) ?*Tab {
        for (self.tabs.items) |t| if (t.id == id) return t;
        return null;
    }

    pub fn findIndexById(self: *Window, id: TabId) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    pub fn onActiveChanged(self: *Window) void {
        self.selection_fade = 0;
        _ = win32.KillTimer(self.hwnd, types.TIMER_SELECTION_FADE);
        self.requestRender();
    }
};
