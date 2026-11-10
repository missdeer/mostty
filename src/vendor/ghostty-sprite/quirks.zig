//! Subset of ghostty's quirks.zig — only the `inlineAssert` helper used by
//! the vendored sprite drawing code.

const std = @import("std");
const builtin = @import("builtin");

pub const inlineAssert = switch (builtin.mode) {
    .debug => std.debug.assert,
    .small, .safe, .fast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
