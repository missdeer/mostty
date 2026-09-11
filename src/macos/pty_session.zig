const PtySession = @This();

const builtin = @import("builtin");
const std = @import("std");
const vt = @import("vt");
const Config = @import("../config.zig");
const TerminalSession = @import("../terminal/session.zig");

const c = std.c;
const posix = std.posix;

comptime {
    if (builtin.os.tag != .macos) @compileError("PtySession is macOS-only");
}

extern "c" fn forkpty(
    master: *c_int,
    name: ?[*]u8,
    termios: ?*c.termios,
    window_size: ?*posix.winsize,
) c.pid_t;

const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

pub const Exit = union(enum) {
    exited: u8,
    signaled: c.SIG,
    stopped: c.SIG,
    unknown: u32,
};

pub const Hooks = struct {
    context: *anyopaque,
    title_changed: ?*const fn (*anyopaque, *TerminalSession) void = null,
};

pub const Options = struct {
    io: std.Io,
    terminal_allocator: std.mem.Allocator,
    stream_allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell: ?[:0]const u8 = null,
    command: ?[:0]const u8 = null,
    // Directory the child chdir's into before exec. null keeps the inherited
    // CWD (the app-bundle process directory). The caller resolves the default
    // ($HOME) and any configured override, so this is a plain absolute path.
    working_directory: ?[:0]const u8 = null,
    // Config `env = NAME=VALUE` entries. Each one replaces the inherited
    // variable of the same name, matching the Windows ConPTY child.
    env: []const Config.EnvEntry = &.{},
    hooks: ?Hooks = null,
    images_enabled: bool = true,
    cell_width: u32 = 0,
    cell_height: u32 = 0,
};

terminal: TerminalSession,
master_fd: c.fd_t,
child_pid: ?c.pid_t,
hooks: ?Hooks,
write_failed: bool,

pub fn init(self: *PtySession, options: Options) !void {
    if (options.cols == 0 or options.rows == 0) return error.InvalidSize;
    @import("png_decoder.zig").install();

    self.* = .{
        .terminal = undefined,
        .master_fd = -1,
        .child_pid = null,
        .hooks = options.hooks,
        .write_failed = false,
    };
    try self.terminal.init(.{
        .io = options.io,
        .terminal_allocator = options.terminal_allocator,
        .stream_allocator = options.stream_allocator,
        .cols = options.cols,
        .rows = options.rows,
        .images_enabled = options.images_enabled,
        .hooks = .{
            .context = self,
            .title_changed = onTitleChanged,
            .write_pty = onWritePty,
            .size = onSize,
        },
    });
    errdefer self.terminal.deinit();
    self.terminal.syncPixelSize(options.cell_width, options.cell_height);

    const shell = options.shell orelse defaultShell();
    // The child reads these pointers after fork, so they only need to outlive
    // the exec handshake below; the arena covers both the entry array and the
    // NAME=VALUE strings built for config overrides.
    var environment_arena = std.heap.ArenaAllocator.init(options.terminal_allocator);
    defer environment_arena.deinit();
    const environment = try childEnvironment(environment_arena.allocator(), options.env);

    var exec_pipe = try createExecPipe();
    errdefer closeFd(exec_pipe[0]);
    errdefer closeFd(exec_pipe[1]);

    var window_size: posix.winsize = .{
        .row = options.rows,
        .col = options.cols,
        .xpixel = pixelDimension(options.cols, options.cell_width),
        .ypixel = pixelDimension(options.rows, options.cell_height),
    };
    var master_fd: c_int = -1;
    const pid = forkpty(&master_fd, null, null, &window_size);
    if (pid < 0) return error.ForkPtyFailed;

    if (pid == 0) {
        closeFd(exec_pipe[0]);
        execShell(shell, options.command, options.working_directory, environment.ptr, exec_pipe[1]);
    }

    closeFd(exec_pipe[1]);
    exec_pipe[1] = -1;
    const exec_failed = readExecFailure(exec_pipe[0]) catch {
        closeFd(master_fd);
        _ = waitPid(pid) catch {};
        return error.ExecHandshakeFailed;
    };
    closeFd(exec_pipe[0]);
    exec_pipe[0] = -1;

    if (exec_failed) {
        closeFd(master_fd);
        _ = waitPid(pid) catch {};
        return error.ShellExecFailed;
    }

    self.master_fd = master_fd;
    self.child_pid = pid;
}

pub fn deinit(self: *PtySession) void {
    self.closeMaster();
    if (self.child_pid) |pid| {
        posix.kill(pid, .HUP) catch {};
        posix.kill(pid, .KILL) catch {};
        _ = waitPid(pid) catch {};
        self.child_pid = null;
    }
    self.terminal.deinit();
    self.* = undefined;
}

pub fn write(self: *PtySession, bytes: []const u8) !void {
    if (self.master_fd < 0) return error.SessionClosed;
    if (self.write_failed) return error.PtyWriteFailed;

    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(self.master_fd, bytes[offset..].ptr, bytes.len - offset);
        switch (posix.errno(written)) {
            .SUCCESS => offset += @intCast(written),
            .INTR => continue,
            else => return error.PtyWriteFailed,
        }
    }
}

pub fn read(self: *PtySession, buffer: []u8) !usize {
    if (self.master_fd < 0) return error.SessionClosed;
    const count = posix.read(self.master_fd, buffer) catch |err| switch (err) {
        error.InputOutput => return 0,
        else => return err,
    };
    if (count != 0) self.terminal.feed(buffer[0..count]);
    return count;
}

pub fn resize(self: *PtySession, cols: u16, rows: u16) !void {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    if (self.master_fd < 0) return error.SessionClosed;

    const old_cols: u16 = @intCast(self.terminal.term.cols);
    const old_rows: u16 = @intCast(self.terminal.term.rows);
    const cell_width = self.terminal.term.width_px / old_cols;
    const cell_height = self.terminal.term.height_px / old_rows;
    try resizePty(self.master_fd, cols, rows, cell_width, cell_height);
    self.terminal.resize(cols, rows) catch |err| {
        resizePty(self.master_fd, old_cols, old_rows, cell_width, cell_height) catch {};
        return err;
    };
    self.terminal.syncPixelSize(cell_width, cell_height);
}

pub fn syncPixelSize(self: *PtySession, cell_width: u32, cell_height: u32) !void {
    if (self.master_fd < 0) return error.SessionClosed;
    if (cell_width == 0 or cell_height == 0) return error.InvalidSize;
    try resizePty(self.master_fd, @intCast(self.terminal.term.cols), @intCast(self.terminal.term.rows), cell_width, cell_height);
    self.terminal.syncPixelSize(cell_width, cell_height);
}

pub fn wait(self: *PtySession) !Exit {
    const pid = self.child_pid orelse return error.ChildAlreadyReaped;
    const status = try waitPid(pid);
    self.child_pid = null;
    return statusToExit(status);
}

pub fn tryWait(self: *PtySession) !?Exit {
    const pid = self.child_pid orelse return error.ChildAlreadyReaped;
    var status: c_int = undefined;
    while (true) {
        const result = c.waitpid(pid, &status, c.W.NOHANG);
        switch (posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                self.child_pid = null;
                return statusToExit(@bitCast(status));
            },
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn closeMaster(self: *PtySession) void {
    if (self.master_fd < 0) return;
    closeFd(self.master_fd);
    self.master_fd = -1;
}

fn onTitleChanged(context: *anyopaque, _: *vt.Terminal) void {
    const self: *PtySession = @ptrCast(@alignCast(context));
    const hooks = self.hooks orelse return;
    const callback = hooks.title_changed orelse return;
    callback(hooks.context, &self.terminal);
}

fn onWritePty(context: *anyopaque, bytes: [:0]const u8) void {
    const self: *PtySession = @ptrCast(@alignCast(context));
    self.write(bytes) catch {
        self.write_failed = true;
    };
}

fn onSize(_: *anyopaque, term: *vt.Terminal) TerminalSession.SizeResponse {
    return .{
        .rows = term.rows,
        .columns = term.cols,
        .cell_width = term.width_px / term.cols,
        .cell_height = term.height_px / term.rows,
    };
}

fn defaultShell() [:0]const u8 {
    const shell_ptr = c.getenv("SHELL") orelse return "/bin/zsh";
    const shell = std.mem.span(shell_ptr);
    return if (shell.len == 0) "/bin/zsh" else shell;
}

// TERM must describe what the VT actually implements, not whatever the launching
// process happened to inherit, so it is forced unless the config names it.
const default_term = "TERM=xterm-256color";

fn childEnvironment(
    allocator: std.mem.Allocator,
    overrides: []const Config.EnvEntry,
) ![:null]?[*:0]const u8 {
    var entries: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    var has_term = false;

    var index: usize = 0;
    while (c.environ[index]) |entry| : (index += 1) {
        const name = entryName(std.mem.span(entry));
        if (hasOverride(overrides, name)) continue;
        if (std.mem.eql(u8, name, "TERM")) {
            try entries.append(allocator, default_term);
            has_term = true;
            continue;
        }
        try entries.append(allocator, entry);
    }

    for (overrides, 0..) |override, position| {
        // Config keeps duplicate `env` names in declaration order, so drop all
        // but the last: emitting both would leave the winner up to the child's
        // libc, where Windows already defines it as last-one-wins.
        if (hasOverride(overrides[position + 1 ..], override.name)) continue;
        const joined = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}={s}",
            .{ override.name, override.value },
            0,
        );
        try entries.append(allocator, joined.ptr);
        if (std.mem.eql(u8, override.name, "TERM")) has_term = true;
    }

    if (!has_term) try entries.append(allocator, default_term);
    return entries.toOwnedSliceSentinel(allocator, null);
}

fn entryName(entry: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return entry;
    return entry[0..eq];
}

fn hasOverride(overrides: []const Config.EnvEntry, name: []const u8) bool {
    for (overrides) |override| {
        if (std.mem.eql(u8, override.name, name)) return true;
    }
    return false;
}

fn createExecPipe() ![2]c.fd_t {
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.PipeFailed;
    errdefer closeFd(pipe[0]);
    errdefer closeFd(pipe[1]);

    const flags = c.fcntl(pipe[1], c.F.GETFD);
    if (flags < 0) return error.PipeFailed;
    if (c.fcntl(pipe[1], c.F.SETFD, flags | c.FD_CLOEXEC) != 0) return error.PipeFailed;
    return pipe;
}

fn execShell(
    shell: [:0]const u8,
    command: ?[:0]const u8,
    working_directory: ?[:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    error_fd: c.fd_t,
) noreturn {
    // Best-effort: a missing/invalid configured directory must not stop the
    // tab from opening, so on failure we fall through to the inherited CWD.
    if (working_directory) |dir| _ = c.chdir(dir.ptr);

    const login_arg: [:0]const u8 = "-l";
    const command_arg: [:0]const u8 = "-lc";
    var login_argv = [_:null]?[*:0]const u8{ shell.ptr, login_arg.ptr };
    var command_argv = [_:null]?[*:0]const u8{ shell.ptr, command_arg.ptr, null };
    const argv: [*:null]const ?[*:0]const u8 = if (command) |value| blk: {
        command_argv[2] = value.ptr;
        break :blk &command_argv;
    } else &login_argv;

    _ = c.execve(shell.ptr, argv, environment);
    var exec_errno: c_int = @intFromEnum(posix.errno(-1));
    _ = c.write(error_fd, @ptrCast(&exec_errno), @sizeOf(c_int));
    c._exit(127);
}

fn readExecFailure(fd: c.fd_t) !bool {
    var exec_errno: c_int = 0;
    var received: usize = 0;
    while (received < @sizeOf(c_int)) {
        const bytes: [*]u8 = @ptrCast(&exec_errno);
        const count = c.read(fd, bytes + received, @sizeOf(c_int) - received);
        switch (posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return received != 0;
                received += @intCast(count);
            },
            .INTR => continue,
            else => return error.ExecHandshakeFailed,
        }
    }
    return true;
}

fn pixelDimension(cells: u16, cell_pixels: u32) u16 {
    return @intCast(@min(@as(u64, cells) * cell_pixels, std.math.maxInt(u16)));
}

fn resizePty(fd: c.fd_t, cols: u16, rows: u16, cell_width: u32, cell_height: u32) !void {
    var window_size: posix.winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = pixelDimension(cols, cell_width),
        .ypixel = pixelDimension(rows, cell_height),
    };
    if (c.ioctl(fd, TIOCSWINSZ, &window_size) != 0) return error.PtyResizeFailed;
}

fn waitPid(pid: c.pid_t) !u32 {
    var status: c_int = undefined;
    while (true) {
        const result = c.waitpid(pid, &status, 0);
        switch (posix.errno(result)) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn statusToExit(status: u32) Exit {
    if (c.W.IFEXITED(status)) return .{ .exited = c.W.EXITSTATUS(status) };
    if (c.W.IFSIGNALED(status)) return .{ .signaled = c.W.TERMSIG(status) };
    if (c.W.IFSTOPPED(status)) return .{ .stopped = c.W.STOPSIG(status) };
    return .{ .unknown = status };
}

fn closeFd(fd: c.fd_t) void {
    if (fd >= 0) _ = c.close(fd);
}

fn drainToEof(session: *PtySession) !void {
    var buffer: [4096]u8 = undefined;
    while (try session.read(&buffer) != 0) {}
}

test "macOS PTY starts a shell and exchanges data through the VT session" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "printf '\\033]0;pty-test\\007'; read line; printf 'seen:%s\\n' \"$line\"; exit 7",
    });
    defer session.deinit();

    try session.write("round-trip\n");
    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 7), exit.exited);
    try std.testing.expectEqualStrings("pty-test", session.terminal.term.getTitle().?);

    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "seen:round-trip") != null);
}

test "macOS PTY resize reaches both the child and VT grid" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "read line; stty size",
    });
    defer session.deinit();

    try session.resize(100, 40);
    try session.write("report\n");
    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 0), exit.exited);
    try std.testing.expectEqual(@as(usize, 100), session.terminal.term.cols);
    try std.testing.expectEqual(@as(usize, 40), session.terminal.term.rows);

    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "40 100") != null);
}

test "Kitty client can obtain pixel dimensions through TIOCGWINSZ" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "read line",
        .cell_width = 10,
        .cell_height = 20,
    });
    defer session.deinit();
    var size: posix.winsize = undefined;
    const TIOCGWINSZ: c_int = @bitCast(@as(u32, 0x40087468));
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(session.master_fd, TIOCGWINSZ, &size));
    try std.testing.expectEqual(@as(u16, 800), size.xpixel);
    try std.testing.expectEqual(@as(u16, 480), size.ypixel);
    try session.resize(100, 30);
    try session.syncPixelSize(12, 24);
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(session.master_fd, TIOCGWINSZ, &size));
    try std.testing.expectEqual(@as(u16, 1200), size.xpixel);
    try std.testing.expectEqual(@as(u16, 720), size.ypixel);
    try std.testing.expectEqual(@as(u32, 1200), session.terminal.term.width_px);
    try std.testing.expectEqual(@as(u32, 720), session.terminal.term.height_px);
}

test "macOS PTY starts the shell in the requested working directory" {
    // MOSTTY-51: a configured working directory must be the child's CWD. `/usr`
    // is a real directory (not a symlink like /tmp -> /private/tmp), so `pwd -P`
    // reports it verbatim regardless of the test runner's own CWD.
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "pwd -P",
        .working_directory = "/usr",
    });
    defer session.deinit();

    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 0), exit.exited);

    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    // Match the pwd output line exactly (trailing grid padding trimmed) so a
    // wrong CWD such as /usr/local cannot satisfy a mere substring check.
    var found = false;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), "/usr")) found = true;
    }
    try std.testing.expect(found);
}

fn expectChildOutputLine(session: *PtySession, expected: []const u8) !void {
    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), expected)) return;
    }
    std.debug.print("child output did not contain '{s}':\n{s}\n", .{ expected, contents });
    return error.TestExpectedEqual;
}

test "macOS size query replies with the resized grid through the PTY" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "stty -echo -icanon min 0 time 10; printf '\\033[18t'; reply=$(dd bs=1 count=11 2>/dev/null); test \"$reply\" = \"$(printf '\\033[8;32;100t')\" && printf 'SIZE_OK\\n'",
    });
    defer session.deinit();
    try session.resize(100, 32);
    try drainToEof(&session);
    const result = try session.wait();
    try std.testing.expectEqual(@as(u8, 0), result.exited);
    try expectChildOutputLine(&session, "SIZE_OK");
}

test "macOS PTY injects configured env entries into the child" {
    // MOSTTY-58: a `env = NAME=VALUE` line must be visible to the child process.
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "printf '%s\\n' \"$MOSTTY_TEST_ENV\"",
        .env = &.{.{ .name = "MOSTTY_TEST_ENV", .value = "from-config" }},
    });
    defer session.deinit();

    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 0), exit.exited);
    try expectChildOutputLine(&session, "from-config");
}

test "a configured env entry overrides the inherited variable of the same name" {
    // The config is the more specific source, so it must win over whatever the
    // launching process exported — otherwise the key would silently do nothing
    // for the variables users most want to change (PATH, LANG, TERM).
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        // HOME is always inherited, so it proves the replacement rather than an
        // append; TERM additionally proves the forced default is overridable.
        .command = "printf '%s %s\\n' \"$HOME\" \"$TERM\"",
        .env = &.{
            .{ .name = "HOME", .value = "/config-home" },
            .{ .name = "TERM", .value = "dumb" },
        },
    });
    defer session.deinit();

    try drainToEof(&session);
    _ = try session.wait();
    try expectChildOutputLine(&session, "/config-home dumb");
}

test "a duplicated env name resolves to the last entry, as on Windows" {
    // Config keeps duplicate `env` lines in declaration order. Emitting both
    // would leave the winner up to the child's libc; the config format's rule
    // everywhere else is that the later line wins, and Windows implements that
    // explicitly, so macOS must not diverge.
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "printf '%s %s\\n' \"$MOSTTY_DUP\" \"$(env | grep -c '^MOSTTY_DUP=')\"",
        .env = &.{
            .{ .name = "MOSTTY_DUP", .value = "first" },
            .{ .name = "MOSTTY_DUP", .value = "last" },
        },
    });
    defer session.deinit();

    try drainToEof(&session);
    _ = try session.wait();
    try expectChildOutputLine(&session, "last 1");
}

test "macOS PTY forces TERM when the config leaves it alone" {
    // Without a config entry the VT's own capabilities decide TERM, so an
    // inherited value must not leak through to the child.
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "printf '%s\\n' \"$TERM\"",
    });
    defer session.deinit();

    try drainToEof(&session);
    _ = try session.wait();
    try expectChildOutputLine(&session, "xterm-256color");
}

test "macOS PTY reports an exec failure without leaving a child session" {
    var session: PtySession = undefined;
    try std.testing.expectError(error.ShellExecFailed, session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/definitely/not/a/shell",
    }));
}
