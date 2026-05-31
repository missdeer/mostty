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
    resizing: bool = false,
    tab_bar_hover: ?TabHit = null,
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
        win32.invalidateHwnd(self.hwnd);
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
