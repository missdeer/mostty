const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const paste = @import("../paste.zig");
const types = @import("../types.zig");

const ReadMsg = types.ReadMsg;
const global = global_mod.global;

pub fn onTimer(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (wparam == types.TIMER_SELECTION_FADE) {
        const window = global_mod.windowFromHwnd(hwnd);
        window.selection_fade -= 0.05;
        if (window.selection_fade <= 0) {
            window.selection_fade = 0;
            _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
            window.active().term.screens.active.clearSelection();
        }
        window.requestRender();
    }
    return 0;
}

pub fn onDropFiles(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    if (wparam == 0) return 0;
    const hdrop: win32.HDROP = @ptrFromInt(wparam);
    paste.onDropFiles(window, hdrop);
    return 0;
}

pub fn onAppChildProcessData(_: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const read_msg: *const ReadMsg = @ptrFromInt(wparam);
    // Always return the magic value, even when dropping payload.
    if (global.window == null) return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    const window = &global.window.?;
    const tab = window.findById(read_msg.tab_id) orelse return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    if (tab.closing) return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    tab.vt_stream.nextSlice(read_msg.data[0..read_msg.len]);
    window.requestRender();
    return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
}
