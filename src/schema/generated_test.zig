//! The schemas strand generates (`json.schema.of`) against strand_schema:
//! every value strand writes for a type is valid against the schema of what
//! it writes and of what it reads, and on documents mutated from those, the
//! schema of what it reads accepts exactly what `json.parseLeaky` reads.
const std = @import("std");
const strand = @import("strand");
const shakedown = @import("shakedown");
const Schema = @import("Schema.zig");

const json = strand.json;
const testing = std.testing;

const Search = struct {
    query: []const u8,
    limit: u8 = 10,
    language: ?enum { zig, rust, go } = null,
    tags: []const []const u8 = &.{},
};
const Shape = union(enum) { circle: struct { r: f64 }, square: struct { side: u32 }, none };
const Tree = struct { name: []const u8, children: []const Tree = &.{} };
const Mixed = struct { flag: bool, n: ?i32, pair: [2]f64, small: i8 };

fn property(comptime T: type) fn (void, *shakedown.Case) anyerror!void {
    return struct {
        fn body(_: void, c: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var encode = try Schema.compile(testing.allocator, testing.io, json, .init(comptime json.schema.of(T, .{ .direction = .encode })), .{});
            defer encode.deinit();
            var decode = try Schema.compile(testing.allocator, testing.io, json, .init(comptime json.schema.of(T, .{ .direction = .decode })), .{});
            defer decode.deinit();
            const value = try shakedown.gen.any(c.source, T, a);
            var out: std.Io.Writer.Allocating = .init(a);
            json.write(&out.writer, value, .{}) catch |err| switch (err) {
                // Values JSON cannot hold: bytes that are not UTF-8, NaN.
                error.InvalidUtf8, error.UnsupportedValue, error.NumberOutOfRange => return,
                else => return err,
            };
            const written = out.written();
            for ([_]*const Schema{ &encode, &decode }) |s| {
                const valid = try s.validate(testing.io, a, json, .init(written), .{ .flag = null });
                if (!valid) c.note("refused what strand wrote: {s}", .{written});
                try testing.expect(valid);
            }
            // A document mutated from it: the schema of what strand reads
            // takes exactly what strand reads.
            var buffer: [256]u8 = undefined;
            const mutated = shakedown.gen.mutated(c.source, &buffer, &.{written});
            if (json.parseLeaky(json.Value, a, mutated, .{})) |_| {} else |_| return;
            const reads = if (json.parseLeaky(T, a, mutated, .{})) |_| true else |_| false;
            const valid = try decode.validate(testing.io, a, json, .init(mutated), .{ .flag = null });
            if (valid != reads) c.note("{s}: strand reads it {}, the schema says {}", .{ mutated, reads, valid });
            try testing.expectEqual(reads, valid);
        }
    }.body;
}

test "the schema strand generates for a type takes what strand writes, and exactly what it reads" {
    inline for (.{ Search, Shape, Tree, Mixed }) |T| {
        try shakedown.check(testing.allocator, {}, property(T), .{ .cases = 1000, .seed = 0x9e7 });
    }
}
