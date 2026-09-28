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
//! Before `std.json` is given the value, the walk below goes through it the
//! way `std.json` would — the same members to the same fields, with the same
//! options — and answers `error.Overflow` where `std.json` would reach the
//! cast. It stops at the first thing `std.json` would refuse and lets it
//! refuse it, so a value that does not reach a panic gets `std.json`'s own
//! answer, value or error. A type with its own `jsonParseFromValue` is
//! stepped over: what it reads is its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const int = @import("int.zig");

/// `std.json.parseFromValueLeaky(T, allocator, value, options)`, with its
/// answer, or `error.Overflow` where it would panic.
pub fn parseFromValue(
    comptime T: type,
    allocator: Allocator,
    value: std.json.Value,
    options: std.json.ParseOptions,
) std.json.ParseFromValueError!T {
    if (comptime risky(T, &.{})) {
        walk(T, value, options) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.Stop => {},
        };
    }
    return std.json.parseFromValueLeaky(T, allocator, value, options);
}

/// Whether `T` holds, anywhere, an integer `std.json` could fail to cast
/// from a value: one whose largest value is not exact as an `f64`.
fn risky(comptime T: type, comptime within: []const type) bool {
    for (within) |outer| if (outer == T) return false;
    const inside = within ++ .{T};
    return switch (@typeInfo(T)) {
        .int => |info| info.bits > 53,
        .optional => |info| risky(info.child, inside),
        .@"union" => |info| for (info.fields) |field| {
            if (field.type != void and risky(field.type, inside)) break true;
        } else false,
        .@"struct" => |info| for (info.fields) |field| {
            if (!field.is_comptime and risky(field.type, inside)) break true;
        } else false,
        .pointer => |info| switch (info.size) {
            .one, .slice => risky(info.child, inside),
            else => false,
        },
        .array => |info| risky(info.child, inside),
        .vector => |info| risky(info.child, inside),
        else => false,
    };
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

/// The walk ends: at `Overflow` because `std.json` would panic, at `Stop`
/// because it would answer first.
const Walk = error{ Overflow, Stop };

/// `std.json.innerParseFromValue`, reading nothing but what it would read
/// into an integer.
fn walk(comptime T: type, value: std.json.Value, options: std.json.ParseOptions) Walk!void {
    switch (@typeInfo(T)) {
        .int => |info| if (comptime info.bits > 53) switch (value) {
            .float => |float| if (floatBreaksCast(T, float)) return error.Overflow,
            .number_string, .string => |slice| if (sliceBreaksCast(T, slice)) return error.Overflow,
            else => {},
        },
        .optional => |info| if (value != .null) try walk(info.child, value, options),
        .@"union" => |info| {
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return;
            if (value != .object or value.object.count() != 1) return error.Stop;
            var it = value.object.iterator();
            const entry = it.next().?;
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                    if (field.type != void) try walk(field.type, entry.value_ptr.*, options);
                    return;
                }
            }
            return error.Stop;
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                if (value != .array or value.array.items.len != info.fields.len) return error.Stop;
                inline for (info.fields, 0..) |field, i| try walk(field.type, value.array.items[i], options);
                return;
            }
            if (comptime std.meta.hasFn(T, "jsonParseFromValue")) return;
            if (value != .object) return error.Stop;
            var it = value.object.iterator();
            while (it.next()) |entry| {
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                        try walk(field.type, entry.value_ptr.*, options);
                        break;
                    }
                } else if (!options.ignore_unknown_fields) return error.Stop;
            }
        },
        .array, .vector => |info| {
            if (value != .array) return error.Stop;
            if (value.array.items.len != info.len) return error.Stop;
            for (value.array.items) |item| try walk(info.child, item, options);
        },
        .pointer => |info| switch (info.size) {
            .one => try walk(info.child, value, options),
            .slice => if (value == .array) {
                for (value.array.items) |item| try walk(info.child, item, options);
            },
            else => {},
        },
        else => {},
    }
}

//=========================================================================
// Tests. `Versioned`'s own are in `versioned.zig`.
//=========================================================================

const testing = std.testing;

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
