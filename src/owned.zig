//! A parsed value copied out of the storage it borrows, without parsing it
//! again. Each allocation belongs to the caller; a failed copy frees what
//! it built before failing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Copies `value` and all the storage it reaches onto `allocator`.
///
/// Structs (including tuples), arrays, slices, single-item pointers,
/// optionals and tagged unions are walked; numbers, booleans, enums and
/// void are copied as values. Sentinels and pointer alignment are preserved.
/// `Raw` keeps its exact bytes. `std.json.Value` gets new strings, object
/// keys and containers, with its arrays using the destination allocator.
/// JSON parse and stringify hooks are not called.
///
/// The input must be a finite tree of data, as a parsed value is. Repeated
/// references are copied separately; cycles and external resources are not
/// data this operation can own. Unsupported field types, untagged unions,
/// sentinels holding pointers and comptime fields that hold pointers are
/// refused at compile time,
/// even in an empty slice, a null optional or an inactive union arm.
///
/// On failure, all allocations made by this call are freed and the input
/// is untouched. On success, call `freeOwned` with the same allocator, or
/// release the destination arena as a whole. Until then, keep the owning
/// pointers and container lengths intact. Ordinary Zig assignment aliases
/// this ownership; it does not make another owned copy.
pub fn copyOwned(allocator: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    comptime check(T);
    if (T == std.json.Value) return copyValue(allocator, value);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                const storage = try allocator.alignedAlloc(info.child, .fromByteUnits(info.alignment orelse @alignOf(info.child)), 1);
                errdefer allocator.free(storage);
                storage[0] = try copyOwned(allocator, value.*);
                return &storage[0];
            },
            .slice => {
                const storage = try allocator.allocWithOptions(info.child, value.len, .fromByteUnits(info.alignment orelse @alignOf(info.child)), info.sentinel());
                errdefer allocator.free(storage);
                var initialized: usize = 0;
                errdefer for (storage[0..initialized]) |item| freeOwned(allocator, item);
                for (value, storage) |from, *to| {
                    to.* = try copyOwned(allocator, from);
                    initialized += 1;
                }
                return storage;
            },
            else => unreachable,
        },
        .optional => return if (value) |item| try copyOwned(allocator, item) else null,
        .@"struct" => |info| {
            var result = value;
            var initialized: usize = 0;
            errdefer inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime and i < initialized)
                    freeOwned(allocator, @field(result, field.name));
            };
            inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime)
                    @field(result, field.name) = try copyOwned(allocator, @field(value, field.name));
                initialized = i + 1;
            }
            return result;
        },
        .array => {
            var result = value;
            var initialized: usize = 0;
            errdefer for (result[0..initialized]) |item| freeOwned(allocator, item);
            for (value, &result) |from, *to| {
                to.* = try copyOwned(allocator, from);
                initialized += 1;
            }
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |item, tag| @unionInit(T, @tagName(tag), try copyOwned(allocator, item)),
        },
        else => return value,
    }
}

/// Frees a complete value returned by `copyOwned`, on the allocator that
/// copied it. Does not free the outer value itself. Do not pass a borrowed
/// or parsed value here, or free the same owned copy twice.
pub fn freeOwned(allocator: Allocator, value: anytype) void {
    const T = @TypeOf(value);
    comptime check(T);
    if (T == std.json.Value) return freeValue(allocator, value);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                freeOwned(allocator, value.*);
                allocator.destroy(value);
            },
            .slice => {
                for (value) |item| freeOwned(allocator, item);
                allocator.free(value);
            },
            else => unreachable,
        },
        .optional => if (value) |item| freeOwned(allocator, item),
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!field.is_comptime) freeOwned(allocator, @field(value, field.name));
        },
        .array => for (value) |item| freeOwned(allocator, item),
        .@"union" => switch (value) {
            inline else => |item| freeOwned(allocator, item),
        },
        else => {},
    }
}

fn copyValue(allocator: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    switch (value) {
        .string => |bytes| return .{ .string = try allocator.dupe(u8, bytes) },
        .number_string => |bytes| return .{ .number_string = try allocator.dupe(u8, bytes) },
        .array => |array| {
            var result: std.json.Array = .init(allocator);
            errdefer freeValue(allocator, .{ .array = result });
            try result.ensureTotalCapacity(array.items.len);
            for (array.items) |item| result.appendAssumeCapacity(try copyValue(allocator, item));
            return .{ .array = result };
        },
        .object => |object| {
            var result: std.json.ObjectMap = .empty;
            errdefer freeValue(allocator, .{ .object = result });
            try result.ensureTotalCapacity(allocator, object.count());
            for (object.keys(), object.values()) |key, item| {
                const copied_key = try allocator.dupe(u8, key);
                errdefer allocator.free(copied_key);
                const copied_item = try copyValue(allocator, item);
                result.putAssumeCapacityNoClobber(copied_key, copied_item);
            }
            return .{ .object = result };
        },
        else => return value,
    }
}

fn freeValue(allocator: Allocator, value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |bytes| allocator.free(bytes),
        .array => |array| {
            for (array.items) |item| freeValue(allocator, item);
            var storage = array;
            storage.deinit();
        },
        .object => |object| {
            for (object.keys(), object.values()) |key, item| {
                allocator.free(key);
                freeValue(allocator, item);
            }
            var storage = object;
            storage.deinit(allocator);
        },
        else => {},
    }
}

fn check(comptime T: type) void {
    if (!canCopy(T, &.{})) @compileError(@typeName(T) ++ " cannot be copied by copyOwned");
}

// Check the whole type before walking a value. Recursive schemas are legal;
// only the runtime data must be a tree.
fn canCopy(comptime T: type, comptime seen: []const type) bool {
    if (T == std.json.Value) return true;
    for (seen) |previous| if (T == previous) return true;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void, .null, .comptime_int, .comptime_float, .enum_literal => true,
        .pointer => |info| (info.size == .one or info.size == .slice) and
            !info.is_volatile and !info.is_allowzero and info.address_space == .generic and
            safeSentinel(info) and canCopy(info.child, next),
        .optional => |info| canCopy(info.child, next),
        .array => |info| safeSentinel(info) and canCopy(info.child, next),
        .vector => |info| canCopy(info.child, next),
        .@"struct" => |info| result: {
            for (info.fields) |field| {
                if (!canCopy(field.type, next) or (field.is_comptime and hasPointers(field.type, &.{}))) break :result false;
            }
            break :result true;
        },
        .@"union" => |info| result: {
            if (info.tag_type == null) break :result false;
            for (info.fields) |field| if (!canCopy(field.type, next)) break :result false;
            break :result true;
        },
        else => false,
    };
}

// A sentinel is part of the type, so its value cannot be replaced with a
// new owning pointer. A null optional sentinel has no storage to copy.
fn safeSentinel(comptime info: anytype) bool {
    if (info.sentinel_ptr == null) return true;
    return !containsPointer(info.sentinel().?);
}

fn containsPointer(comptime value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => true,
        .optional => if (value) |item| containsPointer(item) else false,
        .array => for (value) |item| {
            if (containsPointer(item)) break true;
        } else false,
        .@"struct" => |info| result: {
            for (info.fields) |field| if (containsPointer(@field(value, field.name))) break :result true;
            break :result false;
        },
        .@"union" => switch (value) {
            inline else => |item| containsPointer(item),
        },
        else => false,
    };
}

fn hasPointers(comptime T: type, comptime seen: []const type) bool {
    for (seen) |previous| if (T == previous) return false;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .pointer => true,
        inline .optional, .array, .vector => |info| hasPointers(info.child, next),
        inline .@"struct", .@"union" => |info| result: {
            for (info.fields) |field| if (hasPointers(field.type, next)) break :result true;
            break :result false;
        },
        else => false,
    };
}
