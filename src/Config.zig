const Config = @This();

pub const Launcher = struct {
    label: []const u8,
    command_line: []const u8,
    working_directory: []const u8, // empty = inherit parent
};

// One contiguous range of codepoints that should resolve to a specific font
// family during DirectWrite fallback (i.e. when the preferred family for the
// active text format doesn't cover the codepoint). `range_end` is inclusive;
// equal to `range_start` for a single-codepoint mapping. Ghostty's
// `font-codepoint-map = U+A-U+B[,U+C-U+D]=Family` syntax expands into one
// entry per range, all sharing the same family.
pub const CodepointMap = struct {
    range_start: u21,
    range_end: u21,
    family: []const u8,
};

// Per-style permission to let DirectWrite synthesize a missing face (algorithmic
// bold / oblique) when the chosen family lacks a real one. Default: all true,
// matching Ghostty. `false` for a style means: if the family has no real face,
// fall back to the regular text format (no synthesis).
pub const SyntheticStyle = struct {
    bold: bool = true,
    italic: bool = true,
    bold_italic: bool = true,
};

// Ghostty's `font-style*` value. `.default` = no override (current
// synthesis/family logic applies). `.disabled` = explicitly forbid using a
// real face for this style; combined with `font-synthetic-style = no-X` this
// forces fall-through to the regular text format. `.named` = pick the named
// face within the chosen family, using its real weight/style/stretch.
pub const FontStyle = union(enum) {
    default,
    disabled,
    named: []const u8,
};

const default_palette: [256]vt.color.RGB = palette: {
    var p = vt.color.default;
    p[0] = u24ToRgb(0x000000);
    p[1] = u24ToRgb(0xff0000);
    p[2] = u24ToRgb(0x00ff00);
    p[3] = u24ToRgb(0xffff00);
    p[4] = u24ToRgb(0x0000ff);
    p[5] = u24ToRgb(0xff00ff);
    p[6] = u24ToRgb(0x00ffff);
    p[7] = u24ToRgb(0xc0c0c0);
    p[8] = u24ToRgb(0x808080);
    p[9] = u24ToRgb(0xff0000);
    p[10] = u24ToRgb(0x00ff00);
    p[11] = u24ToRgb(0xffff00);
    p[12] = u24ToRgb(0x0000ff);
    p[13] = u24ToRgb(0xff00ff);
    p[14] = u24ToRgb(0x00ffff);
    p[15] = u24ToRgb(0xffffff);
    break :palette p;
};

// Resolved theme/color state. Pure value type (no arena-backed pointers) so it
// survives the Config arena being freed on hot-reload, and can be copied into
// the renderer / each tab's vt color state cheaply. The default palette keeps
// vt's xterm 256-color cube/ramp for 16-255, but uses saturated ANSI 0-15 so
// 4-bit SGR colors match common terminal compatibility screenshots. Themes and
// explicit `palette = N=#RRGGBB` entries still override these values.
pub const ThemeColors = struct {
    palette: [256]vt.color.RGB = default_palette,
    foreground: u24 = 0xc8c4d0,
    background: u24 = 0x2a2a2a,
    cursor_color: ?u24 = null,
    cursor_text: ?u24 = null,
    selection_background: ?u24 = null,
    selection_foreground: ?u24 = null,

    // Seed a freshly-created terminal's dynamic colors from this theme. cursor
    // is left unset when the theme has no cursor-color (renderer then inverts).
    pub fn applyToNewTerminal(self: *const ThemeColors, term: *vt.Terminal) void {
        term.colors.foreground = .init(u24ToRgb(self.foreground));
        term.colors.background = .init(u24ToRgb(self.background));
        if (self.cursor_color) |c| term.colors.cursor = .init(u24ToRgb(c));
        term.colors.palette = .init(self.palette);
    }

    // Re-baseline an existing terminal's colors on hot-reload, preserving any
    // genuine OSC override an app set at runtime.
    pub fn rebaseTerminal(self: *const ThemeColors, term: *vt.Terminal) void {
        rebaseDynamicRGB(&term.colors.foreground, u24ToRgb(self.foreground));
        rebaseDynamicRGB(&term.colors.background, u24ToRgb(self.background));
        rebaseDynamicRGB(&term.colors.cursor, if (self.cursor_color) |c| u24ToRgb(c) else null);
        term.colors.palette.changeDefault(self.palette);
    }
};

// Updates a DynamicRGB's default while preserving a real OSC override. vt's
// reset() sets override = old default, so "override == old default" (or null)
// means the app hasn't truly overridden the color and it should follow the new
// theme; a different override is a live app choice and is kept.
fn rebaseDynamicRGB(c: *vt.color.DynamicRGB, new_default: ?vt.color.RGB) void {
    const unmodified = c.override == null or
        (c.default != null and std.meta.eql(c.override.?, c.default.?));
    c.default = new_default;
    if (unmodified) c.override = null;
}

font_families: []const []const u8 = &.{},
// Per-style primary family overrides. Empty -> inherit the regular family
// (one of font_families or the renderer's built-in default). Each is a single
// family name, not a fallback list — fallback comes from font_families.
font_family_bold: []const u8 = &.{},
font_family_italic: []const u8 = &.{},
font_family_bold_italic: []const u8 = &.{},
font_synthetic_style: SyntheticStyle = .{},
font_style: FontStyle = .default,
font_style_bold: FontStyle = .default,
font_style_italic: FontStyle = .default,
font_style_bold_italic: FontStyle = .default,
font_size_pt: ?f32 = null,
font_codepoint_maps: []const CodepointMap = &.{},
launchers: []const Launcher = &.{},
theme: ThemeColors = .{},
// Default cell background alpha (0..1). Anything <1 lets the DWM blur-behind
// show through under non-themed cells; cells with an explicit `bg_color_*`
// stay opaque so highlighted regions remain readable.
background_opacity: f32 = 0.94,

arena: ?std.heap.ArenaAllocator = null,

// The default config location, %LOCALAPPDATA%/mostty/config. Returns null when
// LOCALAPPDATA is unset. Caller owns the returned slice.
pub fn defaultPath(gpa: std.mem.Allocator) ?[]const u8 {
    const localappdata = std.process.getEnvVarOwned(gpa, "LOCALAPPDATA") catch return null;
    defer gpa.free(localappdata);
    return std.fs.path.join(gpa, &.{ localappdata, "mostty", "config" }) catch oom();
}

pub fn loadDefault(gpa: std.mem.Allocator) Config {
    const path = defaultPath(gpa) orelse {
        std.log.info("config: LOCALAPPDATA unavailable; using defaults", .{});
        return .{};
    };
    defer gpa.free(path);

    return loadPath(gpa, path);
}

pub const ReloadError = error{ReadFailed};

// Like loadDefault, but distinguishes a transient read failure (config locked
// while an editor is mid-save) from "file absent", so the live-reload path can
// keep the previous config instead of clobbering it with defaults. A genuinely
// missing file still yields defaults (the user deleting the config legitimately
// means "all defaults").
pub fn loadDefaultChecked(gpa: std.mem.Allocator) ReloadError!Config {
    const path = defaultPath(gpa) orelse return .{};
    defer gpa.free(path);
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return error.ReadFailed,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, path);
}

pub fn loadPath(gpa: std.mem.Allocator, path: []const u8) Config {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("config: '{s}' not found; using defaults", .{path});
            return .{};
        },
        else => {
            std.log.warn("config: read '{s}' failed: {s}; using defaults", .{ path, @errorName(err) });
            return .{};
        },
    };
    defer gpa.free(bytes);

    std.log.info("config: loaded '{s}'", .{path});
    return parse(gpa, bytes, path);
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8, source_name: []const u8) Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    var families: std.ArrayListUnmanaged([]const u8) = .empty;
    var family_bold: []const u8 = &.{};
    var family_italic: []const u8 = &.{};
    var family_bold_italic: []const u8 = &.{};
    var synthetic: SyntheticStyle = .{};
    var style_regular: FontStyle = .default;
    var style_bold: FontStyle = .default;
    var style_italic: FontStyle = .default;
    var style_bold_italic: FontStyle = .default;
    var font_size_pt: ?f32 = null;
    var background_opacity: f32 = 0.94;
    var codepoint_maps: std.ArrayListUnmanaged(CodepointMap) = .empty;
    var launchers: std.ArrayListUnmanaged(Launcher) = .empty;
    var theme: ThemeColors = .{};

    // Strip UTF-8 BOM if present (Notepad and other Windows editors add one).
    const input = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;

    // Phase 1: load any `theme = X` files as the color baseline first, so the
    // config's own explicit color keys (phase 2) always win regardless of line
    // order — matching Ghostty's "theme provides defaults, config overrides".
    {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (!std.mem.eql(u8, key, "theme")) continue;
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            applyThemeFile(gpa, &theme, value);
        }
    }

    // Phase 2: everything else. Color keys overwrite the theme baseline.
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.log.warn("config: {s}:{}: missing '=' in '{s}'", .{ source_name, line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "theme")) {
            // Handled in phase 1.
        } else if (applyColorKey(&theme, key, value)) {
            // Recognized color key (palette/background/foreground/cursor-*/selection-*).
        } else if (isKnownUnsupportedKey(key)) {
            // Known Ghostty key with no mostty equivalent: ignore silently so
            // ported configs don't spam warnings.
        } else if (std.mem.eql(u8, key, "font-family")) {
            var vit = std.mem.splitScalar(u8, value, ',');
            while (vit.next()) |v| {
                const name = std.mem.trim(u8, v, " \t");
                if (name.len == 0) continue;
                const owned = a.dupe(u8, name) catch oom();
                families.append(a, owned) catch oom();
            }
        } else if (std.mem.eql(u8, key, "font-family-bold")) {
            family_bold = a.dupe(u8, value) catch oom();
        } else if (std.mem.eql(u8, key, "font-family-italic")) {
            family_italic = a.dupe(u8, value) catch oom();
        } else if (std.mem.eql(u8, key, "font-family-bold-italic")) {
            family_bold_italic = a.dupe(u8, value) catch oom();
        } else if (std.mem.eql(u8, key, "font-synthetic-style")) {
            synthetic = parseSyntheticStyle(value) orelse {
                std.log.warn("config: {s}:{}: invalid font-synthetic-style '{s}'", .{ source_name, line_no, value });
                continue;
            };
        } else if (std.mem.eql(u8, key, "font-style")) {
            style_regular = parseFontStyle(a, value);
        } else if (std.mem.eql(u8, key, "font-style-bold")) {
            style_bold = parseFontStyle(a, value);
        } else if (std.mem.eql(u8, key, "font-style-italic")) {
            style_italic = parseFontStyle(a, value);
        } else if (std.mem.eql(u8, key, "font-style-bold-italic")) {
            style_bold_italic = parseFontStyle(a, value);
        } else if (std.mem.eql(u8, key, "font-size")) {
            const n = std.fmt.parseFloat(f32, value) catch {
                std.log.warn("config: {s}:{}: invalid font-size '{s}'", .{ source_name, line_no, value });
                continue;
            };
            if (!(n > 0)) {
                std.log.warn("config: {s}:{}: font-size must be positive (got {d})", .{ source_name, line_no, n });
                continue;
            }
            font_size_pt = n;
        } else if (std.mem.eql(u8, key, "background-opacity")) {
            const n = std.fmt.parseFloat(f32, value) catch {
                std.log.warn("config: {s}:{}: invalid background-opacity '{s}'", .{ source_name, line_no, value });
                continue;
            };
            if (!(n >= 0.0 and n <= 1.0)) {
                std.log.warn("config: {s}:{}: background-opacity must be in [0,1] (got {d})", .{ source_name, line_no, n });
                continue;
            }
            background_opacity = n;
        } else if (std.mem.eql(u8, key, "font-codepoint-map")) {
            parseCodepointMap(a, value, &codepoint_maps) catch {
                std.log.warn("config: {s}:{}: invalid font-codepoint-map '{s}'", .{ source_name, line_no, value });
            };
        } else if (std.mem.eql(u8, key, "launcher")) {
            const launcher = parseLauncher(a, value) orelse {
                std.log.warn("config: {s}:{}: invalid launcher '{s}'", .{ source_name, line_no, value });
                continue;
            };
            launchers.append(a, launcher) catch oom();
        } else {
            std.log.warn("config: {s}:{}: unknown key '{s}'", .{ source_name, line_no, key });
        }
    }

    const families_slice = families.toOwnedSlice(a) catch oom();
    const codepoint_maps_slice = codepoint_maps.toOwnedSlice(a) catch oom();
    const launchers_slice = launchers.toOwnedSlice(a) catch oom();
    return .{
        .font_families = families_slice,
        .font_family_bold = family_bold,
        .font_family_italic = family_italic,
        .font_family_bold_italic = family_bold_italic,
        .font_synthetic_style = synthetic,
        .font_style = style_regular,
        .font_style_bold = style_bold,
        .font_style_italic = style_italic,
        .font_style_bold_italic = style_bold_italic,
        .font_size_pt = font_size_pt,
        .font_codepoint_maps = codepoint_maps_slice,
        .launchers = launchers_slice,
        .theme = theme,
        .background_opacity = background_opacity,
        .arena = arena,
    };
}

// Empty value is treated as `.default` so users can clear a previously-set
// key on hot-reload by writing `font-style = `. Anything else (including
// `true`) is taken as a face name — Ghostty's only special value is `false`.
fn parseFontStyle(a: std.mem.Allocator, value: []const u8) FontStyle {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return .default;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return .disabled;
    return .{ .named = a.dupe(u8, trimmed) catch oom() };
}

// Ghostty syntax: `true`/`false` for all-on/all-off, or a comma-separated
// list of negations subtracted from the all-on baseline:
// `no-bold`, `no-italic`, `no-bold-italic` (combine with commas).
// Returns null on any unrecognized token — caller logs and discards the line.
fn parseSyntheticStyle(value: []const u8) ?SyntheticStyle {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "yes")) {
        return .{ .bold = true, .italic = true, .bold_italic = true };
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "no")) {
        return .{ .bold = false, .italic = false, .bold_italic = false };
    }

    var out: SyntheticStyle = .{};
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(tok, "no-bold")) {
            out.bold = false;
        } else if (std.ascii.eqlIgnoreCase(tok, "no-italic")) {
            out.italic = false;
        } else if (std.ascii.eqlIgnoreCase(tok, "no-bold-italic")) {
            out.bold_italic = false;
        } else return null;
    }
    return out;
}

// Parses `<ranges>=<family>` where ranges is comma-separated
// `U+HEX[-U+HEX]`. Each range becomes a CodepointMap entry; all entries on the
// line share the same (duped) family string. Returns `error.Invalid` on any
// syntactic problem — caller logs and discards the line.
fn parseCodepointMap(
    a: std.mem.Allocator,
    value: []const u8,
    out: *std.ArrayListUnmanaged(CodepointMap),
) error{Invalid}!void {
    const eq = std.mem.lastIndexOfScalar(u8, value, '=') orelse return error.Invalid;
    const ranges_part = std.mem.trim(u8, value[0..eq], " \t");
    const family_part = std.mem.trim(u8, value[eq + 1 ..], " \t");
    if (ranges_part.len == 0 or family_part.len == 0) return error.Invalid;
    if (!std.unicode.utf8ValidateSlice(family_part)) return error.Invalid;

    const family_dup = a.dupe(u8, family_part) catch oom();

    // Stage entries locally so a malformed segment mid-line rejects the whole
    // line atomically — partial application would leave a half-mapped range.
    var staged: std.ArrayListUnmanaged(CodepointMap) = .empty;
    defer staged.deinit(a);

    var rit = std.mem.splitScalar(u8, ranges_part, ',');
    while (rit.next()) |raw_range| {
        const range = std.mem.trim(u8, raw_range, " \t");
        if (range.len == 0) return error.Invalid;
        const dash = std.mem.indexOfScalar(u8, range, '-');
        const start = parseCodepoint(if (dash) |d| range[0..d] else range) orelse return error.Invalid;
        const end = if (dash) |d|
            parseCodepoint(range[d + 1 ..]) orelse return error.Invalid
        else
            start;
        if (end < start) return error.Invalid;
        staged.append(a, .{ .range_start = start, .range_end = end, .family = family_dup }) catch oom();
    }
    if (staged.items.len == 0) return error.Invalid;
    out.appendSlice(a, staged.items) catch oom();
}

// Accepts `U+HEX`, `u+HEX`, or bare `HEX` (Ghostty's reference uses the
// `U+` form exclusively; bare hex is a pragmatic concession for hand-edited
// configs). Caps at 0x10FFFF — the Unicode scalar maximum.
fn parseCodepoint(raw: []const u8) ?u21 {
    const s = std.mem.trim(u8, raw, " \t");
    const hex = if (s.len >= 2 and (s[0] == 'U' or s[0] == 'u') and s[1] == '+') s[2..] else s;
    if (hex.len == 0) return null;
    const v = std.fmt.parseInt(u32, hex, 16) catch return null;
    if (v > 0x10FFFF) return null;
    return @intCast(v);
}

// Parses `#RRGGBB` / `RRGGBB` into a packed 0xRRGGBB. Named X11 colors are not
// supported (theme files are all hex).
fn parseHex(value: []const u8) ?u24 {
    const v = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
    if (v.len != 6) return null;
    return std.fmt.parseInt(u24, v, 16) catch null;
}

fn u24ToRgb(c: u24) vt.color.RGB {
    return .{
        .r = @intCast((c >> 16) & 0xFF),
        .g = @intCast((c >> 8) & 0xFF),
        .b = @intCast(c & 0xFF),
    };
}

// Applies one color key to `theme`. Returns true if `key` was a recognized
// color key (even when the value was malformed — it still belongs to the color
// namespace and must not fall through to the unknown-key warning).
fn applyColorKey(theme: *ThemeColors, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "palette")) {
        // value is `N=#hex`.
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return true;
        const idx = std.fmt.parseInt(u8, std.mem.trim(u8, value[0..eq], " \t"), 10) catch return true;
        const rgb = parseHex(std.mem.trim(u8, value[eq + 1 ..], " \t")) orelse return true;
        theme.palette[idx] = u24ToRgb(rgb);
        return true;
    }
    const dst: *?u24 = if (std.mem.eql(u8, key, "cursor-color"))
        &theme.cursor_color
    else if (std.mem.eql(u8, key, "cursor-text"))
        &theme.cursor_text
    else if (std.mem.eql(u8, key, "selection-background"))
        &theme.selection_background
    else if (std.mem.eql(u8, key, "selection-foreground"))
        &theme.selection_foreground
    else {
        // foreground/background are non-optional u24.
        if (std.mem.eql(u8, key, "foreground")) {
            if (parseHex(value)) |c| theme.foreground = c;
            return true;
        }
        if (std.mem.eql(u8, key, "background")) {
            if (parseHex(value)) |c| theme.background = c;
            return true;
        }
        return false;
    };
    if (parseHex(value)) |c| dst.* = c;
    return true;
}

// Ghostty theme/color-doc keys that mostty has no feature for. Ignored silently
// (vs the warn for genuinely unknown keys, which catches user typos).
fn isKnownUnsupportedKey(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "split-")) return true;
    if (std.mem.startsWith(u8, key, "search-")) return true;
    if (std.mem.startsWith(u8, key, "window-titlebar-")) return true;
    return std.mem.eql(u8, key, "unfocused-split-fill") or
        std.mem.eql(u8, key, "palette-generate") or
        std.mem.eql(u8, key, "palette-harmonious") or
        std.mem.eql(u8, key, "config-file") or
        // macOS-only / shaping-pipeline keys: no Windows equivalent in mostty.
        std.mem.eql(u8, key, "font-thicken") or
        std.mem.eql(u8, key, "font-thicken-strength") or
        std.mem.eql(u8, key, "font-shaping-break");
}

// Resolves `theme = X` to a file and folds its color keys into `theme` as the
// baseline. Handles Ghostty's `light:A, dark:B` syntax (mostty is a dark-chrome
// app, so the dark variant wins). Does NOT recurse: `theme`/`config-file` keys
// inside a theme file are ignored.
fn applyThemeFile(gpa: std.mem.Allocator, theme: *ThemeColors, value: []const u8) void {
    const name = resolveThemeName(value, systemPrefersDark());
    if (name.len == 0) return;

    const path: []const u8 = if (std.fs.path.isAbsolute(name))
        gpa.dupe(u8, name) catch oom()
    else
        findThemeFile(gpa, name) orelse {
            std.log.warn("config: theme '{s}' not found in %LOCALAPPDATA%/mostty/themes or <exe>/themes", .{name});
            return;
        };
    defer gpa.free(path);

    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| {
        std.log.warn("config: theme read '{s}' failed: {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(bytes);

    const input = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, key, "theme")) continue; // no recursion
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        _ = applyColorKey(theme, key, v); // ignore non-color keys silently in theme files
    }
}

// Extracts the effective theme name from a `theme` value. For Ghostty's variant
// form `light:A, dark:B` (order-independent) it picks the variant matching the
// OS light/dark mode (`prefer_dark`), falling back to the other variant if only
// one is given. A segment is only treated as a variant when it exactly starts
// with `light:`/`dark:`, so a plain Windows path like `C:\themes\x` is never
// mis-parsed.
fn resolveThemeName(value: []const u8, prefer_dark: bool) []const u8 {
    var dark: ?[]const u8 = null;
    var light: ?[]const u8 = null;
    var any_variant = false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |seg| {
        const s = std.mem.trim(u8, seg, " \t");
        if (std.mem.startsWith(u8, s, "dark:")) {
            dark = std.mem.trim(u8, s["dark:".len..], " \t");
            any_variant = true;
        } else if (std.mem.startsWith(u8, s, "light:")) {
            light = std.mem.trim(u8, s["light:".len..], " \t");
            any_variant = true;
        }
    }
    if (!any_variant) return value;
    return if (prefer_dark) (dark orelse light orelse value) else (light orelse dark orelse value);
}

// Whether Windows is in dark mode (apps use dark theme). Reads HKCU
// Themes\Personalize\AppsUseLightTheme (DWORD: 1 = light, 0 = dark). Defaults to
// dark when the value is missing/unreadable, matching mostty's dark chrome.
fn systemPrefersDark() bool {
    var data: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const rc = win32.RegGetValueW(
        win32.HKEY_CURRENT_USER,
        win32.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        win32.L("AppsUseLightTheme"),
        win32.RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    if (@intFromEnum(rc) != 0) return true; // missing/unreadable -> assume dark
    return data == 0;
}

// Searches the theme name under %LOCALAPPDATA%/mostty/themes then <exeDir>/themes.
// Returns the first existing path (caller owns it) or null.
fn findThemeFile(gpa: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.process.getEnvVarOwned(gpa, "LOCALAPPDATA")) |lad| {
        defer gpa.free(lad);
        const p = std.fs.path.join(gpa, &.{ lad, "mostty", "themes", name }) catch oom();
        if (fileExists(p)) return p;
        gpa.free(p);
    } else |_| {}

    if (exeDir(gpa)) |dir| {
        defer gpa.free(dir);
        const p = std.fs.path.join(gpa, &.{ dir, "themes", name }) catch oom();
        if (fileExists(p)) return p;
        gpa.free(p);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// Directory containing the running executable (caller owns the slice).
fn exeDir(gpa: std.mem.Allocator) ?[]const u8 {
    var buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    const full = std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]) catch return null;
    defer gpa.free(full);
    const dir = std.fs.path.dirname(full) orelse return null;
    return gpa.dupe(u8, dir) catch oom();
}

fn parseLauncher(a: std.mem.Allocator, value: []const u8) ?Launcher {
    // Split with first-and-last '|' semantics so the middle (command-line)
    // segment may contain literal '|' (common in shell pipelines).
    const first = std.mem.indexOfScalar(u8, value, '|') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, value, '|').?;
    const label = std.mem.trim(u8, value[0..first], " \t");
    const cmd_slice = if (first == last) value[first + 1 ..] else value[first + 1 .. last];
    const cwd_slice = if (first == last) value[0..0] else value[last + 1 ..];
    const command_line = std.mem.trim(u8, cmd_slice, " \t");
    const working_directory = std.mem.trim(u8, cwd_slice, " \t");

    if (label.len == 0 or command_line.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(label)) return null;
    if (!std.unicode.utf8ValidateSlice(command_line)) return null;
    if (!std.unicode.utf8ValidateSlice(working_directory)) return null;

    return .{
        .label = a.dupe(u8, label) catch oom(),
        .command_line = a.dupe(u8, command_line) catch oom(),
        .working_directory = a.dupe(u8, working_directory) catch oom(),
    };
}

pub fn deinit(self: *Config) void {
    if (self.arena) |*a| a.deinit();
    self.* = undefined;
}

fn oom() noreturn {
    @panic("OOM in config loader");
}

test "parseHex accepts #RRGGBB and RRGGBB, rejects bad length" {
    try std.testing.expectEqual(@as(?u24, 0x282a36), parseHex("#282a36"));
    try std.testing.expectEqual(@as(?u24, 0xff5555), parseHex("ff5555"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("#fff"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("nothex"));
}

test "u24ToRgb keeps channel order (not a bitcast)" {
    const rgb = u24ToRgb(0x112233);
    try std.testing.expectEqual(@as(u8, 0x11), rgb.r);
    try std.testing.expectEqual(@as(u8, 0x22), rgb.g);
    try std.testing.expectEqual(@as(u8, 0x33), rgb.b);
}

test "resolveThemeName picks variant by mode, leaves plain paths alone" {
    // Order-independent; picks the variant matching the mode.
    try std.testing.expectEqualStrings("Dracula", resolveThemeName("light:GitHub, dark:Dracula", true));
    try std.testing.expectEqualStrings("GitHub", resolveThemeName("light:GitHub, dark:Dracula", false));
    try std.testing.expectEqualStrings("Dracula", resolveThemeName("dark:Dracula, light:GitHub", true));
    // Non-variant values pass through untouched regardless of mode.
    try std.testing.expectEqualStrings("Nord", resolveThemeName("Nord", true));
    try std.testing.expectEqualStrings("C:\\themes\\x", resolveThemeName("C:\\themes\\x", false));
    // Only one variant given: fall back to it.
    try std.testing.expectEqualStrings("OnlyLight", resolveThemeName("light:OnlyLight", true));
    try std.testing.expectEqualStrings("OnlyDark", resolveThemeName("dark:OnlyDark", false));
}

test "parse reads color keys into theme" {
    const src =
        \\background = #000000
        \\foreground = #abcdef
        \\palette = 1=#ff5555
        \\palette = 200=#102030
        \\cursor-color = #112233
        \\selection-background = #445566
        \\split-divider-color = #999999
    ;
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u24, 0x000000), cfg.theme.background);
    try std.testing.expectEqual(@as(u24, 0xabcdef), cfg.theme.foreground);
    try std.testing.expectEqual(u24ToRgb(0xff5555), cfg.theme.palette[1]);
    try std.testing.expectEqual(u24ToRgb(0x102030), cfg.theme.palette[200]);
    try std.testing.expectEqual(@as(?u24, 0x112233), cfg.theme.cursor_color);
    try std.testing.expectEqual(@as(?u24, 0x445566), cfg.theme.selection_background);
    // Index not set by the theme keeps the standard xterm cube (non-zero).
    try std.testing.expectEqual(vt.color.default[16], cfg.theme.palette[16]);
}

test "parse font-codepoint-map: single, range, multi-range, repeats" {
    const src =
        \\font-codepoint-map = U+1F300-U+1F5FF=Noto Color Emoji
        \\font-codepoint-map = U+2500-U+257F,U+2580-U+259F=Cascadia Mono
        \\font-codepoint-map = U+4E2D=Noto Sans CJK SC
    ;
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 4), cfg.font_codepoint_maps.len);

    const m0 = cfg.font_codepoint_maps[0];
    try std.testing.expectEqual(@as(u21, 0x1F300), m0.range_start);
    try std.testing.expectEqual(@as(u21, 0x1F5FF), m0.range_end);
    try std.testing.expectEqualStrings("Noto Color Emoji", m0.family);

    const m1 = cfg.font_codepoint_maps[1];
    try std.testing.expectEqual(@as(u21, 0x2500), m1.range_start);
    try std.testing.expectEqual(@as(u21, 0x257F), m1.range_end);
    try std.testing.expectEqualStrings("Cascadia Mono", m1.family);

    const m2 = cfg.font_codepoint_maps[2];
    try std.testing.expectEqual(@as(u21, 0x2580), m2.range_start);
    try std.testing.expectEqual(@as(u21, 0x259F), m2.range_end);
    // Same family pointer reused within one line.
    try std.testing.expectEqual(m1.family.ptr, m2.family.ptr);

    const m3 = cfg.font_codepoint_maps[3];
    try std.testing.expectEqual(@as(u21, 0x4E2D), m3.range_start);
    try std.testing.expectEqual(@as(u21, 0x4E2D), m3.range_end);
}

test "parse font-codepoint-map: malformed lines are skipped atomically" {
    // A line with one good range and one bad range must reject the whole line
    // (atomic) so a typo can't half-map. Following lines still parse.
    const src =
        \\font-codepoint-map = U+1F300-U+1F5FF,GARBAGE=Emoji
        \\font-codepoint-map = =Empty
        \\font-codepoint-map = U+30-U+10=Reversed
        \\font-codepoint-map = U+1F600=Good
    ;
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.font_codepoint_maps.len);
    try std.testing.expectEqual(@as(u21, 0x1F600), cfg.font_codepoint_maps[0].range_start);
    try std.testing.expectEqualStrings("Good", cfg.font_codepoint_maps[0].family);
}

test "parseCodepoint accepts U+/u+/bare hex; rejects overflow" {
    try std.testing.expectEqual(@as(?u21, 0x4E2D), parseCodepoint("U+4E2D"));
    try std.testing.expectEqual(@as(?u21, 0x4E2D), parseCodepoint("u+4e2d"));
    try std.testing.expectEqual(@as(?u21, 0x4E2D), parseCodepoint("4E2D"));
    try std.testing.expectEqual(@as(?u21, null), parseCodepoint(""));
    try std.testing.expectEqual(@as(?u21, null), parseCodepoint("U+"));
    try std.testing.expectEqual(@as(?u21, null), parseCodepoint("ZZZ"));
    try std.testing.expectEqual(@as(?u21, null), parseCodepoint("110000")); // > 0x10FFFF
    try std.testing.expectEqual(@as(?u21, 0x10FFFF), parseCodepoint("10FFFF"));
}

test "parse font-style: default/false/named" {
    const src =
        \\font-style = SemiBold
        \\font-style-bold = Heavy
        \\font-style-italic = false
        \\font-style-bold-italic =
    ;
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expect(cfg.font_style == .named);
    try std.testing.expectEqualStrings("SemiBold", cfg.font_style.named);
    try std.testing.expect(cfg.font_style_bold == .named);
    try std.testing.expectEqualStrings("Heavy", cfg.font_style_bold.named);
    try std.testing.expect(cfg.font_style_italic == .disabled);
    // Empty value resets to default.
    try std.testing.expect(cfg.font_style_bold_italic == .default);
}

test "parseSyntheticStyle: true/false/list/invalid" {
    {
        const s = parseSyntheticStyle("true").?;
        try std.testing.expect(s.bold and s.italic and s.bold_italic);
    }
    {
        const s = parseSyntheticStyle("FALSE").?;
        try std.testing.expect(!s.bold and !s.italic and !s.bold_italic);
    }
    {
        const s = parseSyntheticStyle("no-bold").?;
        try std.testing.expect(!s.bold and s.italic and s.bold_italic);
    }
    {
        const s = parseSyntheticStyle("no-bold, no-italic").?;
        try std.testing.expect(!s.bold and !s.italic and s.bold_italic);
    }
    {
        const s = parseSyntheticStyle("no-bold,no-italic,no-bold-italic").?;
        try std.testing.expect(!s.bold and !s.italic and !s.bold_italic);
    }
    // Unknown token poisons the whole line.
    try std.testing.expectEqual(@as(?SyntheticStyle, null), parseSyntheticStyle("no-bold,bogus"));
    try std.testing.expectEqual(@as(?SyntheticStyle, null), parseSyntheticStyle(""));
}

test "font-thicken/font-shaping-break are silently ignored" {
    const src =
        \\font-thicken = true
        \\font-thicken-strength = 128
        \\font-shaping-break = cursor
    ;
    // Should produce no entries, no panic. Warning-as-error would surface via
    // the unknown-key warn, which these keys must NOT trigger.
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.font_codepoint_maps.len);
}

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;
