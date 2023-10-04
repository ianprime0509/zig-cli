const std = @import("std");

pub const App = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    author: ?[]const u8 = null,
    options: ?[]const *Option = null,
    subcommands: ?[]const *const Command = null,
    action: ?Action = null,

    help_config: HelpConfig = HelpConfig{},
};

pub const ColorUsage = enum {
    always,
    never,
    auto,
};

pub const HelpConfig = struct {
    color_usage: ColorUsage = .auto,
    color_app_name: []const u8 = "33;1",
    color_section: []const u8 = "33;1",
    color_option: []const u8 = "32",
    color_error: []const u8 = "31;1",
};

pub const Command = struct {
    name: []const u8,
    /// Detailed multiline command description
    description: ?[]const u8 = null,
    /// One liner for subcommands
    help: []const u8,
    options: ?[]const *Option = null,
    subcommands: ?[]const *const Command = null,
    action: ?Action = null,
};

pub const Action = *const fn (args: []const []const u8) anyerror!void;

pub const OptionValue = union(enum) {
    bool: bool,
    string: ?[]const u8,
    int: ?i64,
    float: ?f64,
    string_list: ?[]const []const u8,
};

const Setter = *const fn (ptr: *anyopaque, value: []const u8) anyerror!void;

pub const ValueRef = struct {
    ptr: *anyopaque,

    vtable: *const VTable,

    const VTable = struct {
        set: Setter,
    };

    pub fn set(self: *ValueRef, value: []const u8) anyerror!void {
        return self.vtable.set(self.ptr, value);
    }
};

fn primitiveTypeVTable(comptime T: anytype) *const ValueRef.VTable {
    const ptr_info = @typeInfo(T);

    std.debug.assert(ptr_info == .Pointer);
    std.debug.assert(ptr_info.Pointer.size == .One);
    const childT = ptr_info.Pointer.child;
    const child_info = @typeInfo(childT);

    const setter = switch (child_info) {
        .Int => a: {
            const gen = struct {
                fn setInt(ptr: *anyopaque, value: []const u8) anyerror!void {
                    var v = try std.fmt.parseInt(childT, value, 10);
                    const p = @as(*childT, @ptrCast(@alignCast(ptr)));
                    p.* = v;
                }
            };
            break :a gen.setInt;
        },
        else => unreachable,
    };

    const vt = ValueRef.VTable{
        .set = setter,
    };
    return &vt;
}

pub fn valueRef(comptime ptr: anytype) ValueRef {
    const ti = @TypeOf(ptr);
    const vtable = primitiveTypeVTable(ti);
    return .{
        .ptr = ptr,
        .vtable = vtable,
    };
}

pub const Option = struct {
    long_name: []const u8,
    short_alias: ?u8 = null,
    help: []const u8,
    required: bool = false,
    value: OptionValue,
    value_ref: ?ValueRef = null,
    value_ref2: ?ValueRef2 = null,
    value_name: []const u8 = "VALUE",
};

pub fn mkOption(comptime ref: anytype, long_name: []const u8, help: []const u8) Option {
    return .{
        .long_name = long_name,
        .help = help,
        .value_ref = valueRef(ref),
    };
}

pub const ValueRef2 = struct {
    impl_ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    const VTable = struct {
        put: *const fn (impl_ptr: *anyopaque, value: []const u8) anyerror!void,

        // finalize and destroy
        finalize: *const fn (impl_ptr: *anyopaque) anyerror!void,
    };

    pub fn put(self: *Self, value: []const u8) anyerror!void {
        return self.vtable.put(self.impl_ptr, value);
    }
    pub fn finalize(self: *Self) anyerror!void {
        return self.vtable.finalize(self.impl_ptr);
    }
};

// const Parser = *const fn (dest: *anyopaque, value: []const u8) anyerror!void;
fn Parser(comptime T: type) type {
    return *const fn (dest: *T, value: []const u8) anyerror!void;
}

pub fn IntParser(comptime T: type) Parser(T) {
    return struct {
        fn parser(dest: *T, value: []const u8) anyerror!void {
            var v = try std.fmt.parseInt(T, value, 10);
            dest.* = v;
        }
    }.parser;
}

pub fn singleValueRef(comptime T: type, dest: *T, parser: Parser(T), alloc: std.mem.Allocator) !ValueRef2 {
    const Impl = struct {
        dest: *T,
        parser: Parser(T),
        alloc: std.mem.Allocator,

        const Self = @This();

        fn put(ctx: *anyopaque, value: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.parser(self.dest, value);
        }
        fn finalize(ctx: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.alloc.destroy(self);
        }
    };

    const im = try alloc.create(Impl);
    im.dest = dest;
    im.parser = parser;
    im.alloc = alloc;

    return ValueRef2{ .impl_ptr = im, .vtable = &.{
        .put = Impl.put,
        .finalize = Impl.finalize,
    } };
}

pub const AllocWrapper = struct {
    alloc: std.mem.Allocator,

    pub fn singleInt(self: *const AllocWrapper, dest: anytype) !ValueRef2 {
        const ti = @typeInfo(@TypeOf(dest));
        const parser = IntParser(ti.Pointer.child);
        return singleValueRef(ti.Pointer.child, dest, parser, self.alloc);
    }
};
