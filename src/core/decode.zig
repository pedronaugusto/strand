//! One bounded typed mapping kernel over immediate semantic events.
const std = @import("std");
const descriptor = @import("descriptor.zig");
const ctx = @import("context.zig");
const model = @import("model.zig");

/// Backend.next(context) must meter wire reads/scratch through context before
/// doing that work, validate grammar, and distinguish input from scratch spans.
/// endInput verifies no trailing value. All backend errors are named.
pub fn deserialize(comptime T: type, backend: anytype, c: *ctx.Context) Errors(T, @TypeOf(backend.*))!T {
    comptime descriptor.check(T, @TypeOf(backend.*).capabilities, true, .borrowed);
    var cursor: Cursor(@TypeOf(backend.*)) = .{ .backend = backend, .context = c };
    const value = try cursor.read(T, .{});
    try backend.endInput(c);
    return value;
}

pub fn Cursor(comptime Backend: type) type {
    return struct {
        backend: *Backend,
        context: *ctx.Context,
        pending: ?model.Event = null,
        pending_start: usize = 0,
        const Self = @This();
        const Error = ctx.DecodeError || Backend.Error;
        fn peek(self: *Self) Error!model.Event {
            if (self.pending == null) {
                self.pending_start = self.backend.offset();
                self.pending = try self.backend.next(self.context);
            }
            return self.pending.?;
        }
        fn take(self: *Self) Error!model.Event {
            const event = try self.peek();
            self.pending = null;
            return event;
        }
        fn end(self: *Self) Error!void {
            if (try self.take() != .end) return error.SyntaxError;
        }
        fn start(self: *Self, expected: model.Kind) Error!model.Compound {
            const event = try self.take();
            if (event != .begin) return error.UnexpectedType;
            if (event.begin.kind != expected and !(expected == .tuple and event.begin.kind == .sequence) and !(expected == .record and event.begin.kind == .map)) return error.UnexpectedType;
            try self.context.enter();
            errdefer self.context.leave();
            if (event.begin.len) |n| try self.context.count(n);
            return event.begin;
        }
        fn equals(self: *Self, a: []const u8, b: []const u8) Error!bool {
            try self.context.chargeWork(@min(a.len, b.len));
            return std.mem.eql(u8, a, b);
        }
        fn key(self: *Self) Error![]const u8 {
            try self.context.node();
            const event = try self.take();
            if (event != .text) return error.UnexpectedType;
            try self.context.span(event.text.bytes.len, true);
            try self.context.chargeWork(event.text.bytes.len);
            if (!std.unicode.utf8ValidateSlice(event.text.bytes)) return error.InvalidUtf8;
            return event.text.bytes;
        }
        fn integer(self: *Self, comptime T: type, number: model.Integer) Error!T {
            @setRuntimeSafety(true);
            const i = @typeInfo(T).int;
            const U = @Int(.unsigned, i.bits);
            if (number.magnitude.len > self.context.limits.numeric_bytes) return error.LengthLimit;
            try self.context.chargeWork(number.magnitude.len);
            var value: U = 0;
            var n = number.magnitude.len;
            while (n > 0) {
                n -= 1;
                if (i.bits < 8) {
                    if (value != 0 or number.magnitude[n] > std.math.maxInt(U)) return error.NumberOutOfRange;
                    // safe: the byte was checked against the destination width.
                    value = @intCast(number.magnitude[n]); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
                } else {
                    if (i.bits == 8) {
                        if (value != 0) return error.NumberOutOfRange;
                        value = number.magnitude[n];
                    } else {
                        if (value > std.math.maxInt(U) >> 8) return error.NumberOutOfRange;
                        value = (value << 8) | number.magnitude[n];
                    }
                }
            }
            if (i.signedness == .unsigned) {
                if (number.negative and value != 0) return error.NumberOutOfRange;
                return value;
            }
            if (i.bits == 0) return 0;
            if (number.negative) {
                const minimum: U = @as(U, 1) << (i.bits - 1);
                if (value > minimum) return error.NumberOutOfRange;
                if (value == minimum) return std.math.minInt(T);
                // safe: value is strictly below the magnitude of the signed min.
                return -@as(T, @intCast(value)); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
            }
            if (value > std.math.maxInt(T)) return error.NumberOutOfRange;
            // safe: positive magnitude was checked against the signed maximum.
            return @intCast(value); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
        }
        pub fn read(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            @setRuntimeSafety(true);
            comptime descriptor.check(T, Backend.capabilities, true, .borrowed);
            try self.context.node();
            try self.context.chargeWork(1);
            if (comptime descriptor.has(T, "strandDeserialize")) {
                var access: Access(Backend) = .{ .cursor = self };
                const value = try T.strandDeserialize(&access);
                if (!access.used) return error.CustomRejected;
                return value;
            }
            switch (@typeInfo(T)) {
                .bool => {
                    const event = try self.take();
                    if (event != .boolean) return error.UnexpectedType;
                    return event.boolean;
                },
                .int => {
                    const event = try self.take();
                    if (event != .integer) return error.UnexpectedType;
                    return self.integer(T, event.integer);
                },
                .float => {
                    const event = try self.take();
                    if (event != .floating) return error.UnexpectedType;
                    // safe: float narrowing is the declared destination's rounding;
                    // overflow is explicitly rejected before publishing the result.
                    const value: T = @floatCast(event.floating); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
                    if (std.math.isFinite(event.floating) and !std.math.isFinite(value)) return error.NumberOutOfRange;
                    return value;
                },
                .void => {
                    if (try self.take() != .unit) return error.UnexpectedType;
                    return {};
                },
                .null => {
                    if (try self.take() != .none) return error.UnexpectedType;
                    return null;
                },
                .optional => |i| {
                    if (try self.peek() == .none) {
                        _ = try self.take();
                        return null;
                    }
                    // Optional presence is a type hint, not an extra wire node.
                    self.context.items -= 1;
                    return try self.read(i.child, policy);
                },
                .pointer => |i| switch (i.size) {
                    .one => {
                        self.context.items -= 1;
                        const storage = try self.context.allocPointer(T, 1);
                        storage.* = try self.read(i.child, policy);
                        return storage;
                    },
                    .slice => return self.slice(T, policy),
                    else => unreachable,
                },
                .array, .vector => return self.fixed(T, policy),
                .@"struct" => |i| {
                    if (i.is_tuple) {
                        _ = try self.start(.tuple);
                        defer self.context.leave();
                        var value: T = undefined;
                        inline for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| {
                            if (attrs.@"comptime") continue;
                            @field(value, name) = try self.read(F, comptime descriptor.field(T, name));
                        }
                        try self.end();
                        return value;
                    }
                    return self.record(T);
                },
                .@"enum" => |i| {
                    const name = try self.keyValue();
                    inline for (i.field_names) |variant| if (try self.equals(name, variant)) return @field(T, variant);
                    return error.UnknownVariant;
                },
                .@"union" => |i| {
                    const header = try self.start(.variant);
                    defer self.context.leave();
                    inline for (i.field_names, i.field_types) |name, F| {
                        if (try self.equals(header.name, name)) {
                            const value = @unionInit(T, name, try self.read(F, .{ .name = name }));
                            try self.end();
                            return value;
                        }
                    }
                    return error.UnknownVariant;
                },
                else => @compileError("unsupported core decode type"),
            }
        }
        fn fixed(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            const i = if (@typeInfo(T) == .array) @typeInfo(T).array else @typeInfo(T).vector;

            if (policy.as != .normal) {
                if (i.child != u8) @compileError("text/bytes array codec requires u8 elements");
                const event = try self.take();
                const span = switch (event) {
                    .text => |v| if (policy.as == .text) v else return error.UnexpectedType,
                    .bytes => |v| if (policy.as == .bytes) v else return error.UnexpectedType,
                    else => return error.UnexpectedType,
                };
                if (span.bytes.len != i.len) return error.UnexpectedType;
                if (span.bytes.len > policy.max_len) return error.LengthLimit;
                try self.context.span(span.bytes.len, false);
                try self.context.chargeWork(span.bytes.len);
                if (policy.as == .text and !std.unicode.utf8ValidateSlice(span.bytes)) return error.InvalidUtf8;
                var array: if (@typeInfo(T) == .array) T else [i.len]i.child = undefined;
                @memcpy(&array, span.bytes);
                if (@typeInfo(T) == .array) if (i.sentinel()) |sentinel| {
                    array[i.len] = sentinel;
                };
                return array;
            }
            const header = try self.start(.tuple);
            defer self.context.leave();
            if (header.len) |n| if (n != i.len) return error.UnexpectedType;
            var array: if (@typeInfo(T) == .array) T else [i.len]i.child = undefined;
            if (@typeInfo(T) == .array) if (i.sentinel()) |sentinel| {
                array[i.len] = sentinel;
            };
            for (&array, 0..) |*element, index| {
                const old = if (self.context.diagnostics) |d| d.count else 0;
                if (self.context.diagnostics) |d| d.index(index);
                element.* = try self.read(i.child, .{ .name = "" });
                if (self.context.diagnostics) |d| d.count = old;
            }
            try self.end();
            return array;
        }
        fn keyValue(self: *Self) Error![]const u8 {
            const event = try self.take();
            if (event != .text) return error.UnexpectedType;
            try self.context.span(event.text.bytes.len, false);
            try self.context.chargeWork(event.text.bytes.len);
            if (!std.unicode.utf8ValidateSlice(event.text.bytes)) return error.InvalidUtf8;
            return event.text.bytes;
        }
        fn slice(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            const i = @typeInfo(T).pointer;
            if (i.child == u8) {
                const event = try self.take();
                const bytes = switch (event) {
                    .text => |s| if (policy.as == .bytes) return error.UnexpectedType else s,
                    .bytes => |s| if (policy.as != .bytes) return error.UnexpectedType else s,
                    else => return error.UnexpectedType,
                };
                if (bytes.bytes.len > policy.max_len) return error.LengthLimit;
                try self.context.span(bytes.bytes.len, false);
                try self.context.chargeWork(bytes.bytes.len);
                if (policy.as != .bytes and !std.unicode.utf8ValidateSlice(bytes.bytes)) return error.InvalidUtf8;
                if (i.attrs.@"const" and i.sentinel() == null and (i.attrs.@"align" orelse 1) == 1) return self.context.retain(bytes.bytes, bytes.lifetime, policy.borrow);
                if (policy.borrow == .require) return error.BorrowUnavailable;
                try self.context.chargeWork(bytes.bytes.len);
                const storage = try self.context.allocPointer(T, bytes.bytes.len);
                @memcpy(storage, bytes.bytes);
                return storage;
            }
            const header = try self.start(.sequence);
            defer self.context.leave();
            if (header.len) |n| {
                if (n > policy.max_len) return error.LengthLimit;
                const values = try self.context.allocPointer(T, n);
                for (values) |*v| v.* = try self.read(i.child, .{ .name = "" });
                try self.end();
                return values;
            }
            var values = try self.context.allocPointer(T, 0);
            var initialized: usize = 0;
            while (try self.peek() != .end) {
                if (initialized >= policy.max_len or initialized >= self.context.limits.container_items) return error.LengthLimit;
                try self.context.count(1);
                if (initialized == values.len) {
                    const capacity = @max(@as(usize, 1), std.math.mul(usize, values.len, 2) catch return error.AllocationLimit);
                    const grown = try self.context.allocPointer(T, @min(capacity, @min(policy.max_len, self.context.limits.container_items)));
                    try self.context.chargeWork(initialized);
                    @memcpy(grown[0..initialized], values[0..initialized]);
                    values = grown;
                }
                values[initialized] = try self.read(i.child, .{});
                initialized += 1;
            }
            try self.end();
            if (i.sentinel()) |sentinel| {
                values.ptr[initialized] = sentinel;
                return values[0..initialized :sentinel];
            }
            return values[0..initialized];
        }
        fn record(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const i = @typeInfo(T).@"struct";
            const opt = comptime descriptor.options(T);
            const unknown: descriptor.Unknown = if (@hasField(@TypeOf(opt), "unknown_fields")) opt.unknown_fields else .ignore;
            const duplicates: descriptor.Duplicates = if (@hasField(@TypeOf(opt), "duplicates")) opt.duplicates else .reject;
            const header = try self.start(.record);
            defer self.context.leave();
            var value: T = undefined;
            var seen: [i.field_names.len]bool = @splat(false);
            var pairs: usize = 0;
            while (try self.peek() != .end) {
                try self.context.count(1);
                if (pairs >= self.context.limits.container_items) return error.ItemLimit;
                pairs += 1;
                const name = try self.key();
                var matched: ?usize = null;
                inline for (i.field_names, i.field_attrs, 0..) |field_name, attrs, index| {
                    if (attrs.@"comptime") continue;
                    const f = comptime descriptor.field(T, field_name);
                    var matches = try self.equals(name, f.name);
                    inline for (f.aliases) |alias| matches = matches or try self.equals(name, alias);
                    if (matches) matched = index;
                }
                inline for (i.field_names, i.field_types, i.field_attrs, 0..) |field_name, F, attrs, index| {
                    if (attrs.@"comptime") continue;
                    if (matched == index) {
                        const f = comptime descriptor.field(T, field_name);
                        if (seen[index] and duplicates == .reject) return error.DuplicateField;
                        if (f.skip_decode or (seen[index] and duplicates == .first)) {
                            try self.skip();
                        } else {
                            const old = if (self.context.diagnostics) |d| d.count else 0;
                            if (self.context.diagnostics) |d| d.field(field_name);
                            @field(value, field_name) = try self.read(F, f);
                            if (self.context.diagnostics) |d| d.count = old;
                        }
                        seen[index] = !f.skip_decode;
                    }
                }
                if (matched == null) {
                    if (unknown == .reject) return error.UnknownField;
                    try self.skip();
                }
            }
            if (header.len) |n| if (n != pairs) return error.SyntaxError;
            try self.end();
            inline for (i.field_names, i.field_types, i.field_attrs, 0..) |name, F, attrs, index| {
                if (attrs.@"comptime") continue;
                if (!seen[index]) {
                    const default_option = comptime descriptor.default(T, name);
                    const default_value = default_option orelse return error.MissingField;
                    // Materialize pointer-bearing defaults in the result arena; static
                    // literals must never be accidentally owned/freed or left borrowed.
                    @field(value, name) = try clone(F, default_value, self.context);
                }
            }
            return value;
        }
        /// Every ignored value still traverses the complete wire structure.
        pub fn skip(self: *Self) Error!void {
            @setRuntimeSafety(true);
            try self.context.node();
            try self.context.chargeWork(1);
            switch (try self.take()) {
                .end => return error.SyntaxError,
                .text => |span| {
                    try self.context.span(span.bytes.len, false);
                    try self.context.chargeWork(span.bytes.len);
                    if (!std.unicode.utf8ValidateSlice(span.bytes)) return error.InvalidUtf8;
                },
                .bytes => |span| {
                    try self.context.span(span.bytes.len, false);
                    try self.context.chargeWork(span.bytes.len);
                },
                .integer => |n| {
                    if (n.magnitude.len > self.context.limits.numeric_bytes) return error.LengthLimit;
                    try self.context.chargeWork(n.magnitude.len);
                },
                .begin => |header| {
                    try self.context.enter();
                    defer self.context.leave();
                    if (header.len) |n| try self.context.count(n);
                    var count: usize = 0;
                    while (try self.peek() != .end) {
                        if (count >= self.context.limits.container_items) return error.ItemLimit;
                        count += 1;
                        if (header.kind == .record) _ = try self.key();
                        if (header.kind == .map) {
                            const key_event = try self.peek();
                            if (key_event == .text) try self.context.span(key_event.text.bytes.len, true);
                            try self.skip();
                        }
                        try self.skip();
                    }
                    if (header.len) |n| if (count != n) return error.SyntaxError;
                    try self.end();
                },
                else => {},
            }
        }
    };
}

/// A custom codec consumes exactly one bounded data value, commonly a surrogate
/// record/tuple/newtype. A second read or no read is rejected. It cannot obtain
/// an unmetered token source through this contract.
pub fn Access(comptime Backend: type) type {
    return struct {
        cursor: *Cursor(Backend),
        used: bool = false,
        pub const Error = ctx.DecodeError || Backend.Error;
        const Self = @This();
        pub fn read(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.cursor.context.items -= 1;
            return self.cursor.read(T, .{ .name = "" });
        }
        pub fn alloc(self: *Self, comptime T: type, n: usize) ctx.DecodeError![]T {
            return self.cursor.context.alloc(T, n);
        }
        pub fn chargeWork(self: *Self, n: usize) ctx.DecodeError!void {
            try self.cursor.context.chargeWork(n);
        }
        pub fn raw(self: *Self, comptime Format: type) (ctx.DecodeError || Backend.Error)![]const u8 {
            if (Backend.Format != Format) @compileError("raw format brand does not match the backend");
            if (self.used) return error.CustomRejected;
            self.used = true;
            const start = if (self.cursor.pending != null) self.cursor.pending_start else self.cursor.backend.offset();
            self.cursor.context.items -= 1;
            try self.cursor.skip();
            const span = self.cursor.backend.raw(start, self.cursor.backend.offset());
            return self.cursor.context.retain(span.bytes, span.lifetime, .prefer);
        }
        pub fn skip(self: *Self) (ctx.DecodeError || Backend.Error)!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.cursor.context.items -= 1;
            try self.cursor.skip();
        }
    };
}

/// Checked copying for defaults; result storage belongs to the same arena.
fn clone(comptime T: type, value: T, c: *ctx.Context) ctx.DecodeError!T {
    @setRuntimeSafety(true);
    try c.enter();
    defer c.leave();
    try c.chargeWork(1);
    switch (@typeInfo(T)) {
        .pointer => |i| switch (i.size) {
            .one => {
                const result = try c.allocPointer(T, 1);
                result.* = try clone(i.child, value.*, c);
                return result;
            },
            .slice => {
                try c.count(value.len);
                const result = try c.allocPointer(T, value.len);
                for (result, value) |*to, from| to.* = try clone(i.child, from, c);
                return result;
            },
            else => unreachable,
        },
        .optional => |i| return if (value) |v| try clone(i.child, v, c) else null,
        .@"struct" => |i| {
            var result = value;
            inline for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| if (!attrs.@"comptime") {
                @field(result, name) = try clone(F, @field(value, name), c);
            };
            return result;
        },
        inline .array, .vector => |i| {
            var result: [i.len]i.child = value;
            for (&result) |*v| v.* = try clone(i.child, v.*, c);
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |v, tag| @unionInit(T, @tagName(tag), try clone(@TypeOf(v), v, c)),
        },
        else => return value,
    }
}

fn Errors(comptime T: type, comptime Backend: type) type {
    return ctx.DecodeError || Backend.Error || HookErrors(T, Backend, &.{});
}
fn HookErrors(comptime T: type, comptime Backend: type, comptime seen: []const type) type {
    for (seen) |prior| if (T == prior) return error{};
    const next = seen ++ .{T};
    if (descriptor.has(T, "strandDeserialize")) {
        const result = @TypeOf(T.strandDeserialize(@as(*Access(Backend), undefined)));
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
