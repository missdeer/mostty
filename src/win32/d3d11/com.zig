//! COM / HRESULT helpers shared by the d3d11 renderer modules.

const std = @import("std");
const win32 = @import("win32").everything;

pub fn queryInterface(obj: anytype, comptime Interface: type) *Interface {
    const iid_name = comptime blk: {
        const name = @typeName(Interface);
        const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| (i + 1) else 0;
        break :blk "IID_" ++ name[start..];
    };
    const iid = @field(win32, iid_name);
    var iface: *Interface = undefined;
    const hr = obj.IUnknown.QueryInterface(iid, @ptrCast(&iface));
    if (hr < 0) fatalHr("QueryInterface", hr);
    return iface;
}

pub fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
