const fixtures_module = @import("fixtures.zig");
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const strand = @import("../strand.zig");
const json = strand.json;
const jsonl = strand.jsonl;
const Fixture = fixtures_module.Fixture;

// A codec's result depends on state outside the JSON. Keeping the result
// must preserve the decision already made, even if that state changes.
pub const Stateful = struct {
    text: []const u8,
    count: u32,

    pub const jsonl_version: u32 = 2;
    var offset: u32 = 0;
    var calls: usize = 0;

    const Wire = struct { text: []const u8, count: u32 };

    pub fn strandDeserialize(access: anytype) @typeInfo(@TypeOf(access.read(Wire))).error_union.error_set!Stateful {
        calls += 1;
        const wire = try access.read(Wire);
        return .{ .text = wire.text, .count = wire.count + offset };
    }

    pub fn strandSerialize(self: Stateful, access: anytype) @typeInfo(@TypeOf(access.write(Wire{ .text = self.text, .count = self.count }))).error_union.error_set!void {
        try access.write(Wire{ .text = self.text, .count = self.count });
    }

    pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!Stateful {
        if (from != 1) return error.UnknownVariant;
        calls += 1;
        const wire = try payload.read(Wire);
        return .{ .text = wire.text, .count = wire.count + offset };
    }
};

const Direction = enum { reader, tail, follower };

fn keepParsed(comptime direction: Direction) !void {
    const T = jsonl.Versioned(Stateful);
    for ([_]u32{ 1, 2 }) |version| {
        Stateful.offset = 7;
        Stateful.calls = 0;
        var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer bytes.deinit();
        try bytes.writer.print("{{\"v\":{d},\"data\":{{\"text\":\"first\\tvalue\",\"count\":3}}}}\n", .{version});
        var fixture = try Fixture.init(bytes.written(), 8);
        defer fixture.deinit();

        var kept: strand.core.Parsed(T) = undefined;
        {
            var reader = switch (direction) {
                .reader => jsonl.Reader(T).init(testing.allocator, &fixture.reader.interface, .{}),
                .tail => try jsonl.Tail(T).init(testing.allocator, &fixture.reader, .{ .block_bytes = 4 }),
                .follower => jsonl.Follower(T).init(testing.allocator, &fixture.reader, .{}),
            };
            defer if (direction == .follower) reader.deinit(testing.io) else reader.deinit();
            var line = switch (direction) {
                .reader => (try reader.next()).?,
                .tail => (try reader.prev()).?,
                .follower => try reader.next(testing.io),
            };
            try testing.expectEqual(@as(u32, 10), line.value.value.count);
            try testing.expectEqual(@as(usize, 1), Stateful.calls);
            // An edit can point outside both the line and the parse arena.
            var edited = "edited\tvalue".*;
            line.value.value.text = &edited;
            line.value.value.count += 1;
            Stateful.offset = 1000;
            kept = try reader.keep(testing.allocator, line);
            errdefer kept.deinit();
            try testing.expectEqual(@as(usize, 1), Stateful.calls);
            try testing.expect(kept.value.value.text.ptr != line.value.value.text.ptr);
            @memset(&edited, 'x');
        }
        defer kept.deinit();
        try testing.expectEqualStrings("edited\tvalue", kept.value.value.text);
        try testing.expectEqual(@as(u32, 11), kept.value.value.count);
        try testing.expectEqual(version, kept.value.from);
        try testing.expectEqual(version == 1, kept.value.migrated());
    }
}

test "Reader keep preserves edits and stateful parsing and migration" {
    try keepParsed(.reader);
}

test "Tail keep preserves edits and stateful parsing and migration" {
    try keepParsed(.tail);
}

test "Follower keep preserves edits and stateful parsing and migration" {
    try keepParsed(.follower);
}

pub const LastData = struct {
    text: []const u8,
    fallback: []const u8 = "default",
    raw: json.Raw,
    dynamic: json.Value,
};

fn lastOwned(a: std.mem.Allocator) !void {
    var fixture = try Fixture.init(
        "{\"text\":\"fir\\u0073t\",\"raw\":{ \"n\": 1 },\"dynamic\":{\"key\":[\"one\"]}}\n" ++
            "{\"text\":\"later\",\"raw\":[ 2 ],\"dynamic\":{\"key\":[\"two\"]}}\n",
        8,
    );
    defer fixture.deinit();
    var batch: strand.core.Parsed([]LastData) = undefined;
    {
        var tail = try jsonl.Tail(LastData).init(testing.allocator, &fixture.reader, .{ .block_bytes = 4 });
        defer tail.deinit();
        batch = try tail.last(a, 3);
    }
    defer batch.deinit();
    try testing.expectEqual(@as(usize, 2), batch.value.len);
    try testing.expectEqualStrings("first", batch.value[0].text);
    try testing.expectEqualStrings("later", batch.value[1].text);
    try testing.expectEqualStrings("default", batch.value[0].fallback);
    try testing.expectEqualStrings("{ \"n\": 1 }", batch.value[0].raw.bytes);
    try testing.expectEqualStrings("[ 2 ]", batch.value[1].raw.bytes);
    try testing.expectEqualStrings("one", batch.value[0].dynamic.object[0].value.array[0].string);
    try testing.expectEqualStrings("two", batch.value[1].dynamic.object[0].value.array[0].string);
}

test "Tail last owns defaults, Raw and dynamic values" {
    try lastOwned(testing.allocator);
}

test "Tail last releases every partial owned batch on allocation failure" {
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), lastOwned, .{});
}

test "Tail last reports only NextError" {
    const result_type = @typeInfo(@TypeOf(jsonl.Tail(LastData).last)).@"fn".return_type.?;
    const error_set = @typeInfo(result_type).error_union.error_set;
    try testing.expect(error_set == jsonl.Tail(LastData).NextError);
}

test "Tail last releases owned values when a later line is malformed" {
    var fixture = try Fixture.init("broken\n{\"text\":\"later\",\"raw\":[2],\"dynamic\":{}}\n", 8);
    defer fixture.deinit();
    var tail = try jsonl.Tail(LastData).init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();
    try testing.expectError(error.MalformedLine, tail.last(testing.allocator, 2));
}
