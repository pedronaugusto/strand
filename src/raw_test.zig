//! A JSON value kept as its bytes, through the public API.
const std = @import("std");
const strand = @import("strand.zig");
const json = strand.json;
const jsonl = strand.jsonl;
const Raw = json.Raw;
const testing = std.testing;

test Raw {
    const Mark = struct {
        kind: []const u8,
        data: Raw = .{ .bytes = "null" },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = "{\"kind\":\"beat\",\"data\":{ \"who\" : \"ada\", \"n\": [1, 2.50] }}";
    const mark = try json.parseLeaky(Mark, a, line, .{});
    // The value's own bytes, spacing and all, borrowed from the line.
    try testing.expectEqualStrings("{ \"who\" : \"ada\", \"n\": [1, 2.50] }", mark.data.bytes);
    try testing.expect(mark.data.bytes.ptr == line.ptr + std.mem.find(u8, line, "{ ").?);

    // Decoded when it is wanted, as whatever it is wanted as.
    const Data = struct { who: []const u8, n: []const f64 };
    const data = try json.parseLeaky(Data, a, mark.data.bytes, .{});
    try testing.expectEqualStrings("ada", data.who);
    try testing.expectEqual(@as(f64, 2.5), data.n[1]);

    // Written back as it came.
    var out: std.Io.Writer.Allocating = .init(a);
    try json.write(&out.writer, mark, .{});
    try testing.expectEqualStrings(line, out.written());

    // Absent, it is its default: JSON null.
    const bare = try json.parseLeaky(Mark, a, "{\"kind\":\"beat\"}", .{});
    try testing.expectEqualStrings("null", bare.data.bytes);
}

test "parsing a Raw is the constructor that checks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("[1, 2]", (try json.parseLeaky(Raw, a, "  [1, 2]\t", .{})).bytes);
    try testing.expectEqualStrings("\"x\"", (try json.parseLeaky(Raw, a, "\"x\"", .{})).bytes);
    try testing.expectError(error.SyntaxError, json.parseLeaky(Raw, a, "[1, 2", .{}));
    try testing.expectError(error.SyntaxError, json.parseLeaky(Raw, a, "[1] 2", .{}));
    try testing.expectError(error.SyntaxError, json.parseLeaky(Raw, a, "", .{}));
    // Owned parsing copies it with the rest.
    const line = "{\"data\":[1]}";
    var owned = try json.parseOwned(struct { data: Raw }, testing.allocator, line, .{});
    defer owned.deinit();
    try testing.expect(owned.value.data.bytes.ptr != line.ptr + 8);
    try testing.expectEqualStrings("[1]", owned.value.data.bytes);
}

test "a Raw made by hand is checked when it is written" {
    const Mark = struct { data: Raw };
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidRaw, json.write(&out, Mark{ .data = .{ .bytes = "[1," } }, .{}));
    try testing.expectError(error.InvalidRaw, json.write(&out, Mark{ .data = .{ .bytes = "1 2" } }, .{}));
}

test "a Raw is written on one line whatever line breaks it holds" {
    const Mark = struct { data: Raw };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var log: jsonl.Writer(Mark) = .init(&out.writer, .{});
    try log.write(.{ .data = .{ .bytes = "[1,\n2,\r\n3]" } });
    try testing.expectEqualStrings("{\"data\":[1, 2,  3]}\n", out.written());
    var source: std.Io.Reader = .fixed(out.written());
    var reader: jsonl.Reader(Mark) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqualStrings("[1, 2,  3]", (try reader.next()).?.value.data.bytes);
    try testing.expectEqual(@as(?jsonl.Line(Mark), null), try reader.next());
}
