//! One bounded typed mapping kernel over immediate semantic events.
const std = @import("std");
const descriptor = @import("descriptor.zig");
const ctx = @import("context.zig");
const model = @import("model.zig");

/// Backend.next(context, request) must meter wire reads/scratch through context before
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
        request: model.Request = .{},
        first_event: bool = true,
        const Self = @This();
        const Error = ctx.DecodeError || Backend.Error;
        fn peek(self: *Self) Error!model.Event {
            if (self.pending == null) {
                self.pending_start = self.backend.offset();
                if (self.context.diagnostics) |d| d.offset = self.pending_start;
                self.pending = self.backend.next(self.context, self.request) catch |err| {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    return err;
                };
                if (self.first_event and self.context.depth == 0 and !Backend.capabilities.scalar_roots and self.pending.? != .begin) return error.UnsupportedValue;
                self.first_event = false;
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
            self.request = .{ .expected = switch (expected) {
                .sequence => .sequence,
                .tuple => .tuple,
                .named_tuple => .named_tuple,
                .map => .map,
                .record => .record,
                .variant => .variant,
                .named_unit => .named_unit,
                .newtype => .newtype,
                .some => .some,
            } };
            const event = try self.take();
            if (event != .begin) return error.UnexpectedType;
            try self.context.span(event.begin.name.len, false);
            try self.context.chargeWork(event.begin.name.len);
            if (!std.unicode.utf8ValidateSlice(event.begin.name)) return error.InvalidUtf8;
            if (event.begin.len == null and !Backend.capabilities.indefinite_containers) return error.UnsupportedValue;
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
            self.request = .{ .expected = .text };
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
            self.request = typeRequest(T, policy);
            if (self.context.diagnostics) |d| d.expected = self.request.expected;
            try self.context.node();
            try self.context.chargeWork(1);
            if (comptime descriptor.has(T, "strandDeserialize")) {
                try self.context.enterHook();
                defer self.context.leaveHook();
                var access: Access(Backend) = .{ .cursor = self };
                const value = try T.strandDeserialize(&access);
                if (!access.used or !access.complete) return error.CustomRejected;
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
                    if (!Backend.capabilities.nonfinite_floats and !std.math.isFinite(event.floating)) return error.UnsupportedValue;
                    const value: T = @floatCast(event.floating); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
                    if (std.math.isFinite(event.floating) and !std.math.isFinite(value)) return error.NumberOutOfRange;
                    if (policy.exact and std.math.isFinite(event.floating) and @as(f128, value) != event.floating) return error.InexactNumber;
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
                    const event = try self.peek();
                    if (event == .begin and event.begin.kind == .some) {
                        const header = try self.start(.some);
                        defer self.context.leave();
                        if (header.len) |n| if (n != 1) return error.SyntaxError;
                        const value: T = try self.read(i.child, policy);
                        try self.end();
                        return value;
                    }
                    // Optional presence is a type hint, not an extra wire node.
                    if (!self.context.replaying) self.context.items -= 1;
                    return try self.read(i.child, policy);
                },
                .pointer => |i| switch (i.size) {
                    .one => {
                        if (!self.context.replaying) self.context.items -= 1;
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
                        const header = try self.start(.tuple);
                        defer self.context.leave();
                        var count: usize = 0;
                        inline for (i.field_attrs) |attrs| if (!attrs.@"comptime") {
                            count += 1;
                        };
                        if (header.len) |n| if (n != count) return error.UnexpectedType;
                        var value: T = undefined;
                        inline for (i.field_names, i.field_attrs) |name, attrs| {
                            if (attrs.@"comptime") continue;
                            @field(value, name) = try self.readField(T, name);
                        }
                        try self.end();
                        return value;
                    }
                    return self.record(T);
                },
                .@"enum" => |i| {
                    const name = try self.keyValue();
                    inline for (i.field_names) |variant| {
                        const v = comptime descriptor.variant(T, variant);
                        var matches = try self.equals(name, v.name);
                        inline for (v.aliases) |alias| matches = matches or try self.equals(name, alias);
                        if (matches) return @field(T, variant);
                    }
                    return error.UnknownVariant;
                },
                .@"union" => return self.readUnion(T),
                else => @compileError("unsupported core decode type"),
            }
        }
        fn readUnion(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const i = @typeInfo(T).@"union";
            const opt = comptime descriptor.options(T);
            if (@hasField(@TypeOf(opt), "tag")) return self.tagged(T);
            const header = try self.start(.variant);
            defer self.context.leave();
            if (header.len) |n| if (n != 1) return error.SyntaxError;
            inline for (i.field_names, i.field_types) |name, F| {
                const v = comptime descriptor.variant(T, name);
                var matches = try self.equals(header.name, v.name);
                inline for (v.aliases) |alias| matches = matches or try self.equals(header.name, alias);
                if (matches) {
                    const value = @unionInit(T, name, try self.read(F, .{ .name = name }));
                    try self.end();
                    return value;
                }
            }
            if (@hasField(@TypeOf(opt), "other")) {
                const F = @FieldType(T, opt.other);
                const payload = if (F == void) blk: {
                    try self.skip();
                    break :blk {};
                } else try self.read(F, .{});
                try self.end();
                return @unionInit(T, opt.other, payload);
            }
            return error.UnknownVariant;
        }
        /// Routing scans a bounded record once, then replays just the selected
        /// payload. This supports content-before-tag without an unbounded DOM.
        fn tagged(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const opt = comptime descriptor.options(T);
            const record_start = if (self.pending != null) self.pending_start else self.backend.offset();
            const header = try self.start(.record);
            var entered = true;
            defer if (entered) self.context.leave();
            var tag: ?[]const u8 = null;
            var payload: ?struct { start: usize, end: usize } = null;
            var count: usize = 0;
            while (try self.peek() != .end) {
                if (count >= self.context.limits.container_items) return error.ItemLimit;
                count += 1;
                const name = try self.key();
                if (try self.equals(name, opt.tag)) {
                    if (tag != null) return error.DuplicateField;
                    try self.context.node();
                    const span = try self.keySpan();
                    tag = if (span.lifetime == .transient) try self.context.retain(span.bytes, .transient, .copy) else span.bytes;
                } else if (@hasField(@TypeOf(opt), "content") and try self.equals(name, opt.content)) {
                    if (payload != null) return error.DuplicateField;
                    const payload_start = self.backend.offset();
                    try self.skip();
                    payload = .{ .start = payload_start, .end = self.backend.offset() };
                } else {
                    if (@hasField(@TypeOf(opt), "content")) return error.UnknownField;
                    try self.skip();
                }
            }
            if (header.len) |n| if (n != count) return error.SyntaxError;
            try self.end();
            self.context.leave();
            entered = false;
            const tag_name = tag orelse return error.MissingField;
            const record_end = self.backend.offset();
            const was_replaying = self.context.replaying;
            self.context.replaying = true;
            defer self.context.replaying = was_replaying;
            inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |name, F| {
                const v = comptime descriptor.variant(T, name);
                var matches = try self.equals(tag_name, v.name);
                inline for (v.aliases) |alias| matches = matches or try self.equals(tag_name, alias);
                if (matches) {
                    const value = if (@hasField(@TypeOf(opt), "content")) blk: {
                        const span = payload orelse return error.MissingField;
                        var backend = self.backend.replay(span.start, span.end);
                        break :blk try deserialize(F, &backend, self.context);
                    } else if (F == void) blk: {
                        if (count != 1) return error.UnknownField;
                        break :blk {};
                    } else blk: {
                        var backend = self.backend.replay(record_start, record_end);
                        var filtered: Filtered(Backend) = .{ .backend = &backend, .tag = opt.tag };
                        break :blk try deserialize(F, &filtered, self.context);
                    };
                    return @unionInit(T, name, value);
                }
            }
            if (@hasField(@TypeOf(opt), "other")) {
                const F = @FieldType(T, opt.other);
                if (F == void) return @unionInit(T, opt.other, {});
                const span = payload orelse .{ .start = record_start, .end = record_end };
                var backend = self.backend.replay(span.start, span.end);
                return @unionInit(T, opt.other, try deserialize(F, &backend, self.context));
            }
            return error.UnknownVariant;
        }
        fn fixed(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            const i = if (@typeInfo(T) == .array) @typeInfo(T).array else @typeInfo(T).vector;
            if (i.len > policy.max_len) return error.LengthLimit;

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
                const mark: ctx.Diagnostics.Checkpoint = if (self.context.diagnostics) |d| d.checkpoint() else .{ .count = 0, .used = 0, .truncated = false };
                if (self.context.diagnostics) |d| d.index(index);
                element.* = try self.read(i.child, .{ .name = "" });
                if (self.context.diagnostics) |d| d.restore(mark);
            }
            try self.end();
            return array;
        }
        fn keyValue(self: *Self) Error![]const u8 {
            return (try self.keySpan()).bytes;
        }
        fn keySpan(self: *Self) Error!model.Span {
            self.request = .{ .expected = .text };
            const event = try self.take();
            if (event != .text) return error.UnexpectedType;
            try self.context.span(event.text.bytes.len, false);
            try self.context.chargeWork(event.text.bytes.len);
            if (!std.unicode.utf8ValidateSlice(event.text.bytes)) return error.InvalidUtf8;
            return event.text;
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
        fn readField(self: *Self, comptime T: type, comptime name: []const u8) Errors(T, Backend)!@FieldType(T, name) {
            const declared = comptime descriptor.fieldOptions(T, name);
            const value = if (@hasField(@TypeOf(declared), "codec")) blk: {
                try self.context.node();
                var access: Access(Backend) = .{ .cursor = self };
                const result = try declared.codec.decode(&access);
                if (!access.used or !access.complete) return error.CustomRejected;
                break :blk result;
            } else try self.read(@FieldType(T, name), comptime descriptor.field(T, name));
            try descriptor.validate(T, name, value);
            return value;
        }
        fn record(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const i = @typeInfo(T).@"struct";
            const opt = comptime descriptor.options(T);
            const unknown: descriptor.Unknown = if (self.context.acceptance.reject_unknown_fields) .reject else if (@hasField(@TypeOf(opt), "unknown_fields")) opt.unknown_fields else .ignore;
            const duplicates: descriptor.Duplicates = if (self.context.acceptance.reject_duplicates) .reject else if (@hasField(@TypeOf(opt), "duplicates")) opt.duplicates else .reject;
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
                inline for (i.field_names, i.field_attrs, 0..) |field_name, attrs, index| {
                    if (attrs.@"comptime") continue;
                    if (matched == index) {
                        const f = comptime descriptor.field(T, field_name);
                        if (seen[index] and duplicates == .reject) {
                            if (self.context.diagnostics) |d| d.field(field_name);
                            return error.DuplicateField;
                        }
                        if (f.skip_decode or (seen[index] and duplicates == .first)) {
                            try self.skip();
                        } else {
                            const mark: ctx.Diagnostics.Checkpoint = if (self.context.diagnostics) |d| d.checkpoint() else .{ .count = 0, .used = 0, .truncated = false };
                            if (self.context.diagnostics) |d| d.field(field_name);
                            @field(value, field_name) = try self.readField(T, field_name);
                            if (self.context.diagnostics) |d| d.restore(mark);
                        }
                        seen[index] = !f.skip_decode;
                    }
                }
                if (matched == null) {
                    if (unknown == .reject) {
                        if (self.context.diagnostics) |d| d.field(name);
                        return error.UnknownField;
                    }
                    try self.skip();
                }
            }
            if (header.len) |n| if (n != pairs) return error.SyntaxError;
            try self.end();
            inline for (i.field_names, i.field_types, i.field_attrs, 0..) |name, F, attrs, index| {
                if (attrs.@"comptime") continue;
                if (!seen[index]) {
                    const mark: ctx.Diagnostics.Checkpoint = if (self.context.diagnostics) |d| d.checkpoint() else .{ .count = 0, .used = 0, .truncated = false };
                    if (self.context.diagnostics) |d| {
                        d.offset = self.backend.offset();
                        d.field(name);
                    }
                    const declared = comptime descriptor.fieldOptions(T, name);
                    if (@hasField(@TypeOf(declared), "default") and @typeInfo(@TypeOf(declared.default)) == .@"fn") {
                        @field(value, name) = try declared.default(self.context);
                    } else {
                        const default_value = (comptime descriptor.default(T, name)) orelse return error.MissingField;
                        @field(value, name) = try cloneField(F, comptime descriptor.field(T, name), default_value, self.context);
                    }
                    try descriptor.validate(T, name, @field(value, name));
                    if (self.context.diagnostics) |d| d.restore(mark);
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
                .scalar => |v| if (!std.unicode.utf8ValidCodepoint(v)) return error.InvalidUtf8,
                .floating => |v| if (!Backend.capabilities.nonfinite_floats and !std.math.isFinite(v)) return error.UnsupportedValue,
                .integer => |n| {
                    if (n.magnitude.len > self.context.limits.numeric_bytes) return error.LengthLimit;
                    try self.context.chargeWork(n.magnitude.len);
                },
                .begin => |header| {
                    if (header.len == null and !Backend.capabilities.indefinite_containers) return error.UnsupportedValue;
                    try self.context.span(header.name.len, false);
                    try self.context.chargeWork(header.name.len);
                    if (!std.unicode.utf8ValidateSlice(header.name)) return error.InvalidUtf8;
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
        complete: bool = true,
        pub const Error = ctx.DecodeError || Backend.Error;
        const Self = @This();
        pub fn begin(self: *Self, kind: model.Kind) Error!CompoundAccess(Backend) {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.complete = false;
            const header = try self.cursor.start(kind);
            return .{ .access = self, .header = header };
        }
        pub fn named(self: *Self, comptime T: type, kind: model.Kind, name: []const u8) Errors(T, Backend)!T {
            var compound = try self.begin(kind);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            const value = try compound.element(T);
            try compound.finish();
            return value;
        }
        pub fn namedUnit(self: *Self, name: []const u8) Error!void {
            var compound = try self.begin(.named_unit);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            try compound.finish();
        }
        pub fn namedTuple(self: *Self, comptime T: type, name: []const u8) Errors(T, Backend)!T {
            var compound = try self.begin(.named_tuple);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            const result: T = switch (@typeInfo(T)) {
                .@"struct" => |i| blk: {
                    if (!i.is_tuple) @compileError("named tuple requires a tuple shape");
                    var value: T = undefined;
                    inline for (i.field_names, i.field_types, i.field_attrs) |field_name, F, attrs| if (!attrs.@"comptime") {
                        @field(value, field_name) = try compound.element(F);
                    };
                    break :blk value;
                },
                .array => |i| blk: {
                    var value: T = undefined;
                    for (0..i.len) |j| value[j] = try compound.element(i.child);
                    if (comptime i.sentinel()) |sentinel| value[i.len] = sentinel;
                    break :blk value;
                },
                .vector => |i| blk: {
                    var value: [i.len]i.child = undefined;
                    for (&value) |*v| v.* = try compound.element(i.child);
                    break :blk value;
                },
                else => @compileError("named tuple requires a fixed tuple shape"),
            };
            try compound.finish();
            return result;
        }
        pub fn scalar(self: *Self) Error!u21 {
            if (self.used) return error.CustomRejected;
            self.used = true;
            const event = try self.cursor.take();
            if (event != .scalar) return error.UnexpectedType;
            if (!std.unicode.utf8ValidCodepoint(event.scalar)) return error.InvalidUtf8;
            return event.scalar;
        }
        pub fn sequence(self: *Self, comptime T: type) Errors(T, Backend)![]T {
            var sequence_access = try self.begin(.sequence);
            defer sequence_access.abort();
            if (sequence_access.header.len) |n| {
                const result = try self.alloc(T, n);
                for (result) |*v| v.* = try sequence_access.element(T);
                try sequence_access.finish();
                return result;
            }
            var result: []T = &.{};
            var n: usize = 0;
            while (try sequence_access.hasNext()) {
                if (n >= self.cursor.context.limits.container_items) return error.ItemLimit;
                if (n == result.len) {
                    const capacity = @max(@as(usize, 1), std.math.mul(usize, n, 2) catch return error.AllocationLimit);
                    const grown = try self.alloc(T, @min(capacity, self.cursor.context.limits.container_items));
                    try self.chargeWork(n);
                    @memcpy(grown[0..n], result[0..n]);
                    result = grown;
                }
                result[n] = try sequence_access.element(T);
                n += 1;
            }
            try sequence_access.finish();
            return result[0..n];
        }
        pub fn reject(self: *Self, code: u32) error{CustomRejected} {
            return self.cursor.context.reject(code);
        }
        pub fn readPairs(self: *Self, comptime K: type, comptime V: type) (Errors(K, Backend) || Errors(V, Backend))![]model.Pair(K, V) {
            var map = try self.begin(.map);
            defer map.abort();
            var storage: []model.Pair(K, V) = &.{};
            var n: usize = 0;
            while (try map.hasNext()) {
                if (n >= self.cursor.context.limits.container_items) return error.ItemLimit;
                if (n == storage.len) {
                    const capacity = @max(@as(usize, 1), std.math.mul(usize, n, 2) catch return error.AllocationLimit);
                    const next = try self.alloc(model.Pair(K, V), @min(capacity, self.cursor.context.limits.container_items));
                    try self.chargeWork(n);
                    @memcpy(next[0..n], storage[0..n]);
                    storage = next;
                }
                storage[n] = .{ .key = try map.key(K), .value = try map.element(V) };
                n += 1;
            }
            try map.finish();
            return storage[0..n];
        }
        pub fn read(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
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
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            try self.cursor.skip();
            const span = self.cursor.backend.raw(start, self.cursor.backend.offset());
            return self.cursor.context.retain(span.bytes, span.lifetime, .prefer);
        }
        pub fn skip(self: *Self) (ctx.DecodeError || Backend.Error)!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            try self.cursor.skip();
        }
    };
}

/// Checked copying for defaults; result storage belongs to the same arena.
pub fn clone(comptime T: type, value: T, c: *ctx.Context) ctx.DecodeError!T {
    return cloneField(T, .{}, value, c);
}
fn cloneField(comptime T: type, comptime policy: descriptor.Field, value: T, c: *ctx.Context) ctx.DecodeError!T {
    @setRuntimeSafety(true);
    try c.enter();
    defer c.leave();
    try c.chargeWork(1);
    try c.node();
    switch (@typeInfo(T)) {
        .pointer => |i| switch (i.size) {
            .one => {
                const result = try c.allocPointer(T, 1);
                result.* = try clone(i.child, value.*, c);
                return result;
            },
            .slice => {
                if (value.len > policy.max_len) return error.LengthLimit;
                try c.count(value.len);
                if (i.child == u8) {
                    try c.span(value.len, false);
                    try c.chargeWork(value.len);
                    if (policy.as != .bytes and !std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                }
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
                @field(result, name) = try cloneField(F, comptime descriptor.field(T, name), @field(value, name), c);
                try descriptor.validate(T, name, @field(result, name));
            };
            return result;
        },
        .array => |i| {
            var result = value;
            for (&result) |*v| v.* = try clone(i.child, v.*, c);
            return result;
        },
        .vector => |i| {
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
            for (i.field_types, i.field_names) |F, name| {
                const opt = descriptor.fieldOptions(T, name);
                if (@hasField(@TypeOf(opt), "codec") and @hasDecl(opt.codec, "decode")) errors = errors || @typeInfo(@TypeOf(opt.codec.decode(@as(*Access(Backend), undefined)))).error_union.error_set else errors = errors || HookErrors(F, Backend, next);
                if (@hasField(@TypeOf(opt), "default") and @typeInfo(@TypeOf(opt.default)) == .@"fn") errors = errors || @typeInfo(@TypeOf(opt.default(@as(*ctx.Context, undefined)))).error_union.error_set;
            }
            if (@typeInfo(errors).error_set.error_names == null) @compileError("field codecs and defaults require named errors");
            break :blk errors;
        },
        else => error{},
    };
}

/// A validated internal-tag replay suppresses exactly the routing key/value.
fn Filtered(comptime Backend: type) type {
    return struct {
        backend: *Backend,
        tag: []const u8,
        level: usize = 0,
        key_turn: bool = true,
        pub const Error = Backend.Error;
        pub const Format = Backend.Format;
        pub const capabilities = Backend.capabilities;
        const Self = @This();
        pub fn offset(self: *const Self) usize {
            return self.backend.offset();
        }
        pub fn endInput(self: *Self, c: *ctx.Context) Error!void {
            try self.backend.endInput(c);
        }
        pub fn raw(self: *const Self, start: usize, end: usize) model.Span {
            return self.backend.raw(start, end);
        }
        pub fn replay(self: *const Self, start: usize, end: usize) Backend {
            return self.backend.replay(start, end);
        }
        pub fn next(self: *Self, c: *ctx.Context, request: model.Request) (ctx.DecodeError || Error)!model.Event {
            while (true) {
                var event = try self.backend.next(c, request);
                if (self.level == 1 and self.key_turn and event == .text) {
                    try c.chargeWork(event.text.bytes.len);
                    if (std.mem.eql(u8, event.text.bytes, self.tag)) {
                        _ = try self.backend.next(c, request);
                        continue;
                    }
                    self.key_turn = false;
                } else if (self.level == 1 and event != .end) self.key_turn = true;
                if (event == .begin) {
                    if (self.level == 0) if (event.begin.len) |n| {
                        event.begin.len = n - 1;
                    };
                    self.level += 1;
                } else if (event == .end) {
                    self.level -= 1;
                }
                return event;
            }
        }
    };
}

/// Bounded compound visitor: every member is read through the same kernel;
/// finishing validates the declared arity and consumes the explicit end marker.
pub fn CompoundAccess(comptime Backend: type) type {
    return struct {
        access: *Access(Backend),
        header: model.Compound,
        count: usize = 0,
        key_pending: bool = false,
        live: bool = true,
        pub const Error = ctx.DecodeError || Backend.Error;
        const Self = @This();
        pub fn hasNext(self: *Self) Error!bool {
            if (!self.live or self.key_pending) return error.CustomRejected;
            return try self.access.cursor.peek() != .end;
        }
        pub fn key(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (!self.live or self.key_pending or (self.header.kind != .map and self.header.kind != .record)) return error.CustomRejected;
            if (self.count >= self.access.cursor.context.limits.container_items) return error.ItemLimit;
            self.key_pending = true;
            const event = try self.access.cursor.peek();
            if (event == .text) try self.access.cursor.context.span(event.text.bytes.len, true);
            return self.access.cursor.read(T, .{});
        }
        pub fn element(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (!self.live or ((self.header.kind == .map or self.header.kind == .record) and !self.key_pending)) return error.CustomRejected;
            if (self.count >= self.access.cursor.context.limits.container_items) return error.ItemLimit;
            self.key_pending = false;
            self.count += 1;
            return self.access.cursor.read(T, .{});
        }
        pub fn finish(self: *Self) Error!void {
            if (!self.live or self.key_pending) return error.CustomRejected;
            if (self.header.len) |n| if (n != self.count) return error.SyntaxError;
            try self.access.cursor.end();
            self.access.complete = true;
            self.abort();
        }
        pub fn abort(self: *Self) void {
            if (self.live) {
                self.access.cursor.context.leave();
                self.live = false;
            }
        }
    };
}

fn expectedKind(comptime T: type, comptime policy: descriptor.Field) ctx.Diagnostics.Expected {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => .integer,
        .float => .floating,
        .optional => .option,
        .void, .null => .unit,
        .pointer => |i| if (i.size == .slice and i.child == u8) (if (policy.as == .bytes) .bytes else .text) else .sequence,
        .array, .vector => .tuple,
        .@"struct" => |i| if (i.is_tuple) .tuple else .record,
        .@"union", .@"enum" => .variant,
        else => .unknown,
    };
}

fn typeRequest(comptime T: type, comptime policy: descriptor.Field) model.Request {
    var result: model.Request = .{ .expected = expectedKind(T, policy), .exact = policy.exact, .borrow = policy.borrow };
    switch (@typeInfo(T)) {
        .int => |i| result.integer_bits = i.bits,
        .float => |i| result.float_bits = i.bits,
        .optional => |i| {
            const child = typeRequest(i.child, policy);
            result.integer_bits = child.integer_bits;
            result.float_bits = child.float_bits;
        },
        .pointer => |i| if (i.size == .one) {
            const child = typeRequest(i.child, policy);
            result.integer_bits = child.integer_bits;
            result.float_bits = child.float_bits;
        },
        else => {},
    }
    return result;
}
