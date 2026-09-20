//! Typed parsing on top of strand's complete-input scanner.
//!
//! The shape and policies are `std.json`'s. The only owned conversion here
//! is the common non-negative fixed-width integer path; everything else is
//! delegated to `std.json.innerParse`.

const std = @import("std");
const Scanner = @import("scanner.zig");
const Allocator = std.mem.Allocator;
const Token = std.json.Token;

pub fn parse(
    comptime T: type,
    allocator: Allocator,
    scanner: *Scanner,
    options: std.json.ParseOptions,
) std.json.ParseError(Scanner)!T {
    const value = try inner(T, allocator, scanner, options);
    if (try scanner.next() != .end_of_document) return error.UnexpectedToken;
    return value;
}

fn inner(
    comptime T: type,
    allocator: Allocator,
    source: *Scanner,
    options: std.json.ParseOptions,
) std.json.ParseError(Scanner)!T {
    switch (@typeInfo(T)) {
        .int, .comptime_int => return parseInt(T, allocator, source, options),
        .optional => |info| {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return null;
            }
            return try inner(info.child, allocator, source, options);
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: T = undefined;
                inline for (info.fields, 0..) |field, i| {
                    result[i] = try inner(field.type, allocator, source, options);
                }
                if (try source.next() != .array_end) return error.UnexpectedToken;
                return result;
            }
            if (std.meta.hasFn(T, "jsonParse"))
                return T.jsonParse(allocator, source, options);
            return parseStruct(T, allocator, source, options);
        },
        .array => |info| {
            // `std.json` also accepts a string for [N]u8; leave that path to
            // its exact implementation.
            if (info.child == u8 and try source.peekNextTokenType() == .string)
                return std.json.innerParse(T, allocator, source, options);
            if (try source.next() != .array_begin) return error.UnexpectedToken;
            var result: T = undefined;
            for (&result) |*item| item.* = try inner(info.child, allocator, source, options);
            if (try source.next() != .array_end) return error.UnexpectedToken;
            return result;
        },
        .vector => |info| {
            const A = [info.len]info.child;
            return @bitCast(try inner(A, allocator, source, options));
        },
        .pointer => |info| switch (info.size) {
            .one => {
                const result = try allocator.create(info.child);
                result.* = try inner(info.child, allocator, source, options);
                return result;
            },
            .slice => {
                // Strings are where the scanner's borrowed/no-escape path is
                // expressed, and std's implementation already does exactly
                // the allocation policy required here.
                if (info.child == u8)
                    return std.json.innerParse(T, allocator, source, options);
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var list: std.ArrayList(info.child) = .empty;
                while (try source.peekNextTokenType() != .array_end) {
                    try list.append(allocator, try inner(info.child, allocator, source, options));
                }
                _ = try source.next();
                if (info.sentinel()) |sentinel| return try list.toOwnedSliceSentinel(allocator, sentinel);
                return try list.toOwnedSlice(allocator);
            },
            else => return std.json.innerParse(T, allocator, source, options),
        },
        .@"union" => |info| {
            if (std.meta.hasFn(T, "jsonParse"))
                return T.jsonParse(allocator, source, options);
            if (info.tag_type == null)
                @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            if (try source.next() != .object_begin) return error.UnexpectedToken;
            var name_token: ?Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const name = switch (name_token.?) {
                inline .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            var result: ?T = null;
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    freeAllocated(allocator, name_token.?);
                    name_token = null;
                    result = if (field.type == void) value: {
                        if (try source.next() != .object_begin) return error.UnexpectedToken;
                        if (try source.next() != .object_end) return error.UnexpectedToken;
                        break :value @unionInit(T, field.name, {});
                    } else @unionInit(T, field.name, try inner(field.type, allocator, source, options));
                    break;
                }
            } else return error.UnknownField;
            if (try source.next() != .object_end) return error.UnexpectedToken;
            return result.?;
        },
        else => return std.json.innerParse(T, allocator, source, options),
    }
}

fn parseStruct(
    comptime T: type,
    allocator: Allocator,
    source: *Scanner,
    options: std.json.ParseOptions,
) std.json.ParseError(Scanner)!T {
    const fields = @typeInfo(T).@"struct".fields;
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;
    // Encoders overwhelmingly write declaration order. Remember the field
    // after the last match, but fall back to the full lookup for arbitrary
    // order and unknown keys.
    var hint: usize = 0;

    fields_loop: while (true) {
        var name_token: ?Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const name = switch (name_token.?) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => break,
            else => return error.UnexpectedToken,
        };

        inline for (fields, 0..) |field, i| {
            if (i == hint and std.mem.eql(u8, field.name, name)) {
                freeAllocated(allocator, name_token.?);
                name_token = null;
                if (seen[i]) switch (options.duplicate_field_behavior) {
                    .use_first => {
                        _ = try inner(field.type, allocator, source, options);
                        hint = (i + 1) % fields.len;
                        continue :fields_loop;
                    },
                    .@"error" => return error.DuplicateField,
                    .use_last => {},
                };
                @field(result, field.name) = try inner(field.type, allocator, source, options);
                seen[i] = true;
                hint = (i + 1) % fields.len;
                continue :fields_loop;
            }
        }
        inline for (fields, 0..) |field, i| {
            if (field.is_comptime)
                @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
            if (std.mem.eql(u8, field.name, name)) {
                freeAllocated(allocator, name_token.?);
                name_token = null;
                if (seen[i]) switch (options.duplicate_field_behavior) {
                    .use_first => {
                        _ = try inner(field.type, allocator, source, options);
                        break;
                    },
                    .@"error" => return error.DuplicateField,
                    .use_last => {},
                };
                @field(result, field.name) = try inner(field.type, allocator, source, options);
                seen[i] = true;
                hint = (i + 1) % fields.len;
                continue :fields_loop;
            }
        } else {
            freeAllocated(allocator, name_token.?);
            if (!options.ignore_unknown_fields) return error.UnknownField;
            try source.skipValue();
        }
    }

    inline for (fields, 0..) |field, i| {
        if (!seen[i]) {
            if (field.defaultValue()) |default| {
                @field(result, field.name) = default;
            } else return error.MissingField;
        }
    }
    return result;
}

fn parseInt(
    comptime T: type,
    allocator: Allocator,
    source: *Scanner,
    options: std.json.ParseOptions,
) std.json.ParseError(Scanner)!T {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer freeAllocated(allocator, token);
    const slice = switch (token) {
        inline .number, .allocated_number, .string, .allocated_string => |value| value,
        else => return error.UnexpectedToken,
    };

    if (comptime @typeInfo(T).int.bits <= 64) {
        if (slice.len != 0 and slice[0] != '-') {
            var value: u64 = 0;
            const limit: u64 = @intCast(std.math.maxInt(T));
            for (slice) |c| {
                if (c < '0' or c > '9') break;
                const digit = c - '0';
                if (value > (limit -| digit) / 10) return error.Overflow;
                value = value * 10 + digit;
            } else return @intCast(value);
        }
    }

    if (std.json.isNumberFormattedLikeAnInteger(slice))
        return std.fmt.parseInt(T, slice, 10);
    const float = try std.fmt.parseFloat(f128, slice);
    if (@round(float) != float) return error.InvalidNumber;
    if (float > @as(f128, @floatFromInt(std.math.maxInt(T))) or
        float < @as(f128, @floatFromInt(std.math.minInt(T)))) return error.Overflow;
    return @intCast(@as(i128, @intFromFloat(float)));
}

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| allocator.free(slice),
        else => {},
    }
}
