//! Direct minified JSON encoding for ordinary Zig values.
//!
//! Custom `jsonStringify` types and pretty output stay with `std.json`.
//! `Raw` has a `jsonStringify` for that path and is written here directly.
const mapping = @import("mapping");
const indent_module = @import("indent.zig");

const std = @import("std");
const tagging = @import("tagging.zig");
const Indent = indent_module.Indent;

pub fn Encoder(comptime Raw: type) type {
    return struct {
        pub const RawType = Raw;
        pub const internal = tagging.internal;
        pub const stdValue = std.json.Stringify.value;
        pub const record_begin = '{';
        pub const record_end = '}';
        pub const sequence_begin = '[';
        pub const sequence_end = ']';
        pub const comma = ',';
        pub const comma_word = ",";
        pub const colon = ':';
        pub const text_begin = '"';
        pub const null_word = "null";
        pub const true_word = "true";
        pub const false_word = "false";
        pub const empty_record = "{}";
        pub fn keyLiteral(comptime name: []const u8) []const u8 {
            return "\"" ++ name ++ "\":";
        }
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
                    for (i.field_types) |field_type| if (!supportsType(field_type, next)) break :fields false;
                    break :fields true;
                },
                .@"union" => |i| fields: {
                    if (i.tag_type == null) break :fields false;
                    for (i.field_types) |field_type| if (field_type != void and !supportsType(field_type, next)) break :fields false;
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
            return mapping.emit(@This(), v, options, writer);
        }

        /// A struct's members, or a tuple's items, with no bracket either side:
        /// what `value` writes between them. `first` says whether nothing has
        /// been written inside the bracket yet; the answer is whether that is
        /// still so, which is whether the next member needs a comma.
        pub fn members(v: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer, first: bool) std.Io.Writer.Error!bool {
            return mapping.emitMembers(@This(), v, options, writer, first);
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
            pub const Error = BufferError;
            bytes: []u8,
            end: usize = 0,

            pub inline fn byte(self: *Buffer, b: u8) BufferError!void {
                std.debug.assert(self.end <= self.bytes.len);
                defer std.debug.assert(self.end <= self.bytes.len);
                if (self.end == self.bytes.len) return error.NoSpace;
                self.bytes[self.end] = b;
                self.end += 1;
            }

            pub inline fn write(self: *Buffer, src: []const u8) BufferError!void {
                std.debug.assert(self.end <= self.bytes.len);
                defer std.debug.assert(self.end <= self.bytes.len);
                if (src.len > self.bytes.len - self.end) return error.NoSpace;
                @memcpy(self.bytes[self.end..][0..src.len], src);
                self.end += src.len;
            }

            pub fn integer(self: *Buffer, v: anytype) BufferError!void {
                if (@typeInfo(@TypeOf(v)).int.bits > 128) {
                    var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                    fixed.printInt(v, 10, .lower, .{}) catch return error.NoSpace;
                    self.end += fixed.end;
                    return;
                }
                var digits: [decimal_max]u8 = undefined;
                try self.write(decimal(&digits, v));
            }

            pub fn stdValue(self: *Buffer, v: anytype, options: std.json.Stringify.Options) BufferError!void {
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                std.json.Stringify.value(v, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }

            pub fn raw(self: *Buffer, bytes: []const u8, options: std.json.Stringify.Options) BufferError!void {
                if (rawAsIs(bytes, options)) return self.write(bytes);
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                rawChanged(bytes, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }

            pub fn members(self: *Buffer, v: anytype, options: std.json.Stringify.Options) BufferError!void {
                return bufferMembers(v, options, self, true);
            }

            pub fn stdString(self: *Buffer, s: []const u8, options: std.json.Stringify.Options) BufferError!void {
                var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
                std.json.Stringify.encodeJsonString(s, options, &fixed) catch return error.NoSpace;
                self.end += fixed.end;
            }
        };

        pub fn bufferValue(v: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            return mapping.emitBuffer(@This(), v, options, out);
        }

        /// A struct's members, or a tuple's items, between its brackets. `lead`
        /// says a member is already written in front of them, so every one of
        /// them takes a comma: the tag of a union tagged inside its object.
        pub fn bufferMembers(v: anytype, options: std.json.Stringify.Options, out: *Buffer, comptime lead: bool) BufferError!void {
            return mapping.emitBufferMembers(@This(), lead, v, options, out);
        }

        /// A union tagged inside its object: the tag first, then the arm's
        /// members, in one object. The arm a tag naming no arm was read as is
        /// written as it was read: a `Raw` holds the record, tag and all, and
        /// a `void` one is its own name.
        pub fn tagged(v: anytype, comptime inside: anytype, options: std.json.Stringify.Options, sink: anytype) !void {
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
        pub fn hasOwnStringify(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => std.meta.hasFn(T, "jsonStringify"),
                else => false,
            };
        }

        pub fn bufferArray(items: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            try out.byte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try out.byte(',');
                try bufferValue(item, options, out);
            }
            try out.byte(']');
        }

        /// An enum tag's name as a string. The name is known when this is
        /// compiled, and so is its JSON when it needs no escaping.
        pub inline fn bufferTagName(comptime name: []const u8, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            if (comptime safeFieldName(name))
                try out.write(comptime "\"" ++ name ++ "\"")
            else
                try bufferString(name, options, out);
        }

        /// A name — a field's, a tag's, an error's — as `std.json` writes it,
        /// whatever its bytes.
        pub fn bufferString(bytes: []const u8, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
            if (!try text(out, bytes, options)) try out.stdString(bytes, options);
        }

        /// Where a `WriterSink` or a `Buffer` is written to: a byte, a run of bytes,
        /// and a string `std.json` escapes itself.
        pub const WriterSink = struct {
            writer: *std.Io.Writer,

            pub fn byte(self: WriterSink, b: u8) std.Io.Writer.Error!void {
                return self.writer.writeByte(b);
            }
            pub fn write(self: WriterSink, bytes: []const u8) std.Io.Writer.Error!void {
                return self.writer.writeAll(bytes);
            }
            pub fn stdString(self: WriterSink, bytes: []const u8, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
                return std.json.Stringify.encodeJsonString(bytes, options, self.writer);
            }
            pub fn raw(self: WriterSink, bytes: []const u8, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
                return Encoder(Raw).raw(bytes, options, self.writer);
            }
            pub fn members(self: WriterSink, v: anytype, options: std.json.Stringify.Options) std.Io.Writer.Error!void {
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
        pub fn text(sink: anytype, bytes: []const u8, options: std.json.Stringify.Options) !bool {
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
        pub const decimal_max = 40;
        comptime {
            // A signed 128-bit magnitude needs 39 decimal digits and its sign.
            std.debug.assert(decimal_max >= 39 + 1);
        }

        /// `v` in base ten, as `{d}` writes it, at the end of `buffer`.
        ///
        /// Two digits a division, and for an integer past 64 bits, nineteen digits
        /// a 128-bit division and the rest in 64 bits, which is where a `u128`'s
        /// time goes otherwise.
        pub fn decimal(buffer: *[decimal_max]u8, v: anytype) []const u8 {
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

        pub fn safeFieldName(bytes: []const u8) bool {
            for (bytes) |b| if (b < 0x20 or b == '"' or b == '\\' or b >= 0x7f) return false;
            return true;
        }

        pub fn array(items: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer) !void {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try value(item, options, writer);
            }
            try writer.writeByte(']');
        }

        pub fn string(bytes: []const u8, options: std.json.Stringify.Options, writer: *std.Io.Writer) !void {
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
                    const codepoint: ?u21 = if (bytes.len - i < len) null else switch (len) {
                        2 => std.unicode.utf8Decode2(bytes[i..][0..2].*) catch null,
                        3 => std.unicode.utf8Decode3(bytes[i..][0..3].*) catch null,
                        4 => std.unicode.utf8Decode4(bytes[i..][0..4].*) catch null,
                        else => unreachable, // a byte from 0x80 up leads two to four bytes or is refused above
                    };
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
