//! Specialized semantic emission. Backends meter wire bytes before output.
const std = @import("std");
const descriptor = @import("descriptor.zig");
const ctx = @import("context.zig");
const model = @import("model.zig");

pub fn serialize(value: anytype, serializer: anytype, c: *ctx.Context) (ctx.EncodeError || @TypeOf(serializer.*).Error)!void {
    comptime descriptor.check(@TypeOf(value), @TypeOf(serializer.*).capabilities, false, .borrowed);
    try emit(.{}, value, serializer, c, null);
}
const Active = struct { address: usize, previous: ?*const Active };
fn emit(comptime policy: descriptor.Field, value: anytype, out: anytype, c: *ctx.Context, active: ?*const Active) (ctx.EncodeError || @TypeOf(out.*).Error)!void {
    @setRuntimeSafety(true);
    const T = @TypeOf(value);
    try c.node();
    try c.chargeWork(1);
    if (comptime descriptor.has(T, "strandSerialize")) {
        var access: Access(@TypeOf(out.*)) = .{ .out = out, .context = c, .active = active };
        try value.strandSerialize(&access);
        if (!access.used) return error.CustomRejected;
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try out.boolean(value, c),
        .int => try out.integer(value, c),
        .float => try out.floating(value, c),
        .void => try out.unit(c),
        .null => try out.nullValue(c),
        .@"enum" => try out.text(@tagName(value), c),
        .optional => if (value) |v| {
            c.items -= 1;
            try emit(policy, v, out, c, active);
        } else try out.nullValue(c),
        .pointer => |i| switch (i.size) {
            .one => {
                var ancestor = active;
                while (ancestor) |a| : (ancestor = a.previous) {
                    try c.chargeWork(1);
                    if (a.address == @intFromPtr(value)) return error.CycleDetected; // safe: only live data pointers are compared for active-path identity; no integer dereference.
                }
                const frame: Active = .{ .address = @intFromPtr(value), .previous = active }; // safe: only live data pointers are compared for active-path identity; no integer dereference.
                try c.enter();
                defer c.leave();
                c.items -= 1;
                try emit(policy, value.*, out, c, &frame);
            },
            .slice => {
                if (value.len > policy.max_len) return error.LengthLimit;
                if (i.child == u8) {
                    try c.span(value.len, false);
                    try c.chargeWork(value.len);
                    if (policy.as == .bytes) try out.bytes(value, c) else {
                        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                        try out.text(value, c);
                    }
                } else {
                    try begin(out, c, .sequence, "", value.len);
                    defer c.leave();
                    for (value) |v| try emit(.{}, v, out, c, active);
                    try out.end(c);
                }
            },
            else => unreachable,
        },
        inline .array, .vector => |i| {
            const values: [i.len]i.child = value;
            try begin(out, c, .tuple, "", i.len);
            defer c.leave();
            for (values) |v| try emit(.{}, v, out, c, active);
            try out.end(c);
        },
        .@"struct" => |i| {
            var count: usize = 0;
            inline for (i.field_names, i.field_attrs) |name, attrs| {
                if (!attrs.@"comptime" and !omit(T, name, value)) count += 1;
            }
            try begin(out, c, if (i.is_tuple) .tuple else .record, @typeName(T), count);
            defer c.leave();
            inline for (i.field_names, i.field_attrs) |name, attrs| {
                if (attrs.@"comptime") continue;
                const f = comptime descriptor.field(T, name);
                if (!omit(T, name, value)) {
                    if (!i.is_tuple) {
                        try c.node();
                        try c.span(f.name.len, true);
                        try c.chargeWork(f.name.len);
                        try out.key(f.name, c);
                    }
                    try emit(f, @field(value, name), out, c, active);
                }
            }
            try out.end(c);
        },
        .@"union" => switch (value) {
            inline else => |v, tag| {
                try begin(out, c, .variant, @tagName(tag), 1);
                defer c.leave();
                try emit(.{}, v, out, c, active);
                try out.end(c);
            },
        },
        else => @compileError("unsupported core encode type"),
    }
}
fn begin(out: anytype, c: *ctx.Context, kind: model.Kind, name: []const u8, n: usize) (ctx.EncodeError || @TypeOf(out.*).Error)!void {
    try c.enter();
    errdefer c.leave();
    try c.count(n);
    try out.begin(kind, name, n, c);
}
fn omit(comptime T: type, comptime name: []const u8, value: T) bool {
    const policy = comptime descriptor.field(T, name);
    if (policy.skip_encode) return true;
    return switch (policy.omit) {
        .never => false,
        .null_value => if (@typeInfo(@FieldType(T, name)) == .optional) @field(value, name) == null else @compileError("omit.null_value requires an optional"),
        .default_value => blk: {
            const expected = comptime descriptor.default(T, name) orelse @compileError("omit.default_value requires a default");
            break :blk std.meta.eql(@field(value, name), expected);
        },
    };
}

/// Custom codecs emit one surrogate value through the same checked kernel.
pub fn Access(comptime Backend: type) type {
    return struct {
        out: *Backend,
        context: *ctx.Context,
        active: ?*const Active,
        used: bool = false,
        const Self = @This();
        pub fn write(self: *Self, value: anytype) (ctx.EncodeError || Backend.Error)!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.context.items -= 1;
            try emit(.{}, value, self.out, self.context, self.active);
        }
    };
}
