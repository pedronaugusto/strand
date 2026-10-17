//! `json.schema`: what is derived for each shape, and a property holding
//! every value strand writes for a type to the schema derived for it.
const std = @import("std");
const aegis = @import("aegis");
const shake = @import("shakedown");
const json = @import("json.zig");
const checker = @import("testing/json_schema.zig");

const testing = std.testing;
const schema = json.schema;

fn expectSchema(comptime T: type, comptime options: schema.Options, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, comptime schema.of(T, options));
}

const bare: schema.Options = .{ .dialect = false };

test "scalars: booleans, integers with their width's bounds, numbers, text" {
    try expectSchema(bool, bare, "{\"type\":\"boolean\"}");
    try expectSchema(u8, bare, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}");
    try expectSchema(i64, bare, "{\"type\":\"integer\",\"minimum\":-9223372036854775808,\"maximum\":9223372036854775807}");
    try expectSchema(f64, bare, "{\"type\":\"number\"}");
    try expectSchema([]const u8, bare, "{\"type\":\"string\"}");
    try expectSchema(?[]const u8, bare, "{\"type\":[\"string\",\"null\"]}");
    try expectSchema(enum { low, high }, bare, "{\"type\":\"string\",\"enum\":[\"low\",\"high\"]}");
}

test "the root names its dialect" {
    try expectSchema(bool, .{}, "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"boolean\"}");
}

const Search = struct {
    query: []const u8,
    limit: u16 = 10,
    language: ?Language = null,
    tags: []const []const u8 = &.{},

    const Language = enum { zig, rust };
    pub const strand = .{
        .description = "Search the index",
        .fields = .{
            .query = .{ .description = "What to look for" },
            .limit = .{ .range = .{ .min = 1, .max = 100 } },
        },
    };
};

test "a record: its fields as properties, the ones without a default required, nothing else taken" {
    try expectSchema(Search, bare, "{\"type\":\"object\",\"description\":\"Search the index\",\"properties\":{" ++
        "\"query\":{\"type\":\"string\",\"description\":\"What to look for\"}," ++
        "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100}," ++
        "\"language\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"zig\",\"rust\"]},{\"type\":\"null\"}]}," ++
        "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}," ++
        "\"required\":[\"query\"],\"additionalProperties\":false}");
}

test "written, every field that is always written is required; ignoring unknown fields opens the object" {
    try expectSchema(Search, .{ .dialect = false, .direction = .encode }, "{\"type\":\"object\",\"description\":\"Search the index\",\"properties\":{" ++
        "\"query\":{\"type\":\"string\",\"description\":\"What to look for\"}," ++
        "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100}," ++
        "\"language\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"zig\",\"rust\"]},{\"type\":\"null\"}]}," ++
        "\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}," ++
        "\"required\":[\"query\",\"limit\",\"tags\"],\"additionalProperties\":false}");
    const Point = struct { x: i8 };
    try expectSchema(Point, .{ .dialect = false, .ignore_unknown_fields = true }, "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127}},\"required\":[\"x\"]}");
}

const Renamed = struct {
    user_name: []const u8,
    pub const strand = .{ .rename_all = .camel_case, .fields = .{ .user_name = .{ .aliases = &.{"login"} } } };
};

test "names as written: casing, and aliases read but never written" {
    try expectSchema(Renamed, bare, "{\"type\":\"object\",\"properties\":{\"userName\":{\"type\":\"string\"},\"login\":{\"type\":\"string\"}},\"allOf\":[{\"anyOf\":[{\"required\":[\"userName\"]},{\"required\":[\"login\"]}]}],\"additionalProperties\":false}");
    try expectSchema(Renamed, .{ .dialect = false, .direction = .encode }, "{\"type\":\"object\",\"properties\":{\"userName\":{\"type\":\"string\"}},\"required\":[\"userName\"],\"additionalProperties\":false}");
}

test "arrays, tuples and nothing" {
    try expectSchema([3]u8, bare, "{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"minItems\":3,\"maxItems\":3}");
    try expectSchema(struct { bool, []const u8 }, bare, "{\"type\":\"array\",\"prefixItems\":[{\"type\":\"boolean\"},{\"type\":\"string\"}],\"items\":false,\"minItems\":2,\"maxItems\":2}");
    try expectSchema(void, bare, "{\"type\":\"object\",\"maxProperties\":0}");
}

const Shape = union(enum) {
    circle: struct { radius: f32 },
    dot,
};
const Tagged = union(enum) {
    circle: struct { radius: f32 },
    dot,
    pub const strand = .{ .tag = "kind" };
};
const Adjacent = union(enum) {
    count: u8,
    pub const strand = .{ .tag = "t", .content = "c" };
};

test "unions: external tags by default, internal and adjacent as declared" {
    try expectSchema(Shape, bare, "{\"oneOf\":[" ++
        "{\"type\":\"object\",\"properties\":{\"circle\":{\"type\":\"object\",\"properties\":{\"radius\":{\"type\":\"number\"}},\"required\":[\"radius\"],\"additionalProperties\":false}},\"required\":[\"circle\"],\"additionalProperties\":false}," ++
        "{\"type\":\"object\",\"properties\":{\"dot\":{\"type\":\"object\",\"maxProperties\":0}},\"required\":[\"dot\"],\"additionalProperties\":false}]}");
    try expectSchema(Tagged, bare, "{\"oneOf\":[" ++
        "{\"type\":\"object\",\"properties\":{\"kind\":{\"const\":\"circle\"},\"radius\":{\"type\":\"number\"}},\"required\":[\"kind\",\"radius\"],\"additionalProperties\":false}," ++
        "{\"type\":\"object\",\"properties\":{\"kind\":{\"const\":\"dot\"}},\"required\":[\"kind\"],\"additionalProperties\":false}]}");
    try expectSchema(Adjacent, bare, "{\"oneOf\":[{\"type\":\"object\",\"properties\":{\"t\":{\"const\":\"count\"},\"c\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"required\":[\"t\",\"c\"],\"additionalProperties\":false}]}");
}

const Tree = struct {
    name: []const u8,
    children: []const Tree = &.{},
};
const Forest = struct { trees: []const Tree };

test "a type that holds itself is written once and referred to" {
    try expectSchema(Tree, bare, "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#\"}}},\"required\":[\"name\"],\"additionalProperties\":false}");
    try expectSchema(Forest, bare, "{\"type\":\"object\",\"properties\":{\"trees\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Tree\"}}},\"required\":[\"trees\"],\"additionalProperties\":false," ++
        "\"$defs\":{\"Tree\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"children\":{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/Tree\"}}},\"required\":[\"name\"],\"additionalProperties\":false}}}");
}

const Limits = struct {
    timeout: aegis.units.Duration(.millisecond, u32),
    retries: aegis.int.Ranged(u8, 1, 5),
    payload: json.Raw = .null,
    extra: json.Value = .null_value,
};

test "aegis scalars as what they hold; Raw and Value admit anything" {
    try expectSchema(Limits, bare, "{\"type\":\"object\",\"properties\":{\"timeout\":{\"type\":\"string\"},\"retries\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":5},\"payload\":true,\"extra\":true},\"required\":[\"timeout\",\"retries\"],\"additionalProperties\":false}");
}

test "the derived schema is JSON" {
    inline for (.{ Search, Renamed, Shape, Tagged, Adjacent, Tree, Forest, Limits }) |T| {
        var parsed = try json.parse(json.Value, testing.allocator, comptime schema.of(T, .{}), .{});
        defer parsed.deinit();
    }
}

/// Every value strand writes for `T` matches both schemas derived for it:
/// what is written, and what is read (what is written is read back).
fn written(comptime T: type) fn (void, *shake.Case) anyerror!void {
    return struct {
        fn body(_: void, c: *shake.Case) anyerror!void {
            const value = try shake.gen.any(c.source, T, c.gpa);
            var out: std.Io.Writer.Allocating = .init(c.gpa);
            json.write(&out.writer, value, .{}) catch |err| switch (err) {
                // Values JSON cannot hold: bytes that are not UTF-8, NaN.
                error.InvalidUtf8, error.UnsupportedValue, error.NumberOutOfRange => return,
                else => return err,
            };
            const instance = try json.parseLeaky(json.Value, c.gpa, out.written(), .{});
            inline for (.{ schema.Direction.encode, schema.Direction.decode }) |direction| {
                const text = comptime schema.of(T, .{ .direction = direction });
                const root = try json.parseLeaky(json.Value, c.gpa, text, .{});
                checker.check(root, root, instance) catch |err| {
                    c.note("{t}: {s} against {s}", .{ direction, out.written(), text });
                    return err;
                };
            }
        }
    }.body;
}

test "every value written for a type matches the schema derived for it" {
    inline for (.{ Search, Shape, Tagged, Adjacent, Tree, Forest, struct { bool, ?i32, [2]f64 } }) |T| {
        try shake.check(testing.allocator, {}, written(T), .{ .cases = 300 });
    }
}

test "what the schema refuses, the parser refuses" {
    const text = comptime schema.of(Search, .{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try json.parseLeaky(json.Value, a, text, .{});
    for ([_][]const u8{ "{}", "{\"query\":1}", "{\"query\":\"x\",\"other\":1}", "{\"query\":\"x\",\"limit\":0}", "{\"query\":\"x\",\"language\":\"go\"}" }) |bad| {
        const instance = try json.parseLeaky(json.Value, a, bad, .{});
        try testing.expectError(error.Mismatch, checker.check(s, s, instance));
        if (json.parseLeaky(Search, a, bad, .{})) |_| return error.TestUnexpectedResult else |_| {}
    }
}
