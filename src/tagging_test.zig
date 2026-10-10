//! Unions tagged inside their object (`strand.tag`) and the member peek
//! (`json.memberOf`), through the public API: the parse agreeing with the
//! recorded answers, and the writer writing the one shape.

const std = @import("std");
const testing = std.testing;
const strand_module = @import("strand.zig");
const json = strand_module.json;
const jsonl = strand_module.jsonl;

/// The union `src/corpus/tagged/answers.txt` was recorded against, tagged by
/// `type`, with no catch-all.
const Closed = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    result: struct { ok: bool },
    pub const strand = .{ .tag = "type" };
};

/// The same, with a catch-all arm.
const Open = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    result: struct { ok: bool },
    unknown,
    pub const strand = .{ .tag = "type", .other = "unknown" };
};

/// What a record a newer writer added looks like to a reader that keeps it.
const Kept = union(enum) {
    assistant: struct { text: []const u8, n: u64 = 0 },
    ping,
    other: json.Raw,
    pub const strand = .{ .tag = "type", .other = "other" };
};

const cases = @embedFile("corpus/tagged/cases.jsonl");
const recorded = @embedFile("corpus/tagged/answers.txt");

/// The class a recorded answer names, from the error this package names.
fn class(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingField => "MissingField",
        error.DuplicateField => "DuplicateField",
        error.UnknownVariant => "InvalidEnumTag",
        // The recorded answers say "invalid type" and "invalid value" alike
        // for a value of the wrong kind and for one out of its type's range.
        error.UnexpectedType, error.NumberOutOfRange => "UnexpectedToken",
        else => "Syntax",
    };
}

/// Lines the recorded answers read and this package refuses, by their place in
/// the cases: they read a union tagged inside its object from a JSON array as
/// well, the tag first and the fields after it in order. No writer writes one;
/// a record here is an object.
const arrays = [_]usize{ 33, 39, 40 };

/// What `U` makes of `line`, as a recorded answer says it: `ok` and the value
/// written, or `err` and the class. Members an arm does not have are passed
/// over, as the recorded reader passes them over.
fn answer(comptime U: type, a: std.mem.Allocator, line: []const u8, diagnosed: bool) ![]const u8 {
    var where: strand_module.core.Diagnostics = .{};
    const v = json.parseLeaky(U, a, line, .{ .ignore_unknown_fields = true, .diagnostics = if (diagnosed) &where else null }) catch |err|
        return a.print("err {s}", .{class(err)});
    var out: std.Io.Writer.Allocating = .init(a);
    try json.write(&out.writer, v, .{});
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
            for ([_]bool{ false, true }) |diagnosed| {
                const got = try answer(U, a, line, diagnosed);
                if (array) {
                    try testing.expectEqualStrings("err UnexpectedToken", got);
                } else {
                    testing.expectEqualStrings(want[which], got) catch |err| {
                        std.debug.print("case {d} {s}: {s}\n", .{ number, @typeName(U), line });
                        return err;
                    };
                }
            }
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
        var where: strand_module.core.Diagnostics = .{};
        const kept = try json.parseLeaky(Kept, a, line, .{ .diagnostics = if (diagnosed) &where else null });
        try testing.expectEqualStrings(line, kept.other.bytes);
        var out: std.Io.Writer.Allocating = .init(a);
        try json.write(&out.writer, kept, .{});
        try testing.expectEqualStrings(line, out.written());
    }
    // A record it knows is read as that arm, and a duplicate tag in one it
    // does not is still a duplicate.
    try testing.expectEqual(.ping, std.meta.activeTag(try json.parseLeaky(Kept, a, "{\"type\":\"ping\"}", .{})));
    try testing.expectError(error.DuplicateField, json.parseLeaky(Kept, a, "{\"type\":\"x\",\"type\":\"y\"}", .{}));
    try testing.expectError(error.DuplicateField, json.parseLeaky(Kept, a, "{\"a\":1,\"type\":\"x\",\"type\":\"y\"}", .{}));
    // Copied rather than borrowed when the result owns its storage.
    var copied = try json.parseOwned(Kept, testing.allocator, line, .{});
    defer copied.deinit();
    try testing.expect(copied.value.other.bytes.ptr != line.ptr);
}

test "unknown members of an arm follow ignore_unknown_fields, and the tag is not one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hi", (try json.parseLeaky(Closed, a, "{\"text\":\"hi\",\"type\":\"assistant\"}", .{})).assistant.text);
    try testing.expectError(error.UnknownField, json.parseLeaky(Closed, a, "{\"type\":\"ping\",\"extra\":1}", .{}));
    try testing.expectError(error.UnknownField, json.parseLeaky(Closed, a, "{\"extra\":1,\"type\":\"assistant\",\"text\":\"x\"}", .{}));
    try testing.expectEqualStrings("x", (try json.parseLeaky(Closed, a, "{\"extra\":1,\"type\":\"assistant\",\"text\":\"x\"}", .{ .ignore_unknown_fields = true })).assistant.text);
    // The catch-all takes a record it does not know as it is.
    try testing.expectEqual(.unknown, std.meta.activeTag(try json.parseLeaky(Open, a, "{\"type\":\"new\",\"extra\":1}", .{})));
    // A payload's own duplicate is refused.
    try testing.expectError(error.DuplicateField, json.parseLeaky(Closed, a, "{\"type\":\"assistant\",\"text\":\"a\",\"text\":\"b\"}", .{}));
}

test "a union tagged inside its object inside other values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Batch = struct { id: u32, messages: []const Closed, last: ?Closed = null };
    const line = "{\"id\":7,\"messages\":[{\"type\":\"ping\"},{\"text\":\"t\",\"type\":\"assistant\",\"n\":2}],\"last\":{\"type\":\"result\",\"ok\":true}}";
    const batch = try json.parseLeaky(Batch, a, line, .{});
    try testing.expectEqual(@as(usize, 2), batch.messages.len);
    try testing.expectEqual(@as(u64, 2), batch.messages[1].assistant.n);
    try testing.expect(batch.last.?.result.ok);

    var out: std.Io.Writer.Allocating = .init(a);
    try json.write(&out.writer, batch, .{});
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
        // A destination too small for a record and one with room write the
        // same bytes.
        for ([_]usize{ 4, 4096 }) |room| {
            var direct: std.Io.Writer.Allocating = try .initCapacity(a, room);
            var log: jsonl.Writer(Kept) = .init(&direct.writer, .{ .format = format });
            for (records) |record| try log.write(record);

            var source: std.Io.Reader = .fixed(direct.written());
            var reader: jsonl.Reader(Kept) = .init(a, &source, .{ .format = format });
            defer reader.deinit();
            for (records) |record| {
                const line = (try reader.next()).?;
                try testing.expectEqual(std.meta.activeTag(record), std.meta.activeTag(line.value));
            }
            try testing.expectEqual(@as(?jsonl.Line(Kept), null), try reader.next());
            if (format == .pretty) {
                try testing.expect(std.mem.find(u8, direct.written(), "{\n  \"type\": \"assistant\",\n  \"text\": ") != null);
            } else {
                try testing.expect(std.mem.startsWith(u8, direct.written(), "{\"type\":\"assistant\",\"text\":"));
            }
        }
    }
}

/// A field that writes and reads itself, inside an arm: seconds as `"9s"`.
pub const Stamp = struct {
    seconds: u32,
    pub fn strandSerialize(self: Stamp, access: anytype) @typeInfo(@TypeOf(access.write(@as([]const u8, "")))).error_union.error_set!void {
        var buffer: [16]u8 = undefined;
        const text = std.mem.print(&buffer, "{d}s", .{self.seconds}) catch unreachable; // unreachable: a u32 and a unit fit in sixteen bytes.
        try access.write(@as([]const u8, text));
    }
    pub fn strandDeserialize(access: anytype) @typeInfo(@TypeOf(access.read([]const u8))).error_union.error_set!Stamp {
        const text = try access.read([]const u8);
        if (text.len == 0 or text[text.len - 1] != 's') return access.reject(1);
        return .{ .seconds = std.fmt.parseInt(u32, text[0 .. text.len - 1], 10) catch return access.reject(2) };
    }
};

test "an arm holding a type with its own codec is written and read by it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Timed = union(enum) {
        tick: struct { at: Stamp },
        pub const strand = .{ .tag = "type" };
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try json.write(&out.writer, Timed{ .tick = .{ .at = .{ .seconds = 9 } } }, .{});
    try testing.expectEqualStrings("{\"type\":\"tick\",\"at\":\"9s\"}", out.written());
    const back = try json.parseLeaky(Timed, a, "{\"at\":\"12s\",\"type\":\"tick\"}", .{});
    try testing.expectEqual(@as(u32, 12), back.tick.at.seconds);
}

test "tagOf reads the arm from the tag member of a union tagged inside its object" {
    try testing.expectEqual(.assistant, json.tagOf(Closed, "{\"text\":\"x\",\"type\":\"assistant\"}").?);
    try testing.expectEqual(.ping, json.tagOf(Closed, "{\"type\":\"ping\"}").?);
    try testing.expectEqual(@as(?std.meta.Tag(Closed), null), json.tagOf(Closed, "{\"type\":\"nope\"}"));
    try testing.expectEqual(@as(?std.meta.Tag(Closed), null), json.tagOf(Closed, "{\"ping\":{}}"));
    try testing.expectEqual(.unknown, json.tagOf(Open, "{\"type\":\"nope\"}").?);
    try testing.expectEqual(@as(?std.meta.Tag(Open), null), json.tagOf(Open, "{\"type\":7}"));
}

test "memberOf peeks at a member wherever it is in the object" {
    const line = "{\"message\":{\"type\":\"inner\",\"content\":[{\"type\":\"text\"}]},\"session_id\":\"s-1\",\"type\":\"assistant\"}";
    try testing.expectEqualStrings("\"assistant\"", json.memberOf(line, "type").?);
    try testing.expectEqualStrings("assistant", json.memberStringOf(line, "type").?);
    try testing.expectEqualStrings("s-1", json.memberStringOf(line, "session_id").?);
    // The value is a view into the line.
    const at = std.mem.findLast(u8, line, "\"assistant\"").?;
    try testing.expect(json.memberOf(line, "type").?.ptr == line.ptr + at);
    // A structured member is not something to route on.
    try testing.expectEqual(@as(?[]const u8, null), json.memberOf(line, "message"));
    // A long string value has no bound: the line is in hand.
    const long = "{\"type\":\"" ++ @as([300]u8, @splat('x')) ++ "\"}";
    try testing.expectEqual(@as(usize, 302), json.memberOf(long, "type").?.len);
}
