const std = @import("std");
const strand = @import("strand.zig");
const testing = std.testing;

// Compare the data and every allocation, including dynamic object keys.
fn independent(source: anytype, copy: @TypeOf(source)) anyerror!void {
    const T = @TypeOf(source);
    if (T == std.json.Value) {
        try testing.expectEqual(std.meta.activeTag(source), std.meta.activeTag(copy));
        switch (source) {
            .array => |array| {
                try independent(array.items, copy.array.items);
                try testing.expect(copy.array.allocator.ptr != array.allocator.ptr);
            },
            .object => |object| {
                try independent(object.keys(), copy.object.keys());
                try independent(object.values(), copy.object.values());
            },
            inline else => |item, tag| try independent(item, @field(copy, @tagName(tag))),
        }
        return;
    }
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
        .@"struct" => |info| inline for (info.fields) |field| {
            try independent(@field(source, field.name), @field(copy, field.name));
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
    const copy = try strand.copyOwned(allocator, source);
    defer strand.freeOwned(allocator, copy);
    try independent(source, copy);
}

test "owned copy outlives the input and parse arena, including Raw" {
    const T = struct {
        text: []const u8,
        escaped: []const u8,
        rows: []const struct { words: [2][]const u8 },
        maybe: ?[]const u8,
        absent: ?[]const u8,
        arm: union(enum) { words: []const u8, none },
        raw: strand.Raw,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    var input = "{\"text\":\"borrowed\",\"escaped\":\"es\\u0063aped\",\"rows\":[{\"words\":[\"one\",\"two\"]}],\"maybe\":\"yes\",\"absent\":null,\"arm\":{\"words\":\"arm\"},\"raw\":{ \"n\": 2.50 }}".*;
    const source = try strand.parseLine(T, arena.allocator(), &input, .{});
    const copy = strand.copyOwned(testing.allocator, source) catch |err| {
        arena.deinit();
        return err;
    };
    defer strand.freeOwned(testing.allocator, copy);
    try testing.expect(copy.text.ptr != source.text.ptr);
    try testing.expect(copy.escaped.ptr != source.escaped.ptr);
    try testing.expect(copy.rows.ptr != source.rows.ptr);
    try testing.expect(copy.rows[0].words[0].ptr != source.rows[0].words[0].ptr);
    try testing.expect(copy.rows[0].words[1].ptr != source.rows[0].words[1].ptr);
    try testing.expect(copy.maybe.?.ptr != source.maybe.?.ptr);
    try testing.expect(copy.arm.words.ptr != source.arm.words.ptr);
    try testing.expect(copy.raw.bytes.ptr != source.raw.bytes.ptr);
    arena.deinit();
    @memset(&input, 'X');
    try testing.expectEqualStrings("borrowed", copy.text);
    try testing.expectEqualStrings("escaped", copy.escaped);
    try testing.expectEqualStrings("one", copy.rows[0].words[0]);
    try testing.expectEqualStrings("two", copy.rows[0].words[1]);
    try testing.expectEqualStrings("yes", copy.maybe.?);
    try testing.expectEqual(@as(?[]const u8, null), copy.absent);
    try testing.expectEqualStrings("arm", copy.arm.words);
    try testing.expectEqualStrings("{ \"n\": 2.50 }", copy.raw.bytes);
}

test "owned copy covers parsed shapes and every allocation failure" {
    const T = struct {
        tuple: struct { []const u8, u32 },
        array: [2]struct { words: []const []const u8 },
        slices: []const ?union(enum) { words: []const u8, none },
        sentinel: [:0]const u8,
        sentinel_array: [2:0]u8,
        pointer: *const struct { text: []const u8 },
        empty: []const []const u8,
        raw: strand.Raw,
        number: i128,
        real: f64,
        flag: bool,
        tag: enum { first, second },
        vector: @Vector(2, u32),
        default: []const u8 = "default",
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try strand.parseLine(T, arena.allocator(),
        \\{"tuple":["tuple",3],"array":[{"words":["a","b"]},{"words":["c"]}],
        \\ "slices":[null,{"words":"word"},{"none":{}}],"sentinel":"end",
        \\ "sentinel_array":[1,2],"pointer":{"text":"pointed"},"empty":[],
        \\ "raw":[ 1, 2.00 ],"number":12345678901234567890,"real":1.25,
        \\ "flag":true,"tag":"second","vector":[4,5]}
    , .{});
    try allocationFailures(source);
}

test "owned copy gives every std.json.Value arm independent storage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"text":"value","numbers":[1,-2.5,1234567890123456789012345678901234567890],
        \\ "flags":[true,false,null],"nested":{"key":[{"another":"text"}]},"object":{},"array":[]}
    , .{});
    try allocationFailures(source);
    const numbers = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "[1.00,2e+3]", .{ .parse_numbers = false });
    try allocationFailures(numbers);
}

test "owned copy's dynamic containers live and grow after the source arena is gone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    const source = strand.parseLine(std.json.Value, arena.allocator(), "{\"items\":[\"kept\"]}", .{}) catch |err| {
        arena.deinit();
        return err;
    };
    var copy = strand.copyOwned(testing.allocator, source) catch |err| {
        arena.deinit();
        return err;
    };
    defer strand.freeOwned(testing.allocator, copy);
    arena.deinit();
    const items = copy.object.getPtr("items").?;
    try testing.expectEqualStrings("kept", items.array.items[0].string);
    try testing.expectEqual(testing.allocator.ptr, items.array.allocator.ptr);
    for (0..50) |i| try items.array.append(.{ .integer = @intCast(i) });
    try testing.expectEqual(@as(i64, 49), items.array.items[50].integer);
    try copy.object.put(testing.allocator, try testing.allocator.dupe(u8, "new"), .null);
    try testing.expect(copy.object.contains("new"));
}

test "owned copy preserves mutable storage, alignment, empty sentinels and repeated references" {
    const T = struct {
        bytes: []align(32) u8,
        ptr: *align(32) u8,
        empty: [:0]const u8,
        sentinel: [:99]const u16,
        array: [2:0]u8,
        again: []const u8,
    };
    var bytes: [3]u8 align(32) = .{ 1, 2, 3 };
    var nums: [2:99]u16 = .{ 4, 5 };
    const source: T = .{ .bytes = &bytes, .ptr = &bytes[0], .empty = "", .sentinel = &nums, .array = .{ 6, 7 }, .again = &bytes };
    try allocationFailures(source);
    const copy = try strand.copyOwned(testing.allocator, source);
    defer strand.freeOwned(testing.allocator, copy);
    try testing.expect(copy.bytes.ptr != copy.again.ptr);
    try testing.expect(copy.ptr != &copy.bytes[0]);
    copy.bytes[0] = 9;
    copy.ptr.* = 8;
    try testing.expectEqual(@as(u8, 1), bytes[0]);
    try testing.expectEqual(@as(u8, 1), copy.again[0]);
}

test "owned copy walks recursive schemas and ignores JSON hooks" {
    const Node = struct { text: []const u8, children: []const @This() };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try strand.parseLine(Node, arena.allocator(), "{\"text\":\"root\",\"children\":[{\"text\":\"leaf\",\"children\":[]}]}", .{});
    try allocationFailures(source);
    const Hooks = struct {
        text: []const u8,
        pub fn jsonParse(_: std.mem.Allocator, _: anytype, _: std.json.ParseOptions) !@This() {
            return error.UnexpectedToken;
        }
        pub fn jsonStringify(_: @This(), _: anytype) !void {
            return error.WriteFailed;
        }
    };
    try allocationFailures(Hooks{ .text = "unchanged" });
    try copyAndFree(testing.allocator, @as(?[]const u8, null));
    try copyAndFree(testing.allocator, @as(union(enum) { none, words: []const u8 }, .none));
    try copyAndFree(testing.allocator, @as(enum(u8) { known = 1, _ }, @enumFromInt(42)));
    try copyAndFree(testing.allocator, @as([0][]const u8, .{}));
    const Constant = struct { text: []const u8, comptime number: u32 = 7 };
    try allocationFailures(Constant{ .text = "constant" });
    const Packed = packed struct { bits: u3, flag: bool };
    try copyAndFree(testing.allocator, Packed{ .bits = 5, .flag = true });
}

test "owned copy preserves null sentinels around optional pointers" {
    const T = [:null]const ?*const struct { text: []const u8 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = try strand.parseLine(T, arena.allocator(), "[{\"text\":\"word\"},null]", .{});
    try allocationFailures(source);
    const array: [1:null]?*const u32 = .{null};
    try copyAndFree(testing.allocator, array);
}

fn allocationFailures(source: anytype) !void {
    const T = @TypeOf(source);
    const Case = struct {
        fn run(allocator: std.mem.Allocator, value: T) !void {
            try copyAndFree(allocator, value);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{source});
}
