const std = @import("std");
const Apple = @This();

const CFIndex = c_long;
const CFStringEncoding = u32;
const CTFontSymbolicTraits = u32;
const CTFontOrientation = u32;
const CGGlyph = u16;

const CFStringRef = *anyopaque;
const CTFontDescriptorRef = *anyopaque;
const CTFontRef = *anyopaque;
const CGColorSpaceRef = *anyopaque;
const CGContextRef = *anyopaque;
const CGImageRef = *anyopaque;

extern "c" fn CFStringCreateWithBytes(
    allocator: ?*anyopaque,
    bytes: [*]const u8,
    count: CFIndex,
    encoding: CFStringEncoding,
    external_representation: bool,
) ?CFStringRef;
extern "c" fn CFStringCreateWithCharacters(
    allocator: ?*anyopaque,
    characters: [*]const u16,
    count: CFIndex,
) ?CFStringRef;
extern "c" fn CFRelease(value: *anyopaque) void;
extern "c" fn CFRetain(value: *anyopaque) *anyopaque;
extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, count: CFIndex) ?*anyopaque;
extern "c" fn CFDataGetLength(data: *anyopaque) CFIndex;
extern "c" fn CFDataGetBytePtr(data: *anyopaque) [*]const u8;
extern "c" fn CFEqual(lhs: *anyopaque, rhs: *anyopaque) bool;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *anyopaque) ?*anyopaque;
extern "c" fn CFDictionaryCreate(allocator: ?*anyopaque, keys: [*]const *anyopaque, values: [*]const *anyopaque, count: CFIndex, key_callbacks: ?*const anyopaque, value_callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" var kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" var kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" fn CFArrayCreateMutable(allocator: ?*anyopaque, capacity: CFIndex, callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFArrayAppendValue(array: *anyopaque, value: *anyopaque) void;
extern "c" fn CFArrayGetCount(array: *anyopaque) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: *anyopaque, index: CFIndex) *anyopaque;
extern "c" fn CFStringCompare(lhs: CFStringRef, rhs: CFStringRef, flags: usize) CFIndex;
extern "c" fn CFNumberCreate(allocator: ?*anyopaque, kind: CFIndex, value: *const anyopaque) ?*anyopaque;
extern "c" var kCFTypeArrayCallBacks: anyopaque;
extern "c" fn CFNumberGetValue(number: *anyopaque, kind: CFIndex, value: *i64) bool;
extern "c" var kCFBooleanTrue: *anyopaque;
extern "c" fn CFAttributedStringCreateMutable(allocator: ?*anyopaque, capacity: CFIndex) ?*anyopaque;
extern "c" fn CFAttributedStringReplaceString(string: *anyopaque, range: Range, replacement: CFStringRef) void;
extern "c" fn CFAttributedStringSetAttribute(string: *anyopaque, range: Range, name: CFStringRef, value: *anyopaque) void;

extern "c" fn CGImageSourceCreateWithData(data: *anyopaque, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageSourceGetType(source: *anyopaque) ?CFStringRef;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(source: *anyopaque, index: usize, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageSourceCreateImageAtIndex(source: *anyopaque, index: usize, options: ?*anyopaque) ?CGImageRef;
extern "c" var kCGImagePropertyPixelWidth: CFStringRef;
extern "c" var kCGImagePropertyPixelHeight: CFStringRef;
extern "c" fn CGDataProviderCreateWithCFData(data: *anyopaque) ?*anyopaque;
extern "c" fn CGDataProviderRelease(provider: *anyopaque) void;
extern "c" fn CGImageCreate(width: usize, height: usize, bits_per_component: usize, bits_per_pixel: usize, bytes_per_row: usize, space: CGColorSpaceRef, bitmap_info: u32, provider: *anyopaque, decode: ?*const f64, interpolate: bool, intent: c_int) ?CGImageRef;
extern "c" fn CGImageRelease(image: CGImageRef) void;
extern "c" fn CGImageGetWidth(image: CGImageRef) usize;
extern "c" fn CGImageGetHeight(image: CGImageRef) usize;
extern "c" fn CGContextDrawImage(context: CGContextRef, rect: Rect, image: CGImageRef) void;
extern "c" fn CGContextSaveGState(context: CGContextRef) void;
extern "c" fn CGContextRestoreGState(context: CGContextRef) void;
extern "c" fn CGContextClipToRect(context: CGContextRef, rect: Rect) void;

extern "c" fn CTFontDescriptorCreateWithNameAndSize(name: CFStringRef, size: f64) ?CTFontDescriptorRef;
extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: *anyopaque) ?CTFontDescriptorRef;
extern "c" fn CTFontCopyFontDescriptor(font: CTFontRef) CTFontDescriptorRef;
extern "c" fn CTFontCopyTable(font: CTFontRef, tag: u32, options: u32) ?*anyopaque;
extern "c" fn CTFontDescriptorCreateMatchingFontDescriptors(descriptor: CTFontDescriptorRef, mandatory: ?*anyopaque) ?*anyopaque;
extern "c" fn CTFontDescriptorCopyAttribute(descriptor: CTFontDescriptorRef, name: CFStringRef) ?*anyopaque;
extern "c" fn CTFontGetSymbolicTraits(font: CTFontRef) CTFontSymbolicTraits;
extern "c" var kCTFontFamilyNameAttribute: CFStringRef;
extern "c" var kCTFontStyleNameAttribute: CFStringRef;
extern "c" var kCTFontFeatureSettingsAttribute: CFStringRef;
extern "c" var kCTFontOpenTypeFeatureTag: CFStringRef;
extern "c" var kCTFontOpenTypeFeatureValue: CFStringRef;
extern "c" fn CTFontCreateCopyWithAttributes(font: CTFontRef, size: f64, matrix: ?*const AffineTransform, descriptor: CTFontDescriptorRef) ?CTFontRef;
extern "c" var kCTFontCascadeListAttribute: CFStringRef;
extern "c" fn CTFontCreateWithFontDescriptor(
    descriptor: CTFontDescriptorRef,
    size: f64,
    matrix: ?*const AffineTransform,
) ?CTFontRef;
extern "c" fn CTFontCreateCopyWithSymbolicTraits(
    font: CTFontRef,
    size: f64,
    matrix: ?*const AffineTransform,
    value: CTFontSymbolicTraits,
    mask: CTFontSymbolicTraits,
) ?CTFontRef;
extern "c" fn CTFontCreateForString(font: CTFontRef, string: CFStringRef, range: Range) ?CTFontRef;
extern "c" fn CTFontGetGlyphsForCharacters(
    font: CTFontRef,
    characters: [*]const u16,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(
    font: CTFontRef,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    advances: ?[*]Size,
    count: CFIndex,
) f64;
extern "c" fn CTFontGetAscent(font: CTFontRef) f64;
extern "c" fn CTFontGetDescent(font: CTFontRef) f64;
extern "c" fn CTFontGetLeading(font: CTFontRef) f64;
extern "c" fn CTFontGetUnderlinePosition(font: CTFontRef) f64;
extern "c" fn CTFontGetUnderlineThickness(font: CTFontRef) f64;
extern "c" fn CTFontGetXHeight(font: CTFontRef) f64;
extern "c" var kCTFontAttributeName: CFStringRef;
extern "c" var kCTForegroundColorFromContextAttributeName: CFStringRef;
extern "c" fn CTLineCreateWithAttributedString(string: *anyopaque) ?*anyopaque;
extern "c" fn CTLineGetTypographicBounds(line: *anyopaque, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
extern "c" fn CTLineDraw(line: *anyopaque, context: CGContextRef) void;

extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: CGColorSpaceRef,
    bitmap_info: u32,
) ?CGContextRef;
extern "c" fn CGContextRelease(context: CGContextRef) void;
extern "c" fn CGContextSetAllowsAntialiasing(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetShouldAntialias(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetTextDrawingMode(context: CGContextRef, mode: c_int) void;
extern "c" fn CGContextSetTextMatrix(context: CGContextRef, transform: AffineTransform) void;
extern "c" fn CGContextSetTextPosition(context: CGContextRef, x: f64, y: f64) void;
extern "c" fn CGContextTranslateCTM(context: CGContextRef, x: f64, y: f64) void;
extern "c" fn CGContextScaleCTM(context: CGContextRef, x: f64, y: f64) void;
extern "c" fn CGContextConcatCTM(context: CGContextRef, transform: AffineTransform) void;
extern "c" fn CGContextSetLineWidth(context: CGContextRef, width: f64) void;
extern "c" fn CGContextSetRGBStrokeColor(context: CGContextRef, red: f64, green: f64, blue: f64, alpha: f64) void;
extern "c" fn CGContextSetAlpha(context: CGContextRef, alpha: f64) void;
extern "c" fn CGContextDrawTiledImage(context: CGContextRef, rect: Rect, image: CGImageRef) void;
extern "c" fn CGContextSetRGBFillColor(context: CGContextRef, red: f64, green: f64, blue: f64, alpha: f64) void;
extern "c" fn CGContextFillRect(context: CGContextRef, rect: Rect) void;
extern "c" fn CGContextClearRect(context: CGContextRef, rect: Rect) void;

pub const foundation = struct {
    pub const StringEncoding = enum(u32) {
        utf8 = 0x08000100,
    };

    pub const String = opaque {
        pub fn createWithBytes(bytes: []const u8, encoding: StringEncoding, external: bool) !*String {
            return @ptrCast(CFStringCreateWithBytes(
                null,
                bytes.ptr,
                @intCast(bytes.len),
                @intFromEnum(encoding),
                external,
            ) orelse return error.OutOfMemory);
        }

        pub fn createWithCharacters(characters: []const u16) !*String {
            return @ptrCast(CFStringCreateWithCharacters(
                null,
                characters.ptr,
                @intCast(characters.len),
            ) orelse return error.OutOfMemory);
        }

        pub fn release(self: *String) void {
            CFRelease(@ptrCast(self));
        }
    };

    pub const Range = Apple.Range;
};

pub const Range = extern struct {
    location: CFIndex,
    length: CFIndex,

    pub fn init(location: usize, length: usize) Range {
        return .{ .location = @intCast(location), .length = @intCast(length) };
    }
};

pub const graphics = struct {
    pub const Glyph = CGGlyph;
    pub const Point = Apple.Point;
    pub const Size = Apple.Size;
    pub const Rect = Apple.Rect;
    pub const AffineTransform = Apple.AffineTransform;

    pub const BitmapInfo = enum(u32) {
        byte_order_32_little = 2 << 12,
    };

    pub const ImageAlphaInfo = enum(u32) {
        premultiplied_last = 1,
        premultiplied_first = 2,
    };

    pub const Image = opaque {
        pub fn createRgba(bytes: []const u8, width: u32, height: u32) !*Image {
            const count = std.math.mul(usize, width, height) catch return error.InvalidData;
            const size = std.math.mul(usize, count, 4) catch return error.InvalidData;
            if (width == 0 or height == 0 or bytes.len != size) return error.InvalidData;
            const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
            defer CFRelease(data);
            const provider = CGDataProviderCreateWithCFData(data) orelse return error.OutOfMemory;
            defer CGDataProviderRelease(provider);
            const space = try ColorSpace.createDeviceRGB();
            defer space.release();
            // Kitty bytes are straight RGBA. The image retains the provider's copy.
            return @ptrCast(CGImageCreate(width, height, 8, 32, @as(usize, width) * 4, @ptrCast(space), 3, provider, null, true, 0) orelse return error.InvalidData);
        }

        pub fn createEncoded(bytes: []const u8, png_only: bool) !*Image {
            const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
            defer CFRelease(data);
            const source = CGImageSourceCreateWithData(data, null) orelse return error.InvalidData;
            defer CFRelease(source);
            if (png_only) {
                const kind = CGImageSourceGetType(source) orelse return error.InvalidData;
                const png = try foundation.String.createWithBytes("public.png", .utf8, false);
                defer png.release();
                if (!CFEqual(kind, @ptrCast(png))) return error.InvalidData;
            }
            const properties = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.InvalidData;
            defer CFRelease(properties);
            // Validate metadata before ImageIO allocates decoded pixels, matching VT's limits.
            for ([_]CFStringRef{ kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight }) |key| {
                const number = CFDictionaryGetValue(properties, key) orelse return error.InvalidData;
                var dimension: i64 = 0;
                if (!CFNumberGetValue(number, 4, &dimension) or dimension <= 0 or dimension > 10000) return error.InvalidData;
            }
            return @ptrCast(CGImageSourceCreateImageAtIndex(source, 0, null) orelse return error.InvalidData);
        }

        pub fn getWidth(self: *Image) usize {
            return CGImageGetWidth(@ptrCast(self));
        }
        pub fn getHeight(self: *Image) usize {
            return CGImageGetHeight(@ptrCast(self));
        }
        pub fn release(self: *Image) void {
            CGImageRelease(@ptrCast(self));
        }
    };

    pub const ColorSpace = opaque {
        pub fn createDeviceRGB() !*ColorSpace {
            return @ptrCast(CGColorSpaceCreateDeviceRGB() orelse return error.OutOfMemory);
        }

        pub fn release(self: *ColorSpace) void {
            CGColorSpaceRelease(@ptrCast(self));
        }
    };

    pub const BitmapContext = opaque {
        pub const context = Context;

        pub fn create(
            data: []u8,
            width: usize,
            height: usize,
            bits_per_component: usize,
            bytes_per_row: usize,
            color_space: *ColorSpace,
            bitmap_info: u32,
        ) !*BitmapContext {
            return @ptrCast(CGBitmapContextCreate(
                data.ptr,
                width,
                height,
                bits_per_component,
                bytes_per_row,
                @ptrCast(color_space),
                bitmap_info,
            ) orelse return error.OutOfMemory);
        }
    };

    pub const Context = struct {
        pub fn drawTiledImage(value: *BitmapContext, rect: Apple.Rect, image: *Image) void {
            CGContextDrawTiledImage(@ptrCast(value), rect, @ptrCast(image));
        }
        pub fn setAlpha(value: *BitmapContext, alpha: f64) void {
            CGContextSetAlpha(@ptrCast(value), alpha);
        }
        pub fn concat(value: *BitmapContext, transform: Apple.AffineTransform) void {
            CGContextConcatCTM(@ptrCast(value), transform);
        }
        pub fn setLineWidth(value: *BitmapContext, width: f64) void {
            CGContextSetLineWidth(@ptrCast(value), width);
        }
        pub fn setRGBStrokeColor(value: *BitmapContext, red: f64, green: f64, blue: f64, alpha: f64) void {
            CGContextSetRGBStrokeColor(@ptrCast(value), red, green, blue, alpha);
        }
        pub fn drawImage(value: *BitmapContext, rect: Apple.Rect, image: *Image) void {
            CGContextDrawImage(@ptrCast(value), rect, @ptrCast(image));
        }

        pub fn save(value: *BitmapContext) void {
            CGContextSaveGState(@ptrCast(value));
        }
        pub fn restore(value: *BitmapContext) void {
            CGContextRestoreGState(@ptrCast(value));
        }
        pub fn clipToRect(value: *BitmapContext, rect: Apple.Rect) void {
            CGContextClipToRect(@ptrCast(value), rect);
        }

        pub fn release(value: *BitmapContext) void {
            CGContextRelease(@ptrCast(value));
        }

        pub fn setAllowsAntialiasing(value: *BitmapContext, enabled: bool) void {
            CGContextSetAllowsAntialiasing(@ptrCast(value), enabled);
        }

        pub fn setShouldAntialias(value: *BitmapContext, enabled: bool) void {
            CGContextSetShouldAntialias(@ptrCast(value), enabled);
        }

        pub fn setShouldSmoothFonts(value: *BitmapContext, enabled: bool) void {
            CGContextSetShouldSmoothFonts(@ptrCast(value), enabled);
        }

        pub fn setTextDrawingMode(value: *BitmapContext, mode: TextDrawingMode) void {
            CGContextSetTextDrawingMode(@ptrCast(value), @intFromEnum(mode));
        }

        pub fn setTextMatrix(value: *BitmapContext, transform: Apple.AffineTransform) void {
            CGContextSetTextMatrix(@ptrCast(value), transform);
        }

        pub fn setTextPosition(value: *BitmapContext, x: f64, y: f64) void {
            CGContextSetTextPosition(@ptrCast(value), x, y);
        }

        pub fn translate(value: *BitmapContext, x: f64, y: f64) void {
            CGContextTranslateCTM(@ptrCast(value), x, y);
        }

        pub fn scale(value: *BitmapContext, x: f64, y: f64) void {
            CGContextScaleCTM(@ptrCast(value), x, y);
        }

        pub fn setRGBFillColor(value: *BitmapContext, red: f64, green: f64, blue: f64, alpha: f64) void {
            CGContextSetRGBFillColor(@ptrCast(value), red, green, blue, alpha);
        }

        pub fn fillRect(value: *BitmapContext, rect: Apple.Rect) void {
            CGContextFillRect(@ptrCast(value), rect);
        }

        /// Resets the region to transparent black. Required before painting a
        /// translucent background, which would otherwise blend with the previous
        /// frame still sitting in the reused pixel buffer.
        pub fn clearRect(value: *BitmapContext, rect: Apple.Rect) void {
            CGContextClearRect(@ptrCast(value), rect);
        }
    };

    pub const TextDrawingMode = enum(c_int) {
        fill = 0,
        fill_stroke = 2,
    };
};

pub const text = struct {
    pub const Line = opaque {
        /// Shape the whole cluster so fallback, variation selectors and emoji
        /// ligatures are resolved together. Ordinary glyphs use the cell color.
        pub fn create(characters: []const u16, font: *Font) !*Line {
            const string = try foundation.String.createWithCharacters(characters);
            defer string.release();
            const attributed = CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
            defer CFRelease(attributed);
            CFAttributedStringReplaceString(attributed, Range.init(0, 0), @ptrCast(string));
            const range = Range.init(0, characters.len);
            CFAttributedStringSetAttribute(attributed, range, kCTFontAttributeName, @ptrCast(font));
            CFAttributedStringSetAttribute(attributed, range, kCTForegroundColorFromContextAttributeName, kCFBooleanTrue);
            return @ptrCast(CTLineCreateWithAttributedString(attributed) orelse return error.OutOfMemory);
        }

        pub fn getTypographicBounds(self: *Line, ascent: *f64, descent: *f64) f64 {
            return CTLineGetTypographicBounds(@ptrCast(self), ascent, descent, null);
        }

        pub fn draw(self: *Line, context: *graphics.BitmapContext) void {
            CTLineDraw(@ptrCast(self), @ptrCast(context));
        }

        pub fn release(self: *Line) void {
            CFRelease(@ptrCast(self));
        }
    };

    pub const FontSymbolicTraits = packed struct(u32) {
        italic: bool = false,
        bold: bool = false,
        _padding: u30 = 0,
    };

    pub const FontDescriptor = opaque {
        pub fn createWithNameAndSize(name: *foundation.String, size: f64) !*FontDescriptor {
            return @ptrCast(CTFontDescriptorCreateWithNameAndSize(
                @ptrCast(name),
                size,
            ) orelse return error.OutOfMemory);
        }

        pub fn release(self: *FontDescriptor) void {
            CFRelease(@ptrCast(self));
        }
    };

    pub const Font = opaque {
        /// Enumerate real faces within the family. Matching the style name
        /// separately prevents CoreText from silently substituting another face.
        pub fn findFace(family: []const u8, style: ?[]const u8, traits: ?FontSymbolicTraits, size: f64) !?*Font {
            const name = try foundation.String.createWithBytes(family, .utf8, false);
            defer name.release();
            const attrs = CFDictionaryCreate(null, &.{kCTFontFamilyNameAttribute}, &.{@ptrCast(name)}, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(attrs);
            const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return error.OutOfMemory;
            defer CFRelease(desc);
            const matches = CTFontDescriptorCreateMatchingFontDescriptors(desc, null) orelse return null;
            defer CFRelease(matches);
            const wanted = if (style) |s| try foundation.String.createWithBytes(s, .utf8, false) else null;
            defer if (wanted) |s| s.release();
            var i: CFIndex = 0;
            while (i < CFArrayGetCount(matches)) : (i += 1) {
                const candidate = CFArrayGetValueAtIndex(matches, i);
                const actual_family = CTFontDescriptorCopyAttribute(candidate, kCTFontFamilyNameAttribute) orelse continue;
                defer CFRelease(actual_family);
                if (CFStringCompare(actual_family, @ptrCast(name), 1) != 0) continue;
                if (wanted) |w| {
                    const face_name = CTFontDescriptorCopyAttribute(candidate, kCTFontStyleNameAttribute) orelse continue;
                    defer CFRelease(face_name);
                    if (CFStringCompare(face_name, @ptrCast(w), 1) != 0) continue;
                }
                const font: *Font = @ptrCast(CTFontCreateWithFontDescriptor(candidate, size, null) orelse continue);
                if (wanted == null and traits != null and (font.symbolicTraits().bold != traits.?.bold or font.symbolicTraits().italic != traits.?.italic)) {
                    font.release();
                    continue;
                }
                return font;
            }
            return null;
        }

        pub fn symbolicTraits(self: *Font) FontSymbolicTraits {
            return @bitCast(CTFontGetSymbolicTraits(@ptrCast(self)));
        }

        /// CoreText advertises the color trait even for COLRv1-only fonts
        /// whose glyphs it cannot paint. Do not let those cmap entries block
        /// a usable fallback. Fonts with sbix/SVG or legacy COLR layers work.
        pub fn hasUnsupportedColorFormat(self: *Font) bool {
            for ([_]u32{ 0x73626978, 0x53564720 }) |tag| { // sbix, SVG
                if (CTFontCopyTable(@ptrCast(self), tag, 0)) |data| {
                    CFRelease(data);
                    return false;
                }
            }
            if (CTFontCopyTable(@ptrCast(self), 0x434f4c52, 0)) |data| { // COLR
                defer CFRelease(data);
                if (CFDataGetLength(data) < 4) return true;
                const header = CFDataGetBytePtr(data)[0..4];
                return std.mem.readInt(u16, header[0..2], .big) > 0 and
                    std.mem.readInt(u16, header[2..4], .big) == 0;
            }
            if (CTFontCopyTable(@ptrCast(self), 0x43424454, 0)) |data| { // CBDT
                CFRelease(data);
                return true;
            }
            return false;
        }

        pub fn copyWithFeatures(self: *Font, features: []const @import("../config.zig").FontFeature) !*Font {
            if (features.len == 0) {
                self.retain();
                return self;
            }
            const settings = CFArrayCreateMutable(null, 0, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(settings);
            for (features) |feature| {
                // Config stores tags in DirectWrite's little-endian byte order.
                const bytes = [4]u8{ @truncate(feature.tag), @truncate(feature.tag >> 8), @truncate(feature.tag >> 16), @truncate(feature.tag >> 24) };
                const tag = try foundation.String.createWithBytes(&bytes, .utf8, false);
                defer tag.release();
                const value: i64 = feature.value;
                const number = CFNumberCreate(null, 4, &value) orelse return error.OutOfMemory;
                defer CFRelease(number);
                const setting = CFDictionaryCreate(null, &.{ kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue }, &.{ @ptrCast(tag), number }, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
                defer CFRelease(setting);
                CFArrayAppendValue(settings, setting);
            }
            const attrs = CFDictionaryCreate(null, &.{kCTFontFeatureSettingsAttribute}, &.{settings}, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(attrs);
            const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return error.OutOfMemory;
            defer CFRelease(desc);
            return @ptrCast(CTFontCreateCopyWithAttributes(@ptrCast(self), 0, null, desc) orelse return error.OutOfMemory);
        }

        /// The primary face is consulted first, then the regular face and the
        /// configured families in order. CoreText supplies system fallback last.
        pub fn copyWithCascade(self: *Font, regular: *Font, families: []const []const u8) !*Font {
            const cascade = CFArrayCreateMutable(null, 0, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(cascade);
            const regular_descriptor = CTFontCopyFontDescriptor(@ptrCast(regular));
            defer CFRelease(regular_descriptor);
            CFArrayAppendValue(cascade, regular_descriptor);
            for (families) |family| {
                if (try Font.findFace(family, null, null, 0)) |font| {
                    defer font.release();
                    if (font.hasUnsupportedColorFormat()) continue;
                }
                const name = try foundation.String.createWithBytes(family, .utf8, false);
                defer name.release();
                const descriptor = try FontDescriptor.createWithNameAndSize(name, 0);
                defer descriptor.release();
                CFArrayAppendValue(cascade, @ptrCast(descriptor));
            }
            const attributes = CFDictionaryCreate(null, &.{kCTFontCascadeListAttribute}, &.{cascade}, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
            defer CFRelease(attributes);
            const descriptor = CTFontDescriptorCreateWithAttributes(attributes) orelse return error.OutOfMemory;
            defer CFRelease(descriptor);
            return @ptrCast(CTFontCreateCopyWithAttributes(@ptrCast(self), 0, null, descriptor) orelse return error.OutOfMemory);
        }

        pub fn createWithFontDescriptor(descriptor: *FontDescriptor, size: f64) !*Font {
            return @ptrCast(CTFontCreateWithFontDescriptor(
                @ptrCast(descriptor),
                size,
                null,
            ) orelse return error.OutOfMemory);
        }

        pub fn copyWithSymbolicTraits(self: *Font, traits: FontSymbolicTraits) ?*Font {
            const raw: CTFontSymbolicTraits = @bitCast(traits);
            return @ptrCast(CTFontCreateCopyWithSymbolicTraits(
                @ptrCast(self),
                0,
                null,
                raw,
                raw,
            ) orelse return null);
        }

        pub fn createForString(self: *Font, string: *foundation.String, range: Range) ?*Font {
            return @ptrCast(CTFontCreateForString(
                @ptrCast(self),
                @ptrCast(string),
                range,
            ) orelse return null);
        }

        pub fn retain(self: *Font) void {
            _ = CFRetain(@ptrCast(self));
        }

        pub fn release(self: *Font) void {
            CFRelease(@ptrCast(self));
        }

        pub fn getGlyphsForCharacters(self: *Font, characters: []const u16, glyphs: []graphics.Glyph) bool {
            std.debug.assert(characters.len == glyphs.len);
            return CTFontGetGlyphsForCharacters(
                @ptrCast(self),
                characters.ptr,
                glyphs.ptr,
                @intCast(characters.len),
            );
        }

        pub fn getAdvancesForGlyphs(
            self: *Font,
            orientation: FontOrientation,
            glyphs: []const graphics.Glyph,
            advances: ?[]graphics.Size,
        ) f64 {
            if (advances) |values| std.debug.assert(values.len == glyphs.len);
            return CTFontGetAdvancesForGlyphs(
                @ptrCast(self),
                @intFromEnum(orientation),
                glyphs.ptr,
                if (advances) |values| values.ptr else null,
                @intCast(glyphs.len),
            );
        }

        pub fn getAscent(self: *Font) f64 {
            return CTFontGetAscent(@ptrCast(self));
        }
        pub fn getDescent(self: *Font) f64 {
            return CTFontGetDescent(@ptrCast(self));
        }
        pub fn getLeading(self: *Font) f64 {
            return CTFontGetLeading(@ptrCast(self));
        }
        pub fn getUnderlinePosition(self: *Font) f64 {
            return CTFontGetUnderlinePosition(@ptrCast(self));
        }
        pub fn getUnderlineThickness(self: *Font) f64 {
            return CTFontGetUnderlineThickness(@ptrCast(self));
        }
        pub fn getXHeight(self: *Font) f64 {
            return CTFontGetXHeight(@ptrCast(self));
        }
    };

    pub const FontOrientation = enum(u32) {
        horizontal = 1,
    };
};

pub const Point = extern struct {
    x: f64,
    y: f64,
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }
};

pub const AffineTransform = extern struct {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    tx: f64,
    ty: f64,

    pub fn identity() AffineTransform {
        return .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
    }
};
