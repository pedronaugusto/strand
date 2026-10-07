//! Raw codec scenarios through the public API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const strand = @import("strand.zig");
const Raw = strand.Raw;

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
    try testing.expect(mark.data.bytes.ptr == line.ptr + std.mem.find(u8, line, "{ ").?);

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

test "Raw.encode keeps hook failure distinct from allocation failure" {
    const Refusing = struct {
        pub const Self = @This();
        partial: bool,

        pub fn jsonStringify(self: Self, json: *std.json.Stringify) !void {
            if (self.partial) try json.write("part");
            return error.WriteFailed;
        }
    };
    for ([_]bool{ false, true }) |partial| {
        try testing.expectError(error.WriteFailed, Raw.encode(testing.allocator, Refusing{ .partial = partial }));
    }
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.WriteFailed, Raw.encode(failing.allocator(), Refusing{ .partial = false }));
    try testing.expectError(error.OutOfMemory, Raw.encode(failing.allocator(), Refusing{ .partial = true }));
}

test "Raw.encode releases storage when encoding or transfer runs out of memory" {
    const Hook = struct {
        pub const Self = @This();
        pub fn jsonStringify(_: Self, json: *std.json.Stringify) !void {
            try json.write(@as([2048]u8, @splat('x')));
        }
    };
    const Case = struct {
        fn run(allocator: Allocator, custom: bool) !void {
            const raw = if (custom) try Raw.encode(allocator, Hook{}) else try Raw.encode(allocator, @as([2048]u8, @splat('x')));
            defer allocator.free(raw.bytes);
            try testing.expectEqualStrings("\"" ++ @as([2048]u8, @splat('x')) ++ "\"", raw.bytes);
        }
    };
    for ([_]bool{ false, true }) |custom|
        try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{custom});

    // Refuse shrinking in place, then refuse the exact-length allocation.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    try testing.expectError(error.OutOfMemory, Raw.encode(failing.allocator(), true));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
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
