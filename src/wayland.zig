const Id = enum {
    display,
    registry,
    callback,
    compositor,
    shm,
    xdg_wm_base,
    seat,
    output,
    surface,
    xdg_surface,
    xdg_toplevel,
    shm_pool,
    buffer,
    keyboard,
    pointer,
};

pub const State = struct {
    ids: wl.IdTable(Id) = .{},
    shm_buf: ShmBuffer = undefined,
    glyph_cache: GlyphCache = .{},
    ttf: TrueType,
    ttf_scale: f32,
    font_ascent: i16,
    win_width: i32,
    win_height: i32,
    buffer_scale: i32,
    mods_ctrl: bool = false,
    mods_shift: bool = false,

    pub fn pixelSize(self: *const State) struct { u32, u32 } {
        return .{
            @intCast(self.win_width * self.buffer_scale),
            @intCast(self.win_height * self.buffer_scale),
        };
    }

    pub fn drain(self: *State, backend: *mostty.Backend, pty: *mostty.Pty, term: *vt.Terminal) !bool {
        var damaged = false;
        const reader = backend.io_pinned.stream_reader.interface();
        const writer = &backend.io_pinned.stream_writer.interface;
        var need_resize = false;
        while (true) {
            const sender, const opcode, const size = wl.readHeader(reader) catch break;
            switch (self.ids.lookup(sender)) {
                .display => switch (opcode) {
                    wl.display.event.@"error" => {
                        const object_id = try reader.takeInt(u32, wl.native_endian);
                        const code = try reader.takeInt(u32, wl.native_endian);
                        const msg_size = try reader.takeInt(u32, wl.native_endian);
                        const msg_word_count = std.mem.alignForward(u32, msg_size, 4);
                        var msg_buf: [400]u8 = undefined;
                        const msg = msg_buf[0..@min(msg_buf.len, msg_size -| 1)];
                        try reader.readSliceAll(msg);
                        try reader.discardAll(msg_word_count - msg.len);
                        std.log.err("display error: object={} code={} message='{s}'", .{ object_id, code, msg });
                        std.process.exit(0xff);
                    },
                    wl.display.event.delete_id => {
                        _ = try reader.takeInt(u32, wl.native_endian);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_wm_base => switch (opcode) {
                    wl.xdg_wm_base.event.ping => {
                        const serial = try reader.takeInt(u32, wl.native_endian);
                        try wl.xdg_wm_base.pong(writer, self.ids.get(.xdg_wm_base), serial);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_toplevel => switch (opcode) {
                    wl.xdg_toplevel.event.configure => {
                        const w = try reader.takeInt(i32, wl.native_endian);
                        const h = try reader.takeInt(i32, wl.native_endian);
                        const states_len = try reader.takeInt(u32, wl.native_endian);
                        try reader.discardAll(std.mem.alignForward(u32, states_len, 4));
                        if (w > 0 and h > 0) {
                            if (w != self.win_width or h != self.win_height) {
                                self.win_width = w;
                                self.win_height = h;
                                need_resize = true;
                                backend.window_state.resizing = true;
                                damaged = true;
                            }
                        }
                    },
                    wl.xdg_toplevel.event.close => {
                        std.log.info("close requested", .{});
                        std.process.exit(0);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .xdg_surface => switch (opcode) {
                    wl.xdg_surface.event.configure => {
                        const serial = try reader.takeInt(u32, wl.native_endian);
                        try wl.xdg_surface.ack_configure(writer, self.ids.get(.xdg_surface), serial);
                    },
                    else => try reader.discardAll(size - 8),
                },
                .keyboard => switch (opcode) {
                    wl.keyboard.event.keymap => {
                        _ = try reader.takeInt(u32, wl.native_endian); // format
                        _ = try reader.takeInt(u32, wl.native_endian); // size
                    },
                    wl.keyboard.event.enter => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        const keys_len = try reader.takeInt(u32, wl.native_endian);
                        try reader.discardAll(std.mem.alignForward(u32, keys_len, 4));
                        backend.window_state.focused = true;
                        damaged = true;
                    },
                    wl.keyboard.event.leave => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        backend.window_state.focused = false;
                        damaged = true;
                    },
                    wl.keyboard.event.key => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        const key = try reader.takeInt(u32, wl.native_endian);
                        const state = try reader.takeInt(u32, wl.native_endian);
                        if (state == 1 or state == 2) { // pressed or repeated
                            const screen = term.screens.active;
                            if (self.mods_shift and key == 104) { // Shift+PageUp
                                screen.scroll(.{ .delta_row = -@as(isize, @intCast(term.rows)) });
                                damaged = true;
                            } else if (self.mods_shift and key == 109) { // Shift+PageDown
                                screen.scroll(.{ .delta_row = @as(isize, @intCast(term.rows)) });
                                damaged = true;
                            } else {
                                if (!screen.viewportIsBottom()) {
                                    screen.scroll(.active);
                                    damaged = true;
                                }
                                var keysym_buf: [4]u8 = undefined;
                                const len = evdevKeyToBytes(&keysym_buf, key, self.mods_shift, self.mods_ctrl);
                                if (len > 0) {
                                    const written = posix.write(pty.master, keysym_buf[0..len]) catch |err| std.debug.panic("pty write failed: {}", .{err});
                                    if (written != len) std.debug.panic("pty short write: {} of {}", .{ written, len });
                                }
                            }
                        }
                    },
                    wl.keyboard.event.modifiers => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        const mods_depressed = try reader.takeInt(u32, wl.native_endian);
                        _ = try reader.takeInt(u32, wl.native_endian); // mods_latched
                        _ = try reader.takeInt(u32, wl.native_endian); // mods_locked
                        _ = try reader.takeInt(u32, wl.native_endian); // group
                        self.mods_ctrl = (mods_depressed & 0x4) != 0;
                        self.mods_shift = (mods_depressed & 0x1) != 0;
                    },
                    wl.keyboard.event.repeat_info => {
                        _ = try reader.takeInt(u32, wl.native_endian); // rate
                        _ = try reader.takeInt(u32, wl.native_endian); // delay
                    },
                    else => try reader.discardAll(size - 8),
                },
                .pointer => switch (opcode) {
                    wl.pointer.event.button => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(u32, wl.native_endian); // button
                        _ = try reader.takeInt(u32, wl.native_endian); // state
                    },
                    wl.pointer.event.axis => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        const axis = try reader.takeInt(u32, wl.native_endian);
                        const value_raw = try reader.takeInt(i32, wl.native_endian);
                        if (axis == 0) { // vertical
                            const scroll_lines: isize = 4;
                            const screen = term.screens.active;
                            if (value_raw < 0) { // scroll up
                                screen.scroll(.{ .delta_row = -scroll_lines });
                                damaged = true;
                            } else if (value_raw > 0) { // scroll down
                                screen.scroll(.{ .delta_row = scroll_lines });
                                damaged = true;
                            }
                        }
                    },
                    wl.pointer.event.enter => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                        _ = try reader.takeInt(i32, wl.native_endian); // x (fixed)
                        _ = try reader.takeInt(i32, wl.native_endian); // y (fixed)
                    },
                    wl.pointer.event.leave => {
                        _ = try reader.takeInt(u32, wl.native_endian); // serial
                        _ = try reader.takeInt(u32, wl.native_endian); // surface
                    },
                    wl.pointer.event.motion => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(i32, wl.native_endian); // x
                        _ = try reader.takeInt(i32, wl.native_endian); // y
                    },
                    wl.pointer.event.frame => {},
                    wl.pointer.event.axis_source => {
                        _ = try reader.takeInt(u32, wl.native_endian);
                    },
                    wl.pointer.event.axis_stop => {
                        _ = try reader.takeInt(u32, wl.native_endian); // time
                        _ = try reader.takeInt(u32, wl.native_endian); // axis
                    },
                    wl.pointer.event.axis_discrete => {
                        _ = try reader.takeInt(u32, wl.native_endian); // axis
                        _ = try reader.takeInt(i32, wl.native_endian); // discrete
                    },
                    else => try reader.discardAll(size - 8),
                },
                .shm => try reader.discardAll(size - 8),
                .seat => try reader.discardAll(size - 8),
                .buffer => try reader.discardAll(size - 8),
                else => try reader.discardAll(size - 8),
            }
            // Keep draining if the reader has buffered data
            if (reader.seek >= reader.end) break;
        }

        if (need_resize) {
            const buf_w, const buf_h = self.pixelSize();
            try self.shm_buf.recreate(backend.stream, &backend.io_pinned.stream_writer.interface, &self.ids, buf_w, buf_h);
            const new_cols: u16 = @intCast(buf_w / backend.font_width);
            const new_rows: u16 = @intCast(buf_h / backend.font_height);
            if (new_cols > 0 and new_rows > 0) {
                pty.updateWinsz(new_cols, new_rows);
                if (new_cols != term.cols or new_rows != term.rows) {
                    term.resize(std.heap.page_allocator, new_cols, new_rows) catch |err| {
                        std.log.err("terminal resize failed: {}", .{err});
                    };
                }
            }
            damaged = true;
        }
        return damaged;
    }

    pub fn setTitle(self: *State, backend: *mostty.Backend, title: []const u8) error{WriteFailed}!void {
        try wl.xdg_toplevel.set_title(
            &backend.io_pinned.stream_writer.interface,
            self.ids.get(.xdg_toplevel),
            title,
        );
    }

    pub fn render(self: *State, backend: *mostty.Backend, term: *vt.Terminal) error{WriteFailed}!void {
        const w, const h = self.pixelSize();
        doRender(
            self.shm_buf.pixel_data,
            w,
            h,
            backend.font_width,
            backend.font_height,
            self.font_ascent,
            &self.glyph_cache,
            self.ttf,
            self.ttf_scale,
            term,
            backend.cellHeight(),
            backend.window_state,
        );
        const writer = &backend.io_pinned.stream_writer.interface;
        try wl.surface.attach(writer, self.ids.get(.surface), self.ids.get(.buffer), 0, 0);
        try wl.surface.damage(writer, self.ids.get(.surface), 0, 0, self.win_width, self.win_height);
        try wl.surface.commit(writer, self.ids.get(.surface));
        backend.window_state.resizing = false;
    }
};

pub fn init(io_pinned: *mostty.IoPinned, cmdline: *const Cmdline) !mostty.Backend {
    var sockaddr_err: wl.SockaddrError = undefined;
    const addr = wl.getSockaddr(&sockaddr_err) catch {
        std.log.err("{f}", .{sockaddr_err});
        std.process.exit(0xff);
    };
    std.log.info("connecting to '{f}'", .{addr});
    const stream = wl.connect(&addr) catch |e| {
        std.log.err("connect to {f} failed with {s}", .{ addr, @errorName(e) });
        std.process.exit(0xff);
    };

    io_pinned.stream_writer = stream.writer(&io_pinned.write_buf);
    io_pinned.stream_reader = stream.reader(&io_pinned.read_buf);
    const writer = &io_pinned.stream_writer.interface;
    const reader = io_pinned.stream_reader.interface();

    var ids: wl.IdTable(Id) = .{};

    // Request registry and sync
    try wl.display.get_registry(writer, ids.new(.registry));
    try wl.display.sync(writer, ids.new(.callback));
    try writer.flush();

    // Discover globals
    const Object = struct { name: u32, version: u32 };
    var maybe_shm: ?Object = null;
    var maybe_compositor: ?Object = null;
    var maybe_xdg_wm_base: ?Object = null;
    var maybe_seat: ?Object = null;
    var maybe_output: ?Object = null;

    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .registry => switch (opcode) {
                wl.registry.event.global => {
                    const name = try reader.takeInt(u32, wl.native_endian);
                    const interface_size = try reader.takeInt(u32, wl.native_endian);
                    const interface_word_count = @divTrunc(interface_size + 3, 4);
                    var interface_buf: [400]u8 = undefined;
                    const interface = interface_buf[0..@min(interface_buf.len, interface_size -| 1)];
                    try reader.readSliceAll(interface);
                    try reader.discardAll(interface_word_count * 4 - interface.len);
                    const version = try reader.takeInt(u32, wl.native_endian);
                    std.log.info("registry global name={} interface='{s}' version={}", .{ name, interface, version });
                    if (std.mem.eql(u8, interface, wl.shm.name)) {
                        maybe_shm = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.compositor.name)) {
                        maybe_compositor = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.xdg_wm_base.name)) {
                        maybe_xdg_wm_base = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.seat.name)) {
                        maybe_seat = .{ .name = name, .version = version };
                    } else if (std.mem.eql(u8, interface, wl.output.name)) {
                        maybe_output = .{ .name = name, .version = version };
                    }
                },
                else => try reader.discardAll(size - 8),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    _ = try reader.takeInt(u32, wl.native_endian);
                    break;
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Bind required globals
    const compositor_global = maybe_compositor orelse mostty.errExit("no wl_compositor", .{});
    try wl.registry.bind(writer, ids.get(.registry), compositor_global.name, wl.compositor.name, @min(wl.compositor.version, compositor_global.version), ids.new(.compositor));

    const shm_global = maybe_shm orelse mostty.errExit("no wl_shm", .{});
    try wl.registry.bind(writer, ids.get(.registry), shm_global.name, wl.shm.name, @min(wl.shm.version, shm_global.version), ids.new(.shm));

    const xdg_wm_base_global = maybe_xdg_wm_base orelse mostty.errExit("no xdg_wm_base", .{});
    try wl.registry.bind(writer, ids.get(.registry), xdg_wm_base_global.name, wl.xdg_wm_base.name, @min(wl.xdg_wm_base.version, xdg_wm_base_global.version), ids.new(.xdg_wm_base));

    const seat_global = maybe_seat orelse mostty.errExit("no wl_seat", .{});
    try wl.registry.bind(writer, ids.get(.registry), seat_global.name, wl.seat.name, @min(wl.seat.version, seat_global.version), ids.new(.seat));

    const output_global = maybe_output orelse mostty.errExit("no wl_output", .{});
    try wl.registry.bind(writer, ids.get(.registry), output_global.name, wl.output.name, @min(wl.output.version, output_global.version), ids.new(.output));

    // Get keyboard and pointer from seat
    try wl.seat.get_keyboard(writer, ids.get(.seat), ids.new(.keyboard));
    try wl.seat.get_pointer(writer, ids.get(.seat), ids.new(.pointer));

    // Roundtrip to receive wl_output events (including scale)
    try wl.display.sync(writer, ids.get(.callback));
    try writer.flush();
    var buffer_scale: i32 = 1;
    while (true) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .output => switch (opcode) {
                wl.output.event.scale => {
                    buffer_scale = try reader.takeInt(i32, wl.native_endian);
                    std.log.info("output scale={}", .{buffer_scale});
                },
                wl.output.event.done => break,
                else => try reader.discardAll(size - 8),
            },
            .callback => switch (opcode) {
                wl.callback.event.done => {
                    _ = try reader.takeInt(u32, wl.native_endian);
                    break;
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Load TrueType font
    const ttf: TrueType = blk: {
        if (cmdline.font_path) |path| {
            const ttf_content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 100 * 1024 * 1024) catch |e|
                mostty.errExit("read ttf file '{s}' failed with {s}", .{ path, @errorName(e) });
            break :blk TrueType.load(ttf_content) catch
                mostty.errExit("load ttf file '{s}' failed", .{path});
        }
        break :blk try fontconfig.match();
    };
    const target_pixel_height: u16 = @intFromFloat(@round(cmdline.font_size * @as(f32, @floatFromInt(buffer_scale))));
    const scale_f = ttf.scaleForPixelHeight(@floatFromInt(target_pixel_height));
    const vm = ttf.verticalMetrics();
    const ascent_f: f32 = @as(f32, @floatFromInt(vm.ascent)) * scale_f;
    const descent_f: f32 = @as(f32, @floatFromInt(vm.descent)) * scale_f;
    const font_ascent: i16 = @intFromFloat(@round(ascent_f));
    const cell_height: u16 = @intFromFloat(@round(ascent_f - descent_f));
    const m_glyph = ttf.codepointGlyphIndex('m');
    const m_metrics = ttf.glyphHMetrics(m_glyph);
    const cell_width: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(m_metrics.advance_width)) * scale_f));
    std.log.info("font: cell={}x{} ascent={}", .{ cell_width, cell_height, font_ascent });

    // Create surface
    try wl.compositor.create_surface(writer, ids.get(.compositor), ids.new(.surface));
    try wl.xdg_wm_base.get_xdg_surface(writer, ids.get(.xdg_wm_base), ids.new(.xdg_surface), ids.get(.surface));
    try wl.xdg_surface.get_toplevel(writer, ids.get(.xdg_surface), ids.new(.xdg_toplevel));
    try wl.xdg_toplevel.set_title(writer, ids.get(.xdg_toplevel), "mostty");
    // Initial empty commit to get the configure event
    try wl.surface.commit(writer, ids.get(.surface));
    try writer.flush();

    // Wait for initial configure
    var win_width: i32 = mostty.window_width_pt;
    var win_height: i32 = mostty.window_height_pt;
    var configured = false;
    while (!configured) {
        const sender, const opcode, const size = try wl.readHeader(reader);
        switch (ids.lookup(sender)) {
            .xdg_toplevel => switch (opcode) {
                wl.xdg_toplevel.event.configure => {
                    const w = try reader.takeInt(i32, wl.native_endian);
                    const h = try reader.takeInt(i32, wl.native_endian);
                    const states_len = try reader.takeInt(u32, wl.native_endian);
                    try reader.discardAll(std.mem.alignForward(u32, states_len, 4));
                    if (w > 0 and h > 0) {
                        win_width = @intCast(w);
                        win_height = @intCast(h);
                    }
                },
                else => try reader.discardAll(size - 8),
            },
            .xdg_surface => switch (opcode) {
                wl.xdg_surface.event.configure => {
                    const serial = try reader.takeInt(u32, wl.native_endian);
                    try wl.xdg_surface.ack_configure(writer, ids.get(.xdg_surface), serial);
                    configured = true;
                },
                else => try reader.discardAll(size - 8),
            },
            .xdg_wm_base => switch (opcode) {
                wl.xdg_wm_base.event.ping => {
                    const serial = try reader.takeInt(u32, wl.native_endian);
                    try wl.xdg_wm_base.pong(writer, ids.get(.xdg_wm_base), serial);
                },
                else => try reader.discardAll(size - 8),
            },
            else => try reader.discardAll(size - 8),
        }
    }

    // Create SHM buffer at native pixel resolution
    const buf_width: u32 = @intCast(win_width * buffer_scale);
    const buf_height: u32 = @intCast(win_height * buffer_scale);
    const shm_buf = try ShmBuffer.create(stream, writer, &ids, buf_width, buf_height);

    // Set buffer scale and attach initial buffer
    try wl.surface.set_buffer_scale(writer, ids.get(.surface), buffer_scale);
    try wl.surface.attach(writer, ids.get(.surface), ids.get(.buffer), 0, 0);
    try wl.surface.commit(writer, ids.get(.surface));

    return .{
        .io_pinned = io_pinned,
        .stream = stream,
        .font_width = @intCast(cell_width),
        .font_height = @intCast(cell_height),
        .specific = .{ .wayland = .{
            .ids = ids,
            .shm_buf = shm_buf,
            .glyph_cache = .{},
            .ttf = ttf,
            .ttf_scale = scale_f,
            .font_ascent = font_ascent,
            .win_width = win_width,
            .win_height = win_height,
            .buffer_scale = buffer_scale,
        } },
    };
}

const GlyphCache = struct {
    // Bitset indexed by TrueType glyph index (u16), 65536 bits = 8KB
    const num_words = 1024;
    // Direct-mapped bitmap storage for glyph indices < max_direct
    const max_direct = 4096;
    bits: [num_words]u64 = .{0} ** num_words,
    bitmaps: [max_direct]GlyphBitmap = undefined,
    pixels: std.ArrayListUnmanaged(u8) = .empty,

    fn isSet(self: *const GlyphCache, glyph_index: u16) bool {
        return self.bits[glyph_index >> 6] & (@as(u64, 1) << @as(u6, @truncate(glyph_index))) != 0;
    }

    fn set(self: *GlyphCache, glyph_index: u16) void {
        self.bits[glyph_index >> 6] |= @as(u64, 1) << @as(u6, @truncate(glyph_index));
    }

    fn getOrRasterize(self: *GlyphCache, ttf: TrueType, scale: f32, glyph_index: u16) ?GlyphBitmap {
        if (self.isSet(glyph_index)) {
            if (glyph_index < max_direct) {
                const cached = self.bitmaps[glyph_index];
                return if (cached.width == 0 or cached.height == 0) null else cached;
            }
            return null;
        }

        // Rasterize on demand
        self.pixels.clearRetainingCapacity();
        const bitmap = ttf.glyphBitmap(std.heap.page_allocator, &self.pixels, @enumFromInt(glyph_index), scale, scale) catch return null;
        if (bitmap.width == 0 or bitmap.height == 0) {
            self.set(glyph_index); // mark as cached (empty glyph)
            if (glyph_index < max_direct) {
                self.bitmaps[glyph_index] = .{ .data = undefined, .width = 0, .height = 0, .off_x = 0, .off_y = 0 };
            }
            return null;
        }
        const alpha_data = std.heap.page_allocator.alloc(u8, bitmap.width * bitmap.height) catch return null;
        @memcpy(alpha_data, self.pixels.items[0 .. bitmap.width * bitmap.height]);
        const gb: GlyphBitmap = .{
            .data = alpha_data.ptr,
            .width = @intCast(bitmap.width),
            .height = @intCast(bitmap.height),
            .off_x = bitmap.off_x,
            .off_y = bitmap.off_y,
        };
        self.set(glyph_index);
        if (glyph_index < max_direct) {
            self.bitmaps[glyph_index] = gb;
        }
        return gb;
    }
};

const GlyphBitmap = struct {
    data: [*]const u8,
    width: u16,
    height: u16,
    off_x: i16,
    off_y: i16,
};

const ShmBuffer = struct {
    fd: posix.fd_t,
    pixel_data: [*]u32,
    mmap_slice: []align(std.heap.pageSize()) u8,
    width: u32,
    height: u32,

    fn create(stream: std.net.Stream, writer: *wl.Writer, ids: *wl.IdTable(Id), width: u32, height: u32) !ShmBuffer {
        const stride: u32 = @as(u32, width) * 4;
        const shm_size: u32 = stride * @as(u32, height);

        const shm_fd = posix.memfd_createZ("mostty-shm", 0) catch |e|
            mostty.errExit("memfd_create failed with {s}", .{@errorName(e)});
        posix.ftruncate(shm_fd, shm_size) catch |e|
            mostty.errExit("ftruncate failed with {s}", .{@errorName(e)});

        const pixels = posix.mmap(null, shm_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e|
            mostty.errExit("mmap shm failed with {s}", .{@errorName(e)});

        try writer.flush();
        wl.shm.create_pool(stream, ids.get(.shm), ids.new(.shm_pool), shm_fd, @intCast(shm_size)) catch |e|
            mostty.errExit("create_pool failed with {s}", .{@errorName(e)});

        try wl.shm_pool.create_buffer(writer, ids.get(.shm_pool), ids.new(.buffer), 0, @intCast(width), @intCast(height), @intCast(stride), .argb8888);
        try wl.shm_pool.destroy(writer, ids.get(.shm_pool));

        return .{
            .fd = shm_fd,
            .pixel_data = @ptrCast(@alignCast(pixels.ptr)),
            .mmap_slice = pixels,
            .width = width,
            .height = height,
        };
    }

    fn recreate(self: *ShmBuffer, stream: std.net.Stream, writer: *wl.Writer, ids: *wl.IdTable(Id), width: u32, height: u32) !void {
        // Clean up old resources
        posix.munmap(self.mmap_slice);
        posix.close(self.fd);
        try wl.buffer.destroy(writer, ids.get(.buffer));

        const stride: u32 = @as(u32, width) * 4;
        const shm_size: u32 = stride * @as(u32, height);

        const shm_fd = posix.memfd_createZ("mostty-shm", 0) catch |e|
            mostty.errExit("memfd_create failed with {s}", .{@errorName(e)});
        posix.ftruncate(shm_fd, shm_size) catch |e|
            mostty.errExit("ftruncate failed with {s}", .{@errorName(e)});

        const pixels = posix.mmap(null, shm_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, shm_fd, 0) catch |e|
            mostty.errExit("mmap shm failed with {s}", .{@errorName(e)});

        try writer.flush();
        wl.shm.create_pool(stream, ids.get(.shm), ids.get(.shm_pool), shm_fd, @intCast(shm_size)) catch |e|
            mostty.errExit("create_pool failed with {s}", .{@errorName(e)});

        try wl.shm_pool.create_buffer(writer, ids.get(.shm_pool), ids.get(.buffer), 0, @intCast(width), @intCast(height), @intCast(stride), .argb8888);
        try wl.shm_pool.destroy(writer, ids.get(.shm_pool));

        self.* = .{
            .fd = shm_fd,
            .pixel_data = @ptrCast(@alignCast(pixels.ptr)),
            .mmap_slice = pixels,
            .width = width,
            .height = height,
        };
    }
};

fn doRender(
    pixel_data: [*]u32,
    win_width: u32,
    win_height: u32,
    cell_width: u16,
    cell_height: u16,
    font_ascent: i16,
    glyph_cache: *GlyphCache,
    ttf: TrueType,
    ttf_scale: f32,
    term: *vt.Terminal,
    visible_rows: u16,
    window_state: mostty.WindowState,
) void {
    // Clear with background color
    const bg_pixel = rgb24ToArgb32(mostty.default_bg);
    const total_pixels = @as(usize, win_width) * @as(usize, win_height);
    for (0..total_pixels) |idx| {
        pixel_data[idx] = bg_pixel;
    }

    const screen = term.screens.active;
    const palette = &term.colors.palette.current;

    // Iterate visible rows from the viewport
    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var screen_row: i16 = 0;
    while (row_it.next()) |row_pin| {
        defer screen_row += 1;
        if (screen_row >= visible_rows) break;

        const page = &row_pin.node.data;
        const cells = page.getCells(row_pin.rowAndCell().row);

        for (cells, 0..) |cell, col_idx| {
            if (cell.wide == .spacer_tail) continue;

            const raw_codepoint: u21 = switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => cell.content.codepoint,
                .bg_color_palette, .bg_color_rgb => ' ',
            };
            const codepoint: u21 = if (raw_codepoint == 0) ' ' else raw_codepoint;

            var cell_fg: u24 = mostty.default_fg;
            var cell_bg: u24 = mostty.default_bg;

            if (cell.style_id != 0) {
                const style = page.styles.get(page.memory, cell.style_id).*;
                cell_fg = mostty.resolveColor(style.fg_color, palette, mostty.default_fg);
                cell_bg = mostty.resolveColor(style.bg_color, palette, mostty.default_bg);
                if (style.flags.inverse) {
                    const tmp = cell_fg;
                    cell_fg = cell_bg;
                    cell_bg = tmp;
                }
            }

            // Handle bg-only cells
            switch (cell.content_tag) {
                .bg_color_palette => cell_bg = mostty.rgbToU24(palette[cell.content.color_palette]),
                .bg_color_rgb => {
                    const rgb = cell.content.color_rgb;
                    cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
                },
                else => {},
            }

            const visual_col: u16 = @intCast(col_idx);
            putGlyph(pixel_data, win_width, win_height, cell_width, cell_height, font_ascent, glyph_cache, ttf, ttf_scale, screen_row, visual_col, codepoint, cell_fg, cell_bg);
        }
    }

    // Draw cursor only when viewport is at the bottom (active area)
    if (screen.viewportIsBottom() and term.modes.get(.cursor_visible)) {
        const cursor_x = screen.cursor.x;
        const cursor_y = screen.cursor.y;
        if (cursor_y < visible_rows) {
            const cursor_screen_row: i16 = @intCast(cursor_y);
            if (window_state.focused) {
                putGlyph(pixel_data, win_width, win_height, cell_width, cell_height, font_ascent, glyph_cache, ttf, ttf_scale, cursor_screen_row, cursor_x, ' ', mostty.default_bg, mostty.default_fg);
            } else {
                drawRect(pixel_data, win_width, win_height, @as(i32, cursor_x) * cell_width, @as(i32, cursor_screen_row) * cell_height, cell_width, cell_height, mostty.default_fg);
            }
        }
    }

    // Draw scrollbar
    const sb = screen.pages.scrollbar();
    if (sb.total > sb.len) {
        const scrollbar_width: u32 = 8;
        const scrollbar_x: i32 = @intCast(win_width - scrollbar_width);

        const min_track_height: u32 = 20;
        const track_height: u32 = @max(min_track_height, @as(u32, @intFromFloat(
            @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * @as(f32, @floatFromInt(win_height)),
        )));

        const max_offset = sb.total - sb.len;
        const track_y: i32 = @intFromFloat(
            @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * @as(f32, @floatFromInt(win_height - track_height)),
        );

        fillRect(pixel_data, win_width, win_height, scrollbar_x, track_y, scrollbar_width, track_height, 0x666666);
    }

    // Draw resize overlay (e.g. "80x25") centered on screen
    if (window_state.resizing) {
        var overlay_buf: [20]u8 = undefined;
        const overlay_text = std.fmt.bufPrint(&overlay_buf, "{}x{}", .{ term.cols, term.rows }) catch unreachable;
        const text_len: u32 = @intCast(overlay_text.len);
        const visible_cols: u32 = win_width / cell_width;
        const text_col: u16 = @intCast((visible_cols -| text_len) / 2);
        const text_row: i16 = @intCast(visible_rows / 2);
        const pad_x: u32 = cell_width;
        const pad_y: u32 = cell_height / 2;
        const box_x: i32 = @as(i32, @intCast(text_col)) * cell_width - @as(i32, @intCast(pad_x));
        const box_y: i32 = @as(i32, text_row) * cell_height - @as(i32, @intCast(pad_y));
        const box_width: u32 = text_len * cell_width + pad_x * 2;
        const box_height: u32 = cell_height + pad_y * 2;

        fillRect(pixel_data, win_width, win_height, box_x, box_y, box_width, box_height, 0x333333);
        for (overlay_text, 0..) |ch, i| {
            putGlyph(pixel_data, win_width, win_height, cell_width, cell_height, font_ascent, glyph_cache, ttf, ttf_scale, text_row, text_col + @as(u16, @intCast(i)), ch, 0xffffff, 0x333333);
        }
    }
}

fn putGlyph(
    pixel_data: [*]u32,
    win_width: u32,
    win_height: u32,
    cell_width: u16,
    cell_height: u16,
    font_ascent: i16,
    glyph_cache: *GlyphCache,
    ttf: TrueType,
    ttf_scale: f32,
    row: i16,
    col: u16,
    codepoint: u21,
    fg: u24,
    bg: u24,
) void {
    const px: i32 = @as(i32, col) * cell_width;
    const py: i32 = @as(i32, row) * cell_height;

    // Fill cell background
    const bg_pixel = rgb24ToArgb32(bg);
    for (0..cell_height) |dy| {
        const y = py + @as(i32, @intCast(dy));
        if (y < 0 or y >= win_height) continue;
        const row_off: usize = @as(usize, @intCast(y)) * win_width;
        for (0..cell_width) |dx| {
            const x = px + @as(i32, @intCast(dx));
            if (x < 0 or x >= win_width) continue;
            pixel_data[row_off + @as(usize, @intCast(x))] = bg_pixel;
        }
    }

    // Draw glyph
    const glyph_index: u16 = @intFromEnum(ttf.codepointGlyphIndex(codepoint));
    const maybe_glyph: ?GlyphBitmap = glyph_cache.getOrRasterize(ttf, ttf_scale, glyph_index);

    if (maybe_glyph) |glyph| {
        const fg_r: u32 = (fg >> 16) & 0xFF;
        const fg_g: u32 = (fg >> 8) & 0xFF;
        const fg_b: u32 = fg & 0xFF;
        const bg_r: u32 = (bg >> 16) & 0xFF;
        const bg_g: u32 = (bg >> 8) & 0xFF;
        const bg_b: u32 = bg & 0xFF;
        for (0..glyph.height) |by| {
            const y = py + @as(i32, font_ascent) + @as(i32, glyph.off_y) + @as(i32, @intCast(by));
            if (y < 0 or y >= win_height) continue;
            const row_off: usize = @as(usize, @intCast(y)) * win_width;
            for (0..glyph.width) |bx| {
                const x = px + @as(i32, glyph.off_x) + @as(i32, @intCast(bx));
                if (x < 0 or x >= win_width) continue;
                const idx = row_off + @as(usize, @intCast(x));
                const alpha: u32 = glyph.data[by * glyph.width + bx];
                if (alpha == 0) continue;
                if (alpha == 255) {
                    pixel_data[idx] = rgb24ToArgb32(fg);
                } else {
                    const inv = 255 - alpha;
                    const r = (fg_r * alpha + bg_r * inv) / 255;
                    const g = (fg_g * alpha + bg_g * inv) / 255;
                    const b = (fg_b * alpha + bg_b * inv) / 255;
                    pixel_data[idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
                }
            }
        }
    }
}

fn fillRect(pixel_data: [*]u32, win_width: u32, win_height: u32, px: i32, py: i32, w: u32, h: u32, color: u24) void {
    const pixel = rgb24ToArgb32(color);
    for (0..h) |dy| {
        const y = py + @as(i32, @intCast(dy));
        if (y < 0 or y >= win_height) continue;
        const row: usize = @as(usize, @intCast(y)) * win_width;
        for (0..w) |dx| {
            const x = px + @as(i32, @intCast(dx));
            if (x < 0 or x >= win_width) continue;
            pixel_data[row + @as(usize, @intCast(x))] = pixel;
        }
    }
}

fn drawRect(pixel_data: [*]u32, win_width: u32, win_height: u32, px: i32, py: i32, w: u32, h: u32, color: u24) void {
    const pixel = rgb24ToArgb32(color);
    const bot = py + @as(i32, @intCast(h)) - 1;
    const right = px + @as(i32, @intCast(w)) - 1;
    // Top and bottom edges
    for (0..w) |dx| {
        const x = px + @as(i32, @intCast(dx));
        if (x < 0 or x >= win_width) continue;
        const x_u: usize = @intCast(x);
        if (py >= 0 and py < win_height)
            pixel_data[@as(usize, @intCast(py)) * win_width + x_u] = pixel;
        if (bot >= 0 and bot < win_height)
            pixel_data[@as(usize, @intCast(bot)) * win_width + x_u] = pixel;
    }
    // Left and right edges
    for (1..h -| 1) |dy| {
        const y = py + @as(i32, @intCast(dy));
        if (y < 0 or y >= win_height) continue;
        const row: usize = @as(usize, @intCast(y)) * win_width;
        if (px >= 0 and px < win_width)
            pixel_data[row + @as(usize, @intCast(px))] = pixel;
        if (right >= 0 and right < win_width)
            pixel_data[row + @as(usize, @intCast(right))] = pixel;
    }
}

fn rgb24ToArgb32(rgb: u24) u32 {
    return 0xFF000000 | @as(u32, rgb);
}

// Evdev keycode to byte mapping for US keyboard layout
fn evdevKeyToBytes(buf: *[4]u8, key: u32, shift: bool, ctrl: bool) u3 {
    // Handle Ctrl+letter
    if (ctrl) {
        const char = evdevToChar(key, false);
        if (char != 0) {
            switch (char) {
                'a'...'z', '@'...'_' => {
                    buf[0] = char & 0x1f;
                    return 1;
                },
                else => {},
            }
        }
    }

    // Function keys / special keys
    const bytes: []const u8 = switch (key) {
        1 => "\x1b", // ESC
        14 => "\x7f", // Backspace
        15 => "\t", // Tab
        28 => "\r", // Enter
        96 => "\r", // Keypad Enter
        102 => "\x1b[H", // Home
        103 => "\x1b[A", // Up
        104 => "\x1b[5~", // PageUp
        105 => "\x1b[D", // Left
        106 => "\x1b[C", // Right
        107 => "\x1b[F", // End
        108 => "\x1b[B", // Down
        109 => "\x1b[6~", // PageDown
        110 => "\x1b[2~", // Insert
        111 => "\x1b[3~", // Delete
        // Modifier-only keys
        29, 97 => "", // Left/Right Ctrl
        42, 54 => "", // Left/Right Shift
        56, 100 => "", // Left/Right Alt
        125, 126 => "", // Left/Right Super
        58 => "", // CapsLock
        69 => "", // NumLock
        70 => "", // ScrollLock
        else => {
            const char = evdevToChar(key, shift);
            if (char != 0) {
                buf[0] = char;
                return 1;
            }
            return 0;
        },
    };
    const len: u3 = @intCast(bytes.len);
    @memcpy(buf[0..len], bytes);
    return len;
}

fn evdevToChar(key: u32, shift: bool) u8 {
    if (shift) {
        return switch (key) {
            2 => '!',
            3 => '@',
            4 => '#',
            5 => '$',
            6 => '%',
            7 => '^',
            8 => '&',
            9 => '*',
            10 => '(',
            11 => ')',
            12 => '_',
            13 => '+',
            16 => 'Q',
            17 => 'W',
            18 => 'E',
            19 => 'R',
            20 => 'T',
            21 => 'Y',
            22 => 'U',
            23 => 'I',
            24 => 'O',
            25 => 'P',
            26 => '{',
            27 => '}',
            30 => 'A',
            31 => 'S',
            32 => 'D',
            33 => 'F',
            34 => 'G',
            35 => 'H',
            36 => 'J',
            37 => 'K',
            38 => 'L',
            39 => ':',
            40 => '"',
            41 => '~',
            43 => '|',
            44 => 'Z',
            45 => 'X',
            46 => 'C',
            47 => 'V',
            48 => 'B',
            49 => 'N',
            50 => 'M',
            51 => '<',
            52 => '>',
            53 => '?',
            57 => ' ',
            else => 0,
        };
    }
    return switch (key) {
        2 => '1',
        3 => '2',
        4 => '3',
        5 => '4',
        6 => '5',
        7 => '6',
        8 => '7',
        9 => '8',
        10 => '9',
        11 => '0',
        12 => '-',
        13 => '=',
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        26 => '[',
        27 => ']',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        39 => ';',
        40 => '\'',
        41 => '`',
        43 => '\\',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        51 => ',',
        52 => '.',
        53 => '/',
        57 => ' ',
        else => 0,
    };
}

const std = @import("std");
const wl = @import("wl");
const vt = @import("vt");
const mostty = @import("mostty.zig");
const Cmdline = @import("Cmdline.zig");
const TrueType = @import("TrueType");
const fontconfig = @import("posix/fontconfig.zig");
const posix = std.posix;
