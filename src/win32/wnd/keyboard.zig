const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const misc = @import("misc.zig");
const paste = @import("../paste.zig");
const state = @import("../state.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");

const Window = state.Window;

const key_encode = @import("../../terminal/key_encode.zig");

fn vkToSpecial(wparam: win32.WPARAM) ?key_encode.Key {
    return switch (wparam) {
        @intFromEnum(win32.VK_UP) => .up,
        @intFromEnum(win32.VK_DOWN) => .down,
        @intFromEnum(win32.VK_RIGHT) => .right,
        @intFromEnum(win32.VK_LEFT) => .left,
        @intFromEnum(win32.VK_HOME) => .home,
        @intFromEnum(win32.VK_END) => .end,
        @intFromEnum(win32.VK_INSERT) => .insert,
        @intFromEnum(win32.VK_DELETE) => .delete,
        @intFromEnum(win32.VK_PRIOR) => .page_up,
        @intFromEnum(win32.VK_NEXT) => .page_down,
        @intFromEnum(win32.VK_F1) => .f1,
        @intFromEnum(win32.VK_F2) => .f2,
        @intFromEnum(win32.VK_F3) => .f3,
        @intFromEnum(win32.VK_F4) => .f4,
        @intFromEnum(win32.VK_F5) => .f5,
        @intFromEnum(win32.VK_F6) => .f6,
        @intFromEnum(win32.VK_F7) => .f7,
        @intFromEnum(win32.VK_F8) => .f8,
        @intFromEnum(win32.VK_F9) => .f9,
        @intFromEnum(win32.VK_F10) => .f10,
        @intFromEnum(win32.VK_F11) => .f11,
        @intFromEnum(win32.VK_F12) => .f12,
        else => null,
    };
}

fn keyModifiers() u32 {
    const shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
    const alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;
    const ctrl = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
    return (if (shift) key_encode.mod_shift else @as(u32, 0)) |
        (if (alt) key_encode.mod_alt else @as(u32, 0)) |
        (if (ctrl) key_encode.mod_ctrl else @as(u32, 0));
}

fn handleShortcut(window: *Window, wparam: win32.WPARAM) bool {
    const ctrl = util.isCtrlDown();
    const shift = util.isShiftDown();
    if (!ctrl) return false;
    if (util.isAltDown()) {
        const direction: ?state.SplitLayout.Direction = switch (wparam) {
            @intFromEnum(win32.VK_LEFT) => .left,
            @intFromEnum(win32.VK_RIGHT) => .right,
            @intFromEnum(win32.VK_UP) => .up,
            @intFromEnum(win32.VK_DOWN) => .down,
            else => null,
        };
        if (direction) |d| {
            @import("../pane_native.zig").focusDirection(window, d);
            return true;
        }
        return false;
    }
    if (shift) switch (wparam) {
        @intFromEnum(win32.VK_D) => {
            tab_mgmt.splitActive(window, .columns);
            return true;
        },
        @intFromEnum(win32.VK_E) => {
            tab_mgmt.splitActive(window, .rows);
            return true;
        },
        @intFromEnum(win32.VK_W) => {
            tab_mgmt.closeActivePane(window);
            return true;
        },
        @intFromEnum(win32.VK_RETURN) => {
            @import("../pane_native.zig").toggleMaximize(window);
            return true;
        },
        else => {},
    };
    if (!shift) {
        switch (wparam) {
            @intFromEnum(win32.VK_T) => {
                tab_mgmt.newTab(window);
                return true;
            },
            @intFromEnum(win32.VK_W) => {
                // tabs can be empty when WM_KEYDOWN is dispatched from a
                // nested pump during teardown; bounds-check before active().
                if (window.tabs.items.len > 0) {
                    tab_mgmt.confirmAndCloseTab(window, window.activeTab().id);
                }
                return true;
            },
            @intFromEnum(win32.VK_TAB) => {
                const n = window.tabs.items.len;
                if (n > 1) tab_mgmt.switchToTab(window, (window.active_index + 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_PRIOR) => {
                const n = window.tabs.items.len;
                if (n > 1) tab_mgmt.switchToTab(window, (window.active_index + n - 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_NEXT) => {
                const n = window.tabs.items.len;
                if (n > 1) tab_mgmt.switchToTab(window, (window.active_index + 1) % n);
                return true;
            },
            @intFromEnum(win32.VK_1)...@intFromEnum(win32.VK_9) => {
                const digit: usize = wparam - @intFromEnum(win32.VK_1);
                if (digit < window.tabs.items.len) tab_mgmt.switchToTab(window, digit);
                return true;
            },
            else => return false,
        }
    } else {
        if (wparam == @intFromEnum(win32.VK_TAB)) {
            const n = window.tabs.items.len;
            if (n > 1) tab_mgmt.switchToTab(window, (window.active_index + n - 1) % n);
            return true;
        }
    }
    return false;
}

pub fn onKeyDown(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);

    // Shortcut interception first.
    if (handleShortcut(window, wparam)) return 0;

    const tab = global_mod.inputPane(hwnd);
    const pty = tab.child_process.pty orelse {
        std.log.err("pty closed", .{});
        return 0;
    };
    // Ctrl+V, Ctrl+Shift+V, or Shift+Insert: paste from clipboard.
    // Exclude Alt: AltGr is reported as Ctrl+Alt, so AltGr+V must stay a
    // printable character on layouts that map it.
    if ((wparam == @intFromEnum(win32.VK_V) and util.isCtrlDown() and !util.isAltDown()) or
        (wparam == @intFromEnum(win32.VK_INSERT) and util.isShiftDown()))
    {
        paste.pasteClipboard(hwnd, tab);
        return 0;
    }

    const screen = tab.term.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        window.requestRender();
    }

    if (!screen.viewportIsBottom()) {
        screen.scroll(.active);
        window.requestRender();
    }

    var key_buf: [16]u8 = undefined;
    const seq: ?[]const u8 = seq_blk: {
        if (wparam == @intFromEnum(win32.VK_BACK)) break :seq_blk "\x7f";
        if (wparam == @intFromEnum(win32.VK_TAB)) {
            break :seq_blk if (util.isShiftDown()) "\x1b[Z" else null;
        }
        if (vkToSpecial(wparam)) |key| {
            break :seq_blk key_encode.encodeKey(key, keyModifiers(), false, &key_buf);
        }
        break :seq_blk null;
    };
    if (seq) |s| {
        pty.writeFlushAll(s) catch |e| std.log.err(
            "write to pty failed: {s}",
            .{@errorName(e)},
        );
    }
    return 0;
}

// Alt+Enter toggles fullscreen. We claim it from WM_SYSKEYDOWN so Alt+Enter
// never reaches the PTY. Ignore auto-repeats (lparam bit 30 = previous key
// state) so a held chord doesn't flip-flop. Anything else (Alt+F4, Alt+Space,
// ...) falls through to DefWindowProcW via the null return.
pub fn onSysKeyDown(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    if (handleShortcut(window, wparam)) return 0;
    if (wparam == @intFromEnum(win32.VK_F4) and util.isAltDown()) {
        _ = win32.PostMessageW(window.hwnd, win32.WM_CLOSE, 0, 0);
        return 0;
    }
    // Strictly plain Alt+Enter: Ctrl+Alt+Enter / Shift+Alt+Enter are reserved
    // for the PTY / app shortcuts.
    if (wparam == @intFromEnum(win32.VK_RETURN) and
        util.isAltDown() and !util.isCtrlDown() and !util.isShiftDown())
    {
        const prev_down = (@as(usize, @bitCast(lparam)) >> 30) & 1 != 0;
        if (!prev_down) misc.toggleFullscreen(global_mod.windowFromHwnd(hwnd).hwnd);
        return 0;
    }
    return null;
}

// TranslateMessage turns WM_SYSKEYDOWN(VK_RETURN+Alt) into WM_SYSCHAR('\r'+Alt).
// If we let DefWindowProcW see that, it interprets it as an unmatched Alt-menu
// mnemonic and MessageBeep()s. Swallow plain Alt+Enter here too; Alt+Space and
// friends still fall through.
pub fn onSysChar(_: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (wparam == '\r') return 0;
    return null;
}

pub fn onChar(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const tab = global_mod.inputPane(hwnd);
    const pty = tab.child_process.pty orelse {
        std.log.err("pty closed", .{});
        return 0;
    };
    const screen = tab.term.screens.active;
    if (!screen.viewportIsBottom()) {
        screen.scroll(.active);
        window.requestRender();
    }
    const char: u16 = std.math.cast(u16, wparam) orelse {
        std.log.warn("unexpected WM_CHAR wparam: {}", .{wparam});
        return 0;
    };
    const ctrl = util.isCtrlDown();
    const shift = util.isShiftDown();
    // Backspace is handled in WM_KEYDOWN (sends \x7f)
    if (ctrl and shift and !util.isAltDown() and (char == 0x04 or char == 0x05 or char == 0x17 or char == 0x0d or char == 0x0a)) return 0;
    if (char == 0x08) return 0;
    // Shift+Tab is handled in WM_KEYDOWN (sends \x1b[Z); plain Tab falls through as \t
    if (char == 0x09 and shift) return 0;
    // Ctrl+Tab is a tab-switch shortcut; suppress the resulting \t.
    if (char == 0x09 and ctrl) return 0;
    // Suppress Ctrl+V control character (paste is handled in WM_KEYDOWN)
    if (char == 0x16) return 0;
    // Ctrl+T (0x14) and Ctrl+W (0x17) are tab shortcuts; suppress.
    if (ctrl and !shift) {
        if (char == 0x14 or char == 0x17) return 0;
        if (char >= '1' and char <= '9') return 0;
    }
    if (std.unicode.utf16IsHighSurrogate(char)) {
        tab.high_surrogate = char;
        return 0;
    }
    const codepoint: u21 = blk: {
        if (tab.high_surrogate) |high| {
            tab.high_surrogate = null;
            if (std.unicode.utf16IsLowSurrogate(char)) {
                break :blk std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, char }) catch return 0;
            }
        }
        break :blk @intCast(char);
    };
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
    pty.writeFlushAll(utf8_buf[0..len]) catch |e| std.log.err(
        "write to pty failed: {s}",
        .{@errorName(e)},
    );
    return 0;
}
