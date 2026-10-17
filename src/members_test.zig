//! `json.Members` against the parser: an object in any spelling yields its
//! members as the parser reads them, any bytes are accepted exactly where the
//! parser accepts an object, and each limit holds at its edge as the
//! parser holds it passing over an object's members.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Source = shakedown.Source;
const strand = @import("strand.zig");
const json = strand.json;
const core = strand.core;

const Allocator = std.mem.Allocator;
const Out = std.Io.Writer.Allocating;

/// Names worth spelling: plain, empty, quoted, escaped, beyond ASCII, and
/// one name twice.
const names = [_][]const u8{ "seq", "at", "", "c", "a\"b", "back\\slash", "line\nbreak", "caf\u{e9}", "\u{1f600}", "/", "seq" };
const strings_ = [_][]const u8{ "", "plain", "with \"quotes\"", "\u{1}\u{1f}", "\u{2028}", "x\\y", "\u{10ffff}" };
const numbers = [_][]const u8{ "0", "-0", "7", "-12", "1.5", "-0.25e+3", "1E9", "18446744073709551616", "9223372036854775807" };

/// Whitespace JSON allows between tokens, often none.
fn space(s: *Source, out: *Out) !void {
    while (gen.intRange(s, u8, 0, 3) == 0) try out.writer.writeAll(gen.oneOf(s, []const u8, &.{ " ", "\t", "\n", "\r", "  " }));
}

/// `text` as the body of a JSON string, each byte or scalar escaped or not
/// as `s` says, where JSON lets it be either.
fn spellText(s: *Source, out: *Out, text: []const u8) !void {
    const w = &out.writer;
    var view: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (true) {
        const from = view.i;
        const scalar = view.nextCodepoint() orelse break;
        const slice = text[from..view.i];
        const must = scalar < 0x20 or scalar == '"' or scalar == '\\';
        if (!must and gen.intRange(s, u8, 0, 3) != 0) {
            try w.writeAll(slice);
            continue;
        }
        switch (if (must) gen.intRange(s, u8, 0, 1) else gen.intRange(s, u8, 0, 2)) {
            0 => switch (scalar) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '/' => try w.writeAll("\\/"),
                else => try unicodeEscape(w, scalar),
            },
            1 => try unicodeEscape(w, scalar),
            else => try w.writeAll(slice),
        }
    }
}

fn unicodeEscape(w: *std.Io.Writer, scalar: u21) !void {
    if (scalar < 0x10000) return w.print("\\u{x:0>4}", .{scalar});
    const v = scalar - 0x10000;
    try w.print("\\u{X:0>4}\\u{x:0>4}", .{ 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff) });
}

/// A value, spelled any way JSON allows, nested at most `depth` deep.
fn spellValue(s: *Source, out: *Out, depth: u8) anyerror!void {
    const w = &out.writer;
    switch (gen.intRange(s, u8, 0, if (depth == 0) 4 else 6)) {
        0 => try w.writeAll(gen.oneOf(s, []const u8, &.{ "null", "true", "false" })),
        1, 2 => try w.writeAll(gen.oneOf(s, []const u8, &numbers)),
        3, 4 => {
            try w.writeByte('"');
            try spellText(s, out, gen.oneOf(s, []const u8, &strings_));
            try w.writeByte('"');
        },
        5 => {
            try w.writeByte('[');
            try space(s, out);
            const n = gen.intRange(s, u8, 0, 3);
            for (0..n) |i| {
                if (i != 0) {
                    try w.writeByte(',');
                    try space(s, out);
                }
                try spellValue(s, out, depth - 1);
                try space(s, out);
            }
            try w.writeByte(']');
        },
        else => _ = try spellObject(s, out, depth - 1, null),
    }
}

/// Where one member was written.
const Written = struct { name: []const u8, separator: usize, start: usize, value_start: usize, value_end: usize };

/// An object, spelled any way JSON allows; with `record`, where each of its
/// members was written. Returns the offset past its closing brace.
fn spellObject(s: *Source, out: *Out, depth: u8, record: ?*std.ArrayList(Written)) anyerror!usize {
    const w = &out.writer;
    var separator = w.end;
    try w.writeByte('{');
    try space(s, out);
    const n = gen.intRange(s, u8, 0, 5);
    for (0..n) |i| {
        if (i != 0) {
            separator = w.end;
            try w.writeByte(',');
            try space(s, out);
        }
        const name = gen.oneOf(s, []const u8, &names);
        const start = w.end;
        try w.writeByte('"');
        try spellText(s, out, name);
        try w.writeByte('"');
        try space(s, out);
        try w.writeByte(':');
        try space(s, out);
        const value_start = w.end;
        try spellValue(s, out, depth);
        const value_end = w.end;
        try space(s, out);
        if (record) |list| try list.append(testing.allocator, .{ .name = name, .separator = separator, .start = start, .value_start = value_start, .value_end = value_end });
    }
    try w.writeByte('}');
    return w.end;
}

/// Any parse into `json.Value`: repeated names kept, as the iterator keeps
/// them.
const any: json.ParseOptions = .{ .duplicates = null };

/// An object read for none of its members: every one passed over, as the
/// iterator passes over a member's value, and checked as it is.
const Nothing = struct {};
const passing: json.ParseOptions = .{ .duplicates = null, .ignore_unknown_fields = true };

fn fuzzSpelled(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Out = .init(a);
    var written: std.ArrayList(Written) = .empty;
    defer written.deinit(testing.allocator);
    try space(s, &out);
    const end = try spellObject(s, &out, gen.intRange(s, u8, 0, 3), &written);
    try space(s, &out);
    const bytes = out.written();

    var members: json.Members = undefined;
    members.init(bytes, .{});
    const parsed = try json.parseLeaky(json.Value, a, bytes, any);
    for (written.items, parsed.object) |want, member| {
        const got = (try members.next()).?;
        try testing.expect(got.is(want.name));
        // The first of the names it is, through `which` as through `is`.
        const first = for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, want.name)) break i;
        } else unreachable;
        try testing.expectEqual(@as(?usize, first), got.which(&names));
        var buffer: [64]u8 = undefined;
        try testing.expectEqualStrings(want.name, try got.nameInto(&buffer));
        try testing.expectEqualStrings(member.key, try got.nameInto(&buffer));
        try testing.expectEqual(want.separator, got.separator);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.value_start, got.value_start);
        try testing.expectEqual(want.value_end, got.valueEnd());
        try testing.expectEqualDeep(member.value, try json.parseLeaky(json.Value, a, got.value, any));
    }
    try testing.expectEqual(@as(?json.Member, null), try members.next());
    try testing.expectEqual(end, try members.finish());
}

test "fuzz: the members of an object spelled any way are its members" {
    try shakedown.check(testing.allocator, {}, fuzzSpelled, .{});
}

/// Any bytes: read as an object exactly where the parser takes them as an
/// object whose members it passes over (`Nothing`), and then as the members
/// the parser reads into a `json.Value`.
fn checkBytes(bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const checked = json.parseLeaky(Nothing, a, bytes, passing);
    // A `json.Value` nests a level deeper per container than the value it
    // reads: a deeper limit, for the members' contents alone.
    var deep = any;
    deep.limits.depth = 4 * json.Members.max_depth;
    const parsed: ?json.Value = json.parseLeaky(json.Value, a, bytes, deep) catch null;

    var members: json.Members = undefined;
    members.init(bytes, .{});
    var read: usize = 0;
    while (members.next()) |found| {
        const member = found orelse break;
        // Members come only off an object the parser takes, or one it
        // refuses after them.
        if (parsed) |value| {
            const want = value.object[read];
            var buffer: [512]u8 = undefined;
            try testing.expectEqualStrings(want.key, try member.nameInto(&buffer));
            try testing.expectEqualDeep(want.value, try json.parseLeaky(json.Value, a, member.value, deep));
        }
        read += 1;
    } else |err| {
        if (checked) |_| return error.TestExpectedError else |refusal| try expectSameRefusal(refusal, err);
        try testing.expectError(err, members.finish());
        return;
    }
    if (members.finish()) |end| {
        _ = try checked;
        try testing.expectEqual(parsed.?.object.len, read);
        try testing.expectEqual(bytes.len, end + (bytes.len - std.mem.trimEnd(u8, bytes, " \t\r\n").len));
    } else |err| {
        if (checked) |_| return error.TestExpectedError else |refusal| try expectSameRefusal(refusal, err);
    }
}

/// A refusal the parser and the iterator both give, for the same reason:
/// the grammar, or the limit both hit.
fn expectSameRefusal(parser: anyerror, iterator: json.MembersError) !void {
    switch (iterator) {
        error.SyntaxError => try testing.expect(parser == error.SyntaxError or parser == error.InvalidUtf8),
        // Valid JSON, refused only for not being an object.
        error.UnexpectedType => try testing.expectEqual(error.UnexpectedType, parser),
        else => try testing.expectEqual(parser, @as(anyerror, iterator)),
    }
}

const examples = [_][]const u8{
    "{\"seq\":7,\"at\":-3,\"v\":2,\"p\":11,\"ev\":{\"x\":1},\"c\":42}",
    "{ \"p\" : 11, \"ev\" : {\"x\":[1,2,{}]}, \"s\\u0065q\":7 }",
    "{\"a\":\"caf\xc3\xa9 \\u0041\\ud83d\\ude00\",\"a\":null,\"\":[true,false]}",
    "[1,2]",
    "{\"deep\":[[[[[[[[{\"x\":{}}]]]]]]]]}",
    "{\"n\":-0.5e-7,\"m\":1E+2}",
    "\t{}\r\n",
};

fn fuzzBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [512]u8 = undefined;
    try checkBytes(gen.mutated(case.source, &buffer, &examples));
}

test "fuzz: any bytes are an object exactly where the parser reads one" {
    try shakedown.check(testing.allocator, {}, fuzzBytes, .{});
}

test "the recorded objects read as the parser reads them" {
    for (examples) |bytes| try checkBytes(bytes);
    for ([_][]const u8{ "", "{", "}", "{\"a\":1,}", "{\"a\" 1}", "{\"a\":1}x", "{\"\\x\":1}", "{\"a\":\"\x01\"}", "{\"a\":\"\xc3\"}", "{\"a\":[1}}", "{\"a\":1 2}", "nul", "\"x\"" }) |bytes|
        try checkBytes(bytes);
}

/// The verdicts of the iterator and of the parser over `bytes` with `limits`.
fn verdicts(bytes: []const u8, limits: core.Limits) !struct { iterator: ?json.MembersError, parser: ?anyerror } {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var members: json.Members = undefined;
    members.init(bytes, .{ .limits = limits });
    const iterator: ?json.MembersError = if (members.finish()) |_| null else |err| err;
    var options = passing;
    options.limits = limits;
    const parser: ?anyerror = if (json.parseLeaky(Nothing, arena.allocator(), bytes, options)) |_| null else |err| err;
    return .{ .iterator = iterator, .parser = parser };
}

/// `bytes` read at `limits`, and with `field` one less: taken at the edge,
/// refused with `refusal` past it, by the iterator and the parser alike.
fn expectEdge(bytes: []const u8, limits: core.Limits, comptime field: []const u8, refusal: json.MembersError) !void {
    const at = try verdicts(bytes, limits);
    try testing.expectEqual(@as(?json.MembersError, null), at.iterator);
    try testing.expectEqual(@as(?anyerror, null), at.parser);
    var tighter = limits;
    @field(tighter, field) -= 1;
    const past = try verdicts(bytes, tighter);
    try testing.expectEqual(@as(?json.MembersError, refusal), past.iterator);
    try testing.expectEqual(@as(?anyerror, refusal), past.parser);
}

test "each limit holds at its edge as the parser's does" {
    try expectEdge("{\"a\":[[{}]]}", .{ .depth = 4 }, "depth", error.DepthLimit);
    try expectEdge("{\"abcd\":1}", .{ .key_bytes = 4 }, "key_bytes", error.LengthLimit);
    // A name is as long as its text, however it is escaped.
    try expectEdge("{\"\\u0061bc\\u0064\":1}", .{ .key_bytes = 4 }, "key_bytes", error.LengthLimit);
    try expectEdge("{\"a\":\"abcde\"}", .{ .string_bytes = 5 }, "string_bytes", error.LengthLimit);
    try expectEdge("{\"a\":-1.25}", .{ .numeric_bytes = 5 }, "numeric_bytes", error.LengthLimit);
    try expectEdge("{\"a\":1,\"b\":2,\"c\":3}", .{ .container_items = 3 }, "container_items", error.ItemLimit);
    try expectEdge("{\"a\":[1,2,3]}", .{ .container_items = 3 }, "container_items", error.ItemLimit);
    const object = "{\"a\":[1,{\"b\":2}],\"c\":3}";
    try expectEdge(object, .{ .input_bytes = object.len }, "input_bytes", error.InputLimit);
    try expectEdge(object, .{ .items = itemsOf(object) }, "items", error.ItemLimit);
}

/// The fewest items the parser checks `bytes` in.
fn itemsOf(bytes: []const u8) usize {
    var n: usize = 1;
    while (true) : (n += 1) {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var options = passing;
        options.limits.items = n;
        if (json.parseLeaky(Nothing, arena.allocator(), bytes, options)) |_| return n else |_| {}
    }
}

test "nesting is held to the decoder's frames, whatever the limit says" {
    var buffer: [2 * json.Members.max_depth + 16]u8 = undefined;
    for ([_]usize{ json.Members.max_depth, json.Members.max_depth + 1 }) |depth| {
        var out: std.Io.Writer = .fixed(&buffer);
        try out.writeAll("{\"a\":");
        for (1..depth) |_| try out.writeByte('[');
        for (1..depth) |_| try out.writeByte(']');
        try out.writeByte('}');
        var members: json.Members = undefined;
        members.init(out.buffered(), .{ .limits = .{ .depth = 10 * json.Members.max_depth } });
        if (depth <= json.Members.max_depth) {
            _ = try members.finish();
        } else try testing.expectError(error.DepthLimit, members.finish());
    }
}

test "a reader stops where it has what it wants" {
    // Nothing after the member asked for is read, valid or not.
    const line = "{\"kind\":\"open\",\"body\":" ++ @as([300]u8, @splat('['));
    var members: json.Members = undefined;
    members.init(line, .{});
    const kind = (try members.next()).?;
    try testing.expect(kind.is("kind"));
    try testing.expectEqualStrings("\"open\"", kind.value);
}
