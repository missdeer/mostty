const std = @import("std");
const win32 = @import("win32").everything;
const vt = @import("vt");

const Config = @import("../Config.zig");
const TerminalSession = @import("../terminal/Session.zig");
const cp_mod = @import("child_process.zig");
const err_mod = @import("error.zig");
const global_mod = @import("global.zig");
const pty_ring_mod = @import("pty_ring.zig");
const state = @import("state.zig");
const tooltip = @import("tooltip.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const window_geom = @import("window_geom.zig");

const ChildProcess = cp_mod.ChildProcess;
const Error = err_mod.Error;
const Tab = state.Pane;
const native = @import("pane_native.zig");
const TabId = types.TabId;
const Window = state.Window;
const global = global_mod.global;

// Effects callback fired when the terminal title changes (OSC 0/2). The
// shared session supplies the owning Tab as callback context. The Window
// comes from the singleton `global.window` (set once in WM_CREATE).
// Only the per-tab title (shown in the tab bar) is updated; the main
// window title bar is kept fixed at "Mostty" (set at window creation).
fn onTitleChanged(context: *anyopaque, term: *vt.Terminal) void {
    if (global.window == null) return;
    const window: *Window = &global.window.?;
    const tab: *Tab = @ptrCast(@alignCast(context));
    const title = term.getTitle() orelse return;
    const n = @min(title.len, tab.title_buf.len);
    @memcpy(tab.title_buf[0..n], title[0..n]);
    tab.title_len = n;
    tooltip.refreshIfShowing(window, tab.tab);
    window.requestRender();
}

// Write a query response (CSI c, DECRQM, DSR, XTVERSION, kitty keyboard
// query, size report, kitty graphics ACK, ...) back to the PTY. Without
// this, tools like nvim/fzf/less hang waiting for the reply they parse off
// stdin. Reached only via TerminalSession.feed on the UI thread; replies
// are small (a few bytes) and go through the same path as user keystrokes
// (see writeToActivePty), so synchronous writeAll is fine in practice.
fn onWritePty(context: *anyopaque, data: [:0]const u8) void {
    const tab: *Tab = @ptrCast(@alignCast(context));
    if (tab.closing) return;
    const pty = tab.child_process.pty orelse return;
    pty.writeFlushAll(data) catch |e| std.log.err(
        "write_pty failed (tab {}): {s}",
        .{ tab.id, @errorName(e) },
    );
}

// Pixel-based size queries (CSI 14/16/18 t). Cell width/height come from
// the active renderer; rows/cols from the per-tab terminal state. Returns
// null (silently ignored) if the renderer hasn't measured a cell yet.
fn onSize(_: *anyopaque, term: *vt.Terminal) TerminalSession.SizeResponse {
    const cs = global.renderer.common.cell_size;
    const cell_width = std.math.cast(u32, cs.cx) orelse return null;
    const cell_height = std.math.cast(u32, cs.cy) orelse return null;
    if (cell_width == 0 or cell_height == 0) return null;
    return .{
        .rows = term.rows,
        .columns = term.cols,
        .cell_width = cell_width,
        .cell_height = cell_height,
    };
}

pub fn syncTerminalPixelSize(tab: *Tab) void {
    const cs = global.renderer.common.cell_size;
    const cell_w = std.math.cast(u32, cs.cx) orelse 0;
    const cell_h = std.math.cast(u32, cs.cy) orelse 0;
    tab.session.syncPixelSize(cell_w, cell_h);
}

pub fn newTab(window: *Window) void {
    const launcher: ?*const Config.Launcher = if (global.config.launchers.len > 0)
        &global.config.launchers[0]
    else
        null;
    newTabWithLauncher(window, launcher);
}

pub fn newTabWithLauncher(window: *Window, launcher: ?*const Config.Launcher) void {
    if (window.tabs.items.len >= types.MAX_TABS or window.panes.items.len >= types.MAX_PANES) {
        std.log.warn("tab or pane limit reached", .{});
        return;
    }
    const gpa = global.gpa.allocator();
    const id = allocatePaneId(window) orelse return;
    const tab = gpa.create(state.Tab) catch util.oom(error.OutOfMemory);
    tab.* = .{ .id = id, .window = window, .layout = state.SplitLayout.init(gpa, id) catch util.oom(error.OutOfMemory) };
    if (createPane(window, tab, id, launcher) == null) {
        tab.layout.deinit();
        gpa.destroy(tab);
        return;
    }
    window.tabs.append(gpa, tab) catch util.oom(error.OutOfMemory);
    window.active_index = window.tabs.items.len - 1;
    native.reflow(window);
    window.onActiveChanged();
    native.focusActive(window);
}

fn allocatePaneId(window: *Window) ?types.TabId {
    if (window.next_pane_id == std.math.maxInt(types.TabId)) {
        std.log.err("pane identity space exhausted", .{});
        return null;
    }
    const id = window.next_pane_id;
    window.next_pane_id += 1;
    return id;
}

fn createPane(window: *Window, owner: *state.Tab, id: types.TabId, launcher: ?*const Config.Launcher) ?*Tab {
    const cs = global.renderer.common.cell_size;
    const cell_count = window_geom.computeGridCellCount(window.hwnd, cs);
    const tab = global.gpa.allocator().create(Tab) catch util.oom(error.OutOfMemory);
    tab.* = .{
        .id = id,
        .tab = owner,
        .child_process = undefined,
        .session = undefined,
        .term = undefined,
        .input_layout = state.systemDefaultInputLayout(),
    };
    tab.pty_ring = pty_ring_mod.PtyRing.init(global.gpa.allocator(), &tab.reader_stop) catch |e| switch (e) {
        error.OutOfMemory => util.oom(error.OutOfMemory),
        error.CreateEventFailed => win32.panicWin32("CreateEventW (pty_ring)", win32.GetLastError()),
    };

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
        cell_count,
        tab.id,
        &tab.reader_stop,
        &tab.pty_ring,
        global.config.env,
    ) catch {
        // User-configurable launchers can fail (bad path, missing exe, etc.);
        // surface and abandon this tab rather than crashing the whole app.
        // The fallback cmd.exe path (launcher == null) still panics on failure
        // because that's a system-level problem.
        if (launcher != null) {
            std.log.err("launcher '{s}' failed to start: {f}", .{ launcher.?.label, err });
            tab.pty_ring.deinit(global.gpa.allocator());
            global.gpa.allocator().destroy(tab);
            return null;
        }
        std.debug.panic("{f}", .{err});
    };

    tab.session.init(.{
        .io = std.Io.Threaded.global_single_threaded.io(),
        .terminal_allocator = std.heap.page_allocator,
        .stream_allocator = global.gpa.allocator(),
        .cols = cell_count.col,
        .rows = cell_count.row,
        .images_enabled = global.config.images_enabled,
        .hooks = .{
            .context = tab,
            .title_changed = onTitleChanged,
            .write_pty = onWritePty,
            .size = onSize,
        },
    }) catch |e| std.debug.panic("TerminalSession.init: {}", .{e});
    tab.term = tab.session.term;
    syncTerminalPixelSize(tab);
    global.config.theme.applyToNewTerminal(tab.term);

    window.panes.append(global.gpa.allocator(), tab) catch util.oom(error.OutOfMemory);
    return tab;
}

pub fn switchToTab(window: *Window, new_idx: usize) void {
    if (new_idx == window.active_index) return;
    if (new_idx >= window.tabs.items.len) return;
    window.active_index = new_idx;
    native.reflow(window);
    window.onActiveChanged();
    native.focusActive(window);
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
    if (window.findTabIndexById(tab_id)) |idx| {
        closeTabByIndex(window, idx);
    }
}

pub fn destroyAllTabs(window: *Window) void {
    while (window.tabs.items.len > 0) {
        const tab = window.tabs.items[0];
        destroyTab(window, tab);
    }
}

pub fn destroyTab(window: *Window, tab: *state.Tab) void {
    tab.closing = true;
    var i: usize = 0;
    while (i < window.panes.items.len) {
        const pane = window.panes.items[i];
        if (pane.tab == tab) releasePane(window, pane) else i += 1;
    }
    removeTab(window, tab);
}

fn removeTab(window: *Window, tab: *state.Tab) void {
    tooltip.hide(window);
    const idx = window.findTabIndexById(tab.id) orelse return;
    _ = window.tabs.orderedRemove(idx);
    if (window.active_index > idx) window.active_index -= 1;
    if (window.active_index >= window.tabs.items.len) window.active_index = window.tabs.items.len -| 1;
    tab.layout.deinit();
    global.gpa.allocator().destroy(tab);
    if (window.tabs.items.len == 0) {
        win32.PostQuitMessage(0);
        return;
    }
    native.reflow(window);
    window.onActiveChanged();
    native.focusActive(window);
}

pub fn destroyPane(window: *Window, pane: *Tab) void {
    const tab = pane.tab;
    const id = pane.id;
    releasePane(window, pane);
    _ = tab.layout.close(id);
    if (tab.layout.count == 0) {
        removeTab(window, tab);
    } else {
        native.reflow(window);
        window.onActiveChanged();
        native.focusActive(window);
    }
}

fn releasePane(window: *Window, tab: *Tab) void {
    tab.closing = true;
    native.destroy(window, tab);
    for (window.panes.items, 0..) |pane, i| {
        if (pane == tab) {
            _ = window.panes.orderedRemove(i);
            break;
        }
    }

    // Stop the reader. Three wake mechanisms:
    //   1. CancelIoEx     — interrupts ReadFile (if reader is parked there)
    //   2. SetEvent       — wakes WaitForSingleObject on the ring's
    //                       wake_event (if ring was full)
    //   3. closePty       — closes the ConPTY + our_write side, guaranteeing
    //                       ReadFile returns BROKEN_PIPE even if CancelIoEx
    //                       lost a race (reader hadn't entered ReadFile yet).
    // (1) and (2) are fast wakes; (3) is the belt-and-suspenders guarantee
    // against the narrow window where reader is between the stop_flag check
    // at the top of the loop and the ReadFile call.
    tab.reader_stop.store(true, .release);
    _ = win32.CancelIoEx(tab.child_process.read, null);
    _ = win32.SetEvent(tab.pty_ring.wake_event);
    tab.child_process.closePty();

    // Direct join: the reader no longer SendMessages to the UI thread, so
    // there is no in-flight cross-thread call to drain via PeekMessage.
    tab.child_process.thread.join();

    global.renderer.releaseKittyImagesForTab(tab.id);

    win32.closeHandle(tab.child_process.read);
    win32.closeHandle(tab.child_process.job);
    win32.closeHandle(tab.child_process.process_handle);

    tab.session.deinit();
    // Ring deinit AFTER thread.join — reader holds &tab.pty_ring until exit.
    tab.pty_ring.deinit(global.gpa.allocator());
    global.gpa.allocator().destroy(tab);
}

pub fn splitActive(window: *Window, axis: state.SplitLayout.Axis) void {
    if (!native.supported()) {
        _ = win32.MessageBoxW(window.hwnd, win32.L("Native split panes currently require D3D11. The selected renderer has not been changed."), win32.L("Mostty split panes"), .{ .ICONASTERISK = 1 });
        return;
    }
    if (window.tabs.items.len == 0 or window.panes.items.len >= types.MAX_PANES) return;
    native.reflow(window);
    const tab = window.activeTab();
    const previous = tab.layout.active.?;
    if (!tab.layout.canSplit(previous, axis)) {
        std.log.warn("pane {} is too small to split", .{previous});
        return;
    }
    const id = allocatePaneId(window) orelse return;
    const launcher: ?*const Config.Launcher = if (global.config.launchers.len > 0) &global.config.launchers[0] else null;
    const pane = createPane(window, tab, id, launcher) orelse return;
    tab.layout.split(previous, id, axis) catch |err| {
        releasePane(window, pane);
        std.log.warn("cannot split pane {}: {s}", .{ previous, @errorName(err) });
        return;
    };
    native.reflow(window);
    window.onActiveChanged();
    native.focusActive(window);
}

pub fn closeActivePane(window: *Window) void {
    if (window.tabs.items.len == 0) return;
    const id = window.active().id;
    if (window.confirming_close) return;
    window.confirming_close = true;
    defer window.confirming_close = false;
    if (!confirmYesNo(window.hwnd, win32.L("Close this pane?"), win32.L("Mostty"))) return;
    const pane = window.findById(id) orelse return;
    pane.closing = true;
    _ = win32.PostMessageW(window.hwnd, types.WM_APP_CLOSE_PANE, id, 0);
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

test "long output with 10 KB scrollback evicts earliest line" {
    // 10_000 bytes is the libghostty-vt built-in default and reproduces
    // MOSTTY-16's pre-fix behavior: PageList clamps it up to min_max_size
    // (~2 std_capacity pages, or ~430 rows for a 215-col terminal); 500
    // lines forces a third page → prune first page → "line 0000" evicted.
    // This asserts the shared session's positive scrollback test can fail if
    // its max_scrollback gets accidentally zeroed or minimized.
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{
        .cols = 215,
        .rows = 2,
        .max_scrollback_bytes = 10_000,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line {d:0>4}\r\n", .{i});
        stream.nextSlice(line);
    }

    term.screens.active.scroll(.{ .top = {} });
    const dump = try term.plainString(alloc);
    defer alloc.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "line 0000") == null);
}

test "upstream stream prints over a wide head without crashing" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 5, .rows = 2 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    try term.print(0x4E2D);
    term.setCursorPos(1, 1);
    stream.nextSlice("x");

    const str = try term.plainString(alloc);
    defer alloc.free(str);
    try std.testing.expectEqualStrings("x", str);
}

test "upstream stream prints over a wide spacer tail without crashing" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 5, .rows = 2 });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    try term.print(0x4E2D);
    term.setCursorPos(1, 2);
    stream.nextSlice("x");

    const str = try term.plainString(alloc);
    defer alloc.free(str);
    try std.testing.expectEqualStrings(" x", str);
}

test "upstream stream handles Kitty graphics APC and emits ACK" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.width_px = 100;
    term.height_px = 100;

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *vt.TerminalStream.Handler, data: [:0]const u8) void {
            if (written) |old| std.testing.allocator.free(old);
            written = std.testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| alloc.free(old);

    var handler = term.vtHandler();
    handler.effects.write_pty = S.writePty;
    var stream = vt.TerminalStream.init(.{ .allocator = alloc, .handler = handler });
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");

    try std.testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", S.written.?);
    const image = term.screens.active.kitty_images.imageById(1).?;
    try std.testing.expectEqual(.rgb, image.format);
}

test "upstream stream creates Kitty transmit-and-display placement" {
    const alloc = std.testing.allocator;
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.width_px = 100;
    term.height_px = 100;

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *vt.TerminalStream.Handler, data: [:0]const u8) void {
            if (written) |old| std.testing.allocator.free(old);
            written = std.testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| alloc.free(old);

    var handler = term.vtHandler();
    handler.effects.write_pty = S.writePty;
    var stream = vt.TerminalStream.init(.{ .allocator = alloc, .handler = handler });
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=41001,s=1,v=1,c=2,r=1;/wAA\x1b\\");

    try std.testing.expectEqualStrings("\x1b_Gi=41001;OK\x1b\\", S.written.?);
    const storage = &term.screens.active.kitty_images;
    const image = storage.imageById(41001).?;
    try std.testing.expectEqual(.rgb, image.format);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    var it = storage.placements.iterator();
    const placement = it.next().?.value_ptr;
    try std.testing.expectEqual(@as(u32, 2), placement.columns);
    try std.testing.expectEqual(@as(u32, 1), placement.rows);
    try std.testing.expect(placement.location == .pin);
}
