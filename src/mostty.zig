const mostty_config: mosttyicon.Config = .{
    .id = "mostty",
    .startup_wm_class = "mostty",
    .desktop_entry = .{
        .Name = "Mostty",
        .Comment = "Terminal Emulator",
        .Exec = "mostty",
        .Categories = "System;TerminalEmulator",
    },
};
pub fn main() !void {
    const cmdline = blk: {
        var args_it = std.process.args();
        break :blk try Cmdline.parse(&args_it);
    };

    try mosttyicon.installDesktop(mostty_config);

    var io_pinned: IoPinned = undefined;
    var backend = blk: {
        if (builtin.os.tag == .linux) {
            const xdg_session_type = std.posix.getenv("XDG_SESSION_TYPE");
            std.log.info("XDG_SESSION_TYPE={?s}", .{xdg_session_type});
            if (std.mem.eql(u8, xdg_session_type orelse "", "wayland"))
                break :blk try wayland_backend.init(&io_pinned, &cmdline);
        }
        break :blk try x11_backend.init(&io_pinned, &cmdline);
    };

    var pty = os.openAndSpawn(backend.cellWidth(), backend.cellHeight());
    defer posix.close(pty.master);
    std.log.info("spawned shell pid={}", .{pty.pid});

    // TODO: should this be a gpa instead?
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var term = try vt.Terminal.init(arena_instance.allocator(), .{
        .cols = backend.cellWidth(),
        .rows = backend.cellHeight(),
    });
    // defer term.deinit(arena_instance.allocator());

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var vt_stream: vt.Stream(TitleHandler) = .initAlloc(
        gpa.allocator(),
        .{ .readonly = term.vtHandler(), .backend = &backend },
    );
    defer vt_stream.deinit();

    var poll_fds = [_]posix.pollfd{
        .{ .fd = backend.stream.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
    };

    var damaged = false;
    var damage_deferred: ?std.time.Instant = null;
    const render_deadline_ns: u64 = 8 * std.time.ns_per_ms; // ~120fps max
    while (true) {
        try backend.flush();
        const ready = try posix.poll(&poll_fds, if (damaged) @as(i32, 0) else -1);
        std.debug.assert(damaged or (ready != 0));
        var handled: usize = 0;

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            handled += 1;
            if (try backend.drain(
                &pty,
                &term,
            )) {
                damaged = true;
            }
        }

        if (poll_fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            handled += 1;
            var read_buf: [8192]u8 = undefined;
            const n = posix.read(pty.master, &read_buf) catch |err| switch (err) {
                error.InputOutput => {
                    std.log.info("pty read EIO", .{});
                    std.process.exit(0);
                },
                else => |e| return e,
            };
            if (n == 0) {
                std.log.info("shell closed", .{});
                return;
            }
            vt_stream.nextSlice(read_buf[0..n]);
            damaged = true;
        }
        std.debug.assert(ready == handled);

        const do_render = blk: {
            if (!damaged) break :blk false;
            if (ready == 0) break :blk true;
            if (damage_deferred == null) {
                damage_deferred = now();
                break :blk false;
            }
            break :blk now().since(damage_deferred.?) >= render_deadline_ns;
        };
        if (do_render) {
            try backend.render(&term);
            damaged = false;
            damage_deferred = null;
        }
    }
}

pub fn now() std.time.Instant {
    return std.time.Instant.now() catch unreachable;
}

pub const vt = @import("vt");

pub const default_fg: u24 = 0xffffff;
pub const default_bg: u24 = 0x2a2a2a;

pub const window_width_pt = 600;
pub const window_height_pt = 400;

/// Resolve a ghostty style color to a u24 RGB value.
pub fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette, default: u24) u24 {
    return switch (c) {
        .none => default,
        .palette => |idx| rgbToU24(palette[idx]),
        .rgb => |rgb| rgbToU24(rgb),
    };
}

pub fn rgbToU24(rgb: vt.color.RGB) u24 {
    return @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
}

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    cols: u16,
    rows: u16,

    pub fn updateWinsz(self: *Pty, cols: u16, rows: u16) void {
        if (cols != self.cols or rows != self.rows) {
            std.log.info("updating winsz from {}x{} to {}x{}", .{ self.cols, self.rows, cols, rows });
            self.cols = cols;
            self.rows = rows;
            os.setWinsz(self.master, cols, rows);
        }
    }
};

pub fn setTermEnv() [*:null]?[*:0]const u8 {
    // Try to find and update TERM in place
    for (std.os.environ) |*entry| {
        if (std.mem.startsWith(u8, std.mem.span(entry.*), "TERM=")) {
            entry.* = @ptrCast(@constCast("TERM=xterm-256color"));
            return @ptrCast(std.os.environ.ptr);
        }
    }
    // TERM not found, allocate a new array with one extra entry
    const old_len = std.os.environ.len;
    const new_envp = std.heap.page_allocator.alloc(?[*:0]const u8, old_len + 2) catch
        errExit("failed to allocate envp", .{});
    @memcpy(new_envp[0..old_len], std.os.environ);
    new_envp[old_len] = "TERM=xterm-256color";
    new_envp[old_len + 1] = null;
    return @ptrCast(new_envp.ptr);
}

pub const IoPinned = struct {
    write_buf: [4096]u8,
    read_buf: [500]u8,
    stream_writer: std.net.Stream.Writer,
    stream_reader: std.net.Stream.Reader,
};

pub const WindowState = struct {
    focused: bool = true,
    resizing: bool = false,
};

pub const Backend = struct {
    io_pinned: *IoPinned,
    stream: std.net.Stream,
    font_width: u8,
    font_height: u8,
    window_state: WindowState = .{},

    specific: Specific,

    pub const Specific = switch (builtin.os.tag) {
        .linux => union(enum) {
            x11: x11_backend.State,
            wayland: wayland_backend.State,
        },
        else => union(enum) {
            x11: x11_backend.State,
        },
    };

    pub fn cellWidth(self: *const Backend) u16 {
        return switch (builtin.os.tag) {
            .linux => switch (self.specific) {
                .x11 => |*s| s.win_width / self.font_width,
                .wayland => |*s| @intCast(s.pixelSize()[0] / self.font_width),
            },
            else => self.specific.x11.win_width / self.font_width,
        };
    }
    pub fn cellHeight(self: *const Backend) u16 {
        return switch (builtin.os.tag) {
            .linux => switch (self.specific) {
                .x11 => |*s| s.win_height / self.font_height,
                .wayland => |*s| @intCast(s.pixelSize()[1] / self.font_height),
            },
            else => self.specific.x11.win_height / self.font_height,
        };
    }

    pub fn flush(self: *Backend) !void {
        self.io_pinned.stream_writer.interface.flush() catch
            return handleWriteErr(&self.io_pinned.stream_writer);
    }

    pub fn drain(self: *Backend, pty: *Pty, term: *vt.Terminal) !bool {
        return switch (self.specific) {
            inline else => |*s| s.drain(self, pty, term) catch |err| switch (err) {
                error.WriteFailed => handleWriteErr(&self.io_pinned.stream_writer),
                else => |e| e,
            },
        };
    }

    pub fn render(self: *Backend, term: *vt.Terminal) !void {
        switch (self.specific) {
            inline else => |*s| s.render(self, term) catch |err| switch (err) {
                error.WriteFailed => return handleWriteErr(&self.io_pinned.stream_writer),
            },
        }
    }

    pub fn setTitle(self: *Backend, title: []const u8) error{WriteFailed}!void {
        switch (self.specific) {
            inline else => |*s| try s.setTitle(self, title),
        }
    }

    pub fn handleWriteErr(sw: *std.net.Stream.Writer) std.net.Stream.WriteError {
        if (sw.err) |e| switch (e) {
            error.BrokenPipe => {
                std.log.info("connection closed", .{});
                std.process.exit(0);
            },
            else => return e,
        };
        unreachable;
    }
};

pub const TitleHandler = struct {
    const vt_mod = @import("vt");

    readonly: vt_mod.ReadonlyHandler,
    backend: *Backend,

    pub fn vt(
        self: *TitleHandler,
        comptime action: vt_mod.StreamAction.Tag,
        value: vt_mod.StreamAction.Value(action),
    ) void {
        switch (action) {
            .window_title => self.backend.setTitle(value.title) catch std.debug.panic(
                "{t} write error {t} (from setTitle)",
                .{
                    self.backend.specific,
                    Backend.handleWriteErr(&self.backend.io_pinned.stream_writer),
                },
            ),
            else => {},
        }
        self.readonly.vt(action, value);
    }

    pub fn deinit(self: *TitleHandler) void {
        self.readonly.deinit();
    }
};

pub fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const mosttyicon = @import("mosttyicon");

const os = switch (builtin.os.tag) {
    .linux => @import("os/linux.zig"),
    else => @import("os/posix.zig"),
};

const x11_backend = @import("x11.zig");
const wayland_backend = switch (builtin.os.tag) {
    .linux => @import("wayland.zig"),
    else => @compileError("wayland only supported on linux"),
};
const Cmdline = @import("Cmdline.zig");
