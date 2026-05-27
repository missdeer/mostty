pub fn setWinsz(fd: posix.fd_t, cols: u16, rows: u16) void {
    var ws: posix.winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    switch (posix.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => {},
        else => |e| std.log.err("TIOCSWINSZ failed: {t}", .{e}),
    }
}

pub fn openAndSpawn(cols: u16, rows: u16) mostty.Pty {
    const dev_ptmx = "/dev/ptmx";
    const master = posix.open(dev_ptmx, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0) catch |err| mostty.errExit(
        "open '{s}' failed with {t}",
        .{ dev_ptmx, err },
    );
    errdefer posix.close(master);

    // Unlock the slave side (equivalent to unlockpt)
    var unlock: i32 = 0;
    switch (posix.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)))) {
        .SUCCESS => {},
        else => |e| mostty.errExit("IOCSPTLCK failed with {t}", .{e}),
    }

    // Get the slave PTY number
    var pty_num: u32 = 0;
    switch (posix.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pty_num)))) {
        .SUCCESS => {},
        else => |e| mostty.errExit("IOCGPTN failed with {t}", .{e}),
    }

    // Build slave path: /dev/pts/N
    var pts_path_buf: [32]u8 = undefined;
    const pts_path = std.fmt.bufPrint(&pts_path_buf, "/dev/pts/{}\x00", .{pty_num}) catch unreachable;
    const pts_path_z: [:0]const u8 = pts_path[0 .. pts_path.len - 1 :0];

    setWinsz(master, cols, rows);

    // Fork
    const pid = posix.fork() catch |err| mostty.errExit("fork failed with {t}", .{err});
    if (pid == 0) {
        // Child process
        posix.close(master);

        // Create new session
        if (linux.setsid() == -1) mostty.errExit("setsid failed", .{});

        // Open the slave — this becomes the controlling terminal
        const slave = posix.open(pts_path_z, .{ .ACCMODE = .RDWR }, 0) catch |err| mostty.errExit(
            "open '{s}' failed with {t}",
            .{ pts_path_z, err },
        );

        // Set up stdin/stdout/stderr
        posix.dup2(slave, 0) catch |err| mostty.errExit("dup2 stdin failed with {t}", .{err});
        posix.dup2(slave, 1) catch |err| mostty.errExit("dup2 stdout failed with {t}", .{err});
        posix.dup2(slave, 2) catch |err| mostty.errExit("dup2 stderr failed with {t}", .{err});
        if (slave > 2) posix.close(slave);

        // Exec shell with TERM=xterm-256color
        const shell = posix.getenv("SHELL") orelse "/bin/sh";
        const envp = mostty.setTermEnv();
        const err = posix.execvpeZ(
            @ptrCast(shell.ptr),
            &[_:null]?[*:0]const u8{ @ptrCast(shell.ptr), null },
            envp,
        );
        mostty.errExit("exec '{s}' failed with {t}", .{ shell, err });
    }

    return .{ .master = master, .pid = pid, .cols = cols, .rows = rows };
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const mostty = @import("../mostty.zig");

