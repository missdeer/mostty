//! Synchronous local JSON control over WM_COPYDATA. VT and model access stay on the UI thread.
const std = @import("std");
const win32 = @import("win32").everything;
const state = @import("state.zig");
const global = @import("global.zig").global;
const tabs = @import("tab_mgmt.zig");
const native = @import("pane_native.zig");
const integration = @import("shell_integration.zig");
const Config = @import("../config.zig");
const util = @import("util.zig");

const request_tag = 0x4d545931;
const response_tag = 0x4d545932;
const limit = 64 * 1024;
var busy = false;
var instance: u64 = 0;

const Request = struct {
    action: enum { list, get, new_tab, focus, split, input, close },
    id: ?[]const u8 = null,
    direction: enum { right, down } = .right,
    text: []const u8 = "",
    directory: []const u8 = "",
    command: ?[]const u8 = null,
};
const Detail = struct {
    id: []const u8,
    title: []const u8,
    directory: ?[]const u8,
    at_prompt: bool,
    active: bool,
};
const Response = struct {
    ok: bool = true,
    @"error": ?[]const u8 = null,
    terminal: ?Detail = null,
    terminals: []const Detail = &.{},
};

fn detail(a: std.mem.Allocator, window: *state.Window, pane: *state.Pane) !Detail {
    return .{
        .id = try std.fmt.allocPrint(a, "{d}:{d}:{d}", .{ win32.GetCurrentProcessId(), instance, pane.id }),
        .title = pane.title_buf[0..pane.title_len],
        .directory = if (pane.term.getPwd()) |pwd| try integration.localDirectory(a, pwd) else null,
        .at_prompt = pane.term.cursorIsAtPrompt(),
        .active = window.tabs.items.len > 0 and window.active() == pane,
    };
}

fn resolve(window: *state.Window, id: ?[]const u8) !*state.Pane {
    if (id) |value| {
        var parts = std.mem.splitScalar(u8, value, ':');
        const pid = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTerminal, 10) catch return error.InvalidTerminal;
        const token = std.fmt.parseInt(u64, parts.next() orelse return error.InvalidTerminal, 10) catch return error.InvalidTerminal;
        const pane_id = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidTerminal, 10) catch return error.InvalidTerminal;
        if (parts.next() != null or pid != win32.GetCurrentProcessId() or token != instance) return error.InvalidTerminal;
        const pane = window.findById(pane_id) orelse return error.InvalidTerminal;
        if (pane.closing or pane.tab.closing) return error.InvalidTerminal;
        return pane;
    }
    if (window.tabs.items.len == 0) return error.InvalidTerminal;
    const pane = window.active();
    if (pane.closing or pane.tab.closing) return error.InvalidTerminal;
    return pane;
}

fn execute(a: std.mem.Allocator, window: *state.Window, request: Request) !Response {
    if (request.action == .list) {
        var list: std.ArrayList(Detail) = .empty;
        for (window.panes.items) |pane| {
            if (!pane.closing and !pane.tab.closing) try list.append(a, try detail(a, window, pane));
        }
        return .{ .terminals = try list.toOwnedSlice(a) };
    }
    if (request.action == .new_tab) {
        if (std.mem.indexOfScalar(u8, request.directory, 0) != null) return error.InvalidDirectory;
        if (request.directory.len > 0) {
            if (!std.fs.path.isAbsolute(request.directory)) return error.InvalidDirectory;
            const wide = try util.utf16ZAllocConst(a, request.directory);
            const attrs = win32.GetFileAttributesW(wide);
            if (attrs == win32.INVALID_FILE_ATTRIBUTES or attrs & 0x10 == 0) return error.InvalidDirectory;
        }
        if (request.command) |command| {
            if (command.len == 0 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
        }
        const configured = if (global.config.launchers.len > 0) global.config.launchers[0] else Config.Launcher{
            .label = "",
            .command_line = "C:\\Windows\\System32\\cmd.exe",
            .working_directory = "",
        };
        const launcher: Config.Launcher = .{
            .label = "automation",
            .command_line = request.command orelse configured.command_line,
            .working_directory = if (request.directory.len > 0) request.directory else configured.working_directory,
        };
        const pane = tabs.openTab(window, &launcher) orelse return error.LaunchFailed;
        return .{ .terminal = try detail(a, window, pane) };
    }
    var pane = try resolve(window, request.id);
    switch (request.action) {
        .get => {},
        .focus, .split => {
            const idx = window.findTabIndexById(pane.tab.id) orelse return error.InvalidTerminal;
            tabs.switchToTab(window, idx);
            if (!pane.tab.layout.focus(pane.id)) return error.InvalidTerminal;
            native.reflow(window);
            window.onActiveChanged();
            native.focusActive(window);
            _ = win32.SetForegroundWindow(window.hwnd);
            if (request.action == .split) pane = tabs.splitActiveResult(window, if (request.direction == .down) .rows else .columns) orelse return error.SplitFailed;
        },
        .input => {
            const pty = pane.child_process.pty orelse return error.TerminalClosed;
            try pty.writeFlushAll(request.text);
        },
        .close => {
            // The confirmation dialog pumps messages; do not retain pane pointers across it.
            if (!tabs.closePane(window, pane.id)) return error.CloseCancelled;
            return .{};
        },
        else => unreachable,
    }
    return .{ .terminal = try detail(a, window, pane) };
}

pub fn onCopyData(hwnd: win32.HWND, wp: win32.WPARAM, lp: win32.LPARAM) ?win32.LRESULT {
    if (wp == 0 or lp == 0) return 0;
    const data: *const win32.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
    if (data.dwData != request_tag or data.cbData == 0 or data.cbData > limit or data.lpData == null) return 0;
    const window = if (global.window) |*w| w else return 0;
    if (instance == 0) instance = win32.GetTickCount64();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes: [*]const u8 = @ptrCast(data.lpData.?);
    const response: Response = blk: {
        if (busy or window.confirming_close) break :blk .{ .ok = false, .@"error" = "TerminalBusy" };
        busy = true;
        defer busy = false;
        const parsed = std.json.parseFromSlice(Request, a, bytes[0..data.cbData], .{ .allocate = .alloc_always }) catch
            break :blk .{ .ok = false, .@"error" = "InvalidRequest" };
        break :blk execute(a, window, parsed.value) catch |err| .{ .ok = false, .@"error" = @errorName(err) };
    };
    const encoded = std.json.Stringify.valueAlloc(a, response, .{}) catch return 0;
    const result = if (encoded.len <= limit) encoded else "{\"ok\":false,\"error\":\"ResponseTooLarge\"}";
    var reply: win32.COPYDATASTRUCT = .{ .dwData = response_tag, .cbData = @intCast(result.len), .lpData = @constCast(result.ptr) };
    const sender: win32.HWND = @ptrFromInt(wp);
    var ignored: usize = 0;
    _ = win32.SendMessageTimeoutW(sender, win32.WM_COPYDATA, @intFromPtr(hwnd), @intCast(@intFromPtr(&reply)), .{ .ABORTIFHUNG = 1 }, 5000, &ignored);
    return 1;
}

var client_target: ?win32.HWND = null;
var client_response: [limit]u8 = undefined;
var client_len: usize = 0;

fn clientProc(hwnd: win32.HWND, msg: u32, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_COPYDATA and lp != 0 and client_target != null and wp == @intFromPtr(client_target.?)) {
        const data: *const win32.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (data.dwData == response_tag and data.cbData <= limit and data.lpData != null) {
            const bytes: [*]const u8 = @ptrCast(data.lpData.?);
            @memcpy(client_response[0..data.cbData], bytes[0..data.cbData]);
            client_len = data.cbData;
            return 1;
        }
    }
    return win32.DefWindowProcW(hwnd, msg, wp, lp);
}

pub fn runClient(a: std.mem.Allocator, pid: ?u32) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    const request = try reader.interface.allocRemaining(a, .limited(limit));
    defer a.free(request);
    if (request.len == 0) return error.InvalidRequest;
    var after: ?win32.HWND = null;
    while (win32.FindWindowExW(null, after, win32.L("MosttyWindow"), null)) |hwnd| {
        after = hwnd;
        var owner: u32 = 0;
        _ = win32.GetWindowThreadProcessId(hwnd, &owner);
        if (pid == null or pid.? == owner) {
            if (client_target != null) return error.MultipleWindowsSpecifyTargetProcess;
            client_target = hwnd;
        }
    }
    const target = client_target orelse return error.TerminalWindowNotFound;
    const module = win32.GetModuleHandleW(null);
    var cls: win32.WNDCLASSEXW = std.mem.zeroes(win32.WNDCLASSEXW);
    cls.cbSize = @sizeOf(win32.WNDCLASSEXW);
    cls.lpfnWndProc = clientProc;
    cls.hInstance = module;
    cls.lpszClassName = win32.L("MosttyControlReply");
    if (win32.RegisterClassExW(&cls) == 0) return error.RegisterWindowFailed;
    defer _ = win32.UnregisterClassW(cls.lpszClassName, module);
    const receiver = win32.CreateWindowExW(.{}, cls.lpszClassName, win32.L(""), .{}, 0, 0, 0, 0, win32.HWND_MESSAGE, null, module, null) orelse return error.CreateWindowFailed;
    defer _ = win32.DestroyWindow(receiver);
    var data: win32.COPYDATASTRUCT = .{ .dwData = request_tag, .cbData = @intCast(request.len), .lpData = request.ptr };
    var accepted: usize = 0;
    // The default flags allow the synchronous reply to reach clientProc while waiting.
    if (win32.SendMessageTimeoutW(target, win32.WM_COPYDATA, @intFromPtr(receiver), @intCast(@intFromPtr(&data)), .{}, 120000, &accepted) == 0 or accepted == 0 or client_len == 0) return error.ControlRequestFailed;
    try std.Io.File.stdout().writeStreamingAll(io, client_response[0..client_len]);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, client_response[0..client_len], .{});
    defer parsed.deinit();
    const ok = parsed.value.object.get("ok") orelse return error.InvalidResponse;
    if (ok != .bool or !ok.bool) std.process.exit(1);
}
