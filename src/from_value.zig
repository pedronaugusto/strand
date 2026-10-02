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
//! integer, vector or empty array. Each leaf is converted where it occurs, so the
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
        .array => |info| info.len == 0 or needsConversion(info.child, next),
        .optional => |info| needsConversion(info.child, next),
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

// Only containers whose descendants need checked integers, vectors or empty arrays arrive
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
