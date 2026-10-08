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
        try c.enterHook();
        defer c.leaveHook();
        var access: Access(@TypeOf(out.*)) = .{ .out = out, .context = c, .active = active };
        try value.strandSerialize(&access);
        if (!access.used) return error.CustomRejected;
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try out.boolean(value, c),
        .int => try out.integer(value, c),
        .float => {
            if (!@TypeOf(out.*).capabilities.nonfinite_floats and !std.math.isFinite(value)) return error.UnsupportedValue;
            try out.floating(value, c);
        },
        .void => try out.unit(c),
        .null => try out.nullValue(c),
        .@"enum" => switch (value) {
            inline else => |tag| {
                const name = (comptime descriptor.variant(T, @tagName(tag))).name;
                try c.span(name.len, false);
                try c.chargeWork(name.len);
                try out.text(name, c);
            },
        },
        .optional => return emitOptional(T, policy, value, out, c, active),
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
            if (i.len > policy.max_len) return error.LengthLimit;
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
                if (!attrs.@"comptime" and !(try omit(T, name, value, c))) count += 1;
            }
            try begin(out, c, if (i.is_tuple) .tuple else .record, @typeName(T), count);
            defer c.leave();
            inline for (i.field_names, i.field_attrs) |name, attrs| {
                if (attrs.@"comptime") continue;
                const f = comptime descriptor.field(T, name);
                if (!(try omit(T, name, value, c))) {
                    if (!i.is_tuple) {
                        try c.node();
                        try c.span(f.name.len, true);
                        try c.chargeWork(f.name.len);
                        try out.key(f.name, c);
                    }
                    try emitField(T, name, value, out, c, active);
                }
            }
            try out.end(c);
        },
        .@"union" => switch (value) {
            inline else => |v, tag| {
                const opt = comptime descriptor.options(T);
                if (@hasField(@TypeOf(opt), "tag")) return tagged(T, value, out, c, active);
                try begin(out, c, .variant, (comptime descriptor.variant(T, @tagName(tag))).name, 1);
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
fn omit(comptime T: type, comptime name: []const u8, value: T, c: *ctx.Context) ctx.EncodeError!bool {
    const policy = comptime descriptor.field(T, name);
    if (policy.skip_encode) return true;
    const declared = comptime descriptor.fieldOptions(T, name);
    if (@hasField(@TypeOf(declared), "omit_if")) return declared.omit_if(@field(value, name));
    return switch (policy.omit) {
        .never => false,
        .null_value => if (@typeInfo(@FieldType(T, name)) == .optional) @field(value, name) == null else @compileError("omit.null_value requires an optional"),
        .default_value => blk: {
            const expected = comptime descriptor.default(T, name) orelse @compileError("omit.default_value requires a default");
            break :blk if (@hasField(@TypeOf(declared), "equal")) declared.equal(@field(value, name), expected) else try equal(@FieldType(T, name), @field(value, name), expected, c);
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
        pub fn named(self: *Self, value: anytype, kind: model.Kind, name: []const u8) Errors(@TypeOf(value), Backend)!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            try self.context.span(name.len, false);
            try begin(self.out, self.context, kind, name, 1);
            defer self.context.leave();
            try emit(.{}, value, self.out, self.context, self.active);
            try self.out.end(self.context);
        }
        pub fn namedUnit(self: *Self, name: []const u8) Error!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            try self.context.span(name.len, false);
            try begin(self.out, self.context, .named_unit, name, 0);
            defer self.context.leave();
            try self.out.end(self.context);
        }
        pub fn namedTuple(self: *Self, value: anytype, name: []const u8) Errors(@TypeOf(value), Backend)!void {
            const T = @TypeOf(value);
            if (self.used) return error.CustomRejected;
            self.used = true;
            try self.context.span(name.len, false);
            switch (@typeInfo(T)) {
                .@"struct" => |i| {
                    if (!i.is_tuple) @compileError("named tuple requires a tuple shape");
                    var count: usize = 0;
                    inline for (i.field_attrs) |attrs| if (!attrs.@"comptime") {
                        count += 1;
                    };
                    try begin(self.out, self.context, .named_tuple, name, count);
                    defer self.context.leave();
                    inline for (i.field_names, i.field_attrs) |field_name, attrs| if (!attrs.@"comptime") {
                        try emit(.{}, @field(value, field_name), self.out, self.context, self.active);
                    };
                },
                inline .array, .vector => |i| {
                    try begin(self.out, self.context, .named_tuple, name, i.len);
                    defer self.context.leave();
                    const lanes: [i.len]i.child = value;
                    for (lanes) |v| try emit(.{}, v, self.out, self.context, self.active);
                },
                else => @compileError("named tuple requires a fixed tuple shape"),
            }
            try self.out.end(self.context);
        }
        pub fn bytes(self: *Self, value: []const u8) Error!void {
            if (!Backend.capabilities.bytes) return error.UnsupportedValue;
            if (self.used) return error.CustomRejected;
            self.used = true;
            try self.context.span(value.len, false);
            try self.context.chargeWork(value.len);
            try self.out.bytes(value, self.context);
        }
        pub fn scalar(self: *Self, value: u21) Error!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!std.unicode.utf8ValidCodepoint(value)) return error.InvalidUtf8;
            try self.out.scalar(value, self.context);
        }
        pub fn writeSequence(self: *Self, values: anytype) Errors(@TypeOf(values[0]), Backend)!void {
            comptime descriptor.check(@TypeOf(values[0]), Backend.capabilities, false, .borrowed);
            if (self.used) return error.CustomRejected;
            self.used = true;
            try begin(self.out, self.context, .sequence, "", values.len);
            defer self.context.leave();
            for (values) |v| try emit(.{}, v, self.out, self.context, self.active);
            try self.out.end(self.context);
        }
        pub fn reject(self: *Self, code: u32) error{CustomRejected} {
            return self.context.reject(code);
        }
        pub fn writePairs(self: *Self, values: anytype) (Errors(@TypeOf(values[0].key), Backend) || Errors(@TypeOf(values[0].value), Backend))!void {
            comptime descriptor.check(@TypeOf(values[0].key), Backend.capabilities, false, .borrowed);
            comptime descriptor.check(@TypeOf(values[0].value), Backend.capabilities, false, .borrowed);
            if (self.used) return error.CustomRejected;
            self.used = true;
            try begin(self.out, self.context, .map, "", values.len);
            defer self.context.leave();
            for (values) |v| {
                if (@typeInfo(@TypeOf(v.key)) == .pointer and @typeInfo(@TypeOf(v.key)).pointer.size == .slice and @typeInfo(@TypeOf(v.key)).pointer.child == u8) try self.context.span(v.key.len, true);
                if (comptime descriptor.has(@TypeOf(v.key), "strandBytes")) try self.context.span(v.key.value.len, true);
                try emit(.{}, v.key, self.out, self.context, self.active);
                try emit(.{}, v.value, self.out, self.context, self.active);
            }
            try self.out.end(self.context);
        }
        pub fn raw(self: *Self, comptime Format: type, payload: []const u8) (ctx.EncodeError || Backend.Error)!void {
            if (Backend.Format != Format) @compileError("raw format brand does not match the backend");
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (Backend.canonical) return error.UnsupportedValue;
            self.context.items -= 1;
            try self.out.validateRaw(payload, self.context);
            try self.out.raw(payload, self.context);
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
            for (i.field_types, i.field_names) |F, name| {
                const opt = descriptor.fieldOptions(T, name);
                if (@hasField(@TypeOf(opt), "codec") and @hasDecl(opt.codec, "encode")) errors = errors || @typeInfo(@TypeOf(opt.codec.encode(@as(F, undefined), @as(*Access(Backend), undefined)))).error_union.error_set else errors = errors || HookErrors(F, Backend, next);
            }
            if (@typeInfo(errors).error_set.error_names == null) @compileError("field codecs require named errors");
            break :blk errors;
        },
        else => error{},
    };
}

/// Structural default equality never compares padding or pointer addresses.
fn equal(comptime T: type, a: T, b: T, c: *ctx.Context) ctx.EncodeError!bool {
    try c.enter();
    defer c.leave();
    try c.chargeWork(1);
    return switch (@typeInfo(T)) {
        .pointer => |i| switch (i.size) {
            .one => try equal(i.child, a.*, b.*, c),
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                for (a, b) |x, y| if (!try equal(i.child, x, y, c)) break :blk false;
                break :blk true;
            },
            else => unreachable,
        },
        .optional => |i| if (a) |x| if (b) |y| try equal(i.child, x, y, c) else false else b == null,
        .@"struct" => |i| blk: {
            inline for (i.field_names, i.field_types) |name, F| if (!try equal(F, @field(a, name), @field(b, name), c)) break :blk false;
            break :blk true;
        },
        .array, .vector => |i| blk: {
            for (0..i.len) |index| if (!try equal(i.child, a[index], b[index], c)) break :blk false;
            break :blk true;
        },
        .@"union" => blk: {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) break :blk false;
            break :blk switch (a) {
                inline else => |v, tag| try equal(@TypeOf(v), v, @field(b, @tagName(tag)), c),
            };
        },
        .void, .null => true,
        else => a == b,
    };
}

fn tagged(comptime T: type, value: T, out: anytype, c: *ctx.Context, active: ?*const Active) Errors(T, @TypeOf(out.*))!void {
    const opt = comptime descriptor.options(T);
    switch (value) {
        inline else => |v, tag| {
            const F = @TypeOf(v);
            const count = if (@hasField(@TypeOf(opt), "content")) 2 else if (F == void) 1 else blk: {
                var n: usize = 1;
                inline for (@typeInfo(F).@"struct".field_names, @typeInfo(F).@"struct".field_attrs) |name, attrs| if (!attrs.@"comptime" and !try omit(F, name, v, c)) {
                    n += 1;
                };
                break :blk n;
            };
            try begin(out, c, .record, @typeName(T), count);
            defer c.leave();
            try c.node();
            try c.span(opt.tag.len, true);
            try out.key(opt.tag, c);
            const wire_tag = (comptime descriptor.variant(T, @tagName(tag))).name;
            try c.node();
            try c.span(wire_tag.len, false);
            try out.text(wire_tag, c);
            if (@hasField(@TypeOf(opt), "content")) {
                try c.node();
                try c.span(opt.content.len, true);
                try out.key(opt.content, c);
                try emit(.{}, v, out, c, active);
            } else if (F != void) {
                inline for (@typeInfo(F).@"struct".field_names, @typeInfo(F).@"struct".field_attrs) |name, attrs| {
                    if (attrs.@"comptime") continue;
                    if (!try omit(F, name, v, c)) {
                        const policy = comptime descriptor.field(F, name);
                        try c.node();
                        try c.span(policy.name.len, true);
                        try out.key(policy.name, c);
                        try emitField(F, name, v, out, c, active);
                    }
                }
            }
            try out.end(c);
        },
    }
}

fn emitField(comptime T: type, comptime name: []const u8, value: T, out: anytype, c: *ctx.Context, active: ?*const Active) Errors(T, @TypeOf(out.*))!void {
    try descriptor.validate(T, name, @field(value, name));
    const declared = comptime descriptor.fieldOptions(T, name);
    if (@hasField(@TypeOf(declared), "codec")) {
        try c.node();
        var access: Access(@TypeOf(out.*)) = .{ .out = out, .context = c, .active = active };
        try declared.codec.encode(@field(value, name), &access);
        if (!access.used) return error.CustomRejected;
    } else try emit(comptime descriptor.field(T, name), @field(value, name), out, c, active);
}

fn emitOptional(comptime T: type, comptime policy: descriptor.Field, value: T, out: anytype, c: *ctx.Context, active: ?*const Active) Errors(T, @TypeOf(out.*))!void {
    if (value) |v| {
        if (@TypeOf(out.*).capabilities.nested_optional) {
            try begin(out, c, .some, "", 1);
            defer c.leave();
            try emit(policy, v, out, c, active);
            try out.end(c);
        } else {
            c.items -= 1;
            try emit(policy, v, out, c, active);
        }
    } else try out.nullValue(c);
}
