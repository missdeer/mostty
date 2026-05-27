const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const Config = @import("../Config.zig");
const cp_mod = @import("child_process.zig");
const err_mod = @import("error.zig");
const global_mod = @import("global.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const window_geom = @import("window_geom.zig");

const ChildProcess = cp_mod.ChildProcess;
const Error = err_mod.Error;
const Tab = state.Tab;
const TabId = types.TabId;
const Window = state.Window;
const global = global_mod.global;

// Effects callback fired when the terminal title changes (OSC 0/2). The
// stream_terminal Handler has no user context, so walk back through the
// Stream's `handler` field to the owning Tab via @fieldParentPtr. The
// Window comes from the singleton `global.window` (set once in WM_CREATE).
fn onTitleChanged(handler: *vt.TerminalStream.Handler) void {
    if (global.window == null) return;
    const window: *Window = &global.window.?;
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const tab: *Tab = @fieldParentPtr("vt_stream", stream);
    const title = handler.terminal.getTitle() orelse return;
    const n = @min(title.len, tab.title_buf.len);
    @memcpy(tab.title_buf[0..n], title[0..n]);
    tab.title_len = n;
    if (window.tabs.items[window.active_index] == tab) {
        util.setWindowTitleFromUtf8(window.hwnd, tab.title_buf[0..tab.title_len]);
    }
    window.requestRender();
}

pub fn newTab(window: *Window) void {
    const launcher: ?*const Config.Launcher = if (global.config.launchers.len > 0)
        &global.config.launchers[0]
    else
        null;
    newTabWithLauncher(window, launcher);
}

pub fn newTabWithLauncher(window: *Window, launcher: ?*const Config.Launcher) void {
    if (window.tabs.items.len >= types.MAX_TABS) {
        std.log.warn("tab limit reached ({}); not opening new tab", .{types.MAX_TABS});
        return;
    }
    const cs = global.renderer.cell_size;
    const cell_count = window_geom.computeGridCellCount(window.hwnd, cs);

    const tab = global.gpa.allocator().create(Tab) catch util.oom(error.OutOfMemory);
    tab.* = .{
        .id = window.next_tab_id,
        .child_process = undefined,
        .term = undefined,
        .term_arena = .init(std.heap.page_allocator),
        .vt_stream = undefined,
    };
    window.next_tab_id += 1;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var application_name: ?[*:0]const u16 = null;
    var command_line: ?[*:0]u16 = null;
    var working_directory: ?[*:0]const u16 = null;
    if (launcher) |L| {
        const cmd_u16 = util.utf16ZAllocMut(arena.allocator(), L.command_line) catch |e| util.oom(e);
        command_line = cmd_u16;
        if (L.working_directory.len > 0) {
            const cwd_u16 = util.utf16ZAllocConst(arena.allocator(), L.working_directory) catch |e| util.oom(e);
            working_directory = cwd_u16;
        }
    } else {
        application_name = win32.L("C:\\Windows\\System32\\cmd.exe");
    }

    var err: Error = undefined;
    tab.child_process = ChildProcess.startConPtyWin32(
        &err,
        arena.allocator(),
        application_name,
        command_line,
        working_directory,
        window.hwnd,
        types.WM_APP_CHILD_PROCESS_DATA,
        types.WM_APP_CHILD_PROCESS_DATA_RESULT,
        cell_count,
        tab.id,
        &tab.reader_stop,
    ) catch {
        // User-configurable launchers can fail (bad path, missing exe, etc.);
        // surface and abandon this tab rather than crashing the whole app.
        // The fallback cmd.exe path (launcher == null) still panics on failure
        // because that's a system-level problem.
        if (launcher != null) {
            std.log.err("launcher '{s}' failed to start: {f}", .{ launcher.?.label, err });
            tab.term_arena.deinit();
            global.gpa.allocator().destroy(tab);
            return;
        }
        std.debug.panic("{f}", .{err});
    };

    tab.term = std.heap.page_allocator.create(vt.Terminal) catch util.oom(error.OutOfMemory);
    tab.term.* = vt.Terminal.init(tab.term_arena.allocator(), .{
        .cols = cell_count.col,
        .rows = cell_count.row,
    }) catch |e| std.debug.panic("Terminal.init: {}", .{e});

    tab.vt_stream = .initAlloc(global.gpa.allocator(), .{
        .terminal = tab.term,
        .effects = effects: {
            var e: vt.TerminalStream.Handler.Effects = .readonly;
            e.title_changed = onTitleChanged;
            break :effects e;
        },
    });

    window.tabs.append(global.gpa.allocator(), tab) catch util.oom(error.OutOfMemory);
    window.active_index = window.tabs.items.len - 1;
    window.onActiveChanged();
}

pub fn switchToTab(window: *Window, new_idx: usize) void {
    if (new_idx == window.active_index) return;
    if (new_idx >= window.tabs.items.len) return;
    window.active_index = new_idx;
    window.onActiveChanged();
}

pub fn closeTabByIndex(window: *Window, idx: usize) void {
    if (idx >= window.tabs.items.len) return;
    const tab = window.tabs.items[idx];
    if (tab.closing) return;
    tab.closing = true;
    _ = win32.PostMessageW(window.hwnd, types.WM_APP_CLOSE_TAB, tab.id, 0);
}

pub fn confirmYesNo(hwnd: win32.HWND, text: [*:0]const u16, caption: [*:0]const u16) bool {
    const result = win32.MessageBoxW(hwnd, text, caption, .{
        .YESNO = 1,
        .ICONQUESTION = 1,
        // Default to "No" so an accidental Enter doesn't close.
        .DEFBUTTON2 = 1,
    });
    return result == win32.IDYES;
}

pub fn confirmAndCloseTab(window: *Window, tab_id: TabId) void {
    if (window.confirming_close) return;
    window.confirming_close = true;
    defer window.confirming_close = false;
    if (!confirmYesNo(
        window.hwnd,
        win32.L("Close this tab?"),
        win32.L("Mostty"),
    )) return;
    // Re-look the index: the modal's nested message pump may have
    // shifted indices (or destroyed the target tab entirely).
    if (window.findIndexById(tab_id)) |idx| {
        closeTabByIndex(window, idx);
    }
}

pub fn destroyAllTabs(window: *Window) void {
    while (window.tabs.items.len > 0) {
        const tab = window.tabs.items[0];
        destroyTab(window, tab);
    }
}

pub fn destroyTab(window: *Window, tab: *Tab) void {
    // Mark closing so any in-flight reader-thread SendMessage during the
    // pump-while-wait below drops its payload (the handler still returns
    // the magic value). Also unhook from window.tabs before any pump or
    // free: queued WM_APP_CLOSE_TAB for this tab won't re-enter
    // destroyTab once findById returns null, and the eventual free can't
    // be observed via findIndexById from a re-entrant message.
    tab.closing = true;
    const removed_idx_opt = window.findIndexById(tab.id);
    if (removed_idx_opt) |idx| {
        _ = window.tabs.orderedRemove(idx);
        if (window.tabs.items.len == 0) {
            window.active_index = 0;
        } else if (window.active_index >= window.tabs.items.len) {
            window.active_index = window.tabs.items.len - 1;
        } else if (window.active_index > idx) {
            window.active_index -= 1;
        }
    }

    tab.reader_stop.store(true, .release);
    _ = win32.CancelIoEx(tab.child_process.read, null);

    const thread_handle: win32.HANDLE = tab.child_process.thread.getHandle();
    while (true) {
        var handles = [_]win32.HANDLE{thread_handle};
        const r = win32.MsgWaitForMultipleObjects(
            1,
            &handles,
            0,
            win32.INFINITE,
            win32.QS_SENDMESSAGE,
        );
        if (r == 0) break; // thread exited
        if (r == 1) {
            var msg: win32.MSG = undefined;
            while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) > 0) {
                if (msg.message == win32.WM_QUIT) {
                    _ = win32.PostQuitMessage(@intCast(msg.wParam));
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
            continue;
        }
        if (r == @intFromEnum(win32.WAIT_FAILED)) {
            win32.panicWin32("MsgWaitForMultipleObjects (destroyTab)", win32.GetLastError());
        }
    }

    tab.child_process.closePty();
    tab.child_process.thread.join();
    win32.closeHandle(tab.child_process.read);
    win32.closeHandle(tab.child_process.job);
    win32.closeHandle(tab.child_process.process_handle);

    tab.vt_stream.deinit();
    tab.term_arena.deinit();
    std.heap.page_allocator.destroy(tab.term);
    global.gpa.allocator().destroy(tab);

    if (window.tabs.items.len == 0) {
        win32.PostQuitMessage(0);
        return;
    }
    window.onActiveChanged();
}

pub fn writeToActivePty(window: *Window, bytes: []const u8) void {
    const tab = window.active();
    const pty = tab.child_process.pty orelse {
        std.log.err("write: pty closed for tab {}", .{tab.id});
        return;
    };
    pty.writeFlushAll(bytes) catch |e| std.log.err(
        "write to pty failed: {s}",
        .{@errorName(e)},
    );
}
