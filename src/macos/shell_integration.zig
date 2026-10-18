//! Shell startup arguments and environment, prepared before fork.
const std = @import("std");
const Config = @import("../config.zig");

pub const Launch = struct {
    argv: [:null]?[*:0]const u8,
    env: []const Config.EnvEntry,
};

pub fn prepare(a: std.mem.Allocator, shell: [:0]const u8, command: ?[:0]const u8, overrides: []const Config.EnvEntry, resources: ?[]const u8) !Launch {
    var env: std.ArrayList(Config.EnvEntry) = .empty;
    try env.appendSlice(a, overrides);
    try env.append(a, .{ .name = "TERM_PROGRAM", .value = overrideValue(overrides, "TERM_PROGRAM") orelse "Mostty" });
    // A Mostty launched from another terminal must not inherit its parent's
    // integration when this session is noninteractive or injection is disabled.
    try env.append(a, .{ .name = "MOSTTY_RESOURCES_DIR", .value = "" });
    try env.append(a, .{ .name = "MOSTTY_SHELL_FEATURES", .value = "" });
    var args: std.ArrayList(?[*:0]const u8) = .empty;
    try args.append(a, shell.ptr);
    if (command) |text| {
        try args.appendSlice(a, &.{ "-lc", text.ptr });
    } else {
        const name = std.fs.path.basename(shell);
        if (resources) |dir| {
            try env.append(a, .{ .name = "MOSTTY_RESOURCES_DIR", .value = dir });
            try env.append(a, .{ .name = "MOSTTY_SHELL_FEATURES", .value = "title,cursor,path" });
            try env.append(a, .{ .name = "MOSTTY_BIN_DIR", .value = try std.process.executableDirPathAlloc(std.Io.Threaded.global_single_threaded.io(), a) });
            const integration_dir = try std.fs.path.join(a, &.{ dir, "shell-integration" });
            const data_dirs = try std.fmt.allocPrint(a, "{s}:{s}/..:{s}", .{
                integration_dir, dir, lookup(overrides, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share",
            });
            try env.append(a, .{ .name = "XDG_DATA_DIRS", .value = data_dirs });
            try env.append(a, .{ .name = "MOSTTY_SHELL_INTEGRATION_XDG_DIR", .value = integration_dir });
            if (std.mem.eql(u8, name, "zsh")) {
                if (lookup(overrides, "ZDOTDIR")) |old| try env.append(a, .{ .name = "MOSTTY_ZSH_ZDOTDIR", .value = old });
                try env.append(a, .{ .name = "ZDOTDIR", .value = try std.fs.path.join(a, &.{ dir, "shell-integration", "zsh" }) });
            } else if (std.mem.eql(u8, name, "bash") and !std.mem.eql(u8, shell, "/bin/bash")) {
                // Apple's Bash 3.2 ignores ENV during this startup mode. Keep
                // its regular login startup; users can source the same hooks
                // manually, as they do in Ghostty.
                if (lookup(overrides, "ENV")) |old| try env.append(a, .{ .name = "MOSTTY_BASH_ENV", .value = old });
                try env.append(a, .{ .name = "ENV", .value = try std.fs.path.join(a, &.{ dir, "shell-integration", "bash", "mostty.bash" }) });
                try env.append(a, .{ .name = "MOSTTY_BASH_INJECT", .value = "1" });
                if (lookup(overrides, "HISTFILE") == null) {
                    if (lookup(overrides, "HOME")) |user_home| {
                        try env.append(a, .{ .name = "HISTFILE", .value = try std.fs.path.join(a, &.{ user_home, ".bash_history" }) });
                        try env.append(a, .{ .name = "MOSTTY_BASH_UNEXPORT_HISTFILE", .value = "1" });
                    }
                }
                try args.append(a, "--posix");
            } else if (std.mem.eql(u8, name, "fish")) {
                // Use an environment variable in shell code: paths containing
                // quotes or spaces must never become executable syntax.
                try args.appendSlice(a, &.{ "--init-command", "source \"$MOSTTY_RESOURCES_DIR/shell-integration/fish/vendor_conf.d/mostty-shell-integration.fish\"" });
            }
        }
        if (!std.mem.eql(u8, name, "elvish")) try args.append(a, "-l");
    }
    return .{ .argv = try args.toOwnedSliceSentinel(a, null), .env = try env.toOwnedSlice(a) };
}

fn overrideValue(overrides: []const Config.EnvEntry, key: []const u8) ?[]const u8 {
    var index = overrides.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, overrides[index].name, key)) return overrides[index].value;
    }
    return null;
}

fn lookup(overrides: []const Config.EnvEntry, key: [:0]const u8) ?[]const u8 {
    return overrideValue(overrides, key) orelse if (std.c.getenv(key)) |value| std.mem.span(value) else null;
}

pub fn bundledResources(a: std.mem.Allocator, io: std.Io) !?[]const u8 {
    if (std.c.getenv("MOSTTY_RESOURCES_DIR")) |value| {
        if (value[0] != 0) return try a.dupe(u8, std.mem.span(value));
    }
    const exe_dir = try std.process.executableDirPathAlloc(io, a);
    const contents = std.fs.path.dirname(exe_dir) orelse return null;
    const dir = try std.fs.path.join(a, &.{ contents, "Resources", "mostty" });
    const probe = try std.fs.path.join(a, &.{ dir, "shell-integration", "zsh", ".zshenv" });
    std.Io.Dir.cwd().access(io, probe, .{}) catch return null;
    return dir;
}

test "integration preserves startup overrides and never injects into commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const overrides = [_]Config.EnvEntry{
        .{ .name = "ZDOTDIR", .value = "/custom config" },
        .{ .name = "TERM_PROGRAM", .value = "configured-program" },
    };
    const launch = try prepare(a, "/bin/zsh", null, &overrides, "/bundle with spaces/mostty");
    try std.testing.expectEqualStrings("-l", std.mem.span(launch.argv[1].?));
    try std.testing.expectEqualStrings("/custom config", lookup(launch.env, "MOSTTY_ZSH_ZDOTDIR").?);
    try std.testing.expectEqualStrings("configured-program", lookup(launch.env, "TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("/bundle with spaces/mostty/shell-integration/zsh", lookup(launch.env, "ZDOTDIR").?);
    try std.testing.expectEqualStrings("/bundle with spaces/mostty/shell-integration", lookup(launch.env, "MOSTTY_SHELL_INTEGRATION_XDG_DIR").?);
    const trailing = try prepare(a, "/bin/zsh", null, &.{}, "/bundle/mostty/");
    const prefix = try std.fmt.allocPrint(a, "{s}:", .{lookup(trailing.env, "MOSTTY_SHELL_INTEGRATION_XDG_DIR").?});
    try std.testing.expect(std.mem.startsWith(u8, lookup(trailing.env, "XDG_DATA_DIRS").?, prefix));
    const noninteractive = try prepare(a, "/bin/bash", "echo ok", &.{}, "/bundle/mostty");
    try std.testing.expectEqualStrings("-lc", std.mem.span(noninteractive.argv[1].?));
    for (noninteractive.env) |entry| try std.testing.expect(!std.mem.eql(u8, entry.name, "ENV"));
    try std.testing.expectEqualStrings("", lookup(noninteractive.env, "MOSTTY_RESOURCES_DIR").?);
}

test "modern Bash retains its history defaults and explicit HISTFILE overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resources = "/bundle/mostty";
    const launch = try prepare(a, "/opt/homebrew/bin/bash", null, &.{}, resources);
    if (std.c.getenv("HISTFILE")) |inherited| {
        try std.testing.expectEqualStrings(std.mem.span(inherited), lookup(launch.env, "HISTFILE").?);
    } else {
        const user_home = std.c.getenv("HOME") orelse return error.TestHomeUnavailable;
        const expected = try std.fs.path.join(a, &.{ std.mem.span(user_home), ".bash_history" });
        try std.testing.expectEqualStrings(expected, lookup(launch.env, "HISTFILE").?);
        try std.testing.expectEqualStrings("1", lookup(launch.env, "MOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }
    const disabled = try prepare(a, "/opt/homebrew/bin/bash", null, &.{.{ .name = "HISTFILE", .value = "" }}, resources);
    try std.testing.expectEqualStrings("", lookup(disabled.env, "HISTFILE").?);
    const elvish = try prepare(a, "/opt/homebrew/bin/elvish", null, &.{}, resources);
    // Elvish must keep its own RC loader and REPL namespace.
    try std.testing.expectEqual(@as(usize, 1), elvish.argv.len);
}
