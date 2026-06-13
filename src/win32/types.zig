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
    mouse_report,
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
pub const TIMER_RENDER_FRAME: usize = 4;
// Coalesce the burst of change notifications an editor emits on save (and let
// it finish writing / release its lock) before re-reading the config.
pub const CONFIG_RELOAD_DEBOUNCE_MS: u32 = 150;

// System-menu command id. Must be < 0xF000 (system range) and a multiple of
// 16, since DefWindowProc masks WM_SYSCOMMAND wparam with 0xFFF0.
pub const IDM_OPEN_SETTINGS: usize = 0x0010;

// Theme submenu IDs occupy 0x1000..0x5000 in steps of 16: clear of
// IDM_OPEN_SETTINGS and the system range (>=0xF000). The Theme menu is
// grouped by first letter (0-9, A-Z, #), so 1024 items is comfortably more
// than Ghostty's ~460 bundled themes.
pub const IDM_THEME_BASE: usize = 0x1000;
pub const MAX_THEME_ITEMS: usize = 1024;
pub const IDM_THEME_END: usize = IDM_THEME_BASE + MAX_THEME_ITEMS * 0x10;

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
pub const close_hover_fg: u24 = 0xff5555;
pub const new_tab_hover_fg: u24 = 0xffffff;

// One tab's drawing description for the proportional tab-bar painter. Column
// fields are grid columns (tab widths/buttons stay column-based); the painter
// multiplies by the cell width to get pixels. `title` borrows the tab's title
// buffer and is only valid during the synchronous render call.
pub const TabDrawInfo = struct {
    col_start: u32,
    col_end: u32,
    close_col: u32,
    tab_number: u32, // 1-based, for the "tab N" placeholder when title is empty
    active: bool,
    hovered: bool,
    close_hovered: bool,
    title: []const u8,
};

pub const TabBarDraw = struct {
    tabs: []const TabDrawInfo,
    new_tab_col: ?u32,
    new_tab_hovered: bool,
};

// Hovered URL highlight range. Inclusive viewport coordinates spanning one or
// more soft-wrapped rows. The start row begins at start_col, end row ends at
// end_col; any row strictly between covers the full row width.
pub const UrlHighlight = struct {
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
};
