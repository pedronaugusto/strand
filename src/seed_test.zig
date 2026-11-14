//! Seeds: decoding with state a type alone cannot carry. A seed reads one
//! value through its access and returns what it makes; the value it makes
//! is its own type's, and a nested value may be read by a seed of another
//! type, each carrying what its position needs.
const std = @import("std");
const strand = @import("strand.zig");
const testing = std.testing;

/// Counts the numbers in a document into `total`, by depth, and returns how
/// many values it read: the parent's seed and each child's differ in type.
const Tally = struct {
    numbers: *[4]usize,
    depth: usize,

    const Error = error{TooDeep};

    pub fn strandDeserializeSeed(self: Tally, access: anytype) (@TypeOf(access.*).Error || Error)!usize {
        if (self.depth >= self.numbers.len) return error.TooDeep;
        switch (try access.peek()) {
            .number => {
                _ = try access.number();
                self.numbers[self.depth] += 1;
                return 1;
            },
            .integer => {
                _ = try access.read(i64);
                self.numbers[self.depth] += 1;
                return 1;
            },
            .begin => |header| {
                var compound = try access.begin(header.kind);
                defer compound.abort();
                var read: usize = 1;
                while (try compound.hasNext()) {
                    if (header.kind == .map or header.kind == .record) {
                        // A member's value: read by a seed of another type,
                        // which makes a bool.
                        const key = try compound.key([]const u8);
                        const named: Named = .{ .tally = .{ .numbers = self.numbers, .depth = self.depth + 1 }, .key = key };
                        if (try compound.elementSeed(named)) read += 1;
                    } else {
                        read += try compound.elementSeed(Tally{ .numbers = self.numbers, .depth = self.depth + 1 });
                    }
                }
                try compound.finish();
                return read;
            },
            else => {
                _ = try access.read(strand.json.Value);
                return 1;
            },
        }
    }
};

/// A member's value, read for its tally and told its key: makes whether the
/// key was "n".
const Named = struct {
    tally: Tally,
    key: []const u8,

    pub fn strandDeserializeSeed(self: Named, access: anytype) (@TypeOf(access.*).Error || Tally.Error)!bool {
        _ = try self.tally.strandDeserializeSeed(access);
        return std.mem.eql(u8, self.key, "n");
    }
};

test "a seed makes its own type's value, and hands nested values seeds of other types" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    var numbers: [4]usize = @splat(0);
    const read = try strand.json.parseLeakySeeded(Tally{ .numbers = &numbers, .depth = 0 }, state.allocator(), "[1, [2, 3], {\"n\": 4, \"m\": [5]}, \"x\"]", .{});
    try testing.expectEqual(@as(usize, 8), read);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 1 }, &numbers);
    // The value made is the seed's own type.
    try testing.expect(@TypeOf(read) == usize);
    // Limits and syntax errors as any parse's; the seed's own errors too.
    try testing.expectError(error.SyntaxError, strand.json.parseLeakySeeded(Tally{ .numbers = &numbers, .depth = 0 }, state.allocator(), "[1,", .{}));
    try testing.expectError(error.TooDeep, strand.json.parseLeakySeeded(Tally{ .numbers = &numbers, .depth = 0 }, state.allocator(), "[[[[[1]]]]]", .{}));
}

test "every format reads with a seed" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var numbers: [4]usize = @splat(0);
    const seed: Tally = .{ .numbers = &numbers, .depth = 0 };
    const nested = "[1, [2, 3]]";
    try testing.expectEqual(@as(usize, 5), try strand.json.parseLeakySeeded(seed, a, nested, .{}));
    try testing.expectEqual(@as(usize, 5), try strand.json.jsonc.parseLeakySeeded(seed, a, "[1, [2, 3], ] // c", .{}));
    try testing.expectEqual(@as(usize, 5), try strand.json.json5.parseLeakySeeded(seed, a, "[1, [2, 3],]", .{}));
    try testing.expectEqual(@as(usize, 5), try strand.yaml.parseLeakySeeded(seed, a, nested, .{}));
    try testing.expectEqual(@as(usize, 5), try strand.zon.parseLeakySeeded(seed, a, ".{ 1, .{ 2, 3 } }", .{}));
    try testing.expect(try strand.toml.parseLeakySeeded(seed, a, "a = [1, [2, 3]]", .{}) > 0);
    try testing.expect(try strand.ini.parseLeakySeeded(seed, a, "[s]\nk = v\n", .{}) > 0);
    try testing.expect(try strand.dotenv.parseLeakySeeded(seed, a, "K=v\n", .{}) > 0);
    try testing.expect(try strand.urlencoded.parseLeakySeeded(seed, a, "a=1&b=2", .{}) > 0);
    try testing.expect(try strand.csv.parseLeakySeeded(seed, a, "a,b\n1,2\n", .{}) > 0);
    try testing.expect(try strand.xml.parseLeakySeeded(seed, a, "<r><a>1</a></r>", .{}) > 0);
    try testing.expect(try strand.cbor.parseLeakySeeded(seed, a, &.{ 0x82, 0x01, 0x82, 0x02, 0x03 }, .{}) > 0);
    try testing.expect(try strand.msgpack.parseLeakySeeded(seed, a, &.{ 0x92, 0x01, 0x92, 0x02, 0x03 }, .{}) > 0);
}
