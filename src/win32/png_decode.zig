const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const log = std.log.scoped(.png_decode);

const S_OK: win32.HRESULT = 0;
const S_FALSE: win32.HRESULT = 1;
const RPC_E_CHANGED_MODE: win32.HRESULT = @bitCast(@as(u32, 0x80010106));

pub fn initUiComApartment() bool {
    const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    if (hr == S_OK or hr == S_FALSE) return true;
    if (hr == RPC_E_CHANGED_MODE) {
        log.warn("COM already initialized with a different apartment model; WIC PNG decode will reuse it", .{});
        return false;
    }
    log.warn("CoInitializeEx failed for PNG decode, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
    return false;
}

pub fn install() void {
    vt.sys.decode_png = decodePng;
}

fn decodePng(
    alloc: std.mem.Allocator,
    data: []const u8,
) vt.sys.DecodeError!vt.sys.Image {
    if (data.len == 0 or data.len > std.math.maxInt(u32)) return error.InvalidData;

    var factory: *win32.IWICImagingFactory = undefined;
    if (win32.CoCreateInstance(
        &win32.CLSID_WICImagingFactory,
        null,
        win32.CLSCTX_INPROC_SERVER,
        win32.IID_IWICImagingFactory,
        @ptrCast(&factory),
    ) < 0) return error.InvalidData;
    defer _ = factory.IUnknown.Release();

    var stream: ?*win32.IWICStream = null;
    if (factory.CreateStream(&stream) < 0) return error.InvalidData;
    defer _ = stream.?.IUnknown.Release();

    if (stream.?.InitializeFromMemory(@ptrCast(@constCast(data.ptr)), @intCast(data.len)) < 0) {
        return error.InvalidData;
    }

    var decoder: ?*win32.IWICBitmapDecoder = null;
    if (factory.CreateDecoderFromStream(
        &stream.?.IStream,
        null,
        win32.WICDecodeMetadataCacheOnLoad,
        &decoder,
    ) < 0) return error.InvalidData;
    defer _ = decoder.?.IUnknown.Release();

    var frame: ?*win32.IWICBitmapFrameDecode = null;
    if (decoder.?.GetFrame(0, &frame) < 0) return error.InvalidData;
    defer _ = frame.?.IUnknown.Release();

    var converter: ?*win32.IWICFormatConverter = null;
    if (factory.CreateFormatConverter(&converter) < 0) return error.InvalidData;
    defer _ = converter.?.IUnknown.Release();

    var fmt: win32.Guid = win32.GUID_WICPixelFormat32bppRGBA;
    if (converter.?.Initialize(
        &frame.?.IWICBitmapSource,
        &fmt,
        win32.WICBitmapDitherTypeNone,
        null,
        0.0,
        win32.WICBitmapPaletteTypeMedianCut,
    ) < 0) return error.InvalidData;

    var w: u32 = 0;
    var h: u32 = 0;
    if (converter.?.IWICBitmapSource.GetSize(&w, &h) < 0 or w == 0 or h == 0) {
        return error.InvalidData;
    }
    if (w > 10000 or h > 10000) return error.InvalidData;

    const stride: u32 = w * 4;
    const size: usize = @as(usize, stride) * h;
    const pixels = try alloc.alloc(u8, size);
    errdefer alloc.free(pixels);
    if (converter.?.IWICBitmapSource.CopyPixels(null, stride, @intCast(size), @ptrCast(pixels.ptr)) < 0) {
        return error.InvalidData;
    }

    return .{ .width = w, .height = h, .data = pixels };
}

test "install wires Ghostty PNG decode hook" {
    const prev = vt.sys.decode_png;
    defer vt.sys.decode_png = prev;
    install();
    try std.testing.expect(vt.sys.decode_png != null);
}
