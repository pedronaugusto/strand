//! Typed parsing on top of strand's complete-input scanner.
//!
//! The shape and policies are `std.json`'s. The one conversion owned here is
//! the integer (`int.zig`), which `std.json` can panic on, and vectors,
//! which accept the byte strings its encoder writes; everything else
//! it does not walk itself is delegated to `std.json.innerParse`.

const std = @import("std");
const Scanner = @import("scanner.zig");
const int = @import("int.zig");
const tagging = @import("tagging.zig");
const from_value = @import("from_value.zig");
const Allocator = std.mem.Allocator;
const Token = std.json.Token;

pub fn parse(
    comptime T: type,
    allocator: Allocator,
    scanner: *Scanner,
    options: std.json.ParseOptions,
) std.json.ParseError(Scanner)!T {
    @import("work.zig").parse();
    const value = try inner(T, allocator, scanner, options);
    if (try scanner.next() != .end_of_document) return error.UnexpectedToken;
    return value;
}

/// Reads one value from strand's scanner, `std.json.Scanner` or
/// `std.json.Reader`, leaving the following token for the caller.
/// Exported as `strand.innerParse`.
///
/// Use inside a custom `jsonParse` hook to delegate ordinary fields while
/// retaining strand's checked integer conversions and byte-vector string
/// support. Delegate the field's type, not the hook's own type, which would
/// call that hook again. The hook still owns its custom wire semantics.
///
/// Pass the allocator and resolved `std.json.ParseOptions` received by the
/// hook unchanged, including `allocate` and `max_value_len`. Allocations
/// follow std.json's leaky contract: use an arena, and retain borrowed input
/// as long as the returned value. This does not check end of document or
/// JSON Lines framing; use `parseLine` for a complete line.
pub fn inner(
    comptime T: type,
    allocator: Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
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
            // Looked at before it is taken, as `std.json` does: a string in
            // the place of an array is refused before it is read to its end.
            switch (try source.peekNextTokenType()) {
                .array_begin => _ = try source.next(),
                .string => if (info.child == u8)
                    return std.json.innerParse(T, allocator, source, options)
                else
                    return error.UnexpectedToken,
                else => return error.UnexpectedToken,
            }
            var result: T = undefined;
            for (&result) |*item| item.* = try inner(info.child, allocator, source, options);
            if (try source.next() != .array_end) return error.UnexpectedToken;
            return result;
        },
        .vector => |info| {
            const A = [info.len]info.child;
            return try inner(A, allocator, source, options);
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
                if (try source.peekNextTokenType() != .array_begin) return error.UnexpectedToken;
                _ = try source.next();
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
            if (comptime tagging.internal(T)) |inside| return tagged(T, inside, allocator, source, options);
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

/// A union tagged inside its object.
///
/// The tag can be anywhere in the object, so the object is read twice: once
/// for the tag, and once for the arm the tag names, passing the tag over. A
/// source holding the whole input is where the object's bytes are, and both
/// reads are over them; a source that streams has only one read to give, and
/// there the object is held as a `std.json.Value` and read from that.
fn tagged(
    comptime T: type,
    comptime inside: anytype,
    allocator: Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    const Source = @TypeOf(source.*);
    if (comptime Source == Scanner or Source == std.json.Scanner) whole: {
        if (Source == std.json.Scanner and !source.is_end_of_input) break :whole;
        if (try source.peekNextTokenType() != .object_begin) {
            _ = try source.next();
            return error.UnexpectedToken;
        }
        const start = source.cursor;
        try source.skipValue();
        const bytes = source.input[start..source.cursor];
        const name = try tagIn(allocator, bytes, inside.tag, options);

        var again: Scanner = .initCompleteInput(allocator, bytes);
        defer again.deinit();
        inline for (@typeInfo(T).@"union".fields) |field| {
            const is_other = comptime inside.other != null and
                std.mem.eql(u8, field.name, @tagName(inside.other.?));
            if (!is_other and std.mem.eql(u8, field.name, name)) {
                if (field.type == void) {
                    _ = try parseStructSkipping(struct {}, allocator, &again, options, inside.tag);
                    return @unionInit(T, field.name, {});
                }
                return @unionInit(T, field.name, try parseStructSkipping(field.type, allocator, &again, options, inside.tag));
            }
        }
        if (comptime inside.other) |other| {
            const Payload = @FieldType(T, @tagName(other));
            if (Payload == void) return @unionInit(T, @tagName(other), {});
            return @unionInit(T, @tagName(other), try Payload.jsonParse(allocator, &again, options));
        }
        return error.InvalidEnumTag;
    }
    const value = try std.json.innerParse(std.json.Value, allocator, source, options);
    return from_value.parseFromValue(T, allocator, value, options);
}

/// The value of the member `tag` of the object that is all of `bytes`,
/// which is checked JSON: a string, the name of an arm.
fn tagIn(allocator: Allocator, bytes: []const u8, comptime tag: []const u8, options: std.json.ParseOptions) std.json.ParseError(Scanner)![]const u8 {
    var scanner: Scanner = .initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    _ = try scanner.next();
    var found: ?[]const u8 = null;
    while (true) {
        const key = try scanner.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const name = switch (key) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        const is_tag = std.mem.eql(u8, name, tag);
        freeAllocated(allocator, key);
        if (!is_tag) {
            try scanner.skipValue();
            continue;
        }
        if (found != null) return error.DuplicateField;
        // Kept on `allocator` when it had to be unescaped, which is the
        // parse's leaky arena, as every other string a parse makes.
        found = switch (try scanner.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
    }
    return found orelse error.MissingField;
}

fn parseStruct(
    comptime T: type,
    allocator: Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    return parseStructSkipping(T, allocator, source, options, null);
}

/// `parseStruct`, with a member named `skip` passed over once and a
/// duplicate the second time: the tag of a union tagged inside its object.
fn parseStructSkipping(
    comptime T: type,
    allocator: Allocator,
    source: anytype,
    options: std.json.ParseOptions,
    comptime skip: ?[]const u8,
) std.json.ParseError(@TypeOf(source.*))!T {
    const fields = @typeInfo(T).@"struct".fields;
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    var result: T = undefined;
    var skipped = false;
    _ = &skipped;
    var seen = [_]bool{false} ** fields.len;
    _ = &seen;
    // Encoders overwhelmingly write declaration order. Remember the field
    // after the last match, but fall back to the full lookup for arbitrary
    // order and unknown keys.
    var hint: usize = 0;
    _ = &hint;

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
            if (skip) |tag| if (std.mem.eql(u8, name, tag)) {
                freeAllocated(allocator, name_token.?);
                if (skipped) return error.DuplicateField;
                skipped = true;
                try source.skipValue();
                continue :fields_loop;
            };
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
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    defer freeAllocated(allocator, token);
    const slice = switch (token) {
        inline .number, .allocated_number, .string, .allocated_string => |value| value,
        else => return error.UnexpectedToken,
    };

    return int.fromSlice(T, slice);
}

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| allocator.free(slice),
        else => {},
    }
}
