//! Direct minified JSON encoding for ordinary Zig values.
//!
//! Custom `jsonStringify` types and pretty output stay with `std.json`.
//! `Raw` has a `jsonStringify` for that path and is written here directly.
const indent_module = @import("indent.zig");

const std = @import("std");
const tagging = @import("tagging.zig");
const Indent = indent_module.Indent;

pub fn Encoder(comptime Raw: type) type {
    return struct {
        pub fn supports(comptime T: type) bool {
            // The walk visits every field of every type reachable from `T`, once
            // per path to it: a line protocol of sixty requests is thousands of
            // steps, past the compiler's default of a thousand. The ceiling is
            // for a schema's size, never a loop that does not end: the walk
            // stops at any type it is already inside.
            @setEvalBranchQuota(1_000_000);
            // A union tagged inside its object is a shape only this encoder
            // writes, so a value that reaches one is written here whatever
            // else it holds: a type with its own `jsonStringify` in it is
            // handed to `std.json` where it is met.
            return supportsType(T, .{}) or tagging.reaches(T);
        }

        fn supportsType(comptime T: type, comptime ancestors: anytype) bool {
            if (T == Raw) return true;
            inline for (ancestors) |ancestor| if (T == ancestor) return false;
            if (std.meta.hasFn(T, "jsonStringify")) return false;
            const next = ancestors ++ .{T};
            return switch (@typeInfo(T)) {
                .bool, .int, .comptime_int, .float, .comptime_float, .@"enum", .enum_literal, .error_set => true,
                .optional => |i| supportsType(i.child, next),
                .array => |i| supportsType(i.child, next),
                .vector => |i| supportsType(i.child, next),
                .pointer => |i| switch (i.size) {
                    .one, .many, .slice => supportsType(i.child, next),
                    else => false,
                },
                .@"struct" => |i| fields: {
                    for (i.fields) |field| if (!supportsType(field.type, next)) break :fields false;
                    break :fields true;
                },
                .@"union" => |i| fields: {
                    if (i.tag_type == null) break :fields false;
                    for (i.fields) |field| if (field.type != void and !supportsType(field.type, next)) break :fields false;
                    break :fields true;
                },
                else => false,
            };
        }

        /// `value`, laid out as `options.whitespace` says, as `std.json`
        /// lays a value out: the pretty path of a value `std.json` cannot
        /// write, because it reaches a union tagged inside its object.
        pub fn indented(v: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            var buffer: [256]u8 = undefined;
            var indent: Indent = .init(writer, options.whitespace, &buffer);
            var minified = options;
            minified.whitespace = .minified;
            try value(v, minified, &indent.interface);
            try indent.interface.flush();
        }

        pub fn value(v: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const T = @TypeOf(v);
            if (T == Raw) return raw(v.bytes, options, writer);
            if (comptime hasOwnStringify(T)) return std.json.Stringify.value(v, options, writer);
            switch (@typeInfo(T)) {
                .bool => try writer.writeAll(if (v) "true" else "false"),
                .int => |info| if (info.bits > 128) {
                    try writer.printInt(v, 10, .lower, .{});
                } else {
                    var digits: [decimal_max]u8 = undefined;
                    try writer.writeAll(decimal(&digits, v));
                },
                .comptime_int => try value(@as(std.math.IntFittingRange(v, v), v), options, writer),
                .float, .comptime_float => {
                    if (@as(f64, @floatCast(v)) == v) {
                        try writer.print("{}", .{@as(f64, @floatCast(v))});
                    } else {
                        try writer.writeByte('"');
                        try writer.print("{}", .{v});
                        try writer.writeByte('"');
                    }
                },
                .optional => if (v) |payload| try value(payload, options, writer) else try writer.writeAll("null"),
                .@"enum" => |info| {
                    if (!info.is_exhaustive) {
                        inline for (info.fields) |field| {
                            if (v == @field(T, field.name)) break;
                        } else return value(@intFromEnum(v), options, writer);
                    }
                    try string(@tagName(v), options, writer);
                },
                .enum_literal => try string(@tagName(v), options, writer),
                .error_set => try string(@errorName(v), options, writer),
                .@"struct" => |info| {
                    try writer.writeByte(if (info.is_tuple) '[' else '{');
                    _ = try members(v, options, writer, true);
                    try writer.writeByte(if (info.is_tuple) ']' else '}');
                },
                .@"union" => |info| {
                    if (comptime tagging.internal(T)) |inside| return tagged(v, inside, options, WriterSink{ .writer = writer });
                    const Tag = info.tag_type.?;
                    try writer.writeByte('{');
                    inline for (info.fields) |field| {
                        if (v == @field(Tag, field.name)) {
                            try memberName(field.name, options, writer);
                            if (field.type == void) {
                                try writer.writeAll("{}");
                            } else {
                                try value(@field(v, field.name), options, writer);
                            }
                            break;
                        }
                    } else unreachable;
                    try writer.writeByte('}');
                },
                .pointer => |info| switch (info.size) {
                    .one => switch (@typeInfo(info.child)) {
                        .array => try value(@as([]const std.meta.Elem(info.child), v), options, writer),
                        else => try value(v.*, options, writer),
                    },
                    .many, .slice => {
                        if (info.size == .many and info.sentinel() == null)
                            @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                        const slice = if (info.size == .many) std.mem.span(v) else v;
                        if (info.child == u8) {
                            if (!try text(WriterSink{ .writer = writer }, slice, options)) try array(slice, options, writer);
                        } else {
                            try array(slice, options, writer);
                        }
                    },
                    else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
                },
                .array => try value(&v, options, writer),
                .vector => |info| {
                    const a: [info.len]info.child = v;
                    try value(&a, options, writer);
                },
                else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
            }
        }

        /// A struct's members, or a tuple's items, with no bracket either side:
        /// what `value` writes between them. `first` says whether nothing has
        /// been written inside the bracket yet; the answer is whether that is
        /// still so, which is whether the next member needs a comma.
        pub fn members(v: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer, first: bool) std.Io.Writer.Error!bool {
            const info = @typeInfo(@TypeOf(v)).@"struct";
            var none = first;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                var emit = true;
                if (!info.is_tuple and @typeInfo(field.type) == .optional and !options.emit_null_optional_fields) {
                    if (@field(v, field.name) == null) emit = false;
                }
                if (emit) {
                    if (!none) try writer.writeByte(',');
                    none = false;
                    if (!info.is_tuple) try memberName(field.name, options, writer);
                    try value(@field(v, field.name), options, writer);
                }
            }
            return none;
        }

        /// A member's name and the colon after it.
        pub fn memberName(comptime name: []const u8, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (comptime safeFieldName(name)) {
                try writer.writeAll(comptime "\"" ++ name ++ "\":");
            } else {
                try string(name, options, writer);
                try writer.writeByte(':');
            }
        }

        pub const BufferError = error{NoSpace};

        /// Encode into caller-owned spare capacity without going through the generic
        /// writer interface for every field and punctuation byte.
        pub fn valueBuffer(v: anytype, options: std.json.Stringify.Options, out: []u8) BufferError!usize {
            var sink: Buffer = .{ .bytes = out };
            try bufferValue(v, options, &sink);
            return sink.end;
        }

        const Buffer = struct {
            bytes: []u8,
            end: usize = 0,

            inline fn byte(self: *Buffer, b: u8) BufferError!void {
                std.debug.assert(self.end <= self.bytes.len);
                defer std.debug.assert(self.end <= self.bytes.len);
                if (self.end == self.bytes.len) return error.NoSpace;
                self.bytes[self.end] = b;
                self.end += 1;
            }

            inline fn write(self: *Buffer, src: []const u8) BufferError!void {
                std.debug.assert(self.end <= self.bytes.len);
                defer std.debug.assert(self.end <= self.bytes.len);
                if (src.len > self.bytes.len - self.end) return error.NoSpace;
                @memcpy(self.bytes[self.end..][0..src.len], src);
                self.end += src.len;
            }

            fn integer(self: *Buffer, v: anytype) BufferError!void {
                if (@typeInfo(@TypeOf(v)).int.bits > 128) {
                    var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                    fixed.printInt(v, 10, .lower, .{}) catch return error.NoSpace;
                    self.end += fixed.end;
                    return;
                }
                var digits: [decimal_max]u8 = undefined;
                try self.write(decimal(&digits, v));
            }

            fn stdValue(self: *Buffer, v: anytype, options: std.json.Stringify.Options) BufferError!void {
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                std.json.Stringify.value(v, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }

            fn raw(self: *Buffer, bytes: []const u8, options: std.json.Stringify.Options) BufferError!void {
                if (rawAsIs(bytes, options)) return self.write(bytes);
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                rawChanged(bytes, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }

            fn members(self: *Buffer, v: anytype, options: std.json.Stringify.Options) BufferError!void {
                return bufferMembers(v, options, self, true);
            }

            fn stdString(self: *Buffer, s: []const u8, options: std.json.Stringify.Options) BufferError!void {
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                std.json.Stringify.encodeJsonString(s, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }
        };

        fn bufferValue(v: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            const T = @TypeOf(v);
            if (T == Raw) return out.raw(v.bytes, options);
            if (comptime hasOwnStringify(T)) return out.stdValue(v, options);
            switch (@typeInfo(T)) {
                .bool => try out.write(if (v) "true" else "false"),
                .int => try out.integer(v),
                .comptime_int => try bufferValue(@as(std.math.IntFittingRange(v, v), v), options, out),
                .float, .comptime_float => try out.stdValue(v, options),
                .optional => if (v) |payload| try bufferValue(payload, options, out) else try out.write("null"),
                .@"enum" => |info| {
                    if (!info.is_exhaustive) {
                        inline for (info.fields) |field| {
                            if (v == @field(T, field.name)) break;
                        } else return bufferValue(@intFromEnum(v), options, out);
                    }
                    // A name is known when this is compiled, and so is its JSON
                    // when it needs no escaping.
                    switch (v) {
                        inline else => |tag| if (comptime safeFieldName(@tagName(tag)))
                            try out.write(comptime "\"" ++ @tagName(tag) ++ "\"")
                        else
                            try bufferString(@tagName(tag), options, out),
                    }
                },
                .enum_literal => try bufferString(@tagName(v), options, out),
                .error_set => try bufferString(@errorName(v), options, out),
                .@"struct" => |info| {
                    try out.byte(if (info.is_tuple) '[' else '{');
                    try bufferMembers(v, options, out, false);
                    try out.byte(if (info.is_tuple) ']' else '}');
                },
                .@"union" => |info| {
                    if (comptime tagging.internal(T)) |inside| return tagged(v, inside, options, out);
                    const Tag = info.tag_type.?;
                    try out.byte('{');
                    inline for (info.fields) |field| {
                        if (v == @field(Tag, field.name)) {
                            if (comptime safeFieldName(field.name)) {
                                try out.write(comptime "\"" ++ field.name ++ "\":");
                            } else {
                                try bufferString(field.name, options, out);
                                try out.byte(':');
                            }
                            if (field.type == void) {
                                try out.write("{}");
                            } else {
                                try bufferValue(@field(v, field.name), options, out);
                            }
                            break;
                        }
                    } else unreachable;
                    try out.byte('}');
                },
                .pointer => |info| switch (info.size) {
                    .one => switch (@typeInfo(info.child)) {
                        .array => try bufferValue(@as([]const std.meta.Elem(info.child), v), options, out),
                        else => try bufferValue(v.*, options, out),
                    },
                    .many, .slice => {
                        if (info.size == .many and info.sentinel() == null)
                            @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                        const slice = if (info.size == .many) std.mem.span(v) else v;
                        if (info.child == u8) {
                            if (!try text(out, slice, options)) try bufferArray(slice, options, out);
                        } else try bufferArray(slice, options, out);
                    },
                    else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
                },
                .array => try bufferValue(&v, options, out),
                .vector => |info| {
                    const a: [info.len]info.child = v;
                    try bufferValue(&a, options, out);
                },
                else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
            }
        }

        /// A struct's members, or a tuple's items, between its brackets. `lead`
        /// says a member is already written in front of them, so every one of
        /// them takes a comma: the tag of a union tagged inside its object.
        fn bufferMembers(v: anytype, options: std.json.Stringify.Options, out: *Buffer, comptime lead: bool) BufferError!void {
            const info = @typeInfo(@TypeOf(v)).@"struct";
            var first = !lead;
            _ = &first;
            // Whether a member before this one is always written, which
            // makes the comma in front of this one a constant.
            comptime var written_before = lead;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                const optional = !info.is_tuple and @typeInfo(field.type) == .optional;
                var emit = true;
                if (optional and !options.emit_null_optional_fields) {
                    if (@field(v, field.name) == null) emit = false;
                }
                if (emit) {
                    if (!info.is_tuple and comptime safeFieldName(field.name)) {
                        const key = comptime "\"" ++ field.name ++ "\":";
                        if (written_before) {
                            try out.write("," ++ key);
                        } else {
                            if (!first) try out.byte(',');
                            try out.write(key);
                        }
                    } else {
                        if (!first) try out.byte(',');
                        if (!info.is_tuple) {
                            try bufferString(field.name, options, out);
                            try out.byte(':');
                        }
                    }
                    first = false;
                    try bufferValue(@field(v, field.name), options, out);
                }
                if (!optional) written_before = true;
            }
        }

        /// A union tagged inside its object: the tag first, then the arm's
        /// members, in one object. The arm a tag naming no arm was read as is
        /// written as it was read: a `Raw` holds the record, tag and all, and
        /// a `void` one is its own name.
        fn tagged(v: anytype, comptime inside: anytype, options: std.json.Stringify.Options, sink: anytype) !void {
            const T = @TypeOf(v);
            const tag_key = comptime "\"" ++ inside.tag ++ "\":";
            switch (v) {
                inline else => |payload, arm| {
                    const Payload = @TypeOf(payload);
                    if (comptime inside.other != null and arm == inside.other.? and Payload == Raw) {
                        return sink.raw(payload.bytes, options);
                    }
                    try sink.write("{" ++ tag_key);
                    if (comptime safeFieldName(@tagName(arm))) {
                        try sink.write(comptime "\"" ++ @tagName(arm) ++ "\"");
                    } else if (!try text(sink, @tagName(arm), options)) {
                        try sink.stdString(@tagName(arm), options);
                    }
                    if (Payload != void) try sink.members(payload, options);
                    try sink.byte('}');
                },
            }
            _ = T;
        }

        /// A type that writes itself, met inside a value this encoder writes
        /// only because it reaches a union tagged inside its object.
        fn hasOwnStringify(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => std.meta.hasFn(T, "jsonStringify"),
                else => false,
            };
        }

        fn bufferArray(items: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            try out.byte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try out.byte(',');
                try bufferValue(item, options, out);
            }
            try out.byte(']');
        }

        /// A name — a field's, a tag's, an error's — as `std.json` writes it,
        /// whatever its bytes.
        fn bufferString(bytes: []const u8, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            if (!try text(out, bytes, options)) try out.stdString(bytes, options);
        }

        /// Where a `WriterSink` or a `Buffer` is written to: a byte, a run of bytes,
        /// and a string `std.json` escapes itself.
        const WriterSink = struct {
            writer: *std.Io.Writer,

            fn byte(self: WriterSink, b: u8) std.Io.Writer.Error!void {
                return self.writer.writeByte(b);
            }
            fn write(self: WriterSink, bytes: []const u8) std.Io.Writer.Error!void {
                return self.writer.writeAll(bytes);
            }
            fn stdString(self: WriterSink, bytes: []const u8, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
                return std.json.Stringify.encodeJsonString(bytes, options, self.writer);
            }
            fn raw(self: WriterSink, bytes: []const u8, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
                return Encoder(Raw).raw(bytes, options, self.writer);
            }
            fn members(self: WriterSink, v: anytype, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
                _ = try Encoder(Raw).members(v, options, self.writer, false);
            }
        };

        /// A byte string as `std.json` writes one, when it is UTF-8: quoted,
        /// escaping only what JSON requires. False, and nothing written, when it
        /// is not UTF-8, which `std.json` writes as an array of numbers instead.
        ///
        /// `std.json` looks at a string a byte at a time. Here it is scanned a
        /// vector at a time for the three things a string must escape — a control
        /// byte, a quote, a backslash — and the runs between them are written
        /// whole, each escape being `std.json`'s own spelling of it. A string with
        /// none of them and nothing past ASCII, which is most, is one scan and one
        /// copy. Under `escape_unicode` a string with anything past ASCII in it is
        /// `std.json`'s.
        fn text(sink: anytype, bytes: []const u8, options: std.json.Stringify.Options) !bool {
            const first = nextSpecial(bytes, 0, true);
            if (first == bytes.len) {
                try sink.byte('"');
                try sink.write(bytes);
                try sink.byte('"');
                return true;
            }
            // The bytes in front of `first` are ASCII, so whether the string is
            // UTF-8 is whether the rest of it is.
            if (!std.unicode.utf8ValidateSlice(bytes[first..])) return false;
            if (options.escape_unicode) {
                try sink.stdString(bytes, options);
                return true;
            }
            try sink.byte('"');
            var from: usize = 0;
            var at = first;
            while (true) {
                at = nextSpecial(bytes, at, false);
                try sink.write(bytes[from..at]);
                if (at == bytes.len) break;
                try sink.write(escapes[bytes[at]]);
                at += 1;
                from = at;
            }
            try sink.byte('"');
            return true;
        }

        /// The index of the first byte at or after `from` that a JSON string has to
        /// escape — a control byte, a quote, a backslash — or, when `ascii`, that
        /// is not ASCII either (0x7f included, which `escape_unicode` escapes).
        /// `bytes.len` when there is none.
        fn nextSpecial(bytes: []const u8, from: usize, comptime ascii: bool) usize {
            const width = 16;
            const vector_type = @Vector(width, u8);
            var at = from;
            while (at + width <= bytes.len) : (at += width) {
                const chunk: vector_type = bytes[at..][0..width].*;
                var hit = (chunk < @as(vector_type, @splat(0x20))) |
                    (chunk == @as(vector_type, @splat('"'))) |
                    (chunk == @as(vector_type, @splat('\\')));
                if (ascii) hit |= chunk >= @as(vector_type, @splat(0x7f));
                if (@reduce(.Or, hit)) break;
            }
            while (at < bytes.len) : (at += 1) {
                const b = bytes[at];
                if (b < 0x20 or b == '"' or b == '\\' or (ascii and b >= 0x7f)) break;
            }
            return at;
        }

        /// What `std.json` writes for each byte a string has to escape, taken from
        /// `std.json` itself when this is compiled.
        const escapes: [256][]const u8 = table: {
            @setEvalBranchQuota(100_000);
            var table: [256][]const u8 = @splat("");
            for (0..256) |b| {
                if (b >= 0x20 and b != '"' and b != '\\') continue;
                var buffer: [6]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buffer);
                // unreachable: one ASCII control, quote or backslash expands to at most six JSON bytes in this fixed buffer.
                std.json.Stringify.encodeJsonStringChars(&.{@as(u8, b)}, .{}, &w) catch unreachable;
                const frozen = buffer[0..w.end].*;
                table[b] = &frozen;
            }
            break :table table;
        };

        /// Enough for any integer up to 128 bits and its sign. Wider ones are
        /// written by `std.fmt`.
        const decimal_max = 40;
        comptime {
            // A signed 128-bit magnitude needs 39 decimal digits and its sign.
            std.debug.assert(decimal_max >= 39 + 1);
        }

        /// `v` in base ten, as `{d}` writes it, at the end of `buffer`.
        ///
        /// Two digits a division, and for an integer past 64 bits, nineteen digits
        /// a 128-bit division and the rest in 64 bits, which is where a `u128`'s
        /// time goes otherwise.
        fn decimal(buffer: *[decimal_max]u8, v: anytype) []const u8 {
            const info = @typeInfo(@TypeOf(v)).int;
            comptime std.debug.assert(info.bits <= 128);
            var at: usize = buffer.len;
            var n: @Int(.unsigned, @max(info.bits, 1)) = @abs(v);
            if (comptime info.bits > 64) {
                while (n > std.math.maxInt(u64)) {
                    const low: u64 = @intCast(n % 10_000_000_000_000_000_000);
                    n /= 10_000_000_000_000_000_000;
                    const end = at;
                    at = digits64(buffer, at, low);
                    // Nineteen digits, the zeros in front included.
                    while (at > end - 19) {
                        at -= 1;
                        buffer[at] = '0';
                    }
                }
            }
            at = digits64(buffer, at, @intCast(n));
            if (info.signedness == .signed and v < 0) {
                at -= 1;
                buffer[at] = '-';
            }
            return buffer[at..];
        }

        /// `n`'s digits, ending at `buffer[end]`; where they begin.
        fn digits64(buffer: *[decimal_max]u8, end: usize, n_: u64) usize {
            var n = n_;
            var at = end;
            while (n >= 100) : (n /= 100) {
                at -= 2;
                buffer[at..][0..2].* = std.fmt.digits2(@intCast(n % 100));
            }
            if (n < 10) {
                at -= 1;
                buffer[at] = '0' + @as(u8, @intCast(n));
            } else {
                at -= 2;
                buffer[at..][0..2].* = std.fmt.digits2(@intCast(n));
            }
            return at;
        }

        fn safeFieldName(bytes: []const u8) bool {
            for (bytes) |b| if (b < 0x20 or b == '"' or b == '\\' or b >= 0x7f) return false;
            return true;
        }

        fn array(items: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer) !void {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try value(item, options, writer);
            }
            try writer.writeByte(']');
        }

        fn string(bytes: []const u8, options: std.json.Stringify.Options, writer: *std.Io.Writer) !void {
            try std.json.Stringify.encodeJsonString(bytes, options, writer);
        }

        /// A `Raw`'s bytes, written as its documentation says: as they are, except
        /// that a line break is a space in minified output, where a record is one
        /// line, and a character that is not ASCII is its `\u` escape under
        /// `escape_unicode`. JSON allows a line break only between tokens and a
        /// character only inside a string, where its escape means the same thing,
        /// so neither changes the value.
        pub fn raw(bytes: []const u8, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (rawAsIs(bytes, options)) return writer.writeAll(bytes);
            return rawChanged(bytes, options, writer);
        }

        /// Whether `raw` has nothing to change in `bytes`, which is the case every
        /// value read from a minified line is in unless `escape_unicode` is on. A
        /// vector at a time, as a string is.
        fn rawAsIs(bytes: []const u8, options: std.json.Stringify.Options) bool {
            const breaks = options.whitespace == .minified;
            const escape = options.escape_unicode;
            if (!breaks and !escape) return true;
            const width = 16;
            const vector_type = @Vector(width, u8);
            var i: usize = 0;
            while (i + width <= bytes.len) : (i += width) {
                const v: vector_type = bytes[i..][0..width].*;
                if (breaks and (@reduce(.Or, v == @as(vector_type, @splat('\n'))) or @reduce(.Or, v == @as(vector_type, @splat('\r'))))) return false;
                if (escape and @reduce(.Or, v >= @as(vector_type, @splat(0x80)))) return false;
            }
            for (bytes[i..]) |b| {
                if (breaks and (b == '\n' or b == '\r')) return false;
                if (escape and b >= 0x80) return false;
            }
            return true;
        }

        fn rawChanged(bytes: []const u8, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const breaks = options.whitespace == .minified;
            var start: usize = 0;
            var i: usize = 0;
            while (i < bytes.len) {
                const b = bytes[i];
                if (breaks and (b == '\n' or b == '\r')) {
                    try writer.writeAll(bytes[start..i]);
                    try writer.writeByte(' ');
                    i += 1;
                    start = i;
                } else if (options.escape_unicode and b >= 0x80) {
                    // Bytes that are not UTF-8 are not a value this could have
                    // read, and are written as they are.
                    const len = std.unicode.utf8ByteSequenceLength(b) catch {
                        i += 1;
                        continue;
                    };
                    const codepoint = if (bytes.len - i < len) null else std.unicode.utf8Decode(bytes[i..][0..len]) catch null;
                    if (codepoint) |c| {
                        try writer.writeAll(bytes[start..i]);
                        try unicodeEscape(c, writer);
                        i += len;
                        start = i;
                    } else i += 1;
                } else i += 1;
            }
            try writer.writeAll(bytes[start..]);
        }

        /// `std.json`'s escape for a character: lowercase hex, and a surrogate pair
        /// past the Basic Multilingual Plane.
        fn unicodeEscape(codepoint: u21, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            std.debug.assert(codepoint <= 0x10FFFF);
            std.debug.assert(codepoint < 0xD800 or codepoint > 0xDFFF);
            if (codepoint <= 0xFFFF) {
                try writer.writeAll("\\u");
                try writer.printInt(codepoint, 16, .lower, .{ .width = 4, .fill = '0' });
                return;
            }
            const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;
            try writer.writeAll("\\u");
            try writer.printInt(high, 16, .lower, .{ .width = 4, .fill = '0' });
            try writer.writeAll("\\u");
            try writer.printInt(low, 16, .lower, .{ .width = 4, .fill = '0' });
        }
    };
}
