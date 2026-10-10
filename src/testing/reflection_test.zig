//! Every property of a type that strand reads by reflection, held to fixed
//! bytes and values: the writer, the parser, the owned and the caller-arena
//! entry points, and the checked copy. A change in how the compiler describes
//! a type shows here as a byte or a value, not as a quieter difference
//! somewhere else.
const std = @import("std");
const testing = std.testing;
const strand = @import("../strand.zig");
const json = strand.json;
const core = strand.core;

const Mode = enum(u8) { off, on };
const Hue = enum { red, green };
const Flags = packed struct(u8) { a: u3, b: bool, c: u4 };
const Arm = union(enum) { none, count: u64, name: []const u8 };

/// One field per reflected property.
const Shape = struct {
    id: u64,
    pair: struct { u8, []const u8 },
    mode: Mode,
    hue: Hue,
    flags: Flags,
    arm: Arm,
    empty: Arm,
    note: ?[]const u8 = null,
    text: [:0]const u8,
    level: u8 = 3,
};

const shape: Shape = .{
    .id = std.math.maxInt(u64),
    .pair = .{ 7, "x" },
    .mode = .on,
    .hue = .green,
    .flags = .{ .a = 5, .b = true, .c = 2 },
    .arm = .{ .count = 4 },
    .empty = .none,
    .text = "zed",
};

const golden =
    \\{"id":18446744073709551615,"pair":[7,"x"],"mode":"on","hue":"green",
++
    \\"flags":{"a":5,"b":true,"c":2},"arm":{"count":4},"empty":{"none":null},"text":"zed","level":3}
;

fn written(value: anytype, options: json.WriteOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try json.write(&aw.writer, value, options);
    return aw.toOwnedSlice();
}

test "a reflected shape is written to fixed bytes" {
    const bytes = try written(shape, .{ .nulls = .omit });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(golden, bytes);

    // A present optional is written; with nulls written, an absent one is null.
    var noted = shape;
    noted.note = "n";
    const with = try written(noted, .{ .nulls = .omit });
    defer testing.allocator.free(with);
    try testing.expect(std.mem.find(u8, with, "\"note\":\"n\"") != null);
    const nulled = try written(shape, .{});
    defer testing.allocator.free(nulled);
    try testing.expect(std.mem.find(u8, nulled, "\"note\":null") != null);
}

fn expectShape(actual: Shape) !void {
    try testing.expectEqual(shape.id, actual.id);
    try testing.expectEqual(shape.pair[0], actual.pair[0]);
    try testing.expectEqualStrings(shape.pair[1], actual.pair[1]);
    try testing.expectEqual(shape.mode, actual.mode);
    try testing.expectEqual(shape.hue, actual.hue);
    try testing.expectEqual(shape.flags, actual.flags);
    try testing.expectEqual(@as(u64, 4), actual.arm.count);
    try testing.expect(actual.empty == .none);
    try testing.expectEqual(@as(?[]const u8, null), actual.note);
    try testing.expectEqualStrings("zed", actual.text);
    try testing.expectEqual(@as(u8, 0), actual.text.ptr[actual.text.len]);
    try testing.expectEqual(@as(u8, 3), actual.level);
}

test "a reflected shape is read back by every entry point" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectShape(try json.parseLeaky(Shape, a, golden, .{}));

    var borrowed = try json.parse(Shape, testing.allocator, golden, .{});
    defer borrowed.deinit();
    try expectShape(borrowed.value);

    var owned = try json.parseOwned(Shape, testing.allocator, golden, .{});
    defer owned.deinit();
    try expectShape(owned.value);
}

test "a missing field takes its default, and a missing required field is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Defaults = struct { id: u64, level: u8 = 3, label: []const u8 = "none", note: ?u8 = null };

    const read = try json.parseLeaky(Defaults, a, "{\"id\":1}", .{});
    try testing.expectEqual(@as(u8, 3), read.level);
    try testing.expectEqualStrings("none", read.label);
    try testing.expectEqual(@as(?u8, null), read.note);
    try testing.expectError(error.MissingField, json.parseLeaky(Defaults, a, "{\"level\":1}", .{}));
}

test "enum names: an exhaustive enum is read by name, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Mode.on, try json.parseLeaky(Mode, a, "\"on\"", .{}));
    try testing.expectError(error.UnknownVariant, json.parseLeaky(Mode, a, "\"dim\"", .{}));
    try testing.expectError(error.UnexpectedType, json.parseLeaky(Hue, a, "1", .{}));

    const bytes = try written(Mode.off, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"off\"", bytes);
}

test "pointer qualifiers decide what the decoder allocates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"c\":\"abc\",\"m\":\"def\",\"z\":\"ghi\",\"one\":5,\"many\":\"jk\"}";
    const Pointers = struct { c: []const u8, m: []u8, z: [:0]const u8, one: *const u16, many: [:0]const u8 = "" };
    const read = try json.parseLeaky(Pointers, a, line, .{});
    // A const string borrows the line; a mutable one cannot, and a
    // sentinel-terminated one needs its terminator after it.
    try testing.expect(read.c.ptr == line.ptr + 6);
    try testing.expect(read.m.ptr != line.ptr + 18);
    read.m[0] = 'D';
    try testing.expectEqualStrings("Def", read.m);
    try testing.expectEqualStrings("ghi", read.z);
    try testing.expectEqual(@as(u8, 0), read.z.ptr[read.z.len]);
    try testing.expectEqual(@as(u16, 5), read.one.*);
    try testing.expectEqualStrings("jk", read.many);
    try testing.expectEqual(@as(u8, 0), read.many.ptr[read.many.len]);

    const Out = struct { many: [:0]const u8, one: *const u8, array: *const [2]u16 };
    const bytes = try written(Out{ .many = "ptr", .one = &@as(u8, 4), .array = &[2]u16{ 1, 2 } }, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"many\":\"ptr\",\"one\":4,\"array\":[1,2]}", bytes);
}

test "the checked copy follows every reflected field and keeps alignment and sentinels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try json.parseLeaky(Shape, arena.allocator(), golden, .{});
    var copy = try core.clone(testing.allocator, parsed, .{});
    defer copy.deinit();
    arena.deinit();
    arena = .init(testing.allocator);
    try expectShape(copy.value);

    const Aligned = struct { bytes: []align(16) const u8, pair: struct { []const u8, u8 } };
    const source: [32]u8 align(16) = @splat(7);
    var aligned = try core.clone(testing.allocator, Aligned{ .bytes = &source, .pair = .{ "p", 2 } }, .{});
    defer aligned.deinit();
    try testing.expect(std.mem.isAligned(@intFromPtr(aligned.value.bytes.ptr), 16));
    try testing.expect(aligned.value.bytes.ptr != &source);
    try testing.expectEqualSlices(u8, &source, aligned.value.bytes);
    try testing.expectEqualStrings("p", aligned.value.pair[0]);
}

test "a union's tag member and catch-all arm are read from its declaration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Message = union(enum) {
        ping: struct { at: u64 },
        other: json.Raw,
        pub const strand = .{ .tag = "type", .other = "other" };
    };
    const read = try json.parseLeaky(Message, a, "{\"type\":\"ping\",\"at\":3}", .{});
    try testing.expectEqual(@as(u64, 3), read.ping.at);
    const kept = try json.parseLeaky(Message, a, "{\"type\":\"pong\",\"at\":3}", .{});
    try testing.expectEqualStrings("{\"type\":\"pong\",\"at\":3}", kept.other.bytes);

    const bytes = try written(Message{ .ping = .{ .at = 3 } }, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"type\":\"ping\",\"at\":3}", bytes);
    try testing.expectEqual(.ping, json.tagOf(Message, "{\"type\":\"ping\",\"at\":3}").?);
}
