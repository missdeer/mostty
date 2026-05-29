const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../../Config.zig");
const global_mod = @import("../global.zig");
const paste = @import("../paste.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");

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

pub fn onSysCommand(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    // DefWindowProc uses the low 4 bits internally; mask before comparing.
    if ((wparam & 0xFFF0) == types.IDM_OPEN_SETTINGS) {
        openSettingsFile(hwnd);
        return 0;
    }
    return null; // delegate the rest (Move/Size/Close/...) to DefWindowProcW
}

// Opens %LOCALAPPDATA%/mostty/config in notepad.exe, creating an empty file
// (and its parent dir) first if it does not exist yet.
fn openSettingsFile(hwnd: win32.HWND) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = Config.defaultPath(a) orelse {
        std.log.err("settings: LOCALAPPDATA unavailable", .{});
        return;
    };

    ensureFileExists(path) catch |err| {
        std.log.err("settings: cannot create '{s}': {s}", .{ path, @errorName(err) });
        return;
    };

    // Quote so a path with spaces reaches notepad as a single argument.
    const quoted = std.fmt.allocPrint(a, "\"{s}\"", .{path}) catch |e| util.oom(e);
    const params_w = util.utf16ZAllocConst(a, quoted) catch |e| util.oom(e);
    const result = win32.ShellExecuteW(
        hwnd,
        win32.L("open"),
        win32.L("notepad.exe"),
        params_w,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    );
    const code = if (result) |h| @intFromPtr(h) else 0;
    if (code <= 32) std.log.err("settings: ShellExecuteW failed, code={d}", .{code});
}

fn ensureFileExists(path: []const u8) !void {
    // Don't require write access to a config that already exists (it may be
    // read-only); only create one when it's actually missing.
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
            // truncate=false guards against clobbering if a racing writer wins.
            const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
            f.close();
        },
        else => return err,
    };
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
