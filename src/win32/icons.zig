const std = @import("std");
const win32 = @import("win32").everything;
const util = @import("util.zig");
const cimport = @cImport({
    @cInclude("ResourceNames.h");
});

pub const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};

pub fn getIcons(dpi: util.XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.debug("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
    });
    const small = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for small icon", win32.GetLastError());
    const large = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(cimport.ID_ICON_MITE),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ) orelse win32.panicWin32("LoadImage for large icon", win32.GetLastError());
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}
