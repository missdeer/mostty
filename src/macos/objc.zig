const std = @import("std");
const builtin = @import("builtin");

const Id = *anyopaque;
const RawSel = *anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) ?Id;
extern "c" fn sel_registerName(name: [*:0]const u8) RawSel;
extern "c" fn objc_msgSend() callconv(.c) void;
extern "c" fn objc_msgSend_stret() callconv(.c) void;
extern "c" fn objc_msgSend_fpret() callconv(.c) void;
extern "c" fn objc_retain(value: Id) Id;
extern "c" fn objc_release(value: Id) void;

pub const Sel = struct {
    value: RawSel,
};

pub fn sel(name: [:0]const u8) Sel {
    return .{ .value = sel_registerName(name.ptr) };
}

pub const Class = struct {
    value: Id,

    const messages = MsgSend(Class);
    pub const msgSend = messages.msgSend;
};

pub fn getClass(name: [:0]const u8) ?Class {
    return .{ .value = objc_getClass(name.ptr) orelse return null };
}

pub const Object = struct {
    value: Id,

    const messages = MsgSend(Object);
    pub const msgSend = messages.msgSend;

    pub fn fromId(value: anytype) Object {
        if (@sizeOf(@TypeOf(value)) != @sizeOf(Id)) @compileError("invalid Objective-C id type");
        return .{ .value = @ptrCast(@alignCast(value)) };
    }

    pub fn retain(self: Object) Object {
        return .{ .value = objc_retain(self.value) };
    }

    pub fn release(self: Object) void {
        objc_release(self.value);
    }

    pub fn setProperty(self: Object, comptime name: [:0]const u8, value: anytype) void {
        self.msgSend(
            void,
            sel("set" ++ [1]u8{std.ascii.toUpper(name[0])} ++ name[1..name.len] ++ ":"),
            .{value},
        );
    }

    pub fn getProperty(self: Object, comptime T: type, comptime name: [:0]const u8) T {
        return self.msgSend(T, sel(name), .{});
    }
};

fn MsgSend(comptime Target: type) type {
    return struct {
        pub fn msgSend(
            target: Target,
            comptime Return: type,
            selector: Sel,
            args: anytype,
        ) Return {
            const wraps_object = Return == Object;
            const RealReturn = if (wraps_object) Id else Return;
            const Fn = msgSendFn(RealReturn, @TypeOf(target.value), @TypeOf(args));
            const function: *const Fn = @ptrCast(@alignCast(msgSendPointer(RealReturn)));
            const result = @call(
                .auto,
                function,
                .{ target.value, selector.value } ++ unwrapArgs(args),
            );
            if (!wraps_object) return result;
            return .{ .value = result };
        }
    };
}

fn msgSendPointer(comptime Return: type) *const fn () callconv(.c) void {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => &objc_msgSend,
        .x86_64 => switch (@typeInfo(Return)) {
            .float => |info| if (info.bits == 64) &objc_msgSend_fpret else &objc_msgSend,
            .@"struct" => if (@sizeOf(Return) > 16) &objc_msgSend_stret else &objc_msgSend,
            else => &objc_msgSend,
        },
        else => @compileError("unsupported Objective-C architecture"),
    };
}

fn msgSendFn(comptime Return: type, comptime Target: type, comptime Args: type) type {
    const info = @typeInfo(Args).@"struct";
    var types: [info.fields.len + 2]type = undefined;
    types[0] = Target;
    types[1] = RawSel;
    for (info.fields, 0..) |field, index| types[index + 2] = unwrapType(field.type);
    return @Fn(&types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |field, index| types[index] = unwrapType(field.type);
    return @Tuple(&types);
}

fn unwrapArgs(args: anytype) UnwrappedArgs(@TypeOf(args)) {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var result: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (fields, 0..) |_, index| {
        result[index] = if (unwrapType(@TypeOf(args[index])) != @TypeOf(args[index]))
            args[index].value
        else
            args[index];
    }
    return result;
}

fn unwrapType(comptime T: type) type {
    if (T == Object) return Id;
    if (T == Class) return Id;
    if (T == Sel) return RawSel;
    return T;
}
