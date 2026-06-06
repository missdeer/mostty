const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const Config = @import("../Config.zig");
const cp_mod = @import("child_process.zig");
const err_mod = @import("error.zig");
const global_mod = @import("global.zig");
const state = @import("state.zig");
const tooltip = @import("tooltip.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const vt_stream_mod = @import("vt_stream.zig");
const window_geom = @import("window_geom.zig");

const ChildProcess = cp_mod.ChildProcess;
const Error = err_mod.Error;
const Tab = state.Tab;
const TabId = types.TabId;
const Window = state.Window;
const global = global_mod.global;

fn tabFromEffectHandler(handler: *vt.TerminalStream.Handler) *Tab {
    const mostty_handler: *vt_stream_mod.Handler = @fieldParentPtr("inner", handler);
    const stream: *vt_stream_mod.Stream = @fieldParentPtr("handler", mostty_handler);
    return @fieldParentPtr("vt_stream", stream);
}

// Effects callback fired when the terminal title changes (OSC 0/2). The
// stream_terminal Handler has no user context, so walk back through the
// Stream's `handler` field to the owning Tab via @fieldParentPtr. The
// Window comes from the singleton `global.window` (set once in WM_CREATE).
// Only the per-tab title (shown in the tab bar) is updated; the main
// window title bar is kept fixed at "Mostty" (set at window creation).
fn onTitleChanged(handler: *vt.TerminalStream.Handler) void {
    if (global.window == null) return;
    const window: *Window = &global.window.?;
    const tab = tabFromEffectHandler(handler);
    const title = handler.terminal.getTitle() orelse return;
    const n = @min(title.len, tab.title_buf.len);
    @memcpy(tab.title_buf[0..n], title[0..n]);
    tab.title_len = n;
    tooltip.refreshIfShowing(window, tab);
    window.requestRender();
}

// Write a query response (CSI c, DECRQM, DSR, XTVERSION, kitty keyboard
// query, size report, kitty graphics ACK, ...) back to the PTY. Without
// this, tools like nvim/fzf/less hang waiting for the reply they parse off
// stdin. Reached only via vt_stream.nextSlice on the UI thread; replies
// are small (a few bytes) and go through the same path as user keystrokes
// (see writeToActivePty), so synchronous writeAll is fine in practice.
fn onWritePty(handler: *vt.TerminalStream.Handler, data: [:0]const u8) void {
    const tab = tabFromEffectHandler(handler);
    if (tab.closing) return;
    const pty = tab.child_process.pty orelse return;
    pty.writeFlushAll(data) catch |e| std.log.err(
        "write_pty failed (tab {}): {s}",
        .{ tab.id, @errorName(e) },
    );
}

// Pull the return type of one of the Effects callback pointers. Lets us
// reference types like `device_attributes.Attributes` / `size_report.Size`
// without ghostty-vt's lib_vt.zig having to re-export them.
fn EffectReturnType(comptime field: []const u8) type {
    const Effects = vt.TerminalStream.Handler.Effects;
    const opt = @typeInfo(@FieldType(Effects, field)).optional;
    const ptr = @typeInfo(opt.child).pointer;
    const func = @typeInfo(ptr.child).@"fn";
    return func.return_type.?;
}

// Encode the response for CSI c / CSI > c / CSI = c. Defaults match what
// ghostty itself reports (VT220 / ANSI color) — good enough for nvim,
// fzf, less, etc.
fn onDeviceAttributes(_: *vt.TerminalStream.Handler) EffectReturnType("device_attributes") {
    return .{};
}

// XTVERSION (CSI > 0 q). Without this, the fallback inside ghostty-vt
// answers "libghostty"; override so apps that switch on the terminal
// identifier see "mostty".
fn onXtVersion(_: *vt.TerminalStream.Handler) []const u8 {
    return "mostty";
}

// Pixel-based size queries (CSI 14/16/18 t). Cell width/height come from
// the active renderer; rows/cols from the per-tab terminal state. Returns
// null (silently ignored) if the renderer hasn't measured a cell yet.
fn onSize(handler: *vt.TerminalStream.Handler) EffectReturnType("size") {
    const cs = global.renderer.cell_size;
    const cell_width = std.math.cast(u32, cs.cx) orelse return null;
    const cell_height = std.math.cast(u32, cs.cy) orelse return null;
    if (cell_width == 0 or cell_height == 0) return null;
    return .{
        .rows = handler.terminal.rows,
        .columns = handler.terminal.cols,
        .cell_width = cell_width,
        .cell_height = cell_height,
    };
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
        global.config.env,
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
        .default_modes = .{ .grapheme_cluster = true },
    }) catch |e| std.debug.panic("Terminal.init: {}", .{e});
    global.config.theme.applyToNewTerminal(tab.term);

    tab.vt_stream = .initAlloc(
        global.gpa.allocator(),
        vt_stream_mod.Handler.init(tab.term, effects: {
            var e: vt.TerminalStream.Handler.Effects = .readonly;
            e.title_changed = onTitleChanged;
            e.write_pty = onWritePty;
            e.device_attributes = onDeviceAttributes;
            e.xtversion = onXtVersion;
            e.size = onSize;
            break :effects e;
        }),
    );

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
    tooltip.hide(window);
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

pub fn writeToPty(tab: *Tab, bytes: []const u8) void {
    const pty = tab.child_process.pty orelse {
        std.log.err("write: pty closed for tab {}", .{tab.id});
        return;
    };
    pty.writeFlushAll(bytes) catch |e| std.log.err(
        "write to pty failed: {s}",
        .{@errorName(e)},
    );
}

pub fn writeToActivePty(window: *Window, bytes: []const u8) void {
    writeToPty(window.active(), bytes);
}
