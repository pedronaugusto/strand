//! Direct minified JSON encoding for ordinary Zig values.
//!
//! Custom `jsonStringify` types and pretty output stay with `std.json`.
//! `Raw` has a `jsonStringify` for that path and is written here directly.

const std = @import("std");
const Raw = @import("raw.zig").Raw;

pub fn supports(comptime T: type) bool {
    // The walk visits every field of every type reachable from `T`, once
    // per path to it: a line protocol of sixty requests is thousands of
    // steps, past the compiler's default of a thousand. The ceiling is
    // for a schema's size, never a loop that does not end: the walk
    // stops at any type it is already inside.
    @setEvalBranchQuota(1_000_000);
    return supportsType(T, .{});
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

pub fn value(v: anytype, options: std.json.Stringify.Options, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const T = @TypeOf(v);
    if (T == Raw) return raw(v.bytes, options, writer);
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (v) "true" else "false"),
        .int => try writer.printInt(v, 10, .lower, .{}),
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
            var first = true;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                var emit = true;
                if (!info.is_tuple and @typeInfo(field.type) == .optional and !options.emit_null_optional_fields) {
                    if (@field(v, field.name) == null) emit = false;
                }
                if (emit) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    if (!info.is_tuple) {
                        try string(field.name, options, writer);
                        try writer.writeByte(':');
                    }
                    try value(@field(v, field.name), options, writer);
                }
            }
            try writer.writeByte(if (info.is_tuple) ']' else '}');
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            try writer.writeByte('{');
            inline for (info.fields) |field| {
                if (v == @field(Tag, field.name)) {
                    try string(field.name, options, writer);
                    try writer.writeByte(':');
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
                if (info.child == u8 and std.unicode.utf8ValidateSlice(slice)) {
                    try string(slice, options, writer);
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
        if (self.end == self.bytes.len) return error.NoSpace;
        self.bytes[self.end] = b;
        self.end += 1;
    }

    inline fn write(self: *Buffer, src: []const u8) BufferError!void {
        if (src.len > self.bytes.len - self.end) return error.NoSpace;
        @memcpy(self.bytes[self.end..][0..src.len], src);
        self.end += src.len;
    }

    fn integer(self: *Buffer, v: anytype) BufferError!void {
        const I = @TypeOf(v);
        const info = @typeInfo(I).int;
        const U = std.meta.Int(.unsigned, @max(info.bits, 8));
        var n: U = @abs(v);
        // A comptime `@max` narrows its result to the smallest type that
        // holds it, which for seven bits is a `u3` that the one added to it
        // overflows; the length is a `usize` before anything is added.
        var tmp: [1 + @as(usize, @max(info.bits, 1))]u8 = undefined;
        var at = tmp.len;
        while (n >= 100) : (n /= 100) {
            at -= 2;
            tmp[at..][0..2].* = std.fmt.digits2(@intCast(n % 100));
        }
        if (n < 10) {
            at -= 1;
            tmp[at] = '0' + @as(u8, @intCast(n));
        } else {
            at -= 2;
            tmp[at..][0..2].* = std.fmt.digits2(@intCast(n));
        }
        if (info.signedness == .signed and v < 0) {
            at -= 1;
            tmp[at] = '-';
        }
        try self.write(tmp[at..]);
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

    fn stdString(self: *Buffer, s: []const u8, options: std.json.Stringify.Options) BufferError!void {
        var fixed: std.Io.Writer = .fixed(self.bytes[self.end..]);
        std.json.Stringify.encodeJsonString(s, options, &fixed) catch return error.NoSpace;
        self.end += fixed.end;
    }
};

fn bufferValue(v: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
    const T = @TypeOf(v);
    if (T == Raw) return out.raw(v.bytes, options);
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
            try bufferString(@tagName(v), options, out);
        },
        .enum_literal => try bufferString(@tagName(v), options, out),
        .error_set => try bufferString(@errorName(v), options, out),
        .@"struct" => |info| {
            try out.byte(if (info.is_tuple) '[' else '{');
            var first = true;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                var emit = true;
                if (!info.is_tuple and @typeInfo(field.type) == .optional and !options.emit_null_optional_fields) {
                    if (@field(v, field.name) == null) emit = false;
                }
                if (emit) {
                    if (!first) try out.byte(',');
                    first = false;
                    if (!info.is_tuple) {
                        if (comptime safeFieldName(field.name)) {
                            try out.byte('"');
                            try out.write(field.name);
                            try out.write("\":");
                        } else {
                            try bufferString(field.name, options, out);
                            try out.byte(':');
                        }
                    }
                    try bufferValue(@field(v, field.name), options, out);
                }
            }
            try out.byte(if (info.is_tuple) ']' else '}');
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            try out.byte('{');
            inline for (info.fields) |field| {
                if (v == @field(Tag, field.name)) {
                    if (comptime safeFieldName(field.name)) {
                        try out.byte('"');
                        try out.write(field.name);
                        try out.write("\":");
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
                    if (try bufferAsciiString(slice, out)) return;
                    if (std.unicode.utf8ValidateSlice(slice))
                        try bufferString(slice, options, out)
                    else
                        try bufferArray(slice, options, out);
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

fn bufferArray(items: anytype, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
    try out.byte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try out.byte(',');
        try bufferValue(item, options, out);
    }
    try out.byte(']');
}

fn bufferString(bytes: []const u8, options: std.json.Stringify.Options, out: *Buffer) BufferError!void {
    var escaped = false;
    for (bytes) |b| {
        if (b < 0x20 or b == '"' or b == '\\' or (options.escape_unicode and b >= 0x7f)) {
            escaped = true;
            break;
        }
    }
    if (escaped) return out.stdString(bytes, options);
    try out.byte('"');
    try out.write(bytes);
    try out.byte('"');
}

/// The overwhelmingly common string needs neither UTF-8 decoding nor an
/// escaping pass: ASCII is already valid UTF-8, and a vector comparison can
/// establish that no JSON-special byte is present while reading each run
/// once. Returns false for the uncommon path, which the full validator and
/// escaper handle.
fn bufferAsciiString(bytes: []const u8, out: *Buffer) BufferError!bool {
    const width = 16;
    const V = @Vector(width, u8);
    var i: usize = 0;
    while (i + width <= bytes.len) : (i += width) {
        const v: V = bytes[i..][0..width].*;
        if (@reduce(.Or, v < @as(V, @splat(0x20))) or
            @reduce(.Or, v == @as(V, @splat('"'))) or
            @reduce(.Or, v == @as(V, @splat('\\'))) or
            @reduce(.Or, v >= @as(V, @splat(0x7f)))) return false;
    }
    for (bytes[i..]) |b| {
        if (b < 0x20 or b == '"' or b == '\\' or b >= 0x7f) return false;
    }
    try out.byte('"');
    try out.write(bytes);
    try out.byte('"');
    return true;
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
    const V = @Vector(width, u8);
    var i: usize = 0;
    while (i + width <= bytes.len) : (i += width) {
        const v: V = bytes[i..][0..width].*;
        if (breaks and (@reduce(.Or, v == @as(V, @splat('\n'))) or @reduce(.Or, v == @as(V, @splat('\r'))))) return false;
        if (escape and @reduce(.Or, v >= @as(V, @splat(0x80)))) return false;
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
