pub fn setWinsz(fd: posix.fd_t, cols: u16, rows: u16) void {
    var ws: posix.winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws)) != 0) {
        std.log.err("TIOCSWINSZ failed: {t}", .{std.posix.errno(0)});
    }
}

pub fn openAndSpawn(cols: u16, rows: u16) mostty.Pty {
    const master = c.posix_openpt(@bitCast(posix.O{ .ACCMODE = .RDWR }));
    if (master == -1) mostty.errExit("posix_openpt failed", .{});
    errdefer posix.close(master);

    if (c.grantpt(master) != 0) mostty.errExit("grantpt failed", .{});
    if (c.unlockpt(master) != 0) mostty.errExit("unlockpt failed", .{});

    const pts_path_z = c.ptsname(master) orelse mostty.errExit("ptsname failed", .{});

    setWinsz(master, cols, rows);

    // Fork
    const pid = posix.fork() catch |err| mostty.errExit("fork failed with {t}", .{err});
    if (pid == 0) {
        // Child process
        posix.close(master);

        // Create new session
        if (std.c.setsid() == -1) mostty.errExit("setsid failed", .{});

        // Open the slave
        const slave = posix.openZ(pts_path_z, .{ .ACCMODE = .RDWR }, 0) catch |err| mostty.errExit(
            "open slave pty '{s}' failed with {t}",
            .{ pts_path_z, err },
        );

        // Set controlling terminal
        if (std.c.ioctl(slave, TIOCSCTTY, @as(c_int, 0)) != 0) {
            mostty.errExit("TIOCSCTTY failed", .{});
        }

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

// _IOW('t', 103, struct winsize) = 0x80087467
const TIOCSWINSZ: c_int = @bitCast(@as(c_uint, 0x80087467));
// _IO('t', 97) = 0x20007461
const TIOCSCTTY: c_int = @bitCast(@as(c_uint, 0x20007461));

// Not yet available in Zig's std.c
const c = struct {
    extern "c" fn posix_openpt(oflag: c_int) posix.fd_t;
    extern "c" fn grantpt(fd: posix.fd_t) c_int;
    extern "c" fn unlockpt(fd: posix.fd_t) c_int;
    extern "c" fn ptsname(fd: posix.fd_t) ?[*:0]const u8;
};

const std = @import("std");
const posix = std.posix;
const mostty = @import("../mostty.zig");
