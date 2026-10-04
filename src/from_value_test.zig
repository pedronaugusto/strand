//! from_value scenarios through the public API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const parseFromValue = @import("from_value.zig").parseFromValue;
const testing = std.testing;

test "payloadOf checks wide integers in arrays and vectors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try std.json.parseFromSliceLeaky(std.json.Value, a, "[1,2]", .{});
    const overflow = try std.json.parseFromSliceLeaky(std.json.Value, a, "[1,1.8446744073709552e19]", .{});
    inline for (.{ [2]u64, @Vector(2, u64) }) |T| {
        const value = try @import("strand.zig").payloadOf(T, a, good);
        try testing.expectEqual(@as(u64, 1), value[0]);
        try testing.expectEqual(@as(u64, 2), value[1]);
        try testing.expectError(error.Overflow, @import("strand.zig").payloadOf(T, a, overflow));
        try testing.expectError(error.UnexpectedToken, @import("strand.zig").payloadOf(T, a, .null));
    }
}

test "payloadOf reports the first conversion error before a later wide integer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"flag\":3,\"number\":1.8446744073709552e19}", .{});
    try testing.expectError(error.UnexpectedToken, parseFromValue(struct { flag: bool, number: u64 }, a, source, .{}));
}

const NestedVectors = struct {
    tuple: struct { @Vector(2, u64), []const u8 },
    array: [1]@Vector(2, u64),
    rows: ?[]const *const @Vector(2, u64),
    arm: union(enum) { vector: @Vector(2, u64), none },
    raw: @import("codec.zig").Raw,
    hook: struct {
        vector: @Vector(2, u64),
        pub fn jsonParseFromValue(_: Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
            if (value != .string) return error.UnexpectedToken;
            return .{ .vector = .{ 7, 8 } };
        }
    },
    default: @Vector(2, u64) = .{ 9, 10 },
};

fn nestedVectors(allocator: Allocator, source: std.json.Value) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const result = try parseFromValue(NestedVectors, arena.allocator(), source, .{});
    try testing.expectEqual(@as(u64, 2), result.tuple[0][1]);
    try testing.expectEqualStrings("tuple", result.tuple[1]);
    try testing.expectEqual(@as(u64, 4), result.array[0][1]);
    try testing.expectEqual(@as(u64, 6), result.rows.?[0].*[1]);
    try testing.expectEqual(@as(u64, 12), result.arm.vector[1]);
    try testing.expectEqualStrings("[1,2]", result.raw.bytes);
    try testing.expectEqual(@as(u64, 8), result.hook.vector[1]);
    try testing.expectEqual(@as(u64, 10), result.default[1]);
}

test "payloadOf converts nested vectors with defaults and custom hooks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tuple":[[1,2],"tuple"],"array":[[3,4]],"rows":[[5,6]],
        \\ "arm":{"vector":[11,12]},"raw":[1,2],"hook":"custom"}
    , .{});
    try testing.checkAllAllocationFailures(testing.allocator, nestedVectors, .{source});
    const Vec = @Vector(2, u64);
    const short = try std.json.parseFromSliceLeaky(std.json.Value, a, "[1]", .{});
    try testing.expectError(error.LengthMismatch, parseFromValue(Vec, a, short, .{}));
    try testing.expectError(error.UnexpectedToken, parseFromValue(Vec, a, .{ .string = "12" }, .{}));
    const object = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"extra\":3,\"v\":[1,2]}", .{});
    const T = struct { v: Vec };
    try testing.expectError(error.UnknownField, parseFromValue(T, a, object, .{}));
    try testing.expectEqual(@as(u64, 2), (try parseFromValue(T, a, object, .{ .ignore_unknown_fields = true })).v[1]);
    try testing.expectError(error.MissingField, parseFromValue(T, a, .{ .object = .empty }, .{}));
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"none\":{}}", .{});
    const Arm = union(enum) { vector: Vec, none };
    try testing.expectEqual(Arm.none, try parseFromValue(Arm, a, empty, .{}));
    try testing.expectEqual(@as(?Vec, null), try parseFromValue(?Vec, a, .null, .{}));
    const Event = struct {
        vector: Vec,
        pub const jsonl_version: u32 = 1;
    };
    const strand = @import("strand.zig");
    const versioned = try strand.parseLine(strand.Versioned(Event), a, "{\"data\":{\"vector\":[1,2]},\"v\":1}", .{});
    try testing.expectEqual(@as(u64, 2), versioned.value.vector[1]);
}

test "a value std.json cannot cast into an integer is Overflow, not a panic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A float that is the type's largest value rounded up is let through
    // std.json's check and cast straight to the type. Each panicked.
    try testing.expectError(error.Overflow, parseFromValue(u64, a, .{ .float = 0x1p64 }, .{}));
    try testing.expectError(error.Overflow, parseFromValue(i64, a, .{ .float = 0x1p63 }, .{}));
    try testing.expectError(error.Overflow, parseFromValue(u128, a, .{ .float = 0x1p128 }, .{}));
    try testing.expectError(error.Overflow, parseFromValue(i128, a, .{ .float = 0x1p127 }, .{}));
    // A number kept as its text, or a string, goes through the cast
    // through an `i128`.
    try testing.expectError(error.Overflow, parseFromValue(u128, a, .{ .number_string = "1.8e38" }, .{}));
    try testing.expectError(error.Overflow, parseFromValue(u128, a, .{ .string = "2e38" }, .{}));
    // Wherever it sits.
    const Holder = struct { a: u8 = 0, b: ?[]const u64 = null };
    const held = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"b\":[1,1.8446744073709552e19]}", .{});
    try testing.expectEqual(@as(f64, 0x1p64), held.object.get("b").?.array.items[1].float);
    try testing.expectError(error.Overflow, parseFromValue(Holder, a, held, .{}));

    // And what it reads, it reads as std.json does.
    try testing.expectEqual(@as(u64, 1 << 63), try parseFromValue(u64, a, .{ .float = 0x1p63 }, .{}));
    try testing.expectEqual(@as(u128, 1 << 127), try parseFromValue(u128, a, .{ .float = 0x1p127 }, .{}));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try parseFromValue(i64, a, .{ .float = -0x1p63 }, .{}));
    try testing.expectError(error.Overflow, parseFromValue(u64, a, .{ .float = 0x1p65 }, .{}));
    try testing.expectEqual(@as(u64, 1500), try parseFromValue(u64, a, .{ .number_string = "1.5e3" }, .{}));
    // std.json refuses the unknown member before it reaches the number.
    const unknown = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"z\":1,\"n\":1.8446744073709552e19}", .{});
    try testing.expectError(error.UnknownField, parseFromValue(struct { n: u64 }, a, unknown, .{}));
}

test "payloadOf reads empty arrays without indexing nonexistent elements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "[]", .{});
    inline for (.{ u8, bool, u32, []const u8 }) |Child| {
        try testing.expectEqualDeep(@as([0]Child, .{}), try @import("strand.zig").payloadOf([0]Child, a, empty));
        const Nested = struct { rows: [1][0]Child };
        const source = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"rows\":[[]]}", .{});
        try testing.expectEqualDeep(Nested{ .rows = .{.{}} }, try @import("strand.zig").payloadOf(Nested, a, source));
        try testing.expectError(error.LengthMismatch, @import("strand.zig").payloadOf([0]Child, a, try std.json.parseFromSliceLeaky(std.json.Value, a, "[0]", .{})));
    }
    try testing.expectEqualDeep(@as([0]u8, .{}), try @import("strand.zig").payloadOf([0]u8, a, .{ .string = "" }));
    try testing.expectError(error.LengthMismatch, @import("strand.zig").payloadOf([0]u8, a, .{ .string = "x" }));
}
