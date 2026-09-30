//! `std.json.parseFromValueLeaky`, except where it would panic.
//!
//! `Versioned` holds a payload as a `std.json.Value` when it cannot parse it
//! straight into `T` — `data` before `v`, a version to migrate from — and
//! reads it from there with `std.json`. In Zig 0.16.0 that reads an integer
//! from the value two ways that can reach a cast the value does not fit:
//!
//! - a `.float` is an `f64` checked against the type's largest value
//!   converted to `f64` and cast straight to the type, so the one value it
//!   lets through is that largest value rounded up: 2^64 into a `u64`,
//!   2^63 into an `i64`;
//! - a `.number_string` or a `.string` goes through `sliceToInt`, which
//!   casts through an `i128` (see `int.zig`).
//!
//! Conversion walks reflected containers here when they contain a checked
//! integer or a vector. Each leaf is converted where it occurs, so the
//! first error is the one `std.json` would report. Scalar and custom
//! conversions stay with `std.json`; a vector is built as an array and then
//! converted, since Zig 0.16.0's value parser uses a runtime vector index.
//! Byte vectors also accept strings, matching the shape its encoder writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const int = @import("int.zig");

/// `std.json.parseFromValueLeaky(T, allocator, value, options)`, with its
/// answer, or `error.Overflow` where it would panic. Byte vectors also
/// accept the string form written by std.json, as byte arrays do.
pub fn parseFromValue(
    comptime T: type,
    allocator: Allocator,
    value: std.json.Value,
    options: std.json.ParseOptions,
) std.json.ParseFromValueError!T {
    @setEvalBranchQuota(1_000_000);
    if (@typeInfo(T) == .int) {
        if (comptime @typeInfo(T).int.bits > 53) switch (value) {
            .float => |float| if (floatBreaksCast(T, float)) return error.Overflow,
            .number_string, .string => |slice| if (sliceBreaksCast(T, slice)) return error.Overflow,
            else => {},
        };
    } else if (comptime needsConversion(T, &.{})) {
        return collections(T, allocator, value, options);
    }
    return std.json.parseFromValueLeaky(T, allocator, value, options);
}

/// Whether `innerParseFromValue` given `float` for a `T` would reach a cast
/// that cannot hold it: past its check, at or past the power of two that
/// ends `T`'s range.
fn floatBreaksCast(comptime T: type, float: f64) bool {
    if (@round(float) != float) return false;
    if (float > @as(f64, @floatFromInt(std.math.maxInt(T)))) return false;
    if (float < @as(f64, @floatFromInt(std.math.minInt(T)))) return false;
    const info = @typeInfo(T).int;
    const bits = if (info.signedness == .signed) info.bits - 1 else info.bits;
    return float >= comptime std.math.ldexp(@as(f64, 1), bits);
}

/// Whether `sliceToInt(T, slice)` would reach a cast that cannot hold it:
/// past its check, and not an `i128` or not a `T`.
fn sliceBreaksCast(comptime T: type, slice: []const u8) bool {
    if (std.json.isNumberFormattedLikeAnInteger(slice)) return false;
    const float = std.fmt.parseFloat(f128, slice) catch return false;
    if (@round(float) != float) return false;
    if (float > @as(f128, @floatFromInt(std.math.maxInt(T)))) return false;
    if (float < @as(f128, @floatFromInt(std.math.minInt(T)))) return false;
    // Whole and in the range the check allows: `int.fromFloat` refuses
    // exactly the values that are not.
    _ = int.fromFloat(T, float) catch return true;
    const past_i128 = comptime std.math.ldexp(@as(f128, 1), 127);
    return float >= past_i128 or float < -past_i128;
}

fn needsConversion(comptime T: type, comptime seen: []const type) bool {
    for (seen) |previous| if (T == previous) return false;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .int => |info| info.bits > 53,
        .vector => true,
        inline .optional, .array => |info| needsConversion(info.child, next),
        .pointer => |info| switch (info.size) {
            .one, .slice => needsConversion(info.child, next),
            else => false,
        },
        inline .@"struct", .@"union" => |info| result: {
            if (std.meta.hasFn(T, "jsonParseFromValue") and
                (@typeInfo(T) != .@"struct" or !@typeInfo(T).@"struct".is_tuple)) break :result false;
            for (info.fields) |field| if (needsConversion(field.type, next)) break :result true;
            break :result false;
        },
        else => false,
    };
}

// Only containers whose descendants need checked integers or vectors arrive
// here. Each child goes through the entry point, so custom hooks retain
// control of their data and integers retain their checked conversions.
fn collections(comptime T: type, allocator: Allocator, value: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
    switch (@typeInfo(T)) {
        .vector => |info| {
            const array = try collections([info.len]info.child, allocator, value, options);
            return array;
        },
        .array => |info| {
            if (info.child == u8 and value == .string) {
                if (value.string.len != info.len) return error.LengthMismatch;
                var result: T = undefined;
                @memcpy(&result, value.string);
                return result;
            }
            if (value != .array) return error.UnexpectedToken;
            if (value.array.items.len != info.len) return error.LengthMismatch;
            var result: T = undefined;
            for (value.array.items, &result) |item, *dest|
                dest.* = try parseFromValue(info.child, allocator, item, options);
            return result;
        },
        .optional => |info| return if (value == .null) null else try parseFromValue(info.child, allocator, value, options),
        .pointer => |info| switch (info.size) {
            .one => {
                const result = try allocator.create(info.child);
                result.* = try parseFromValue(info.child, allocator, value, options);
                return result;
            },
            .slice => {
                if (value != .array) return error.UnexpectedToken;
                const result = try allocator.allocWithOptions(info.child, value.array.items.len, null, info.sentinel());
                for (value.array.items, result) |item, *dest|
                    dest.* = try parseFromValue(info.child, allocator, item, options);
                return result;
            },
            else => unreachable,
        },
        .@"struct" => |info| {
            var result: T = undefined;
            if (info.is_tuple) {
                if (value != .array or value.array.items.len != info.fields.len) return error.UnexpectedToken;
                inline for (info.fields, 0..) |field, i|
                    result[i] = try parseFromValue(field.type, allocator, value.array.items[i], options);
                return result;
            }
            if (value != .object) return error.UnexpectedToken;
            var seen = [_]bool{false} ** info.fields.len;
            for (value.object.keys(), value.object.values()) |key, item| {
                inline for (info.fields, 0..) |field, i| {
                    if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                    if (std.mem.eql(u8, key, field.name)) {
                        @field(result, field.name) = try parseFromValue(field.type, allocator, item, options);
                        seen[i] = true;
                        break;
                    }
                } else if (!options.ignore_unknown_fields) return error.UnknownField;
            }
            inline for (info.fields, 0..) |field, i| if (!seen[i]) {
                if (field.defaultValue()) |default| @field(result, field.name) = default else return error.MissingField;
            };
            return result;
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            if (value != .object or value.object.count() != 1) return error.UnexpectedToken;
            const key = value.object.keys()[0];
            const item = value.object.values()[0];
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, key, field.name)) {
                    if (field.type == void) {
                        if (item != .object or item.object.count() != 0) return error.UnexpectedToken;
                        return @unionInit(T, field.name, {});
                    }
                    return @unionInit(T, field.name, try parseFromValue(field.type, allocator, item, options));
                }
            }
            return error.UnknownField;
        },
        else => unreachable,
    }
}

//=========================================================================
// Tests. `Versioned`'s own are in `versioned.zig`.
//=========================================================================

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
    raw: @import("raw.zig").Raw,
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
