const win32 = @import("win32").everything;

pub const TabId = u32;

pub const MAX_TABS: usize = 32;

pub const TabHit = union(enum) {
    none,
    activate: usize,
    close: usize,
    new_tab,
};

pub const MouseCapture = enum {
    none,
    scrollbar_drag,
    selecting,
};

pub const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

pub const GridPos = struct {
    col: u16,
    row: u16,
};

pub const ReadMsg = struct {
    tab_id: TabId,
    data: [*]const u8,
    len: u32,
};

pub const WM_APP_CHILD_PROCESS_DATA = win32.WM_APP + 0;
pub const WM_APP_CHILD_PROCESS_DATA_RESULT = 0x1bb502b6;
pub const WM_APP_CLOSE_TAB = win32.WM_APP + 1;
pub const WM_APP_CONFIG_CHANGED = win32.WM_APP + 2;
pub const TIMER_SELECTION_FADE: usize = 1;
pub const TIMER_CONFIG_RELOAD: usize = 2;
pub const TIMER_TEXT_BLINK: usize = 3;
// Coalesce the burst of change notifications an editor emits on save (and let
// it finish writing / release its lock) before re-reading the config.
pub const CONFIG_RELOAD_DEBOUNCE_MS: u32 = 150;

// System-menu command id. Must be < 0xF000 (system range) and a multiple of
// 16, since DefWindowProc masks WM_SYSCOMMAND wparam with 0xFFF0.
pub const IDM_OPEN_SETTINGS: usize = 0x0010;

pub const window_style = win32.WS_OVERLAPPEDWINDOW;
pub const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    .NOREDIRECTIONBITMAP = 1,
};

pub const tab_bar_bg: u24 = 0x1f1f1f;
pub const tab_bar_fg: u24 = 0x808080;
pub const tab_active_bg: u24 = 0x2a2a2a;
pub const tab_active_fg: u24 = 0xffffff;
pub const tab_hover_bg: u24 = 0x252525;
pub const new_tab_button_fg: u24 = 0xc8c4d0;
