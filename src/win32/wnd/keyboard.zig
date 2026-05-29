const std = @import("std");
const win32 = @import("win32").everything;

const global_mod = @import("../global.zig");
const paste = @import("../paste.zig");
const state = @import("../state.zig");
const tab_mgmt = @import("../tab_mgmt.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");

const Window = state.Window;

const SpecialKey = union(enum) {
    cursor: u8,
    tilde: u8,
    fkey14: u8,
};

fn vkToSpecial(wparam: win32.WPARAM) ?SpecialKey {
    return switch (wparam) {
        @intFromEnum(win32.VK_UP) => .{ .cursor = 'A' },
        @intFromEnum(win32.VK_DOWN) => .{ .cursor = 'B' },
        @intFromEnum(win32.VK_RIGHT) => .{ .cursor = 'C' },
        @intFromEnum(win32.VK_LEFT) => .{ .cursor = 'D' },
        @intFromEnum(win32.VK_HOME) => .{ .cursor = 'H' },
        @intFromEnum(win32.VK_END) => .{ .cursor = 'F' },
        @intFromEnum(win32.VK_INSERT) => .{ .tilde = 2 },
        @intFromEnum(win32.VK_DELETE) => .{ .tilde = 3 },
        @intFromEnum(win32.VK_PRIOR) => .{ .tilde = 5 },
        @intFromEnum(win32.VK_NEXT) => .{ .tilde = 6 },
        @intFromEnum(win32.VK_F1) => .{ .fkey14 = 'P' },
        @intFromEnum(win32.VK_F2) => .{ .fkey14 = 'Q' },
        @intFromEnum(win32.VK_F3) => .{ .fkey14 = 'R' },
        @intFromEnum(win32.VK_F4) => .{ .fkey14 = 'S' },
        @intFromEnum(win32.VK_F5) => .{ .tilde = 15 },
        @intFromEnum(win32.VK_F6) => .{ .tilde = 17 },
        @intFromEnum(win32.VK_F7) => .{ .tilde = 18 },
        @intFromEnum(win32.VK_F8) => .{ .tilde = 19 },
        @intFromEnum(win32.VK_F9) => .{ .tilde = 20 },
        @intFromEnum(win32.VK_F10) => .{ .tilde = 21 },
        @intFromEnum(win32.VK_F11) => .{ .tilde = 23 },
        @intFromEnum(win32.VK_F12) => .{ .tilde = 24 },
        else => null,
    };
}

fn xtermModifier() u8 {
    const shift = win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
    const alt = win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;
    const ctrl = win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
    return 1 + @as(u8, if (shift) 1 else 0) + @as(u8, if (alt) 2 else 0) + @as(u8, if (ctrl) 4 else 0);
}

fn formatSpecialKey(buf: *[16]u8, key: SpecialKey, mod: u8) []const u8 {
    return switch (key) {
        .cursor => |final| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1b[{c}", .{final}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable,
        .tilde => |num| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1b[{d}~", .{num}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ num, mod }) catch unreachable,
        .fkey14 => |final| if (mod == 1)
            std.fmt.bufPrint(buf, "\x1bO{c}", .{final}) catch unreachable
        else
            std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch unreachable,
    };
}

fn handleShortcut(window: *Window, wparam: win32.WPARAM) bool {
    const ctrl = util.isCtrlDown();
    const shift = util.isShiftDown();
    if (!ctrl) return false;
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
                    tab_mgmt.confirmAndCloseTab(window, window.active().id);
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

    const tab = window.active();
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
        window.selection_fade = 0;
        _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
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
            break :seq_blk formatSpecialKey(&key_buf, key, xtermModifier());
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

pub fn onChar(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    const tab = window.active();
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
