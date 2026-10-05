const std = @import("std");
const testing = std.testing;
const strand = @import("../strand.zig");
const Fixture = @import("fixtures.zig").Fixture;

// A hook's output depends on state outside the JSON. Keeping the result
// must preserve the decision already made, even if that state changes.
pub const Stateful = struct {
    text: []const u8,
    count: u32,

    pub const jsonl_version: u32 = 2;
    var offset: u32 = 0;
    var calls: usize = 0;

    const Wire = struct { text: []const u8, count: u32 };

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Stateful {
        calls += 1;
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        return .{ .text = wire.text, .count = wire.count + offset };
    }

    pub fn jsonlMigrate(allocator: std.mem.Allocator, from: u32, data: std.json.Value) std.json.ParseFromValueError!Stateful {
        if (from != 1) return error.UnknownField;
        calls += 1;
        const wire = try strand.payloadOf(Wire, allocator, data);
        return .{ .text = wire.text, .count = wire.count + offset };
    }
};

const Direction = enum { reader, tail, follower };

fn keepParsed(comptime direction: Direction) !void {
    const T = strand.Versioned(Stateful);
    for ([_]u32{ 1, 2 }) |version| {
        Stateful.offset = 7;
        Stateful.calls = 0;
        var bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer bytes.deinit();
        try bytes.writer.print("{{\"v\":{d},\"data\":{{\"text\":\"first\\tvalue\",\"count\":3}}}}\n", .{version});
        var fixture = try Fixture.init(bytes.written(), 8);
        defer fixture.deinit();

        var kept: T = undefined;
        {
            var reader = switch (direction) {
                .reader => strand.Reader(T).init(testing.allocator, &fixture.reader.interface, .{}),
                .tail => try strand.Tail(T).init(testing.allocator, &fixture.reader, .{ .block_bytes = 4 }),
                .follower => strand.Follower(T).init(testing.allocator, testing.io, &fixture.reader, .{}),
            };
            defer reader.deinit();
            var line = switch (direction) {
                .reader => (try reader.next()).?,
                .tail => (try reader.prev()).?,
                .follower => try reader.next(),
            };
            try testing.expectEqual(@as(u32, 10), line.value.value.count);
            try testing.expectEqual(@as(usize, 1), Stateful.calls);
            // An edit can point outside both the line and the parse arena.
            var edited = "edited\tvalue".*;
            line.value.value.text = &edited;
            line.value.value.count += 1;
            Stateful.offset = 1000;
            const result: std.mem.Allocator.Error!T = reader.keep(testing.allocator, line);
            kept = try result;
            errdefer strand.freeOwned(testing.allocator, kept);
            try testing.expectEqual(@as(usize, 1), Stateful.calls);
            try testing.expect(kept.value.text.ptr != line.value.value.text.ptr);
            @memset(&edited, 'x');
        }
        defer strand.freeOwned(testing.allocator, kept);
        try testing.expectEqualStrings("edited\tvalue", kept.value.text);
        try testing.expectEqual(@as(u32, 11), kept.value.count);
        try testing.expectEqual(version, kept.from);
        try testing.expectEqual(version == 1, kept.migrated());
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
    raw: strand.Raw,
    dynamic: std.json.Value,

    var shared: [5]u8 = undefined;
    var calls: usize = 0;

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !LastData {
        calls += 1;
        const wire = try std.json.innerParse(struct { text: [5]u8, raw: strand.Raw, dynamic: std.json.Value }, a, source, options);
        shared = wire.text;
        return .{ .text = &shared, .raw = wire.raw, .dynamic = wire.dynamic };
    }
};

fn lastOwned(a: std.mem.Allocator) !void {
    LastData.calls = 0;
    var fixture = try Fixture.init(
        "{\"text\":\"first\",\"raw\":{ \"n\": 1 },\"dynamic\":{\"key\":[\"one\"]}}\n" ++
            "{\"text\":\"later\",\"raw\":[ 2 ],\"dynamic\":{\"key\":[\"two\"]}}\n",
        8,
    );
    defer fixture.deinit();
    var batch: []LastData = undefined;
    {
        var tail = try strand.Tail(LastData).init(testing.allocator, &fixture.reader, .{ .block_bytes = 4 });
        defer tail.deinit();
        batch = try tail.last(a, 3);
    }
    defer {
        for (batch) |value| strand.freeOwned(a, value);
        a.free(batch);
    }
    try testing.expectEqual(@as(usize, 2), LastData.calls);
    try testing.expectEqual(@as(usize, 2), batch.len);
    try testing.expect(batch[0].text.ptr != &LastData.shared);
    try testing.expect(batch[0].fallback.ptr != @as([]const u8, "default").ptr);
    @memset(&LastData.shared, 'x');
    try testing.expectEqualStrings("first", batch[0].text);
    try testing.expectEqualStrings("later", batch[1].text);
    try testing.expectEqualStrings("default", batch[0].fallback);
    try testing.expectEqualStrings("{ \"n\": 1 }", batch[0].raw.bytes);
    try testing.expectEqualStrings("[ 2 ]", batch[1].raw.bytes);
    try testing.expectEqualStrings("one", batch[0].dynamic.object.get("key").?.array.items[0].string);
    try testing.expectEqualStrings("two", batch[1].dynamic.object.get("key").?.array.items[0].string);
}

test "Tail last owns hook references defaults Raw and dynamic values" {
    try lastOwned(testing.allocator);
}

test "Tail last releases every partial owned batch on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, lastOwned, .{});
}

test "Tail last reports only NextError" {
    const Result = @typeInfo(@TypeOf(strand.Tail(LastData).last)).@"fn".return_type.?;
    const Errors = @typeInfo(Result).error_union.error_set;
    try testing.expect(Errors == strand.Tail(LastData).NextError);
}

test "Tail last releases owned values when a later line is malformed" {
    var fixture = try Fixture.init("broken\n{\"text\":\"later\",\"raw\":[2],\"dynamic\":{}}\n", 8);
    defer fixture.deinit();
    var tail = try strand.Tail(LastData).init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();
    try testing.expectError(error.MalformedLine, tail.last(testing.allocator, 2));
}
