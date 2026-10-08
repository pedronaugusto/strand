//! Specialized semantic emission. Backends meter wire bytes before output.
const std = @import("std");
const descriptor = @import("descriptor.zig");
const ctx = @import("context.zig");
const model = @import("model.zig");

pub fn serialize(value: anytype, serializer: anytype, c: *ctx.Context) Errors(@TypeOf(value), @TypeOf(serializer.*))!void {
    comptime descriptor.check(@TypeOf(value), @TypeOf(serializer.*).capabilities, false, .borrowed);
    try emit(.{}, value, serializer, c, null);
}
const Active = struct { address: usize, previous: ?*const Active };
fn emit(comptime policy: descriptor.Field, value: anytype, out: anytype, c: *ctx.Context, active: ?*const Active) Errors(@TypeOf(value), @TypeOf(out.*))!void {
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
            if (policy.as != .normal) {
                if (i.child != u8) @compileError("text/bytes array codec requires u8 elements");
                if (i.len > policy.max_len) return error.LengthLimit;
                try c.span(i.len, false);
                try c.chargeWork(i.len);
                if (policy.as == .bytes) try out.bytes(&values, c) else {
                    if (!std.unicode.utf8ValidateSlice(&values)) return error.InvalidUtf8;
                    try out.text(&values, c);
                }
                return;
            }
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
        pub const Error = ctx.EncodeError || Backend.Error;
        const Self = @This();
        pub fn raw(self: *Self, comptime Format: type, bytes: []const u8) (ctx.EncodeError || Backend.Error)!void {
            if (Backend.Format != Format) @compileError("raw format brand does not match the backend");
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (Backend.canonical) return error.UnsupportedValue;
            self.context.items -= 1;
            try self.out.validateRaw(bytes, self.context);
            try self.out.raw(bytes, self.context);
        }
        pub fn write(self: *Self, value: anytype) Errors(@TypeOf(value), Backend)!void {
            comptime descriptor.check(@TypeOf(value), Backend.capabilities, false, .borrowed);
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.context.items -= 1;
            try emit(.{}, value, self.out, self.context, self.active);
        }
    };
}

fn Errors(comptime T: type, comptime Backend: type) type {
    return ctx.EncodeError || Backend.Error || HookErrors(T, Backend, &.{});
}
fn HookErrors(comptime T: type, comptime Backend: type, comptime seen: []const type) type {
    for (seen) |prior| if (T == prior) return error{};
    const next = seen ++ .{T};
    if (descriptor.has(T, "strandSerialize")) {
        const result = @TypeOf(@as(T, undefined).strandSerialize(@as(*Access(Backend), undefined)));
        const errors = @typeInfo(result).error_union.error_set;
        if (@typeInfo(errors).error_set.error_names == null) @compileError("data codecs require a named error set");
        return errors;
    }
    return switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| HookErrors(i.child, Backend, next),
        inline .@"struct", .@"union" => |i| blk: {
            var errors: type = error{};
            for (i.field_types) |F| errors = errors || HookErrors(F, Backend, next);
            break :blk errors;
        },
        else => error{},
    };
}
