//! A checked copy of a parsed value into an owner of its own, through the
//! public API: what `keep` returns.
const std = @import("std");
const strand = @import("strand.zig");
const core = strand.core;
const json = strand.json;
const testing = std.testing;
const shakedown = @import("shakedown");

// Compare the data and every allocation.
fn independent(source: anytype, copy: @TypeOf(source)) anyerror!void {
    const T = @TypeOf(source);
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => {
                if (@sizeOf(info.child) != 0) try testing.expect(source != copy);
                try independent(source.*, copy.*);
            },
            .slice => {
                try testing.expectEqual(source.len, copy.len);
                if (@sizeOf(info.child) != 0 and (source.len != 0 or info.sentinel_ptr != null))
                    try testing.expect(source.ptr != copy.ptr);
                for (source, copy) |from, to| try independent(from, to);
                if (info.sentinel_ptr != null) try testing.expectEqual(source[source.len], copy[copy.len]);
            },
            else => unreachable,
        },
        .@"struct" => |info| inline for (info.field_names, info.field_attrs) |field_name, attrs| {
            if (!attrs.@"comptime") try independent(@field(source, field_name), @field(copy, field_name));
        },
        .array => for (source, copy) |from, to| try independent(from, to),
        .optional => {
            try testing.expectEqual(source == null, copy == null);
            if (source) |item| try independent(item, copy.?);
        },
        .@"union" => {
            try testing.expectEqual(std.meta.activeTag(source), std.meta.activeTag(copy));
            switch (source) {
                inline else => |item, tag| try independent(item, @field(copy, @tagName(tag))),
            }
        },
        else => try testing.expectEqualDeep(source, copy),
    }
}

fn copyAndFree(allocator: std.mem.Allocator, source: anytype) !void {
    var copy = try core.clone(allocator, source, .{});
    defer copy.deinit();
    try independent(source, copy.value);
}

fn allocationFailures(source: anytype) !void {
    const T = @TypeOf(source);
    const Case = struct {
        fn run(allocator: std.mem.Allocator, value: T) !void {
            try copyAndFree(allocator, value);
        }
    };
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), Case.run, .{source});
}

test "a copy outlives the input and the parse arena, Raw included" {
    const T = struct {
        text: []const u8,
        escaped: []const u8,
        rows: []const struct { words: [2][]const u8 },
        maybe: ?[]const u8,
        absent: ?[]const u8,
        arm: union(enum) { words: []const u8, none },
        raw: json.Raw,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var input = "{\"text\":\"borrowed\",\"escaped\":\"es\\u0063aped\",\"rows\":[{\"words\":[\"one\",\"two\"]}],\"maybe\":\"yes\",\"absent\":null,\"arm\":{\"words\":\"arm\"},\"raw\":{ \"n\": 2.50 }}".*;
    const source = json.parseLeaky(T, arena.allocator(), &input, .{}) catch |err| {
        arena.deinit();
        return err;
    };
    var copy = core.clone(testing.allocator, source, .{}) catch |err| {
        arena.deinit();
        return err;
    };
    defer copy.deinit();
    try testing.expect(copy.value.text.ptr != source.text.ptr);
    try testing.expect(copy.value.escaped.ptr != source.escaped.ptr);
    try testing.expect(copy.value.rows.ptr != source.rows.ptr);
    try testing.expect(copy.value.rows[0].words[0].ptr != source.rows[0].words[0].ptr);
    try testing.expect(copy.value.maybe.?.ptr != source.maybe.?.ptr);
    try testing.expect(copy.value.arm.words.ptr != source.arm.words.ptr);
    try testing.expect(copy.value.raw.bytes.ptr != source.raw.bytes.ptr);
    arena.deinit();
    @memset(&input, 'X');
    try testing.expectEqualStrings("borrowed", copy.value.text);
    try testing.expectEqualStrings("escaped", copy.value.escaped);
    try testing.expectEqualStrings("one", copy.value.rows[0].words[0]);
    try testing.expectEqualStrings("two", copy.value.rows[0].words[1]);
    try testing.expectEqualStrings("yes", copy.value.maybe.?);
    try testing.expectEqual(@as(?[]const u8, null), copy.value.absent);
    try testing.expectEqualStrings("arm", copy.value.arm.words);
    try testing.expectEqualStrings("{ \"n\": 2.50 }", copy.value.raw.bytes);
}

test "a copy covers parsed shapes and releases everything on every allocation failure" {
    const T = struct {
        tuple: struct { []const u8, u32 },
        array: [2]struct { words: []const []const u8 },
        slices: []const ?union(enum) { words: []const u8, none },
        sentinel: [:0]const u8,
        sentinel_array: [2:0]u8,
        pointer: *const struct { text: []const u8 },
        empty: []const []const u8,
        raw: json.Raw,
        number: i128,
        real: f64,
        flag: bool,
        tag: enum { first, second },
        vector: @Vector(2, u32),
        default: []const u8 = "default",
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try json.parseLeaky(T, arena.allocator(),
        \\{"tuple":["tuple",3],"array":[{"words":["a","b"]},{"words":["c"]}],
        \\ "slices":[null,{"words":"word"},{"none":{}}],"sentinel":"end",
        \\ "sentinel_array":[1,2],"pointer":{"text":"pointed"},"empty":[],
        \\ "raw":[ 1, 2.00 ],"number":12345678901234567890,"real":1.25,
        \\ "flag":true,"tag":"second","vector":[4,5]}
    , .{});
    try allocationFailures(source);
}

test "a dynamic value is copied into storage of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try json.parseLeaky(json.Value, arena.allocator(),
        \\{"text":"value","numbers":[1,-2.5,1234567890123456789012345678901234567890],
        \\ "flags":[true,false,null],"nested":{"key":[{"another":"text"}]},"object":{},"array":[]}
    , .{});
    try allocationFailures(source);
}

test "a copy keeps alignment, empty sentinels and repeated references apart" {
    const T = struct {
        bytes: []align(32) const u8,
        ptr: *align(32) const u8,
        empty: [:0]const u8,
        sentinel: [:99]const u16,
        array: [2:0]u8,
        again: []const u8,
    };
    const bytes: [3]u8 align(32) = .{ 1, 2, 3 };
    const nums: [2:99]u16 = .{ 4, 5 };
    const source: T = .{ .bytes = &bytes, .ptr = &bytes[0], .empty = "", .sentinel = &nums, .array = .{ 6, 7 }, .again = &bytes };
    try allocationFailures(source);
    var copy = try core.clone(testing.allocator, source, .{});
    defer copy.deinit();
    try testing.expect(copy.value.bytes.ptr != copy.value.again.ptr);
    try testing.expect(copy.value.ptr != &copy.value.bytes[0]);
    try testing.expect(std.mem.isAligned(@intFromPtr(copy.value.bytes.ptr), 32));
}

test "a copy walks recursive schemas and constant fields" {
    const Node = struct {
        pub const Self = @This();
        text: []const u8,
        children: []const Self,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try json.parseLeaky(Node, arena.allocator(), "{\"text\":\"root\",\"children\":[{\"text\":\"leaf\",\"children\":[]}]}", .{});
    try allocationFailures(source);
    try copyAndFree(testing.allocator, @as(?[]const u8, null));
    try copyAndFree(testing.allocator, @as(union(enum) { none, words: []const u8 }, .none));
    try copyAndFree(testing.allocator, @as([0][]const u8, .{}));
    const Constant = struct { text: []const u8, comptime number: u32 = 7 };
    try allocationFailures(Constant{ .text = "constant" });
    const Packed = packed struct { bits: u3, flag: bool };
    try copyAndFree(testing.allocator, Packed{ .bits = 5, .flag = true });
}

test "a copy accepts a full protocol schema" {
    const Leaf = struct { text: []const u8, rows: []const struct { text: []const u8 } };
    const T = @Tuple(&@as([64]type, @splat(Leaf)));
    var source: T = undefined;
    inline for (0..64) |i| source[i] = .{ .text = "protocol", .rows = &.{.{ .text = "row" }} };
    try copyAndFree(testing.allocator, source);
}

test "a copy is held to its limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source: []const []const u8 = &.{ "one", "two", "three" };
    try testing.expectError(error.AllocationLimit, core.clone(testing.allocator, source, .{ .allocation_bytes = 16 }));
}
