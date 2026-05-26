const std = @import("std");
const win32 = @import("win32").everything;

const state = @import("state.zig");
const util = @import("util.zig");

const Tab = state.Tab;
const Window = state.Window;

pub const paste_end = "\x1b[201~";

pub const PasteEndStripper = struct {
    matched: usize = 0,

    pub fn finish(stripper: *PasteEndStripper, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (stripper.matched != 0) {
            try writer.writeAll(paste_end[0..stripper.matched]);
            stripper.matched = 0;
        }
    }

    pub fn onCodepoint(
        stripper: *PasteEndStripper,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) error{WriteFailed}!enum { consumed, ignored } {
        if (codepoint == paste_end[stripper.matched]) {
            stripper.matched += 1;
            if (stripper.matched == paste_end.len) {
                std.log.warn("stripped paste-end marker from clipboard data", .{});
                stripper.matched = 0;
            }
            return .consumed;
        }
        if (stripper.matched != 0) {
            try writer.writeAll(paste_end[0..stripper.matched]);
            stripper.matched = 0;
        }
        if (codepoint == paste_end[0]) {
            stripper.matched = 1;
            return .consumed;
        }
        return .ignored;
    }
};

pub fn copyToClipboard(hwnd: win32.HWND, utf8: [:0]const u8) void {
    if (win32.OpenClipboard(hwnd) == 0) {
        std.log.err("copy: OpenClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());

    if (win32.EmptyClipboard() == 0) {
        std.log.err("copy: EmptyClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }

    const u16_len = std.unicode.calcUtf16LeLen(utf8) catch {
        std.log.err("copy: invalid utf-8 in selection", .{});
        return;
    };
    const hmem = win32.GlobalAlloc(.{ .MEM_MOVEABLE = 1 }, (u16_len + 1) * @sizeOf(u16));
    if (hmem == 0) {
        std.log.err("copy: GlobalAlloc failed, error={f}", .{win32.GetLastError()});
        return;
    }
    var hmem_owned = true;
    defer if (hmem_owned) if (0 != win32.GlobalFree(hmem)) win32.panicWin32("GlobalFree", win32.GetLastError());

    {
        const ptr: [*]u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse {
            std.log.err("copy: GlobalLock failed, error={f}", .{win32.GetLastError()});
            return;
        }));
        defer util.globalUnlock(hmem);
        const len = std.unicode.utf8ToUtf16Le(ptr[0 .. u16_len + 1], utf8) catch unreachable;
        std.debug.assert(len == u16_len);
        ptr[u16_len] = 0;
    }

    const handle: win32.HANDLE = @ptrFromInt(@as(usize, @bitCast(hmem)));
    if (win32.SetClipboardData(@intFromEnum(win32.CF_UNICODETEXT), handle) == null) {
        std.log.err("copy: SetClipboardData failed, error={f}", .{win32.GetLastError()});
    } else {
        hmem_owned = false;
    }
}

pub fn pasteClipboard(hwnd: win32.HWND, tab: *Tab) void {
    const pty = tab.child_process.pty orelse {
        std.log.err("paste: pty closed", .{});
        return;
    };
    if (win32.OpenClipboard(hwnd) == 0) {
        std.log.err("paste: OpenClipboard failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer if (0 == win32.CloseClipboard()) win32.panicWin32("CloseClipboard", win32.GetLastError());
    const handle = win32.GetClipboardData(@intFromEnum(win32.CF_UNICODETEXT)) orelse {
        std.log.err("paste: GetClipboardData failed, error={f}", .{win32.GetLastError()});
        return;
    };
    const hmem: isize = @bitCast(@intFromPtr(handle));
    const mem: [*:0]const u16 = @ptrCast(@alignCast(win32.GlobalLock(hmem) orelse {
        std.log.err("paste: GlobalLock failed, error={f}", .{win32.GetLastError()});
        return;
    }));
    defer util.globalUnlock(hmem);
    var buf: [4096]u8 = undefined;
    var pty_writer = pty.write.writerStreaming(&buf);
    pasteUtf16(tab, mem, &pty_writer.interface) catch |err| switch (err) {
        error.WriteFailed => std.log.err("paste: write to pty failed with {t}", .{pty_writer.err.?}),
        error.Reported => {},
    };
}

pub fn onDropFiles(window: *Window, hdrop: win32.HDROP) void {
    defer win32.DragFinish(hdrop);

    const tab = window.active();
    const pty = tab.child_process.pty orelse {
        std.log.err("drop: pty closed", .{});
        return;
    };

    const count = win32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a single UTF-16 buffer: each path is wrapped in double quotes
    // and separated by a space; one trailing space lets the user keep
    // typing arguments. Always-quote is the simplest defence against
    // shell metacharacters (cmd's `&|<>()^`, bash's `$()`, etc.) — file
    // paths on Windows can't contain `"` so escaping isn't needed.
    var combined: std.ArrayListUnmanaged(u16) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const wlen = win32.DragQueryFileW(hdrop, i, null, 0);
        if (wlen == 0) continue;
        const path = a.allocSentinel(u16, wlen, 0) catch |e| util.oom(e);
        const got = win32.DragQueryFileW(hdrop, i, path.ptr, wlen + 1);
        if (got == 0) continue;

        if (combined.items.len > 0) combined.append(a, ' ') catch |e| util.oom(e);
        combined.append(a, '"') catch |e| util.oom(e);
        combined.appendSlice(a, path[0..wlen]) catch |e| util.oom(e);
        combined.append(a, '"') catch |e| util.oom(e);
    }
    if (combined.items.len == 0) return;
    combined.append(a, ' ') catch |e| util.oom(e);

    const final = a.allocSentinel(u16, combined.items.len, 0) catch |e| util.oom(e);
    @memcpy(final[0..combined.items.len], combined.items);

    var write_buf: [4096]u8 = undefined;
    var pty_writer = pty.write.writerStreaming(&write_buf);
    pasteUtf16(tab, final.ptr, &pty_writer.interface) catch |err| switch (err) {
        error.WriteFailed => std.log.err("drop: write to pty failed with {t}", .{pty_writer.err.?}),
        error.Reported => {},
    };
}

pub fn pasteUtf16(tab: *Tab, utf16: [*:0]const u16, writer: *std.Io.Writer) error{ WriteFailed, Reported }!void {
    const bracketed = tab.term.modes.get(.bracketed_paste);
    if (bracketed) try writer.writeAll("\x1b[200~");
    var end_stripper: PasteEndStripper = .{};

    var i: usize = 0;
    var last_was_cr = false;
    while (utf16[i] != 0) {
        const cp: u21 = blk: {
            if (std.unicode.utf16IsHighSurrogate(utf16[i])) {
                const high = utf16[i];
                i += 1;
                if (utf16[i] == 0 or !std.unicode.utf16IsLowSurrogate(utf16[i])) {
                    std.log.err("paste: lone high surrogate 0x{x} at index {}", .{ high, i - 1 });
                    return error.Reported;
                }
                const pair = std.unicode.utf16DecodeSurrogatePair(&[2]u16{ high, utf16[i] }) catch {
                    std.log.err("paste: bad surrogate pair 0x{x} 0x{x} at index {}", .{ high, utf16[i], i - 1 });
                    return error.Reported;
                };
                i += 1;
                break :blk pair;
            }
            if (std.unicode.utf16IsLowSurrogate(utf16[i])) {
                std.log.err("paste: lone low surrogate 0x{x} at index {}", .{ utf16[i], i });
                return error.Reported;
            }
            const c: u21 = @intCast(utf16[i]);
            i += 1;
            break :blk c;
        };

        // Normalize line endings to CR. Windows clipboards store newlines
        // as CRLF, but terminals treat Enter as a bare CR — passing the LF
        // through leaves it as a stray byte the shell can't interpret, so
        // pasted lines collapse onto one line. Matches xterm bracketed
        // paste spec and what alacritty/kitty/foot do.
        var out_cp: u21 = cp;
        if (cp == '\n') {
            if (last_was_cr) {
                last_was_cr = false;
                continue;
            }
            out_cp = '\r';
        } else {
            last_was_cr = (cp == '\r');
        }

        switch (if (bracketed) try end_stripper.onCodepoint(writer, out_cp) else .ignored) {
            .consumed => {},
            .ignored => {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(out_cp, &utf8_buf) catch {
                    std.log.err("paste: invalid codepoint U+{x} at index {}", .{ out_cp, i });
                    return error.Reported;
                };
                try writer.writeAll(utf8_buf[0..len]);
            },
        }
    }
    try end_stripper.finish(writer);
    if (bracketed) try writer.writeAll(paste_end);
    try writer.flush();
}
