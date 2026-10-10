const std = @import("std");
const win32 = @import("win32").everything;

const state = @import("state.zig");
const util = @import("util.zig");

const Tab = state.Pane;
const Window = state.Window;

const paste_core = @import("../terminal/paste.zig");

pub fn copyToClipboard(hwnd: win32.HWND, utf8: []const u8) void {
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
    enqueuePaste(tab, pty, mem);
}

pub fn onDropFiles(window: *Window, hwnd: win32.HWND, hdrop: win32.HDROP) void {
    defer win32.DragFinish(hdrop);

    const tab = window.paneFromHwnd(hwnd) orelse return;
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

    enqueuePaste(tab, pty, final.ptr);
}

fn enqueuePaste(tab: *Tab, pty: @import("child_process.zig").ChildProcess.Pty, utf16: [*:0]const u16) void {
    var encoded: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer encoded.deinit();
    pasteUtf16(tab, utf16, &encoded.writer) catch |err| {
        std.log.err("paste: encoding failed: {s}", .{@errorName(err)});
        return;
    };
    // Enqueue the complete transaction atomically, including both markers.
    pty.writeFlushAll(encoded.written()) catch |err|
        std.log.err("paste: enqueue failed: {s}", .{@errorName(err)});
}

pub fn pasteUtf16(tab: *Tab, utf16: [*:0]const u16, writer: *std.Io.Writer) error{ WriteFailed, Reported }!void {
    const bracketed = tab.term.modes.get(.bracketed_paste);
    paste_core.writeUtf16(writer, std.mem.span(utf16), bracketed) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => {
            std.log.err("paste: invalid UTF-16: {s}", .{@errorName(err)});
            return error.Reported;
        },
    };
    try writer.flush();
}
