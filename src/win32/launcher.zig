const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../Config.zig");
const global_mod = @import("global.zig");
const state = @import("state.zig");
const tab_mgmt = @import("tab_mgmt.zig");
const util = @import("util.zig");

const Window = state.Window;
const global = global_mod.global;

pub const SshHost = struct {
    name: []const u8,
};

// Parses ~/.ssh/config and returns concrete host aliases. Wildcards (`*`,
// `?`) and negations (`!`) are skipped — they're patterns, not connectable
// targets. Include directives are not followed; keep it to the top-level
// file to avoid recursive globbing.
fn loadSshHosts(arena: std.mem.Allocator) []const SshHost {
    return loadSshHostsErr(arena) catch |err| {
        std.log.debug("ssh config: load failed: {s}", .{@errorName(err)});
        return &.{};
    };
}

fn loadSshHostsErr(arena: std.mem.Allocator) ![]const SshHost {
    const home = std.process.getEnvVarOwned(arena, "USERPROFILE") catch return &.{};
    const path = try std.fs.path.join(arena, &.{ home, ".ssh", "config" });
    const raw = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const bytes = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;

    var hosts: std.ArrayListUnmanaged(SshHost) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len < 5) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..4], "Host")) continue;
        // Require whitespace after "Host" so "HostName" doesn't match.
        if (line[4] != ' ' and line[4] != '\t') continue;
        const rest = std.mem.trim(u8, line[4..], " \t");
        var nit = std.mem.tokenizeAny(u8, rest, " \t");
        while (nit.next()) |name| {
            if (name[0] == '#') break; // trailing comment
            if (std.mem.indexOfAny(u8, name, "*?!\"") != null) continue;
            if (!std.unicode.utf8ValidateSlice(name)) continue;
            try hosts.append(arena, .{ .name = try arena.dupe(u8, name) });
        }
    }
    return hosts.toOwnedSlice(arena);
}

pub fn showLauncherMenu(window: *Window, client_x: i32, client_y: i32) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const launchers = global.config.launchers;
    const ssh_hosts = loadSshHosts(a);
    if (launchers.len == 0 and ssh_hosts.len == 0) return;

    const menu = win32.CreatePopupMenu() orelse {
        std.log.err("CreatePopupMenu failed, error={f}", .{win32.GetLastError()});
        return;
    };
    defer _ = win32.DestroyMenu(menu);

    for (launchers, 0..) |L, i| {
        const label_u16 = util.utf16ZAllocConst(a, L.label) catch |e| util.oom(e);
        const id: usize = i + 1; // 0 reserved for "cancelled"
        if (0 == win32.AppendMenuW(menu, win32.MF_STRING, id, label_u16)) {
            std.log.err("AppendMenuW failed, error={f}", .{win32.GetLastError()});
            return;
        }
    }

    if (launchers.len > 0 and ssh_hosts.len > 0) {
        _ = win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null);
    }

    for (ssh_hosts, 0..) |h, i| {
        const label = std.fmt.allocPrint(a, "[SSH: {s}]", .{h.name}) catch |e| util.oom(e);
        const label_u16 = util.utf16ZAllocConst(a, label) catch |e| util.oom(e);
        const id: usize = launchers.len + i + 1;
        if (0 == win32.AppendMenuW(menu, win32.MF_STRING, id, label_u16)) {
            std.log.err("AppendMenuW failed, error={f}", .{win32.GetLastError()});
            return;
        }
    }

    var pt: win32.POINT = .{ .x = client_x, .y = client_y };
    _ = win32.ClientToScreen(window.hwnd, &pt);

    // MSDN-recommended quirk: ensure foreground so the menu dismisses
    // correctly when the user clicks outside it.
    _ = win32.SetForegroundWindow(window.hwnd);

    const flags = win32.TRACK_POPUP_MENU_FLAGS{
        .RETURNCMD = 1,
        .RIGHTBUTTON = 1,
    };
    const selected = win32.TrackPopupMenu(menu, flags, pt.x, pt.y, 0, window.hwnd, null);
    if (selected <= 0) return;
    const idx: usize = @intCast(selected - 1);
    if (idx < launchers.len) {
        tab_mgmt.newTabWithLauncher(window, &launchers[idx]);
        return;
    }
    const ssh_idx = idx - launchers.len;
    if (ssh_idx >= ssh_hosts.len) return;
    // `--` so hostnames starting with `-` can't be reinterpreted as ssh options
    // (e.g. `-oProxyCommand=...`).
    const cmd = std.fmt.allocPrint(
        a,
        "ssh -- {s}",
        .{ssh_hosts[ssh_idx].name},
    ) catch |e| util.oom(e);
    const launcher: Config.Launcher = .{
        .label = ssh_hosts[ssh_idx].name,
        .command_line = cmd,
        .working_directory = "",
    };
    tab_mgmt.newTabWithLauncher(window, &launcher);
}
