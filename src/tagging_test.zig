//! Unions tagged inside their object (`jsonl_tag`) and the member peek
//! (`memberOf`), through the public API: every decoder agreeing with the
//! others and with the recorded answers, and every encoder writing the one
//! shape.

const std = @import("std");
const testing = std.testing;
const strand = @import("strand.zig");

/// The union `src/corpus/tagged/answers.txt` was recorded against, tagged by
/// `type`, with no catch-all.
const Closed = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    result: struct { ok: bool },
    pub const jsonl_tag = "type";
};

/// The same, with a catch-all arm.
const Open = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    result: struct { ok: bool },
    unknown,
    pub const jsonl_tag = "type";
    pub const jsonl_other = .unknown;
};

/// What a record a newer writer added looks like to a reader that keeps it.
const Kept = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    other: strand.json.Raw,
    pub const jsonl_tag = "type";
    pub const jsonl_other = .other;
};

const cases = @embedFile("corpus/tagged/cases.jsonl");
const recorded = @embedFile("corpus/tagged/answers.txt");

/// The class a recorded answer names, from the error this package names.
fn class(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingField => "MissingField",
        error.DuplicateField => "DuplicateField",
        error.InvalidEnumTag => "InvalidEnumTag",
        // The recorded answers say "invalid type" and "invalid value" alike
        // for a value of the wrong kind and for one out of its type's range.
        error.UnexpectedToken, error.Overflow, error.InvalidCharacter, error.InvalidNumber => "UnexpectedToken",
        else => "Syntax",
    };
}

/// Lines the recorded answers read and this package refuses, by their place in
/// the cases: they read a union tagged inside its object from a JSON array as
/// well, the tag first and the fields after it in order. No writer writes one;
/// a record here is an object.
const arrays = [_]usize{ 33, 39, 40 };

/// What `U` makes of `line` by one path, as a recorded answer says it: `ok` and
/// the value written, or `err` and the class.
const Path = enum { direct, tokens, value };

fn answer(comptime U: type, a: std.mem.Allocator, line: []const u8, path: Path) ![]const u8 {
    const parsed: anyerror!U = switch (path) {
        .direct => strand.parseLine(U, a, line, .{}),
        .tokens => tokens: {
            var where: strand.Diagnostics = .{};
            break :tokens strand.parseLine(U, a, line, .{ .diagnostics = &where });
        },
        .value => value: {
            const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .duplicate_field_behavior = .@"error" }) catch |err|
                break :value err;
            break :value strand.jsonl.payloadOf(U, a, value);
        },
    };
    const v = parsed catch |err| return a.print("err {s}", .{class(err)});
    var out: std.Io.Writer.Allocating = .init(a);
    try strand.writeValue(&out.writer, v, .{});
    return a.print("ok {s}", .{out.written()});
}

test "a union tagged inside its object reads as the recorded answers say" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines = std.mem.splitScalar(u8, cases[0 .. cases.len - 1], '\n');
    var answers = std.mem.splitScalar(u8, recorded[0 .. recorded.len - 1], '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const expected = answers.next().?;
        const tab = std.mem.findScalar(u8, expected, '\t').?;
        const want = [2][]const u8{ expected[0..tab], expected[tab + 1 ..] };
        const array = std.mem.findScalar(usize, &arrays, number) != null;
        inline for (.{ Closed, Open }, 0..) |U, which| {
            for ([_]Path{ .direct, .tokens }) |path| {
                const got = try answer(U, a, line, path);
                if (array) {
                    try testing.expectEqualStrings("err UnexpectedToken", got);
                } else {
                    testing.expectEqualStrings(want[which], got) catch |err| {
                        std.debug.print("case {d} {s} {s}: {s}\n", .{ number, @typeName(U), @tagName(path), line });
                        return err;
                    };
                }
            }
            // A `std.json.Value` has no duplicate members and no syntax to
            // be wrong, so it is held to the parse for what it can hold.
            const direct = try answer(U, a, line, .direct);
            if (std.json.parseFromSliceLeaky(std.json.Value, a, line, .{})) |_| {
                try testing.expectEqualStrings(direct, try answer(U, a, line, .value));
            } else |_| {}
        }
    }
    try testing.expectEqual(@as(?[]const u8, null), answers.next());
}

test "the arm a newer writer added is kept whole and written back as it came" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"data\":[1, 2],\"type\":\"tool_use\",\"id\":\"t1\"}";
    for ([_]bool{ false, true }) |diagnosed| {
        var where: strand.Diagnostics = .{};
        const kept = try strand.parseLine(Kept, a, line, .{ .diagnostics = if (diagnosed) &where else null });
        try testing.expectEqualStrings(line, kept.other.bytes);
        var out: std.Io.Writer.Allocating = .init(a);
        try strand.writeValue(&out.writer, kept, .{});
        try testing.expectEqualStrings(line, out.written());
    }
    // A record it knows is read as that arm, and a duplicate tag in one it
    // does not is still a duplicate.
    try testing.expectEqual(.ping, std.meta.activeTag(try strand.parseLine(Kept, a, "{\"type\":\"ping\"}", .{})));
    try testing.expectError(error.DuplicateField, strand.parseLine(Kept, a, "{\"type\":\"x\",\"type\":\"y\"}", .{}));
    try testing.expectError(error.DuplicateField, strand.parseLine(Kept, a, "{\"a\":1,\"type\":\"x\",\"type\":\"y\"}", .{}));
    // Copied rather than borrowed when every string is to be copied.
    const copied = try strand.parseLine(Kept, a, line, .{ .copy_strings = true });
    try testing.expect(copied.other.bytes.ptr != line.ptr);
}

test "unknown members of an arm follow ignore_unknown_fields, and the tag is not one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const strict: strand.ParseOptions = .{ .ignore_unknown_fields = false };
    try testing.expectEqualStrings("hi", (try strand.parseLine(Closed, a, "{\"text\":\"hi\",\"type\":\"assistant\"}", strict)).assistant.text);
    try testing.expectError(error.UnknownField, strand.parseLine(Closed, a, "{\"type\":\"ping\",\"extra\":1}", strict));
    try testing.expectError(error.UnknownField, strand.parseLine(Closed, a, "{\"extra\":1,\"type\":\"assistant\",\"text\":\"x\"}", strict));
    // The catch-all takes a record it does not know as it is.
    try testing.expectEqual(.unknown, std.meta.activeTag(try strand.parseLine(Open, a, "{\"type\":\"new\",\"extra\":1}", strict)));
    // A payload's own duplicate follows `duplicate_fields`.
    const twice = "{\"type\":\"assistant\",\"text\":\"a\",\"text\":\"b\"}";
    try testing.expectEqualStrings("b", (try strand.parseLine(Closed, a, twice, .{ .duplicate_fields = .use_last })).assistant.text);
    try testing.expectEqualStrings("a", (try strand.parseLine(Closed, a, twice, .{ .duplicate_fields = .use_first })).assistant.text);
}

test "a union tagged inside its object inside other values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Batch = struct { id: u32, messages: []const Closed, last: ?Closed = null };
    const line = "{\"id\":7,\"messages\":[{\"type\":\"ping\"},{\"text\":\"t\",\"type\":\"assistant\",\"n\":2}],\"last\":{\"type\":\"result\",\"ok\":true}}";
    const batch = try strand.parseLine(Batch, a, line, .{});
    try testing.expectEqual(@as(usize, 2), batch.messages.len);
    try testing.expectEqual(@as(u64, 2), batch.messages[1].assistant.n);
    try testing.expect(batch.last.?.result.ok);

    var out: std.Io.Writer.Allocating = .init(a);
    try strand.writeValue(&out.writer, batch, .{});
    try testing.expectEqualStrings(
        "{\"id\":7,\"messages\":[{\"type\":\"ping\"},{\"type\":\"assistant\",\"text\":\"t\",\"n\":2}],\"last\":{\"type\":\"result\",\"ok\":true}}",
        out.written(),
    );
}

test "a Writer writes the tag inside the object in both formats, and reads it back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]Kept{
        .{ .assistant = .{ .text = "quote \" and\nbreak", .n = 3 } },
        .ping,
        .{ .other = .{ .bytes = "{\"type\":\"new\",\"x\":[]}" } },
    };
    inline for (.{ .minified, .pretty }) |format| {
        // A destination too small for a record takes the slow path, and
        // one with room the fast one; both write the same bytes.
        for ([_]usize{ 4, 4096 }) |room| {
            var direct: std.Io.Writer.Allocating = try .initCapacity(a, room);
            var log: strand.jsonl.Writer(Kept) = .init(&direct.writer, .{ .format = format });
            for (records) |record| try log.write(record);

            var source: std.Io.Reader = .fixed(direct.written());
            var reader: strand.jsonl.Reader(Kept) = .init(a, &source, .{ .format = format });
            defer reader.deinit();
            for (records) |record| {
                const line = (try reader.next()).?;
                try testing.expectEqual(std.meta.activeTag(record), std.meta.activeTag(line.value));
            }
            try testing.expectEqual(@as(?strand.jsonl.Line(Kept), null), try reader.next());
            if (format == .pretty) {
                try testing.expect(std.mem.find(u8, direct.written(), "{\n  \"type\": \"assistant\",\n  \"text\": ") != null);
            } else {
                try testing.expect(std.mem.startsWith(u8, direct.written(), "{\"type\":\"assistant\",\"text\":"));
            }
        }
    }
}

/// A field that writes and reads itself, inside an arm.
pub const Stamp = struct {
    seconds: u32,
    pub fn jsonStringify(self: Stamp, jw: anytype) !void {
        try jw.print("\"{d}s\"", .{self.seconds});
    }
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Stamp {
        const text = try std.json.innerParse([]const u8, a, source, options);
        if (text.len == 0 or text[text.len - 1] != 's') return error.UnexpectedToken;
        return .{ .seconds = std.fmt.parseInt(u32, text[0 .. text.len - 1], 10) catch return error.UnexpectedToken };
    }
};

test "an arm holding a type with its own hooks is written and read by them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Timed = union(enum) {
        tick: struct { at: Stamp },
        pub const jsonl_tag = "type";
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try strand.writeValue(&out.writer, Timed{ .tick = .{ .at = .{ .seconds = 9 } } }, .{});
    try testing.expectEqualStrings("{\"type\":\"tick\",\"at\":\"9s\"}", out.written());
    const back = try strand.parseLine(Timed, a, "{\"at\":\"12s\",\"type\":\"tick\"}", .{});
    try testing.expectEqual(@as(u32, 12), back.tick.at.seconds);
}

test "tagOf reads the arm from the tag member of a union tagged inside its object" {
    try testing.expectEqual(.assistant, strand.json.tagOf(Closed, "{\"text\":\"x\",\"type\":\"assistant\"}").?);
    try testing.expectEqual(.ping, strand.json.tagOf(Closed, "{\"type\":\"ping\"}").?);
    try testing.expectEqual(@as(?std.meta.Tag(Closed), null), strand.json.tagOf(Closed, "{\"type\":\"nope\"}"));
    try testing.expectEqual(@as(?std.meta.Tag(Closed), null), strand.json.tagOf(Closed, "{\"ping\":{}}"));
    try testing.expectEqual(.unknown, strand.json.tagOf(Open, "{\"type\":\"nope\"}").?);
    try testing.expectEqual(@as(?std.meta.Tag(Open), null), strand.json.tagOf(Open, "{\"type\":7}"));
}

test "memberOf peeks at a member wherever it is in the object" {
    const line = "{\"message\":{\"type\":\"inner\",\"content\":[{\"type\":\"text\"}]},\"session_id\":\"s-1\",\"type\":\"assistant\"}";
    try testing.expectEqualStrings("\"assistant\"", strand.json.memberOf(line, "type").?);
    try testing.expectEqualStrings("assistant", strand.json.memberStringOf(line, "type").?);
    try testing.expectEqualStrings("s-1", strand.json.memberStringOf(line, "session_id").?);
    // The value is a view into the line.
    const at = std.mem.findLast(u8, line, "\"assistant\"").?;
    try testing.expect(strand.json.memberOf(line, "type").?.ptr == line.ptr + at);
    // A structured member is not something to route on.
    try testing.expectEqual(@as(?[]const u8, null), strand.json.memberOf(line, "message"));
    // A long string value has no bound: the line is in hand.
    const long = "{\"type\":\"" ++ @as([300]u8, @splat('x')) ++ "\"}";
    try testing.expectEqual(@as(usize, 302), strand.json.memberOf(long, "type").?.len);
}
