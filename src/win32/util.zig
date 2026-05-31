const std = @import("std");
const win32 = @import("win32").everything;
const types = @import("types.zig");
const Config = @import("../Config.zig");
const d3d11 = @import("d3d11.zig");

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

// Converts Config codepoint-map entries (UTF-8 family) to renderer entries
// (UTF-16 family). Same leak-by-design lifetime as utf16FontFamilies: the
// returned slice and each family buffer live for the renderer's lifetime.
// Entries with invalid UTF-8 in the family are dropped (with a warning).
pub fn utf16CodepointMaps(
    allocator: std.mem.Allocator,
    maps: []const Config.CodepointMap,
) []const d3d11.FontConfig.CodepointMapEntry {
    var out: std.ArrayListUnmanaged(d3d11.FontConfig.CodepointMapEntry) = .empty;
    for (maps) |m| {
        const required = std.unicode.calcUtf16LeLen(m.family) catch {
            std.log.warn("config: invalid utf-8 in font-codepoint-map family '{s}'; skipping", .{m.family});
            continue;
        };
        const buf = allocator.allocSentinel(u16, required, 0) catch |e| oom(e);
        const written = std.unicode.utf8ToUtf16Le(buf[0..required], m.family) catch unreachable;
        std.debug.assert(written == required);
        out.append(allocator, .{
            .first = m.range_start,
            .last = m.range_end,
            .family = buf.ptr,
        }) catch |e| oom(e);
    }
    if (out.items.len == 0) return &.{};
    return out.toOwnedSlice(allocator) catch |e| oom(e);
}

// Converts a Config.FontStyle (UTF-8 in arena) into a FontConfig.StyleSpec
// (UTF-16 for DirectWrite). Same leak-by-design lifetime as families.
pub fn convertStyleSpec(allocator: std.mem.Allocator, style: Config.FontStyle) d3d11.FontConfig.StyleSpec {
    return switch (style) {
        .default => .default,
        .disabled => .disabled,
        .named => |name| blk: {
            const u16name = utf16FamilyOptional(allocator, name) orelse break :blk .default;
            break :blk .{ .named = u16name };
        },
    };
}

// Converts a single UTF-8 family name to a heap-allocated null-terminated
// UTF-16 string, or returns null if the input is empty / invalid utf-8.
// Same leak-by-design lifetime as utf16FontFamilies.
pub fn utf16FamilyOptional(allocator: std.mem.Allocator, family: []const u8) ?[*:0]const u16 {
    if (family.len == 0) return null;
    const required = std.unicode.calcUtf16LeLen(family) catch {
        std.log.warn("config: invalid utf-8 in font family '{s}'; ignoring", .{family});
        return null;
    };
    const buf = allocator.allocSentinel(u16, required, 0) catch |e| oom(e);
    const written = std.unicode.utf8ToUtf16Le(buf[0..required], family) catch unreachable;
    std.debug.assert(written == required);
    return buf.ptr;
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
