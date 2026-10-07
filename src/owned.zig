//! A parsed value copied out of the storage it borrows, without parsing it
//! again. Each allocation belongs to the caller; a failed copy frees what
//! it built before failing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Copies `value` and all the storage it reaches onto `gpa`.
///
/// Structs (including tuples), arrays, vectors, slices, single-item pointers,
/// optionals and tagged unions are walked; numbers, booleans, enums and
/// void are copied as values. Sentinels and pointer alignment are preserved.
/// `Raw` keeps its exact bytes. `std.json.Value` gets new strings, object
/// keys and containers, with its arrays using the destination allocator.
/// JSON parse and stringify hooks are not called.
///
/// The input must be a finite tree of data, as a parsed value is. The copy
/// recurses once per level of it, as `freeOwned` does; a recursive schema
/// parsed by this package is held to `ParseOptions.max_depth`, which bounds
/// that. Repeated
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
pub fn copyOwned(gpa: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    comptime check(T);
    if (T == std.json.Value) return copyValue(gpa, value);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                const storage = try gpa.alignedAlloc(info.child, .fromByteUnits(info.attrs.@"align" orelse @alignOf(info.child)), 1);
                errdefer gpa.free(storage);
                storage[0] = try copyOwned(gpa, value.*);
                return &storage[0];
            },
            .slice => {
                const storage = try gpa.allocWithOptions(info.child, value.len, .fromByteUnits(info.attrs.@"align" orelse @alignOf(info.child)), info.sentinel());
                errdefer gpa.free(storage);
                var initialized: usize = 0;
                errdefer for (storage[0..initialized]) |item| freeOwned(gpa, item);
                for (value, storage) |from, *to| {
                    to.* = try copyOwned(gpa, from);
                    initialized += 1;
                }
                return storage;
            },
            else => unreachable,
        },
        .optional => return if (value) |item| try copyOwned(gpa, item) else null,
        .@"struct" => |info| {
            var result = value;
            var initialized: usize = 0;
            errdefer inline for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
                if (!attrs.@"comptime" and i < initialized)
                    freeOwned(gpa, @field(result, name));
            };
            inline for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
                if (!attrs.@"comptime")
                    @field(result, name) = try copyOwned(gpa, @field(value, name));
                initialized = i + 1;
            }
            return result;
        },
        .array => {
            var result = value;
            var initialized: usize = 0;
            errdefer for (result[0..initialized]) |item| freeOwned(gpa, item);
            for (value, &result) |from, *to| {
                to.* = try copyOwned(gpa, from);
                initialized += 1;
            }
            return result;
        },
        .vector => |info| {
            const items: [info.len]info.child = value;
            return try copyOwned(gpa, items);
        },
        .@"union" => return switch (value) {
            inline else => |item, tag| @unionInit(T, @tagName(tag), try copyOwned(gpa, item)),
        },
        else => return value,
    }
}

/// Frees a complete value returned by `copyOwned`, on the allocator that
/// copied it. Does not free the outer value itself. Also accepts values
/// returned by `Reader.keep`, `Tail.keep`, `Follower.keep` and each element
/// of `Tail.last` (free its outer slice separately). Do not pass a
/// borrowed or directly parsed value here, or free the same owned copy twice.
pub fn freeOwned(gpa: Allocator, value: anytype) void {
    const T = @TypeOf(value);
    comptime check(T);
    if (T == std.json.Value) return freeValue(gpa, value);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                freeOwned(gpa, value.*);
                gpa.destroy(value);
            },
            .slice => {
                for (value) |item| freeOwned(gpa, item);
                gpa.free(value);
            },
            else => unreachable,
        },
        .optional => if (value) |item| freeOwned(gpa, item),
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |name, attrs| {
            if (!attrs.@"comptime") freeOwned(gpa, @field(value, name));
        },
        .array => for (value) |item| freeOwned(gpa, item),
        .vector => |info| {
            const items: [info.len]info.child = value;
            freeOwned(gpa, items);
        },
        .@"union" => switch (value) {
            inline else => |item| freeOwned(gpa, item),
        },
        else => {},
    }
}

fn copyValue(gpa: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    switch (value) {
        .string => |bytes| return .{ .string = try gpa.dupe(u8, bytes) },
        .number_string => |bytes| return .{ .number_string = try gpa.dupe(u8, bytes) },
        .array => |array| {
            var result: std.json.Array = .init(gpa);
            errdefer freeValue(gpa, .{ .array = result });
            try result.ensureTotalCapacity(array.items.len);
            for (array.items) |item| result.appendAssumeCapacity(try copyValue(gpa, item));
            return .{ .array = result };
        },
        .object => |object| {
            var result: std.json.ObjectMap = .empty;
            errdefer freeValue(gpa, .{ .object = result });
            try result.ensureTotalCapacity(gpa, object.count());
            for (object.keys(), object.values()) |key, item| {
                const copied_key = try gpa.dupe(u8, key);
                errdefer gpa.free(copied_key);
                const copied_item = try copyValue(gpa, item);
                result.putAssumeCapacityNoClobber(copied_key, copied_item);
            }
            return .{ .object = result };
        },
        else => return value,
    }
}

fn freeValue(gpa: Allocator, value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |bytes| gpa.free(bytes),
        .array => |array| {
            for (array.items) |item| freeValue(gpa, item);
            var storage = array;
            storage.deinit();
        },
        .object => |object| {
            for (object.keys(), object.values()) |key, item| {
                gpa.free(key);
                freeValue(gpa, item);
            }
            var storage = object;
            storage.deinit(gpa);
        },
        else => {},
    }
}

fn check(comptime T: type) void {
    // As in the reflected codecs, a whole protocol can take more than the
    // default thousand steps. The walk still stops at recursive schemas.
    @setEvalBranchQuota(1_000_000);
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
            !info.attrs.@"volatile" and !info.attrs.@"allowzero" and (info.attrs.@"addrspace" orelse .generic) == .generic and
            safeSentinel(info) and canCopy(info.child, next),
        .optional => |info| canCopy(info.child, next),
        .array => |info| safeSentinel(info) and canCopy(info.child, next),
        .vector => |info| canCopy(info.child, next),
        .@"struct" => |info| result: {
            for (info.field_types, info.field_attrs) |Field, attrs| {
                if (!canCopy(Field, next) or (attrs.@"comptime" and hasPointers(Field, &.{}))) break :result false;
            }
            break :result true;
        },
        .@"union" => |info| result: {
            if (info.tag_type == null) break :result false;
            for (info.field_types) |Field| if (!canCopy(Field, next)) break :result false;
            break :result true;
        },
        else => false,
    };
}

// A sentinel is part of the type, so its value cannot be replaced with a
// new owning pointer. A null optional sentinel has no storage to copy.
fn safeSentinel(comptime info: anytype) bool {
    if (info.sentinel_ptr == null) return true;
    if (containsPointer(info.sentinel().?))
        @compileError("sentinels holding pointers have storage fixed by the type and cannot be copied by copyOwned");
    return true;
}

fn containsPointer(comptime value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .pointer => true,
        .optional => if (value) |item| containsPointer(item) else false,
        .array => for (value) |item| {
            if (containsPointer(item)) break true;
        } else false,
        .vector => |info| {
            const items: [info.len]info.child = value;
            return containsPointer(items);
        },
        .@"struct" => |info| result: {
            for (info.field_names) |name| if (containsPointer(@field(value, name))) break :result true;
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
            for (info.field_types) |Field| if (hasPointers(Field, next)) break :result true;
            break :result false;
        },
        else => false,
    };
}
