//! Shapes a value takes on its way through JSON and back: vectors of every
//! element kind and width, in every container, through every path a record
//! takes; and brackets that close the wrong kind of container.
const std = @import("std");
const testing = std.testing;
const strand = @import("strand.zig");
const json = strand.json;
const jsonl = strand.jsonl;
const fixtures = @import("testing/fixtures.zig");

test "a bracket that closes the other kind of container is refused, whatever reads it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A `Raw` member is checked by passing over it, where an array closed by
    // `}` could be taken for the end of an object.
    const Carrying = struct { data: json.Raw = .{ .bytes = "null" }, more: []const json.Raw = &.{} };
    for ([_][]const u8{
        "{\"more\":[1}",
        "{\"more\":[1,2}}",
        "{\"more\":[{\"a\":1]]}",
        "{\"data\":1]",
        "{\"data\":[1}}",
        "[1}",
        "{\"a\":1]",
    }) |line| {
        // A line that is not a record at all is refused as that first.
        try testing.expect(std.meta.isError(json.parseLeaky(Carrying, a, line, .{ .ignore_unknown_fields = true })));
        try testing.expectError(error.SyntaxError, json.parseLeaky(json.Value, a, line, .{}));
        try testing.expectError(error.SyntaxError, json.parseLeaky(json.Raw, a, line, .{}));
    }
}

/// `expected` written by `json.write`, and read back by `json.parseLeaky`,
/// a `Reader`, a `.pretty` `Reader`, a `Tail`, its `last`, a `Follower` and
/// both orders of a `Versioned` envelope: the same value every time.
fn expectRoundTrip(expected: anytype) !void {
    const T = @TypeOf(expected);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var encoded: std.Io.Writer.Allocating = .init(a);
    try json.write(&encoded.writer, expected, .{});
    const bytes = encoded.written();
    try testing.expectEqualDeep(expected, try json.parseLeaky(T, a, bytes, .{}));

    inline for (.{ jsonl.Format.minified, jsonl.Format.pretty }) |format| {
        var out: std.Io.Writer.Allocating = .init(a);
        var writer: jsonl.Writer(T) = .init(&out.writer, .{ .format = format });
        try writer.write(expected);
        var input: std.Io.Reader = .fixed(out.written());
        var reader: jsonl.Reader(T) = .init(testing.allocator, &input, .{ .format = format });
        defer reader.deinit();
        try testing.expectEqualDeep(expected, (try reader.next()).?.value);
        try testing.expectEqual(null, try reader.next());
    }

    const Payload = struct {
        item: T,
        pub const jsonl_version: u32 = 2;
        pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!@This() {
            if (from != 1) return error.UnknownVariant;
            return payload.read(@This());
        }
    };
    // The payload read straight into its type, held until the version comes,
    // and migrated: the same value through each.
    for ([_][]const u8{
        try a.print("{{\"v\":2,\"data\":{{\"item\":{s}}}}}", .{bytes}),
        try a.print("{{\"data\":{{\"item\":{s}}},\"v\":2}}", .{bytes}),
        try a.print("{{\"v\":1,\"data\":{{\"item\":{s}}}}}", .{bytes}),
    }) |envelope| {
        try testing.expectEqualDeep(expected, (try json.parseLeaky(jsonl.Versioned(Payload), a, envelope, .{})).value.item);
    }

    const framed = try std.mem.concat(a, u8, &.{ bytes, "\n" });
    var fixture = try fixtures.Fixture.init(framed, 1);
    defer fixture.deinit();
    var tail: jsonl.Tail(T) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = 1 });
    defer tail.deinit();
    try testing.expectEqualDeep(expected, (try tail.prev()).?.value);
    var batch_tail: jsonl.Tail(T) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = 1 });
    defer batch_tail.deinit();
    var batch = try batch_tail.last(testing.allocator, 1);
    defer batch.deinit();
    try testing.expectEqualDeep(expected, batch.value[0]);
    try fixture.reader.seekTo(0);
    var follower: jsonl.Follower(T) = .init(testing.allocator, &fixture.reader, .{});
    defer follower.deinit(testing.io);
    try testing.expectEqualDeep(expected, (try follower.next(testing.io)).value);
}

test "a vector of any element round trips through every path a record takes" {
    const number: u32 = 42;
    inline for (.{
        @as(@Vector(1, u8), .{0}),
        @as(@Vector(3, u8), .{ 'a', 'b', 'c' }),
        @as(@Vector(3, u8), .{ 0xff, 0x80, 0xc3 }),
        @as(@Vector(3, bool), .{ true, false, true }),
        @as(@Vector(3, u0), .{ 0, 0, 0 }),
        @as(@Vector(3, i1), .{ -1, 0, -1 }),
        @as(@Vector(3, u3), .{ 0, 2, 7 }),
        @as(@Vector(3, i3), .{ -4, 0, 3 }),
        @as(@Vector(3, u64), .{ 0, 1 << 63, std.math.maxInt(u64) }),
        @as(@Vector(3, i64), .{ std.math.minInt(i64), 0, std.math.maxInt(i64) }),
        @as(@Vector(3, u128), .{ 0, 1 << 127, std.math.maxInt(u128) }),
        @as(@Vector(3, i128), .{ std.math.minInt(i128), 0, std.math.maxInt(i128) }),
        @as(@Vector(3, f16), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, f32), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, f64), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, *const u32), .{ &number, &number, &number }),
    }) |vector| {
        try expectRoundTrip(vector);
        const V = @TypeOf(vector);
        const Containers = struct {
            optional: ?V,
            pointer: *const V,
            array: [2]V,
            slice: []const V,
            tuple: struct { V, bool },
            arm: union(enum) { vector: V, empty },
        };
        // Built from a runtime copy: Zig 0.17.0 miscompiles a comptime-known
        // struct whose `?@Vector(n, u64)` member (32 bytes or more) comes
        // before a pointer, and the pointer reads back as part of the vector.
        var runtime_vector = vector;
        _ = &runtime_vector;
        try expectRoundTrip(Containers{
            .optional = runtime_vector,
            .pointer = &vector,
            .array = .{ vector, vector },
            .slice = &.{ vector, vector },
            .tuple = .{ vector, true },
            .arm = .{ .vector = vector },
        });
    }
}

test "a vector with no lanes, and byte vectors of every width, round trip" {
    try expectRoundTrip(@as(@Vector(0, u8), .{}));
    try expectRoundTrip(@as(@Vector(0, bool), .{}));
    inline for (.{ 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33 }) |n| {
        try expectRoundTrip(@as(@Vector(n, u8), @splat('a')));
        try expectRoundTrip(@as(@Vector(n, u8), @splat(0xff)));
    }
}

test "a vector holds exactly its lanes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        .{ @Vector(3, u8), "[1,2]" },
        .{ @Vector(3, u8), "[1,2,3,4]" },
        .{ @Vector(3, u3), "[1,2,8]" },
        .{ @Vector(3, bool), "\"abc\"" },
        .{ @Vector(3, u8), "{}" },
        .{ @Vector(3, u8), "null" },
    }) |case| {
        try testing.expect(std.meta.isError(json.parseLeaky(case[0], a, case[1], .{})));
    }
}

test "a raw value is written as one checked line, escapes and all, with no scratch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Carrying = struct { data: json.Raw };
    // An escaped string and an escaped key are checked without being
    // unescaped anywhere, and a line break between two tokens is a space.
    var out: std.Io.Writer.Allocating = .init(a);
    var writer: jsonl.Writer(Carrying) = .init(&out.writer, .{});
    try writer.write(.{ .data = .{ .bytes = "{\"k\\u0069nd\":\"a\\nb\",\r\n\"x\" :\n[1]}" } });
    try testing.expectEqualStrings("{\"data\":{\"k\\u0069nd\":\"a\\nb\",  \"x\" : [1]}}\n", out.written());
    // A key repeated under another spelling is still repeated.
    try testing.expectError(error.InvalidRaw, json.write(&out.writer, Carrying{ .data = .{ .bytes = "{\"kind\":1,\"k\\u0069nd\":2}" } }, .{}));
}

test "a catch-all arm holding the record as read writes it back as it was" {
    const Message = union(enum) {
        open: struct { at: u64 },
        other: json.Raw,
        pub const strand = .{ .tag = "kind", .other = "other" };
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"at\":1,\"kind\":\"new\",\"why\":[true]}";
    const message = try json.parseLeaky(Message, a, line, .{});
    try testing.expectEqualStrings(line, message.other.bytes);
    var out: std.Io.Writer.Allocating = .init(a);
    try json.write(&out.writer, message, .{});
    try testing.expectEqualStrings(line, out.written());
}

test "an integer narrower than a digit reads any spelling of its values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Narrow = struct { one: u1, three: i3 };
    const value = try json.parseLeaky(Narrow, a, "{\"one\":1e0,\"three\":-0.4e1}", .{});
    try testing.expectEqual(@as(u1, 1), value.one);
    try testing.expectEqual(@as(i3, -4), value.three);
    try testing.expectError(error.NumberOutOfRange, json.parseLeaky(Narrow, a, "{\"one\":2e0,\"three\":0}", .{}));
}
