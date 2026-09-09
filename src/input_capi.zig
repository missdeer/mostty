//! Stateless host bridge, also linked into native interaction tests.
const std = @import("std");
const key_encode = @import("terminal/key_encode.zig");
const paste = @import("terminal/paste.zig");
const ssh = @import("ssh_config.zig");

export fn mostty_encode_key(key: u32, mods: u32, app_cursor: bool, buf: [*]u8, cap: usize) usize {
    var stack: [16]u8 = undefined;
    const seq = key_encode.encodeKey(@enumFromInt(key), mods, app_cursor, &stack);
    const n = @min(seq.len, cap);
    @memcpy(buf[0..n], seq[0..n]);
    return n;
}

// Output never exceeds input length plus the two framing markers. On failure
// the host must discard the buffer; no bytes have reached the PTY yet.
export fn mostty_encode_paste(ptr: [*]const u8, len: usize, bracketed: bool, normalize: bool, buf: [*]u8, cap: usize) usize {
    var writer: std.Io.Writer = .fixed(buf[0..cap]);
    const input = if (len == 0) "" else ptr[0..len];
    paste.writeUtf8(&writer, input, bracketed, normalize) catch return 0;
    return writer.buffered().len;
}

const Host = extern struct { offset: usize, len: usize };

// Returns required entry count. Offsets refer to the caller's input buffer;
// cap == 0 is a size query, and no native allocation crosses the ABI.
export fn mostty_ssh_hosts(ptr: [*]const u8, len: usize, out: ?[*]Host, cap: usize) usize {
    if (len == 0) return 0;
    var it = ssh.Iterator.init(ptr[0..len]);
    var count: usize = 0;
    while (it.next()) |name| {
        if (count < cap) {
            if (out) |entries| {
                entries[count] = .{ .offset = @intFromPtr(name.ptr) - @intFromPtr(ptr), .len = name.len };
            }
        }
        count += 1;
    }
    return count;
}

test "C bridge preserves caller-owned SSH slices and paste framing" {
    const source = "Host alpha 日本\n";
    var hosts: [2]Host = undefined;
    try std.testing.expectEqual(@as(usize, 2), mostty_ssh_hosts(source.ptr, source.len, &hosts, 0));
    try std.testing.expectEqual(@as(usize, 2), mostty_ssh_hosts(source.ptr, source.len, &hosts, hosts.len));
    try std.testing.expectEqualStrings("日本", source[hosts[1].offset..][0..hosts[1].len]);
    var output: [128]u8 = undefined;
    const input = "界\n\x1b[201~";
    const n = mostty_encode_paste(input.ptr, input.len, true, true, &output, output.len);
    try std.testing.expectEqualStrings(paste.paste_start ++ "界\r" ++ paste.paste_end, output[0..n]);
    try std.testing.expectEqual(@as(usize, 0), mostty_encode_paste(input.ptr, input.len, true, true, &output, 1));
}
