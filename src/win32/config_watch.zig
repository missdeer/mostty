// Watches %LOCALAPPDATA%/Mostty for changes to the `config` file and pokes the
// UI thread (WM_APP_CONFIG_CHANGED) so it can hot-reload. Runs on a detached
// thread blocked in ReadDirectoryChangesW; the process exits via ExitProcess,
// so there's no graceful shutdown/join — the OS reaps the blocked thread.
const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../Config.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn start(hwnd: win32.HWND) void {
    const thread = std.Thread.spawn(.{}, watchThread, .{hwnd}) catch |e| {
        std.log.warn("config watch: spawn failed: {s}; live reload disabled", .{@errorName(e)});
        return;
    };
    thread.detach();
}

fn watchThread(hwnd: win32.HWND) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg_path = Config.defaultPath(a) orelse {
        std.log.info("config watch: LOCALAPPDATA unavailable; live reload disabled", .{});
        return;
    };
    const dir = std.fs.path.dirname(cfg_path) orelse return;
    // Open requires the directory to exist; "Open Settings File..." also
    // creates it lazily, but the watcher may run first.
    std.fs.cwd().makePath(dir) catch |e| {
        std.log.warn("config watch: makePath '{s}' failed: {s}", .{ dir, @errorName(e) });
        return;
    };
    const dir_w = util.utf16ZAllocConst(a, dir) catch return;

    const handle = win32.CreateFileW(
        dir_w,
        win32.FILE_LIST_DIRECTORY,
        .{ .READ = 1, .WRITE = 1, .DELETE = 1 },
        null,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        std.log.warn("config watch: open dir failed, error={f}", .{win32.GetLastError()});
        return;
    }
    defer win32.closeHandle(handle);

    const filter = win32.FILE_NOTIFY_CHANGE{ .FILE_NAME = 1, .SIZE = 1, .LAST_WRITE = 1 };
    // FILE_NOTIFY_INFORMATION entries are DWORD-aligned.
    var buffer: [4096]u8 align(@alignOf(u32)) = undefined;

    while (true) {
        var bytes_returned: u32 = 0;
        const ok = win32.ReadDirectoryChangesW(
            handle,
            &buffer,
            buffer.len,
            0, // bWatchSubtree: directory has only the config file
            filter,
            &bytes_returned,
            null,
            null,
        );
        if (ok == 0) switch (win32.GetLastError()) {
            // Buffer overflowed: specific events lost. Reload unconditionally.
            .ERROR_NOTIFY_ENUM_DIR => {
                _ = win32.PostMessageW(hwnd, types.WM_APP_CONFIG_CHANGED, 0, 0);
                continue;
            },
            .ERROR_OPERATION_ABORTED => return,
            else => |e| {
                std.log.warn("config watch: ReadDirectoryChangesW error={f}", .{e});
                return;
            },
        };
        // Zero bytes also signals an overflow on some systems.
        if (bytes_returned == 0 or configTouched(buffer[0..bytes_returned])) {
            _ = win32.PostMessageW(hwnd, types.WM_APP_CONFIG_CHANGED, 0, 0);
        }
    }
}

// Walks the FILE_NOTIFY_INFORMATION list; true if any entry names "config".
// FileNameLength is in bytes (UTF-16, not NUL-terminated).
fn configTouched(data: []const u8) bool {
    const name_field_off = @offsetOf(win32.FILE_NOTIFY_INFORMATION, "FileName");
    var offset: usize = 0;
    while (offset + name_field_off <= data.len) {
        const info: *const win32.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(data.ptr + offset));
        // FileNameLength is in bytes; bound the name to the buffer before reading.
        const name_start = offset + name_field_off;
        if (name_start + info.FileNameLength > data.len) break;
        const name_ptr: [*]const u16 = @ptrCast(@alignCast(data.ptr + name_start));
        const name = name_ptr[0 .. info.FileNameLength / 2];
        if (utf16EqlAsciiIgnoreCase(name, "config")) return true;
        if (info.NextEntryOffset == 0) break;
        offset += info.NextEntryOffset;
    }
    return false;
}

fn utf16EqlAsciiIgnoreCase(name: []const u16, ascii: []const u8) bool {
    if (name.len != ascii.len) return false;
    for (name, ascii) |w, c| {
        if (w > 0x7f) return false;
        if (std.ascii.toLower(@intCast(w)) != std.ascii.toLower(c)) return false;
    }
    return true;
}
