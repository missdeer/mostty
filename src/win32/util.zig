const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn isCtrlDown() bool {
    return win32.GetKeyState(@intFromEnum(win32.VK_CONTROL)) < 0;
}

pub fn isShiftDown() bool {
    return win32.GetKeyState(@intFromEnum(win32.VK_SHIFT)) < 0;
}

pub fn isAltDown() bool {
    return win32.GetKeyState(@intFromEnum(win32.VK_MENU)) < 0;
}

pub fn rectIntFromSize(args: struct { left: i32, top: i32, width: i32, height: i32 }) win32.RECT {
    return .{
        .left = args.left,
        .top = args.top,
        .right = args.left + args.width,
        .bottom = args.top + args.height,
    };
}

pub fn setWindowPosRect(hwnd: win32.HWND, rect: win32.RECT) void {
    if (0 == win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) win32.panicWin32("SetWindowPos", win32.GetLastError());
}

pub fn getClientInset(dpi: u32) win32.SIZE {
    var rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (0 == win32.AdjustWindowRectExForDpi(
        &rect,
        types.window_style,
        0,
        types.window_style_ex,
        dpi,
    )) win32.panicWin32("AdjustWindowRect", win32.GetLastError());
    return .{ .cx = rect.right - rect.left, .cy = rect.bottom - rect.top };
}

pub fn hitEql(a: ?types.TabHit, b: types.TabHit) bool {
    if (a == null) return b == .none;
    const av = a.?;
    if (@as(std.meta.Tag(types.TabHit), av) != @as(std.meta.Tag(types.TabHit), b)) return false;
    return switch (av) {
        .none => true,
        .new_tab => true,
        .activate => |i| b.activate == i,
        .close => |i| b.close == i,
    };
}

pub fn globalUnlock(hmem: isize) void {
    win32.SetLastError(.NO_ERROR);
    if (0 == win32.GlobalUnlock(hmem)) {
        const err = win32.GetLastError();
        if (err != .NO_ERROR) win32.panicWin32("GlobalUnlock", err);
    }
}

pub const Utf8ToUtf16Result = struct {
    len: usize,
    replacement_count: usize,
    bytes_consumed: usize,
};

pub fn utf8ToUtf16Short(utf8: []const u8, buf: []u16) Utf8ToUtf16Result {
    const replacement = std.mem.nativeToLittle(u16, 0xFFFD);
    var bytes_consumed: usize = 0;
    var out: usize = 0;
    var replacement_count: usize = 0;
    while (bytes_consumed < utf8.len and out < buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[bytes_consumed]) catch {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            bytes_consumed += 1;
            continue;
        };
        if (bytes_consumed + seq_len > utf8.len) {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(utf8[bytes_consumed..][0..seq_len]) catch {
            buf[out] = replacement;
            out += 1;
            replacement_count += 1;
            bytes_consumed += seq_len;
            continue;
        };
        if (cp >= 0x10000) {
            if (out + 2 > buf.len) break;
            const high: u16 = @intCast((cp - 0x10000) >> 10);
            const low: u16 = @intCast((cp - 0x10000) & 0x3FF);
            buf[out] = std.mem.nativeToLittle(u16, 0xD800 + high);
            buf[out + 1] = std.mem.nativeToLittle(u16, 0xDC00 + low);
            out += 2;
        } else {
            buf[out] = std.mem.nativeToLittle(u16, @intCast(cp));
            out += 1;
        }
        bytes_consumed += seq_len;
    }
    return .{
        .len = out,
        .replacement_count = replacement_count,
        .bytes_consumed = bytes_consumed,
    };
}

pub fn setWindowTitleFromUtf8(hwnd: win32.HWND, title: []const u8) void {
    const max_u16 = 500;
    var utf16_buf: [max_u16 + 1]u16 = undefined;
    const result = utf8ToUtf16Short(title, utf16_buf[0..max_u16]);
    if (result.replacement_count > 0) {
        std.log.warn("window title contained {} invalid utf-8 sequence(s)", .{result.replacement_count});
    }
    utf16_buf[result.len] = 0;
    if (win32.SetWindowTextW(hwnd, @ptrCast(&utf16_buf)) == 0) {
        std.log.err("SetWindowTextW failed, error={f}", .{win32.GetLastError()});
    }
}

pub fn utf16ZAlloc(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![]u16 {
    const required = std.unicode.calcUtf16LeLen(utf8) catch unreachable;
    const out = try allocator.alloc(u16, required);
    const written = std.unicode.utf8ToUtf16Le(out, utf8) catch unreachable;
    std.debug.assert(written == required);
    return out;
}

pub fn utf16ZAllocMut(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![*:0]u16 {
    const required = std.unicode.calcUtf16LeLen(utf8) catch unreachable;
    const buf = try allocator.allocSentinel(u16, required, 0);
    const written = std.unicode.utf8ToUtf16Le(buf[0..required], utf8) catch unreachable;
    std.debug.assert(written == required);
    return buf.ptr;
}

pub fn utf16ZAllocConst(allocator: std.mem.Allocator, utf8: []const u8) error{OutOfMemory}![*:0]const u16 {
    return utf16ZAllocMut(allocator, utf8);
}

// Converts UTF-8 family names to heap-allocated, null-terminated UTF-16
// strings. The returned outer slice and each inner string are leaked
// intentionally; they live for the lifetime of the renderer.
pub fn utf16FontFamilies(allocator: std.mem.Allocator, families: []const []const u8) []const [*:0]const u16 {
    var out: std.ArrayListUnmanaged([*:0]const u16) = .empty;
    for (families) |name| {
        const required = std.unicode.calcUtf16LeLen(name) catch {
            std.log.warn("config: invalid utf-8 in font-family '{s}'; skipping", .{name});
            continue;
        };
        const buf = allocator.allocSentinel(u16, required, 0) catch |e| oom(e);
        const written = std.unicode.utf8ToUtf16Le(buf[0..required], name) catch unreachable;
        std.debug.assert(written == required);
        out.append(allocator, buf.ptr) catch |e| oom(e);
    }
    if (out.items.len == 0) return &.{};
    return out.toOwnedSlice(allocator) catch |e| oom(e);
}
