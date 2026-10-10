//! Every property of a type that strand reads by reflection, held to fixed
//! bytes on every path that reads it: the streaming and the buffered
//! encoders, the direct decoder, the token decoder, conversion from a
//! `std.json.Value`, and the owned copy. A change in how the compiler
//! describes a type shows here as a byte or a value, not as a quieter
//! difference somewhere else.
const std = @import("std");
const testing = std.testing;
const strand = @import("../strand.zig");
const codec = @import("../json/api.zig").codec_module;

/// A non-exhaustive enum: a named value is written by name, any other by
/// number, and both are read back.
const Mode = enum(u8) { off, on, _ };
const Hue = enum { red, green };
const Flags = packed struct(u8) { a: u3, b: bool, c: u4 };
const Arm = union(enum) { none, count: u64, name: []const u8 };

/// One field per reflected property. `id` is wide enough that conversion
/// from a value walks the struct itself rather than leaving it to std.json.
const Shape = struct {
    id: u64,
    pair: struct { u8, []const u8 },
    mode: Mode,
    raw_mode: Mode,
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
    .raw_mode = @fromBackingInt(@intCast(9)),
    .hue = .green,
    .flags = .{ .a = 5, .b = true, .c = 2 },
    .arm = .{ .count = 4 },
    .empty = .none,
    .text = "zed",
};

const golden =
    \\{"id":18446744073709551615,"pair":[7,"x"],"mode":"on","raw_mode":9,"hue":"green",
++
    \\"flags":{"a":5,"b":true,"c":2},"arm":{"count":4},"empty":{"none":{}},"text":"zed","level":3}
;

test "reflected shapes are written to the same bytes by every encoder" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try strand.writeLine(&aw.writer, shape);
    try testing.expectEqualStrings(golden ++ "\n", aw.written());

    // The buffered encoder, which runs whenever the destination has room.
    var buffer: [512]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try strand.writeValue(&fixed, shape, .{});
    try testing.expectEqualStrings(golden, fixed.buffered());

    // The streaming encoder, straight.
    aw.clearRetainingCapacity();
    try codec.encode.value(shape, .{ .emit_null_optional_fields = false }, &aw.writer);
    try testing.expectEqualStrings(golden, aw.written());

    // A present optional is written; with nulls emitted, an absent one is
    // written as null.
    var noted = shape;
    noted.note = "n";
    fixed = .fixed(&buffer);
    try strand.writeValue(&fixed, noted, .{});
    try testing.expect(std.mem.find(u8, fixed.buffered(), "\"note\":\"n\"") != null);
    fixed = .fixed(&buffer);
    try strand.writeValue(&fixed, shape, .{ .emit_null_optional_fields = true });
    try testing.expect(std.mem.find(u8, fixed.buffered(), "\"note\":null") != null);
}

fn expectShape(actual: Shape) !void {
    try testing.expectEqual(shape.id, actual.id);
    try testing.expectEqual(shape.pair[0], actual.pair[0]);
    try testing.expectEqualStrings(shape.pair[1], actual.pair[1]);
    try testing.expectEqual(shape.mode, actual.mode);
    try testing.expectEqual(shape.raw_mode, actual.raw_mode);
    try testing.expectEqual(shape.hue, actual.hue);
    try testing.expectEqual(shape.flags, actual.flags);
    try testing.expectEqual(@as(u64, 4), actual.arm.count);
    try testing.expect(actual.empty == .none);
    try testing.expectEqual(@as(?[]const u8, null), actual.note);
    try testing.expectEqualStrings("zed", actual.text);
    try testing.expectEqual(@as(u8, 0), actual.text.ptr[actual.text.len]);
    try testing.expectEqual(@as(u8, 3), actual.level);
}

test "reflected shapes are read back by every decoder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectShape(try strand.parseLine(Shape, a, golden, .{}));
    try expectShape(try strand.parseLine(Shape, a, golden, .{ .copy_strings = true }));

    var scanner: std.json.Scanner = .initCompleteInput(a, golden);
    try expectShape(try strand.innerParse(Shape, a, &scanner, .{ .max_value_len = golden.len, .allocate = .alloc_always }));

    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, golden, .{});
    try expectShape(try strand.payloadOf(Shape, a, value));
}

test "a missing field takes its default, and a missing required field is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Defaults = struct { id: u64, level: u8 = 3, label: []const u8 = "none", note: ?u8 = null };

    const read = try strand.parseLine(Defaults, a, "{\"id\":1}", .{});
    try testing.expectEqual(@as(u8, 3), read.level);
    try testing.expectEqualStrings("none", read.label);
    try testing.expectEqual(@as(?u8, null), read.note);
    try testing.expectError(error.MissingField, strand.parseLine(Defaults, a, "{\"level\":1}", .{}));

    var scanner: std.json.Scanner = .initCompleteInput(a, "{\"id\":1}");
    const token = try strand.innerParse(Defaults, a, &scanner, .{ .max_value_len = 8 });
    try testing.expectEqual(@as(u8, 3), token.level);

    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":1}", .{});
    const converted = try strand.payloadOf(Defaults, a, value);
    try testing.expectEqual(@as(u8, 3), converted.level);
    try testing.expectEqualStrings("none", converted.label);
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"level\":1}", .{});
    try testing.expectError(error.MissingField, strand.payloadOf(Defaults, a, missing));
}

test "enum tags: an exhaustive enum refuses a number, a non-exhaustive one keeps it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(Mode, @fromBackingInt(@intCast(200))), try strand.parseLine(Mode, a, "200", .{}));
    try testing.expectEqual(Mode.off, try strand.parseLine(Mode, a, "0", .{}));
    try testing.expectEqual(Mode.on, try strand.parseLine(Mode, a, "\"on\"", .{}));
    try testing.expectError(error.InvalidEnumTag, strand.parseLine(Mode, a, "\"dim\"", .{}));
    try testing.expectError(error.InvalidEnumTag, strand.parseLine(Mode, a, "256", .{}));
    try testing.expectError(error.InvalidEnumTag, strand.parseLine(Hue, a, "\"blue\"", .{}));
    try testing.expectEqual(Hue.green, try strand.parseLine(Hue, a, "1", .{}));
    try testing.expectError(error.InvalidEnumTag, strand.parseLine(Hue, a, "2", .{}));

    var buffer: [16]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try strand.writeValue(&fixed, @as(Mode, @fromBackingInt(@intCast(200))), .{});
    try testing.expectEqualStrings("200", fixed.buffered());
    fixed = .fixed(&buffer);
    try strand.writeValue(&fixed, Mode.off, .{});
    try testing.expectEqualStrings("\"off\"", fixed.buffered());
}

test "pointer qualifiers decide what the decoder allocates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"c\":\"abc\",\"m\":\"def\",\"z\":\"ghi\",\"one\":5,\"many\":[1,2]}";
    const Pointers = struct { c: []const u8, m: []u8, z: [:0]const u8, one: *const u16, many: [:0]const u8 = "" };
    const read = try strand.parseLine(Pointers, a, line, .{});
    // A const string borrows the line; a mutable one cannot, and a
    // sentinel-terminated one needs its terminator after it.
    try testing.expect(read.c.ptr == line.ptr + 6);
    try testing.expect(read.m.ptr != line.ptr + 18);
    read.m[0] = 'D';
    try testing.expectEqualStrings("Def", read.m);
    try testing.expectEqualStrings("ghi", read.z);
    try testing.expectEqual(@as(u8, 0), read.z.ptr[read.z.len]);
    try testing.expectEqual(@as(u16, 5), read.one.*);
    try testing.expectEqualStrings(&.{ 1, 2 }, read.many);
    try testing.expectEqual(@as(u8, 0), read.many.ptr[read.many.len]);

    var buffer: [128]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    const many: [*:0]const u8 = "ptr";
    try strand.writeValue(&fixed, .{ .many = many, .one = &@as(u8, 4), .array = &[2]u16{ 1, 2 } }, .{});
    try testing.expectEqualStrings("{\"many\":\"ptr\",\"one\":4,\"array\":[1,2]}", fixed.buffered());
}

test "the owned copy follows every reflected field and keeps alignment and sentinels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try strand.parseLine(Shape, arena.allocator(), golden, .{});
    const copy = try strand.copyOwned(testing.allocator, parsed);
    defer strand.freeOwned(testing.allocator, copy);
    arena.deinit();
    arena = .init(testing.allocator);
    try expectShape(copy);

    const Aligned = struct { bytes: []align(16) const u8, pair: struct { []const u8, u8 }, comptime fixed: u8 = 1 };
    const source: [32]u8 align(16) = @splat(7);
    const aligned = try strand.copyOwned(testing.allocator, Aligned{ .bytes = &source, .pair = .{ "p", 2 } });
    defer strand.freeOwned(testing.allocator, aligned);
    try testing.expect(std.mem.isAligned(@intFromPtr(aligned.bytes.ptr), 16));
    try testing.expect(aligned.bytes.ptr != &source);
    try testing.expectEqualSlices(u8, &source, aligned.bytes);
    try testing.expectEqualStrings("p", aligned.pair[0]);
}

test "a union's tag member and catch-all arm are read from its public declarations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Message = union(enum) {
        ping: struct { at: u64 },
        other: strand.Raw,
        pub const jsonl_tag = "type";
        pub const jsonl_other = .other;
    };
    const read = try strand.parseLine(Message, a, "{\"type\":\"ping\",\"at\":3}", .{});
    try testing.expectEqual(@as(u64, 3), read.ping.at);
    const kept = try strand.parseLine(Message, a, "{\"type\":\"pong\",\"at\":3}", .{});
    try testing.expectEqualStrings("{\"type\":\"pong\",\"at\":3}", kept.other.bytes);

    var buffer: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try strand.writeValue(&fixed, Message{ .ping = .{ .at = 3 } }, .{});
    try testing.expectEqualStrings("{\"type\":\"ping\",\"at\":3}", fixed.buffered());
}
