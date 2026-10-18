//! Windows shell startup preparation. All returned storage belongs to the caller's arena.
const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../config.zig");
const util = @import("util.zig");

pub const Launch = struct {
    command: []const u8,
    env: []const Config.EnvEntry,
};

fn lookup(a: std.mem.Allocator, env: []const Config.EnvEntry, name: []const u8) !?[]const u8 {
    var i = env.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(env[i].name, name)) return env[i].value;
    }
    const environ: std.process.Environ = .{ .block = .global };
    return environ.getAlloc(a, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

fn resources(a: std.mem.Allocator, env: []const Config.EnvEntry) !?[]const u8 {
    if (try lookup(a, env, "MOSTTY_RESOURCES_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    const exe = std.process.executableDirPathAlloc(io, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    for ([_][]const u8{ exe, std.fs.path.dirname(exe) orelse exe }) |base| {
        const dir = try std.fs.path.join(a, &.{ base, "share", "mostty" });
        const probe = try std.fs.path.join(a, &.{ dir, "shell-integration", "powershell", "mostty.ps1" });
        std.Io.Dir.cwd().access(io, probe, .{}) catch continue;
        return dir;
    }
    return null;
}

// Quote one argument using the Windows CRT rules, including trailing backslashes.
fn quote(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            slashes += 1;
            continue;
        }
        try out.appendNTimes(a, '\\', slashes * (if (ch == '"') @as(usize, 2) else 1));
        if (ch == '"') try out.append(a, '\\');
        try out.append(a, ch);
        slashes = 0;
    }
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

pub fn prepare(a: std.mem.Allocator, command: []const u8, overrides: []const Config.EnvEntry, enabled: bool) !Launch {
    var env: std.ArrayList(Config.EnvEntry) = .empty;
    var term_program: []const u8 = "Mostty";
    for (overrides) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "TERM_PROGRAM")) term_program = entry.value;
    }
    try env.appendSlice(a, overrides);
    try env.appendSlice(a, &.{
        .{ .name = "TERM_PROGRAM", .value = term_program },
        .{ .name = "MOSTTY_RESOURCES_DIR", .value = "" },
        .{ .name = "MOSTTY_SHELL_FEATURES", .value = "" },
        .{ .name = "MOSTTY_CMD_INTEGRATED", .value = "" },
    });
    const unchanged: Launch = .{ .command = command, .env = env.items };
    if (!enabled) return unchanged;
    const dir = (try resources(a, overrides)) orelse return unchanged;
    const wide = try util.utf16ZAlloc(a, command);
    var args = try std.process.Args.Iterator.Windows.init(a, wide);
    defer args.deinit();
    const exe = args.next() orelse return unchanged;
    const name = std.fs.path.basename(exe);
    const powershell = std.ascii.eqlIgnoreCase(name, "pwsh.exe") or std.ascii.eqlIgnoreCase(name, "pwsh") or
        std.ascii.eqlIgnoreCase(name, "powershell.exe") or std.ascii.eqlIgnoreCase(name, "powershell");
    const cmd = std.ascii.eqlIgnoreCase(name, "cmd.exe") or std.ascii.eqlIgnoreCase(name, "cmd");
    const bash = std.ascii.eqlIgnoreCase(name, "bash.exe") or std.ascii.eqlIgnoreCase(name, "bash");
    if (!powershell and !cmd and !bash) return unchanged;
    var line: std.ArrayList(u8) = .empty;
    var no_exit = false;
    try line.appendSlice(a, try quote(a, exe));
    // Bash requires long options before short options such as the user's -l/-i.
    if (bash) try line.appendSlice(a, " --posix");
    var bash_flags: std.ArrayList(u8) = .empty;
    while (args.next()) |arg| {
        // An allowlist keeps commands, scripts, encoded commands, and wrappers untouched.
        const allowed = if (powershell)
            eqlAny(arg, &.{ "-NoLogo", "-NoExit", "-NoProfile", "-STA", "-MTA", "-Login" })
        else if (cmd)
            eqlAny(arg, &.{ "/D", "/Q", "/A", "/U", "/E:ON", "/E:OFF", "/F:ON", "/F:OFF", "/V:ON", "/V:OFF" })
        else
            eqlAny(arg, &.{ "-l", "--login", "-i", "--noprofile", "--norc" });
        if (!allowed) return unchanged;
        if (std.ascii.eqlIgnoreCase(arg, "-NoExit")) no_exit = true;
        try line.append(a, ' ');
        try line.appendSlice(a, try quote(a, arg));
        try bash_flags.append(a, ' ');
        try bash_flags.appendSlice(a, arg);
    }
    const bin = std.process.executableDirPathAlloc(std.Io.Threaded.global_single_threaded.io(), a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unchanged,
    };
    try env.appendSlice(a, &.{
        .{ .name = "MOSTTY_RESOURCES_DIR", .value = dir },
        .{ .name = "MOSTTY_SHELL_FEATURES", .value = "title,cursor,path" },
        .{ .name = "MOSTTY_BIN_DIR", .value = bin },
    });
    if (powershell) {
        if (!no_exit) try line.appendSlice(a, " -NoExit");
        try line.appendSlice(a, " -Command \". ($env:MOSTTY_RESOURCES_DIR + '/shell-integration/powershell/mostty.ps1')\"");
    } else if (cmd) {
        try line.appendSlice(a, " /K \"\"%MOSTTY_RESOURCES_DIR%\\shell-integration\\cmd\\mostty.cmd\"\"");
    } else {
        const normalized = try a.dupe(u8, dir);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        const normalized_bin = try a.dupe(u8, bin);
        std.mem.replaceScalar(u8, normalized_bin, '\\', '/');
        const bash_bin = if (normalized_bin.len >= 3 and normalized_bin[1] == ':')
            try std.fmt.allocPrint(a, "/{c}{s}", .{ std.ascii.toLower(normalized_bin[0]), normalized_bin[2..] })
        else
            normalized_bin;
        try env.appendSlice(a, &.{
            .{ .name = "MOSTTY_RESOURCES_DIR", .value = normalized },
            .{ .name = "MOSTTY_BIN_DIR", .value = bash_bin },
            .{ .name = "ENV", .value = try std.fmt.allocPrint(a, "{s}/shell-integration/bash/mostty.bash", .{normalized}) },
            .{ .name = "MOSTTY_BASH_INJECT", .value = if (bash_flags.items.len > 0) bash_flags.items else "1" },
        });
        if (try lookup(a, overrides, "ENV")) |old| try env.append(a, .{ .name = "MOSTTY_BASH_ENV", .value = old });
        if (try lookup(a, overrides, "HISTFILE") == null) {
            if ((try lookup(a, overrides, "HOME")) orelse (try lookup(a, overrides, "USERPROFILE"))) |user_home| {
                const home_path = try a.dupe(u8, user_home);
                std.mem.replaceScalar(u8, home_path, '\\', '/');
                try env.appendSlice(a, &.{
                    .{ .name = "HISTFILE", .value = try std.fmt.allocPrint(a, "{s}/.bash_history", .{home_path}) },
                    .{ .name = "MOSTTY_BASH_UNEXPORT_HISTFILE", .value = "1" },
                });
            }
        }
        try line.appendSlice(a, " -i");
    }
    return .{ .command = try line.toOwnedSlice(a), .env = try env.toOwnedSlice(a) };
}

fn eqlAny(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(value, choice)) return true;
    return false;
}

/// Accept only this machine's drive paths. POSIX/MSYS drive reports are translated;
/// remote hosts, UNC paths, WSL paths and malformed escapes cannot become local CWDs.
pub fn localDirectory(a: std.mem.Allocator, report: []const u8) !?[]const u8 {
    const raw = std.mem.startsWith(u8, report, "kitty-shell-cwd://");
    const prefix: []const u8 = if (raw) "kitty-shell-cwd://" else "file://";
    if (!std.mem.startsWith(u8, report, prefix)) return null;
    const rest = report[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (host.len > 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) {
        var matched = false;
        // Git Bash reports the DNS hostname, which can exceed NetBIOS's 15 characters.
        for ([_]win32.COMPUTER_NAME_FORMAT{ .NetBIOS, .DnsHostname, .DnsFullyQualified }) |format| {
            var name: [256:0]u16 = undefined;
            var len: u32 = name.len;
            if (win32.GetComputerNameExW(format, &name, &len) == 0) continue;
            const local = std.unicode.utf16LeToUtf8Alloc(a, name[0..len]) catch continue;
            if (std.ascii.eqlIgnoreCase(host, local)) {
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
    var decoded: std.ArrayList(u8) = .empty;
    var i = slash;
    while (i < rest.len) : (i += 1) {
        var ch = rest[i];
        if (!raw and ch == '%') {
            if (i + 2 >= rest.len) return null;
            ch = std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16) catch return null;
            i += 2;
        }
        if (ch < 0x20 or ch == 0x7f) return null;
        try decoded.append(a, ch);
    }
    var path = decoded.items;
    if (path.len == 2 and path[0] == '/' and std.ascii.isAlphabetic(path[1])) {
        path = try std.fmt.allocPrint(a, "{c}:/", .{std.ascii.toUpper(path[1])});
    }
    if (path.len >= 4 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') path = path[1..];
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == '/') {
        path[0] = std.ascii.toUpper(path[1]);
        path[1] = ':';
    }
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '/' and path[2] != '\\')) return null;
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    const wide = try util.utf16ZAllocConst(a, path);
    const attrs = win32.GetFileAttributesW(wide);
    if (attrs == win32.INVALID_FILE_ATTRIBUTES or attrs & 0x10 == 0) return null;
    return path;
}
