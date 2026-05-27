const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn offscreenPixmap(self: Ids) x11.Pixmap {
        return self.base.add(2).pixmap();
    }
    pub fn tempPixmap(self: Ids) x11.Pixmap {
        return self.base.add(3).pixmap();
    }
    pub fn tempGc(self: Ids) x11.GraphicsContext {
        return self.base.add(4).graphicsContext();
    }
    pub fn backbufPicture(self: Ids) x11.render.Picture {
        return self.base.add(5).picture();
    }
    pub fn solidPicture(self: Ids) x11.render.Picture {
        return self.base.add(6).picture();
    }
    pub fn glyphPicture(self: Ids, glyph_index: TrueType.GlyphIndex) x11.render.Picture {
        return self.base.add(@as(u32, 7) + @intFromEnum(glyph_index)).picture();
    }
};

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub const State = struct {
    sink: x11.RequestSink,
    source: x11.Source,
    ids: Ids,
    root: Root,
    keymap: x11.keymap.Full,
    dpi_scale: f32,
    gc: Gc,
    ttf_font: TtfFont,
    net_wm_name_atom: x11.Atom,
    utf8_string_atom: x11.Atom,
    win_width: u16,
    win_height: u16,
    // Pixmap tracking
    pixmap_width: u16,
    pixmap_height: u16,

    pub fn drain(self: *State, backend: *mostty.Backend, pty: *mostty.Pty, term: *vt.Terminal) !bool {
        var damaged = drainX11Events(&self.source, &self.keymap, pty, term, &self.win_width, &self.win_height, backend, backend.font_width, backend.font_height) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed", .{});
                std.process.exit(0);
            },
            else => return err,
        };
        // Recreate offscreen pixmap if window was resized
        if (self.win_width != self.pixmap_width or self.win_height != self.pixmap_height) {
            try x11.render.FreePicture(&self.sink, self.ttf_font.render_ext_opcode, self.ids.backbufPicture());
            try self.sink.FreePixmap(self.ids.offscreenPixmap());
            try self.sink.CreatePixmap(self.ids.offscreenPixmap(), self.ids.window().drawable(), .{
                .depth = self.root.depth,
                .width = self.win_width,
                .height = self.win_height,
            });
            try x11.render.CreatePicture(
                &self.sink,
                self.ttf_font.render_ext_opcode,
                self.ids.backbufPicture(),
                self.ids.offscreenPixmap().drawable(),
                self.ttf_font.render_ext_screen_format,
                .{},
            );
            self.ttf_font.dst_picture = self.ids.backbufPicture();
            self.pixmap_width = self.win_width;
            self.pixmap_height = self.win_height;
            damaged = true;
        }
        return damaged;
    }

    pub fn setTitle(self: *State, _: *mostty.Backend, title: []const u8) error{WriteFailed}!void {
        try self.sink.ChangeProperty(
            .replace,
            self.ids.window(),
            self.net_wm_name_atom,
            self.utf8_string_atom,
            u8,
            .{ .ptr = title.ptr, .len = @intCast(title.len) },
        );
    }

    pub fn render(self: *State, backend: *mostty.Backend, term: *vt.Terminal) error{WriteFailed}!void {
        try doRender(
            &self.sink,
            self.ids.window(),
            self.ids.gc(),
            self.root.depth,
            backend.font_width,
            backend.font_height,
            term,
            &self.gc,
            backend.cellHeight(),
            self.ids.offscreenPixmap(),
            self.win_width,
            self.win_height,
            self.dpi_scale,
            &self.ttf_font,
            backend.window_state,
        );
        backend.window_state.resizing = false;
    }
};

pub fn init(io_pinned: *mostty.IoPinned, cmdline: *const Cmdline) !mostty.Backend {
    io_pinned.stream_reader, const used_auth = try x11.draft.connect(&io_pinned.read_buf);
    errdefer x11.disconnect(io_pinned.stream_reader.getStream());
    _ = used_auth;
    io_pinned.stream_writer = io_pinned.stream_reader.getStream().writer(&io_pinned.write_buf);
    return init2(io_pinned, cmdline) catch |err| switch (err) {
        error.ReadFailed => return io_pinned.stream_reader.getError().?,
        error.WriteFailed => return io_pinned.stream_writer.err.?,
        else => |e| return e,
    };
}
fn init2(io_pinned: *mostty.IoPinned, cmdline: *const Cmdline) !mostty.Backend {
    const setup = try x11.readSetupSuccess(io_pinned.stream_reader.interface());
    std.log.info("setup reply {f}", .{setup});
    var source: x11.Source = .initFinishSetup(io_pinned.stream_reader.interface(), &setup);
    const root: Root = blk: {
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
            mostty.errExit("no screen", .{});
        };
        break :blk .{
            .window = screen.root,
            .visual = screen.root_visual,
            .depth = x11.Depth.init(screen.root_depth) orelse
                mostty.errExit("unsupported depth {}", .{screen.root_depth}),
        };
    };
    var sink: x11.RequestSink = .{ .writer = &io_pinned.stream_writer.interface };

    const keyrange: x11.KeycodeRange = try .init(setup.min_keycode, setup.max_keycode);
    const keymap: x11.keymap.Full = try .initSynchronous(&sink, &source, keyrange);

    // Read DPI from X11 RESOURCE_MANAGER property (Xft.dpi)
    const dpi_scale = blk: {
        try sink.GetProperty(root.window, .{
            .property = .RESOURCE_MANAGER,
            .type = .STRING,
            .offset = 0,
            .len = 1024 * 1024, // up to 1MB
            .delete = false,
        });
        try sink.writer.flush();
        const reply = try source.readSynchronousReply1(sink.sequence);
        break :blk readDpiScale(&source, reply.flexible);
    };
    std.log.info("dpi_scale={d:.2}", .{dpi_scale});

    const scaled_width: u16 = @intFromFloat(@as(f32, @floatFromInt(mostty.window_width_pt)) * dpi_scale);
    const scaled_height: u16 = @intFromFloat(@as(f32, @floatFromInt(mostty.window_height_pt)) * dpi_scale);

    // Intern atoms
    const _NET_WM_NAME = "_NET_WM_NAME";
    try sink.InternAtom(.{ .only_if_exists = false, .name = .{ .ptr = _NET_WM_NAME, .len = _NET_WM_NAME.len } });
    const net_wm_name_seq = sink.sequence;
    const UTF8_STRING = "UTF8_STRING";
    try sink.InternAtom(.{ .only_if_exists = false, .name = .{ .ptr = UTF8_STRING, .len = UTF8_STRING.len } });
    const utf8_string_seq = sink.sequence;
    const _NET_WM_ICON = "_NET_WM_ICON";
    try sink.InternAtom(.{ .only_if_exists = false, .name = .{ .ptr = _NET_WM_ICON, .len = _NET_WM_ICON.len } });
    const net_wm_icon_seq = sink.sequence;
    try sink.writer.flush();
    const net_wm_name_atom = (try source.readSynchronousReplyFull(net_wm_name_seq, .InternAtom))[0].atom;
    const utf8_string_atom = (try source.readSynchronousReplyFull(utf8_string_seq, .InternAtom))[0].atom;
    const net_wm_icon_atom = (try source.readSynchronousReplyFull(net_wm_icon_seq, .InternAtom))[0].atom;

    const ids: Ids = .{ .base = setup.resource_id_base };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = scaled_width,
            .height = scaled_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = root.visual,
        },
        .{
            .bg_pixel = root.depth.rgbFrom24(mostty.default_bg),
            .bit_gravity = .north_west,
            .event_mask = .{
                .KeyPress = 1,
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .ButtonMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
                .FocusChange = 1,
            },
        },
    );

    // Set WM_CLASS so the desktop environment can match the window to its .desktop file
    // Format: "instance\0class\0"
    try sink.ChangeProperty(.replace, ids.window(), .WM_CLASS, .STRING, u8, .{ .ptr = "mostty\x00mostty\x00", .len = 14 });

    try mosttyicon.setWmIcons(&sink, ids.window(), net_wm_icon_atom);

    const render_ext: RenderExt = blk: {
        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.render.name) orelse {
            mostty.errExit("X11 RENDER extension is required", .{});
        };

        // Query version (we need at least 0.10 for CreateSolidFill)
        try x11.render.request.QueryVersion(&sink, ext.opcode_base, 0, 10);
        try sink.writer.flush();
        const version, _ = try source.readSynchronousReplyFull(sink.sequence, .render_QueryVersion);
        std.log.info("extension '{f}': version {}.{}", .{ x11.render.name, version.major, version.minor });
        if (version.major != 0 or version.minor < 10) {
            mostty.errExit("X11 RENDER extension version {}.{} is too old (need 0.10+)", .{ version.major, version.minor });
        }

        // Query pict formats to find A8 and screen-depth formats
        try x11.render.QueryPictFormats(&sink, ext.opcode_base);
        try sink.writer.flush();
        const result, _ = try source.readSynchronousReplyHeader(sink.sequence, .render_QueryPictFormats);

        var a8_format: ?x11.render.PictureFormat = null;
        var screen_format: ?x11.render.PictureFormat = null;
        for (0..result.num_formats) |_| {
            var format: x11.render.PictureFormatInfo = undefined;
            try source.readReply(std.mem.asBytes(&format));
            // A8 format: 8-bit depth, direct type, alpha_mask=0xff
            if (format.depth == 8 and format.direct.alpha_mask == 0xff and a8_format == null) {
                a8_format = format.id;
            }
            // Screen format: matches screen depth
            if (format.depth == root.depth.byte() and screen_format == null) {
                screen_format = format.id;
            }
        }
        try source.replyDiscard(source.replyRemainingSize());

        if (a8_format == null or screen_format == null) {
            mostty.errExit("X11 RENDER extension: required pict formats not found (a8={?d}, screen={?d})", .{ a8_format, screen_format });
        }
        break :blk .{ .opcode = ext.opcode_base, .a8_format = a8_format.?, .screen_format = screen_format.? };
    };

    const target_pixel_height: u16 = @intFromFloat(@round(cmdline.font_size * dpi_scale));
    const ttf: TrueType = blk: {
        if (cmdline.font_path) |path| {
            const ttf_content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 100 * 1024 * 1024) catch |err|
                mostty.errExit("read ttf file '{s}' failed with {s}", .{ path, @errorName(err) });
            break :blk TrueType.load(ttf_content) catch |err| {
                std.log.err("load ttf file '{s}' failed with {t}", .{ path, err });
                return err;
            };
        }
        break :blk try fontconfig.match();
    };
    var ttf_font = try TtfFont.init(
        ttf,
        target_pixel_height,
        &sink,
        ids,
        render_ext,
        root.window.drawable(),
    );
    const font_width: u8 = @intCast(ttf_font.cell_width);
    const font_height: u8 = @intCast(ttf_font.cell_height);

    const gc: Gc = .{ .fg = mostty.default_fg, .bg = mostty.default_bg };
    try sink.CreateGc(ids.gc(), ids.window().drawable(), .{
        .foreground = root.depth.rgbFrom24(gc.fg),
        .background = root.depth.rgbFrom24(gc.bg),
        .graphics_exposures = false,
    });

    // Set up double buffering via offscreen pixmap + CopyArea
    try sink.CreatePixmap(ids.offscreenPixmap(), ids.window().drawable(), .{
        .depth = root.depth,
        .width = scaled_width,
        .height = scaled_height,
    });
    try x11.render.CreatePicture(
        &sink,
        ttf_font.render_ext_opcode,
        ids.backbufPicture(),
        ids.offscreenPixmap().drawable(),
        ttf_font.render_ext_screen_format,
        .{},
    );
    ttf_font.dst_picture = ids.backbufPicture();

    try sink.MapWindow(ids.window());

    std.debug.assert(source.state == .kind);
    return .{
        .io_pinned = io_pinned,
        .stream = io_pinned.stream_reader.getStream(),
        .font_width = font_width,
        .font_height = font_height,
        .specific = .{
            .x11 = .{
                .sink = sink,
                .source = .initAfterSetup(io_pinned.stream_reader.interface()),
                .ids = ids,
                .root = root,
                .keymap = keymap,
                .dpi_scale = dpi_scale,
                .gc = gc,
                .ttf_font = ttf_font,
                .net_wm_name_atom = net_wm_name_atom,
                .utf8_string_atom = utf8_string_atom,
                .win_width = scaled_width,
                .win_height = scaled_height,
                .pixmap_width = scaled_width,
                .pixmap_height = scaled_height,
            },
        },
    };
}

const Gc = struct {
    fg: u24,
    bg: u24,

    const Opts = struct {
        fg: ?u24 = null,
        bg: ?u24 = null,
    };

    fn update(self: *Gc, sink: *x11.RequestSink, gc: x11.GraphicsContext, depth: x11.Depth, opts: Opts) !void {
        var gc_opts: x11.ChangeGcOptions = .{};
        if (opts.fg) |fg| if (self.fg != fg) {
            self.fg = fg;
            gc_opts.foreground = depth.rgbFrom24(fg);
        };
        if (opts.bg) |bg| if (self.bg != bg) {
            self.bg = bg;
            gc_opts.background = depth.rgbFrom24(bg);
        };
        if (gc_opts.foreground != null or gc_opts.background != null) {
            try sink.ChangeGc(gc, gc_opts);
        }
    }
};

const RenderExt = struct {
    opcode: u8,
    a8_format: x11.render.PictureFormat,
    screen_format: x11.render.PictureFormat,
};

fn updateSolidFill(
    sink: *x11.RequestSink,
    render_opcode: u8,
    id: x11.render.Picture,
    current_color: *?u24,
    new_color: u24,
) error{WriteFailed}!void {
    if (current_color.* == new_color) return;
    if (current_color.* != null) try x11.render.FreePicture(sink, render_opcode, id);
    try x11.render.CreateSolidFill(sink, render_opcode, id, .fromRgb24(new_color));
    current_color.* = new_color;
}

comptime {
    std.debug.assert(@sizeOf(GlyphSet) == 8192);
}
pub const GlyphSet = struct {
    const GlyphIndexInt = @typeInfo(TrueType.GlyphIndex).@"enum".tag_type;

    bit_set: std.StaticBitSet(std.math.maxInt(GlyphIndexInt) + 1),

    pub fn initEmpty() GlyphSet {
        return .{ .bit_set = .initEmpty() };
    }
    pub fn isSet(self: *const GlyphSet, glyph_index: TrueType.GlyphIndex) bool {
        return self.bit_set.isSet(@intFromEnum(glyph_index));
    }
    pub fn set(self: *GlyphSet, glyph_index: TrueType.GlyphIndex) void {
        self.bit_set.set(@intFromEnum(glyph_index));
    }
};

const TtfFont = struct {
    cell_width: u16,
    cell_height: u16,
    ascent: i16,
    scale: f32,
    ttf: TrueType,
    render_ext_opcode: u8,
    render_ext_a8_format: x11.render.PictureFormat,
    render_ext_screen_format: x11.render.PictureFormat,
    dst_picture: x11.render.Picture,
    ids: Ids,
    solid_color: ?u24 = null,
    glyph_cache: GlyphCache,

    const GlyphCache = struct {
        set: GlyphSet = .initEmpty(),
        pixels: std.ArrayListUnmanaged(u8) = .empty,

        fn getOrCreate(
            self: *GlyphCache,
            sink: *x11.RequestSink,
            font: *TtfFont,
            glyph_index: TrueType.GlyphIndex,
        ) !?x11.render.Picture {
            const pic = font.ids.glyphPicture(glyph_index);
            if (self.set.isSet(glyph_index)) return pic;

            // Cache miss — rasterize and upload
            self.pixels.clearRetainingCapacity();
            const bitmap = font.ttf.glyphBitmap(std.heap.page_allocator, &self.pixels, glyph_index, font.scale, font.scale) catch return null;
            if (bitmap.width == 0 or bitmap.height == 0) return null;

            // Stream scanlines directly to X11 via PutImageStart/Finish
            const scanline: u18 = std.mem.alignForward(u18, font.cell_width, 4);
            const padded_size: u18 = scanline * font.cell_height;
            const pad_len = try sink.PutImageStart(padded_size, .{
                .format = .z_pixmap,
                .drawable = font.ids.tempPixmap().drawable(),
                .gc_id = font.ids.tempGc(),
                .width = font.cell_width,
                .height = font.cell_height,
                .x = 0,
                .y = 0,
                .depth = .@"8",
            });

            const gx: i16 = bitmap.off_x;
            const gy: i16 = font.ascent + bitmap.off_y;
            const pad_per_line = scanline - font.cell_width;
            for (0..font.cell_height) |cy_usize| {
                const cy: i32 = @intCast(cy_usize);
                const by = cy - gy;
                if (by >= 0 and by < bitmap.height) {
                    const src_row = self.pixels.items[@as(usize, @intCast(by)) * bitmap.width ..][0..bitmap.width];
                    for (0..font.cell_width) |cx_usize| {
                        const cx: i32 = @intCast(cx_usize);
                        const bx = cx - gx;
                        const alpha: u8 = if (bx >= 0 and bx < bitmap.width) src_row[@intCast(bx)] else 0;
                        try sink.writer.writeByte(alpha);
                    }
                } else {
                    try sink.writer.splatByteAll(0, font.cell_width);
                }
                try sink.writer.splatByteAll(0, pad_per_line);
            }
            try sink.PutImageFinish(pad_len);

            try x11.render.CreatePicture(
                sink,
                font.render_ext_opcode,
                pic,
                font.ids.tempPixmap().drawable(),
                font.render_ext_a8_format,
                .{},
            );

            // Picture now references the pixmap data, need fresh pixmap for next glyph
            try sink.FreePixmap(font.ids.tempPixmap());
            try sink.CreatePixmap(font.ids.tempPixmap(), font.ids.window().drawable(), .{
                .depth = .@"8",
                .width = font.cell_width,
                .height = font.cell_height,
            });

            self.set.set(glyph_index);
            return pic;
        }
    };

    fn init(
        ttf: TrueType,
        target_pixel_height: u16,
        sink: *x11.RequestSink,
        ids: Ids,
        render_ext: RenderExt,
        screen: x11.Drawable,
    ) !TtfFont {
        const scale = ttf.scaleForPixelHeight(@floatFromInt(target_pixel_height));
        const vm = ttf.verticalMetrics();
        const ascent_f: f32 = @as(f32, @floatFromInt(vm.ascent)) * scale;
        const descent_f: f32 = @as(f32, @floatFromInt(vm.descent)) * scale;
        const ascent: i16 = @intFromFloat(@round(ascent_f));
        const cell_height: u16 = @intFromFloat(@round(ascent_f - descent_f));

        const m_glyph = ttf.codepointGlyphIndex('m');
        const m_metrics = ttf.glyphHMetrics(m_glyph);
        const cell_width: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(m_metrics.advance_width)) * scale));

        std.log.info("TrueType font: cell={}x{} ascent={}", .{ cell_width, cell_height, ascent });

        // Create temp 8-bit pixmap and GC for uploading alpha masks
        try sink.CreatePixmap(ids.tempPixmap(), screen, .{
            .depth = .@"8",
            .width = cell_width,
            .height = cell_height,
        });
        try sink.CreateGc(ids.tempGc(), ids.tempPixmap().drawable(), .{});

        return .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .ascent = ascent,
            .scale = scale,
            .ttf = ttf,
            .render_ext_opcode = render_ext.opcode,
            .render_ext_a8_format = render_ext.a8_format,
            .render_ext_screen_format = render_ext.screen_format,
            .dst_picture = .none, // set after drawable is known
            .ids = ids,
            .solid_color = null,
            .glyph_cache = .{},
        };
    }

    fn putFgGlyph(self: *TtfFont, sink: *x11.RequestSink, row: u16, col: u16, codepoint: u21, fg: u24) !void {
        const glyph_index = self.ttf.codepointGlyphIndex(codepoint);
        const mask_picture: ?x11.render.Picture = try self.glyph_cache.getOrCreate(sink, self, glyph_index);

        if (mask_picture) |mask_pic| {
            try updateSolidFill(
                sink,
                self.render_ext_opcode,
                self.ids.solidPicture(),
                &self.solid_color,
                fg,
            );
            const px: i16 = std.math.cast(i16, col *| self.cell_width) orelse return;
            const py: i16 = std.math.cast(i16, row *| self.cell_height) orelse return;
            try x11.render.Composite(sink, self.render_ext_opcode, .{
                .picture_operation = .over,
                .src_picture = self.ids.solidPicture(),
                .mask_picture = mask_pic,
                .dst_picture = self.dst_picture,
                .src_x = 0,
                .src_y = 0,
                .mask_x = 0,
                .mask_y = 0,
                .dst_x = px,
                .dst_y = py,
                .width = self.cell_width,
                .height = self.cell_height,
            });
        }
    }
};

fn drainX11Events(
    source: *x11.Source,
    keymap: *const x11.keymap.Full,
    pty: *mostty.Pty,
    term: *vt.Terminal,
    win_width: *u16,
    win_height: *u16,
    backend: *mostty.Backend,
    font_width: u8,
    font_height: u8,
) !bool {
    var damaged = false;
    while (true) {
        const msg_kind = source.readKind() catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => return err,
        };
        switch (msg_kind) {
            .Expose => {
                _ = try source.read2(.Expose);
                damaged = true;
            },
            .ConfigureNotify => {
                const config = try source.read2(.ConfigureNotify);
                if (config.width != win_width.* or config.height != win_height.*) {
                    win_width.* = config.width;
                    win_height.* = config.height;
                    const new_cols = config.width / font_width;
                    const new_rows = config.height / font_height;
                    if (new_cols > 0 and new_rows > 0) {
                        pty.updateWinsz(new_cols, new_rows);
                        if (new_cols != term.cols or new_rows != term.rows) {
                            term.resize(std.heap.page_allocator, new_cols, new_rows) catch |err| {
                                std.log.err("terminal resize failed: {}", .{err});
                            };
                        }
                    }
                    backend.window_state.resizing = true;
                    damaged = true;
                }
            },
            .KeyPress => {
                const event = try source.read2(.KeyPress);
                // Check unshifted keysym for Shift+PageUp/Down scroll
                const unshifted = keymap.getKeysym(event.keycode, .lower) catch |err| switch (err) {
                    error.KeycodeTooSmall => std.debug.panic("keycode {} is too small", .{event.keycode}),
                };
                const screen = term.screens.active;
                if (event.state.shift and unshifted == .kbd_page_up) {
                    screen.scroll(.{ .delta_row = -@as(isize, @intCast(term.rows)) });
                    damaged = true;
                } else if (event.state.shift and unshifted == .kbd_page_down) {
                    screen.scroll(.{ .delta_row = @as(isize, @intCast(term.rows)) });
                    damaged = true;
                } else {
                    const keysym = keymap.getKeysym(event.keycode, event.state.mod()) catch |err| switch (err) {
                        error.KeycodeTooSmall => std.debug.panic("keycode {} is too small", .{event.keycode}),
                    };
                    // Any other key resets scroll to bottom
                    if (!screen.viewportIsBottom()) {
                        screen.scroll(.active);
                        damaged = true;
                    }
                    var keysym_buf: [4]u8 = undefined;
                    const len = if (event.state.control)
                        keysymToCtrlBytes(&keysym_buf, keysym)
                    else
                        keysymToBytes(&keysym_buf, keysym);
                    if (len > 0) {
                        const written = std.posix.write(pty.master, keysym_buf[0..len]) catch |err| std.debug.panic("pty write failed: {}", .{err});
                        if (written != len) std.debug.panic("pty short write: {} of {}", .{ written, len });
                    }
                }
            },
            .ButtonPress => {
                const event = try source.read2(.ButtonPress);
                const scroll_lines: isize = 4;
                const screen = term.screens.active;
                switch (event.button) {
                    4 => { // scroll up
                        screen.scroll(.{ .delta_row = -scroll_lines });
                        damaged = true;
                    },
                    5 => { // scroll down
                        screen.scroll(.{ .delta_row = scroll_lines });
                        damaged = true;
                    },
                    else => {},
                }
            },
            .ButtonRelease => {
                _ = try source.read2(.ButtonRelease);
            },
            .MotionNotify => {
                _ = try source.read2(.MotionNotify);
            },
            .FocusIn => {
                _ = try source.read2(.FocusIn);
                backend.window_state.focused = true;
                damaged = true;
            },
            .FocusOut => {
                _ = try source.read2(.FocusOut);
                backend.window_state.focused = false;
                damaged = true;
            },
            .KeyRelease => _ = try source.read2(.KeyRelease),
            .MappingNotify,
            .ReparentNotify,
            .MapNotify,
            .UnmapNotify,
            .DestroyNotify,
            .GravityNotify,
            .CirculateNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        // Keep draining if the reader has buffered data
        if (source.reader.seek >= source.reader.end) break;
    }
    return damaged;
}

fn resolveCellBg(cell: vt.Cell, page: *const vt.Page, palette: *const vt.color.Palette) u24 {
    var cell_bg: u24 = mostty.default_bg;
    if (cell.style_id != 0) {
        const style = page.styles.get(page.memory, cell.style_id).*;
        cell_bg = mostty.resolveColor(style.bg_color, palette, mostty.default_bg);
        if (style.flags.inverse) {
            cell_bg = mostty.resolveColor(style.fg_color, palette, mostty.default_fg);
        }
    }
    switch (cell.content_tag) {
        .bg_color_palette => cell_bg = mostty.rgbToU24(palette[cell.content.color_palette]),
        .bg_color_rgb => {
            const rgb = cell.content.color_rgb;
            cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
        },
        else => {},
    }
    return cell_bg;
}

fn doRender(
    sink: *x11.RequestSink,
    window_id: x11.Window,
    gc: x11.GraphicsContext,
    depth: x11.Depth,
    font_width: u8,
    font_height: u8,
    term: *vt.Terminal,
    gc_state: *Gc,
    visible_rows: u16,
    offscreen_pixmap: x11.Pixmap,
    win_width: u16,
    win_height: u16,
    dpi_scale: f32,
    ttf_font: *TtfFont,
    window_state: mostty.WindowState,
) error{WriteFailed}!void {
    try x11.render.FillRectangles(sink, ttf_font.render_ext_opcode, .{
        .picture_operation = .src,
        .dst_picture = ttf_font.dst_picture,
        .color = .fromRgb24(mostty.default_bg),
        .rects = .init(@ptrCast(&x11.Rectangle{ .x = 0, .y = 0, .width = win_width, .height = win_height }), 1),
    });

    const screen = term.screens.active;
    const palette = &term.colors.palette.current;

    // Pass 1: Background rectangles
    // Batch adjacent cells with the same non-default bg color into single FillRectangles calls.
    {
        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var screen_row: u16 = 0;
        while (row_it.next()) |row_pin| : (screen_row += 1) {
            if (screen_row >= visible_rows) break;

            const page = &row_pin.node.data;
            const cells = page.getCells(row_pin.rowAndCell().row);
            const py: i16 = std.math.cast(i16, screen_row *| ttf_font.cell_height) orelse continue;

            var run_start: u16 = 0;
            var run_width: u16 = 0;
            var run_bg: u24 = mostty.default_bg;

            for (cells, 0..) |cell, col_idx| {
                const cell_bg = resolveCellBg(cell, page, palette);
                const col: u16 = @intCast(col_idx);

                if (cell_bg == run_bg and run_width > 0) {
                    run_width += ttf_font.cell_width;
                    continue;
                }

                // Flush previous run if non-default
                if (run_bg != mostty.default_bg and run_width > 0) {
                    const px: i16 = std.math.cast(i16, run_start *| ttf_font.cell_width) orelse {
                        run_start = col;
                        run_width = ttf_font.cell_width;
                        run_bg = cell_bg;
                        continue;
                    };
                    try x11.render.FillRectangles(sink, ttf_font.render_ext_opcode, .{
                        .picture_operation = .src,
                        .dst_picture = ttf_font.dst_picture,
                        .color = .fromRgb24(run_bg),
                        .rects = .init(@ptrCast(&x11.Rectangle{ .x = px, .y = py, .width = run_width, .height = ttf_font.cell_height }), 1),
                    });
                }

                run_start = col;
                run_width = ttf_font.cell_width;
                run_bg = cell_bg;
            }

            // Flush final run
            if (run_bg != mostty.default_bg and run_width > 0) {
                if (std.math.cast(i16, run_start *| ttf_font.cell_width)) |px| {
                    try x11.render.FillRectangles(sink, ttf_font.render_ext_opcode, .{
                        .picture_operation = .src,
                        .dst_picture = ttf_font.dst_picture,
                        .color = .fromRgb24(run_bg),
                        .rects = .init(@ptrCast(&x11.Rectangle{ .x = px, .y = py, .width = run_width, .height = ttf_font.cell_height }), 1),
                    });
                }
            }
        }
    }

    // Cursor background (drawn between bg and fg passes so text composites on top)
    if (screen.viewportIsBottom() and term.modes.get(.cursor_visible)) {
        const cursor_x = screen.cursor.x;
        const cursor_y = screen.cursor.y;
        if (cursor_y < visible_rows and window_state.focused) {
            const cursor_screen_row: u16 = @intCast(cursor_y);
            if (std.math.cast(i16, cursor_x *| ttf_font.cell_width)) |px| {
                const py: i16 = std.math.cast(i16, cursor_screen_row *| ttf_font.cell_height) orelse return;
                try x11.render.FillRectangles(sink, ttf_font.render_ext_opcode, .{
                    .picture_operation = .src,
                    .dst_picture = ttf_font.dst_picture,
                    .color = .fromRgb24(mostty.default_fg),
                    .rects = .init(@ptrCast(&x11.Rectangle{ .x = px, .y = py, .width = ttf_font.cell_width, .height = ttf_font.cell_height }), 1),
                });
            }
        }
    }

    // Pass 2: Foreground glyphs
    {
        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var screen_row: u16 = 0;
        while (row_it.next()) |row_pin| : (screen_row += 1) {
            if (screen_row >= visible_rows) break;

            const page = &row_pin.node.data;
            const cells = page.getCells(row_pin.rowAndCell().row);

            for (cells, 0..) |cell, col_idx| {
                if (cell.wide == .spacer_tail) continue;

                const raw_codepoint: u21 = switch (cell.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.content.codepoint,
                    .bg_color_palette, .bg_color_rgb => continue,
                };
                const codepoint: u21 = if (raw_codepoint == 0) continue else raw_codepoint;

                var cell_fg: u24 = mostty.default_fg;

                if (cell.style_id != 0) {
                    const style = page.styles.get(page.memory, cell.style_id).*;
                    cell_fg = mostty.resolveColor(style.fg_color, palette, mostty.default_fg);
                    if (style.flags.inverse) {
                        cell_fg = mostty.resolveColor(style.bg_color, palette, mostty.default_bg);
                    }
                }

                try ttf_font.putFgGlyph(sink, screen_row, @intCast(col_idx), codepoint, cell_fg);
            }
        }
    }

    // Cursor foreground
    if (screen.viewportIsBottom() and term.modes.get(.cursor_visible)) {
        const cursor_x = screen.cursor.x;
        const cursor_y = screen.cursor.y;
        if (cursor_y < visible_rows) {
            const cursor_screen_row: u16 = @intCast(cursor_y);
            if (window_state.focused) {
                // Render the character under the cursor with inverted colors
                const cursor_pin = screen.pages.getCell(.{ .viewport = .{ .x = cursor_x, .y = cursor_y } });
                if (cursor_pin) |pin| {
                    const cursor_cell = pin.cell.*;
                    const raw_cp: u21 = switch (cursor_cell.content_tag) {
                        .codepoint, .codepoint_grapheme => cursor_cell.content.codepoint,
                        .bg_color_palette, .bg_color_rgb => ' ',
                    };
                    const cp: u21 = if (raw_cp == 0) ' ' else raw_cp;
                    if (cp != ' ') {
                        try ttf_font.putFgGlyph(sink, cursor_screen_row, cursor_x, cp, mostty.default_bg);
                    }
                }
            } else if (std.math.cast(i16, cursor_x *| font_width)) |px| {
                if (std.math.cast(i16, cursor_screen_row *| font_height)) |py| {
                    try gc_state.update(sink, gc, depth, .{ .fg = mostty.default_fg });
                    try sink.PolyRectangle(offscreen_pixmap.drawable(), gc, .initAssume(&.{
                        .{ .x = px, .y = py, .width = font_width -| 1, .height = font_height -| 1 },
                    }));
                }
            }
        }
    }

    // Draw scrollbar
    const sb = screen.pages.scrollbar();
    if (sb.total > sb.len) {
        const scrollbar_width: u16 = @intFromFloat(@round(8.0 * dpi_scale));
        const scrollbar_x: i16 = @intCast(win_width -| scrollbar_width);

        // Track height proportional to visible/total ratio
        const min_track_height: u16 = @intFromFloat(@round(20.0 * dpi_scale));
        const track_height: u16 = @max(min_track_height, @as(u16, @intFromFloat(
            @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * @as(f32, @floatFromInt(win_height)),
        )));

        // Track position based on viewport offset
        const max_offset = sb.total - sb.len;
        const track_y: i16 = @intCast(@as(u16, @intFromFloat(
            @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * @as(f32, @floatFromInt(win_height -| track_height)),
        )));

        try gc_state.update(sink, gc, depth, .{ .fg = 0x666666 });
        try sink.PolyFillRectangle(offscreen_pixmap.drawable(), gc, .initAssume(&.{
            .{ .x = scrollbar_x, .y = track_y, .width = scrollbar_width, .height = track_height },
        }));
    }

    // Draw resize overlay (e.g. "80x25") centered on screen
    if (window_state.resizing) {
        var overlay_buf: [20]u8 = undefined;
        const overlay_text = std.fmt.bufPrint(&overlay_buf, "{}x{}", .{ term.cols, term.rows }) catch unreachable;
        const text_len: u16 = @intCast(overlay_text.len);
        const visible_cols: u16 = win_width / font_width;
        const text_col: u16 = (visible_cols -| text_len) / 2;
        const text_row: u16 = visible_rows / 2;
        const pad_x: u16 = font_width;
        const pad_y: u16 = font_height / 2;
        const box_x: i16 = std.math.cast(i16, text_col *| font_width -| pad_x) orelse return;
        const box_y: i16 = std.math.cast(i16, text_row *| font_height -| pad_y) orelse return;
        const box_width: u16 = text_len * font_width + pad_x * 2;
        const box_height: u16 = font_height + pad_y * 2;

        try gc_state.update(sink, gc, depth, .{ .fg = 0x333333 });
        try sink.PolyFillRectangle(offscreen_pixmap.drawable(), gc, .initAssume(&.{
            .{ .x = box_x, .y = box_y, .width = box_width, .height = box_height },
        }));
        for (overlay_text, 0..) |ch, i| {
            try ttf_font.putFgGlyph(sink, text_row, text_col + @as(u16, @intCast(i)), ch, 0xffffff);
        }
    }

    // Swap: CopyArea offscreen pixmap to window
    try sink.CopyArea(.{
        .src_drawable = offscreen_pixmap.drawable(),
        .dst_drawable = window_id.drawable(),
        .gc = gc,
        .src_x = 0,
        .src_y = 0,
        .dst_x = 0,
        .dst_y = 0,
        .width = win_width,
        .height = win_height,
    });
}

fn keysymToCtrlBytes(buf: *[4]u8, keysym: x11.charset.Combined) u3 {
    const charset = keysym.charset();
    const code = keysym.code();
    if (charset == .latin1) {
        switch (code) {
            // Ctrl+letter: map a-z to control codes 1-26
            'a'...'z' => {
                buf[0] = code & 0x1f;
                return 1;
            },
            // Ctrl+special characters that produce control codes
            // Includes A-Z (same as lowercase) plus @[\]^_
            // e.g. Ctrl+@ = 0x00, Ctrl+[ = 0x1b, Ctrl+\ = 0x1c, Ctrl+] = 0x1d, Ctrl+^ = 0x1e, Ctrl+_ = 0x1f
            '@'...'_' => {
                buf[0] = code & 0x1f;
                return 1;
            },
            else => {},
        }
    }
    // For keys without a Ctrl mapping (e.g. function keys), fall through to normal handling
    return keysymToBytes(buf, keysym);
}

fn keysymToBytes(buf: *[4]u8, keysym: x11.charset.Combined) u3 {
    const charset = keysym.charset();
    const code = keysym.code();
    switch (charset) {
        .latin1 => switch (code) {
            0...126, 128...255 => {
                buf[0] = code;
                return 1;
            },
            127 => std.debug.panic("unhandled latin1 code: {}", .{code}),
        },
        .keyboard => {
            const bytes: []const u8 = switch (keysym) {
                .kbd_return_enter, .kbd_keypad_enter => "\r",
                .kbd_backspace_back_space_back_char => "\x7f",
                .kbd_tab => "\t",
                .kbd_escape => "\x1b",
                .kbd_delete_rubout => "\x1b[3~",
                .kbd_up => "\x1b[A",
                .kbd_down => "\x1b[B",
                .kbd_right => "\x1b[C",
                .kbd_left => "\x1b[D",
                .kbd_home => "\x1b[H",
                .kbd_end_eol => "\x1b[F",
                .kbd_page_up => "\x1b[5~",
                .kbd_page_down => "\x1b[6~",
                .kbd_insert_insert_here => "\x1b[2~",
                // Modifier-only keys produce no bytes
                .kbd_left_shift,
                .kbd_right_shift,
                .kbd_left_control,
                .kbd_right_control,
                .kbd_caps_lock,
                .kbd_shift_lock,
                .kbd_left_meta,
                .kbd_right_meta,
                .kbd_left_alt,
                .kbd_right_alt,
                .kbd_left_super,
                .kbd_right_super,
                .kbd_left_hyper,
                .kbd_right_hyper,
                .kbd_num_lock,
                .kbd_scroll_lock,
                => "",
                else => std.debug.panic("unhandled keyboard keysym: code={}", .{code}),
            };
            const len: u3 = @intCast(bytes.len);
            @memcpy(buf[0..len], bytes);
            return len;
        },
        else => {
            if (keysymToUnicode(charset, code)) |codepoint| {
                const len = std.unicode.utf8Encode(codepoint, buf) catch unreachable;
                return @intCast(len);
            }
            std.log.warn("unhandled keysym: charset={} code={}", .{ charset, code });
            return 0;
        },
    }
}

/// Map X11 keysym charset+code to a Unicode codepoint.
/// Based on the standard X.org keysym-to-unicode mapping (keysym2ucs.c).
fn keysymToUnicode(charset: x11.charset.Charset, code: u8) ?u21 {
    return switch (charset) {
        .greek => greekToUnicode(code),
        else => null,
    };
}

// X11 Greek keysym codes to Unicode codepoints.
// The mapping is not a simple offset due to gaps in both X11 and Unicode.
fn greekToUnicode(code: u8) ?u21 {
    return switch (code) {
        // Accented capitals
        161 => 0x0386, // Ά
        162 => 0x0388, // Έ
        163 => 0x0389, // Ή
        164 => 0x038A, // Ί
        165 => 0x03AA, // Ϊ
        167 => 0x038C, // Ό
        168 => 0x038E, // Ύ
        169 => 0x03AB, // Ϋ
        171 => 0x038F, // Ώ
        174 => 0x0385, // ΅
        175 => 0x2015, // ―
        // Accented lowercase
        177 => 0x03AC, // ά
        178 => 0x03AD, // έ
        179 => 0x03AE, // ή
        180 => 0x03AF, // ί
        181 => 0x03CA, // ϊ
        182 => 0x0390, // ΐ
        183 => 0x03CC, // ό
        184 => 0x03CD, // ύ
        185 => 0x03CB, // ϋ
        186 => 0x03B0, // ΰ
        187 => 0x03CE, // ώ
        // Uppercase Alpha-Rho (no gap)
        193...209 => 0x0391 + @as(u21, code) - 193,
        // Uppercase Sigma (skips Unicode 0x03A2 which is reserved)
        210 => 0x03A3,
        // Uppercase Tau-Omega
        212...217 => 0x03A4 + @as(u21, code) - 212,
        // Lowercase alpha-rho
        225...241 => 0x03B1 + @as(u21, code) - 225,
        // Lowercase sigma, final sigma
        242 => 0x03C3,
        243 => 0x03C2,
        // Lowercase tau-omega
        244...249 => 0x03C4 + @as(u21, code) - 244,
        else => null,
    };
}

fn readDpiScale(source: *x11.Source, value_format: u8) f32 {
    const prop_header = source.read3Header(.GetProperty) catch |err|
        std.debug.panic("failed to read GetProperty reply: {}", .{err});
    const result: f32 = blk: {
        if (value_format == 0) {
            // Property not found, use default scale
            std.log.info("RESOURCE_MANAGER property not found, defaulting to dpi_scale=1.0", .{});
            break :blk 1.0;
        }
        if (value_format != 8) {
            std.debug.panic("Xft.dpi unexpected format {}", .{value_format});
        }
        if (prop_header.value_size_in_format_units == 0) {
            std.log.info("RESOURCE_MANAGER property is empty, defaulting to dpi_scale=1.0", .{});
            break :blk 1.0;
        }
        const value_len: u35 = prop_header.value_size_in_format_units;
        const data = source.takeReply(value_len) catch |err|
            std.debug.panic("failed to take GetProperty reply data: {}", .{err});
        if (parseXftDpi(data)) |xft_dpi| {
            const scale = xft_dpi / 96.0;
            std.log.info("Xft.dpi={d:.2} scale={d:.2}", .{ xft_dpi, scale });
            break :blk scale;
        }
        std.log.info("Xft.dpi not found in RESOURCE_MANAGER, defaulting to dpi_scale=1.0", .{});
        break :blk 1.0;
    };
    source.discardRemaining() catch |err|
        std.debug.panic("failed to discard remaining GetProperty data: {}", .{err});
    return result;
}

fn parseXftDpi(data: []const u8) ?f32 {
    const prefix = "Xft.dpi:";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const value_str = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
            return std.fmt.parseFloat(f32, value_str) catch null;
        }
    }
    return null;
}

const std = @import("std");
const x11 = @import("x11");
const mosttyicon = @import("mosttyicon");
const vt = @import("vt");
const mostty = @import("mostty.zig");
const Cmdline = @import("Cmdline.zig");
const TrueType = @import("TrueType");
const fontconfig = @import("posix/fontconfig.zig");
