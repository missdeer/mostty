const Config = @This();

font_families: []const []const u8 = &.{},
font_size_pt: ?f32 = null,

arena: ?std.heap.ArenaAllocator = null,

pub fn loadDefault(gpa: std.mem.Allocator) Config {
    const localappdata = std.process.getEnvVarOwned(gpa, "LOCALAPPDATA") catch |err| {
        std.log.info("config: LOCALAPPDATA unavailable ({s}); using defaults", .{@errorName(err)});
        return .{};
    };
    defer gpa.free(localappdata);

    const path = std.fs.path.join(gpa, &.{ localappdata, "mite", "config" }) catch oom();
    defer gpa.free(path);

    return loadPath(gpa, path);
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
    var font_size_pt: ?f32 = null;

    // Strip UTF-8 BOM if present (Notepad and other Windows editors add one).
    const input = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
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

        if (std.mem.eql(u8, key, "font-family")) {
            var vit = std.mem.splitScalar(u8, value, ',');
            while (vit.next()) |v| {
                const name = std.mem.trim(u8, v, " \t");
                if (name.len == 0) continue;
                const owned = a.dupe(u8, name) catch oom();
                families.append(a, owned) catch oom();
            }
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
        } else {
            std.log.warn("config: {s}:{}: unknown key '{s}'", .{ source_name, line_no, key });
        }
    }

    const slice = families.toOwnedSlice(a) catch oom();
    return .{
        .font_families = slice,
        .font_size_pt = font_size_pt,
        .arena = arena,
    };
}

pub fn deinit(self: *Config) void {
    if (self.arena) |*a| a.deinit();
    self.* = undefined;
}

fn oom() noreturn {
    @panic("OOM in config loader");
}

const std = @import("std");
