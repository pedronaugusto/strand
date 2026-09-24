//! A JSON value kept as the bytes it was written in.
//!
//! A line often carries a value its reader does not read: another program's
//! record passed along, the payload of a plugin the reader only routes, a
//! request handed on as it came. Typed as a `std.json.Value`, that value is
//! built into a tree nobody walks, and the type around it leaves the direct
//! decoder for `std.json`'s token parser, because a `Value` parses itself.
//! Typed as a `Raw`, it is checked and kept: the line is refused if the value
//! is not JSON, and otherwise the value is its bytes, decoded when and if the
//! caller asks and written back as they came.

const std = @import("std");
const Allocator = std.mem.Allocator;

const strand = @import("strand.zig");
const Scanner = @import("scanner.zig");
const encode_mod = @import("encode.zig");

/// One JSON value as its bytes, undecoded.
///
/// Decoding a field of this type checks the value the way the rest of the
/// line is checked — a value that is not JSON is the line's error, named as
/// any other would be — and keeps its bytes, from its first to its last,
/// whitespace inside it included. They borrow from the line exactly as a
/// string does: a view into it by default, a copy on the allocator under
/// `copy_strings`, which is what `Reader.keep` asks for. `parse` is the value
/// when it is wanted, as any type at all.
///
/// Writing one writes the bytes, with two exceptions, both of them promises
/// the writer makes about every line: a line break, which JSON allows only
/// between tokens, is written as a space in `.minified`, so a record stays
/// one line; and under `escape_unicode` a character that is not ASCII is
/// written as its `\u` escape. Neither changes the value. It is not
/// re-indented in `.pretty`.
///
/// A `Raw` made by hand is trusted: bytes that are not one JSON value are
/// written as they are, and make a line no reader will take back.
/// `parseLine(Raw, ...)` is the constructor that checks them, and `encode` is
/// the one that makes them from a value.
///
/// The type is on the direct path both ways, and a struct or a union holding
/// one stays there. Through `std.json`'s own entry points it parses and
/// stringifies itself; there, a value handed over as a `std.json.Value`
/// (`std.json.parseFromValue`, `Versioned`'s migration) is kept as that value
/// encoded, since the bytes it was written in are no longer anywhere.
pub const Raw = struct {
    /// The value's bytes: one complete JSON value, with nothing before or
    /// after it.
    bytes: []const u8,

    /// JSON `null`, as a default: `data: strand.Raw = .null`.
    pub const @"null": Raw = .{ .bytes = "null" };

    /// `value`, encoded as `Writer` encodes it with its default options, as
    /// a `Raw` on `allocator`. The bytes are one allocation of exactly their
    /// length, so `allocator.free(raw.bytes)` returns it.
    pub fn encode(allocator: Allocator, value: anytype) Allocator.Error!Raw {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        strand.writeLine(&out.writer, value) catch return error.OutOfMemory;
        // `writeLine` ends the record with its terminator, which is not part
        // of the value.
        out.writer.end -= 1;
        return .{ .bytes = try out.toOwnedSlice() };
    }

    /// The value, as a `T`: `parseLine` over the bytes, with its options,
    /// its errors and its ownership. Strings that need no unescaping point
    /// into `raw.bytes`, so they live as long as those do.
    pub fn parse(
        raw: Raw,
        comptime T: type,
        allocator: Allocator,
        options: strand.ParseOptions,
    ) strand.ParseLineError!T {
        return strand.parseLine(T, allocator, raw.bytes, options);
    }

    /// Reads the value. Called by `std.json`, and by this package on the
    /// paths that use `std.json`'s token parser.
    ///
    /// A source that holds the whole input in one slice — this package's
    /// scanner, or `std.json.Scanner` over complete input — is where the
    /// bytes are, so the value is checked by skipping it and the bytes it
    /// covered are kept. A source that streams has no such slice; there the
    /// value is parsed and encoded, which keeps what it means and not how it
    /// was spaced.
    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Raw {
        const Source = @TypeOf(source.*);
        if (comptime Source == Scanner or Source == std.json.Scanner) whole: {
            if (Source == std.json.Scanner and !source.is_end_of_input) break :whole;
            // The peek steps over whitespace and the colon before a
            // field's value, so the cursor is on the value's first byte.
            _ = try source.peekNextTokenType();
            const start = source.cursor;
            try source.skipValue();
            return keep(allocator, source.input[start..source.cursor], options);
        }
        const value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return encode(allocator, value);
    }

    /// A value `std.json` has already parsed into a `std.json.Value`: kept
    /// as that value encoded.
    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Raw {
        _ = options;
        return encode(allocator, source);
    }

    /// Writes the value. Called by `std.json`; `Writer` writes a `Raw`
    /// itself in `.minified` and through this in `.pretty`, and the bytes
    /// written are the same, line breaks and escapes as the type says.
    pub fn jsonStringify(raw: Raw, jw: anytype) !void {
        try jw.beginWriteRaw();
        try encode_mod.raw(raw.bytes, jw.options, jw.writer);
        jw.endWriteRaw();
    }

    /// The bytes as a decoded value would hold them: borrowed unless every
    /// string is to be copied.
    fn keep(allocator: Allocator, bytes: []const u8, options: std.json.ParseOptions) Allocator.Error!Raw {
        if ((options.allocate orelse .alloc_always) == .alloc_always)
            return .{ .bytes = try allocator.dupe(u8, bytes) };
        return .{ .bytes = bytes };
    }
};

//=========================================================================
// Tests. The scenarios with a stream in them are in `tests.zig`.
//=========================================================================

const testing = std.testing;

test Raw {
    const Mark = struct {
        kind: []const u8,
        data: Raw = .null,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = "{\"kind\":\"beat\",\"data\":{ \"who\" : \"ada\", \"n\": [1, 2.50] }}";
    const mark = try strand.parseLine(Mark, a, line, .{});
    // The value's own bytes, spacing and all, borrowed from the line.
    try testing.expectEqualStrings("{ \"who\" : \"ada\", \"n\": [1, 2.50] }", mark.data.bytes);
    try testing.expect(mark.data.bytes.ptr == line.ptr + std.mem.indexOf(u8, line, "{ ").?);

    // Decoded when it is wanted, as whatever it is wanted as.
    const Data = struct { who: []const u8, n: []const f64 };
    const data = try mark.data.parse(Data, a, .{});
    try testing.expectEqualStrings("ada", data.who);
    try testing.expectEqual(@as(f64, 2.5), data.n[1]);
    try testing.expectEqualStrings("ada", (try mark.data.parse(std.json.Value, a, .{})).object.get("who").?.string);

    // Written back as it came.
    var out: std.Io.Writer.Allocating = .init(a);
    try strand.writeLine(&out.writer, mark);
    try testing.expectEqualStrings(line ++ "\n", out.written());

    // Absent, it is JSON null.
    const bare = try strand.parseLine(Mark, a, "{\"kind\":\"beat\"}", .{});
    try testing.expectEqualStrings("null", bare.data.bytes);
}

test "encode makes a Raw of any value, one allocation long" {
    const raw = try Raw.encode(testing.allocator, .{ .who = "ada", .n = @as(u32, 3), .gone = @as(?u8, null) });
    defer testing.allocator.free(raw.bytes);
    try testing.expectEqualStrings("{\"who\":\"ada\",\"n\":3}", raw.bytes);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try strand.parseLine(std.json.Value, arena.allocator(), "[true, {\"a\":null}]", .{});
    const from_value = try Raw.encode(arena.allocator(), value);
    try testing.expectEqualStrings("[true,{\"a\":null}]", from_value.bytes);
}

test "parseLine is the constructor that checks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("[1, 2]", (try strand.parseLine(Raw, a, "  [1, 2]\t", .{})).bytes);
    try testing.expectEqualStrings("\"x\"", (try strand.parseLine(Raw, a, "\"x\"", .{})).bytes);
    try testing.expectError(error.UnexpectedEndOfInput, strand.parseLine(Raw, a, "[1, 2", .{}));
    try testing.expectError(error.SyntaxError, strand.parseLine(Raw, a, "[1] 2", .{}));
    try testing.expectError(error.UnexpectedEndOfInput, strand.parseLine(Raw, a, "", .{}));
}

test "std.json's own entry points read and write a Raw" {
    const Mark = struct { data: Raw };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Over complete input the bytes are kept as they are.
    const line = "{\"data\" :  [1, 2] }";
    const mark = try std.json.parseFromSliceLeaky(Mark, a, line, .{});
    try testing.expectEqualStrings("[1, 2]", mark.data.bytes);

    // A value that has been through a `std.json.Value` is kept encoded.
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    const from_value = try std.json.parseFromValueLeaky(Mark, a, value, .{});
    try testing.expectEqualStrings("[1,2]", from_value.data.bytes);

    // A stream is parsed and encoded.
    var source: std.Io.Reader = .fixed(line);
    var json_reader: std.json.Reader = .init(a, &source);
    const streamed = try std.json.parseFromTokenSourceLeaky(Mark, a, &json_reader, .{});
    try testing.expectEqualStrings("[1,2]", streamed.data.bytes);

    // And written verbatim, but not with a line break in a minified line.
    const text = try std.json.Stringify.valueAlloc(a, Mark{ .data = .{ .bytes = "[1,\n2]" } }, .{});
    try testing.expectEqualStrings("{\"data\":[1, 2]}", text);
}
