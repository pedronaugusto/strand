//! `json.go`: JSON read as Go's `encoding/json` reads it. The answers are Go
//! 1.27's for the matching Go types.
const std = @import("std");
const shakedown = @import("shakedown");
const core = @import("core.zig");
const json = @import("json.zig");

const testing = std.testing;
const go = json.go;

const ObjectError = struct {
    code: i64 = 0,
    message: []const u8 = "",
};
const Action = struct {
    href: []const u8 = "",
    header: core.Pairs([]const u8, []const u8) = .{ .items = &.{} },
    expires_in: i64 = 0,
    id: []const u8 = "",
    pub const strand = .{ .fields = .{ .id = .{ .skip_decode = true } } };
};
const Transfer = struct {
    oid: []const u8 = "",
    size: i64 = 0,
    authenticated: bool = false,
    actions: core.Pairs([]const u8, ?Action) = .{ .items = &.{} },
    @"error": ?ObjectError = null,
};
const Batch = struct {
    objects: []const ?Transfer = &.{},
    transfer: []const u8 = "",
};

fn batch(arena: std.mem.Allocator, input: []const u8) go.Error!Batch {
    return go.parseLeaky(Batch, arena, input, .{});
}

fn first(arena: std.mem.Allocator, input: []const u8) !Transfer {
    const b = try batch(arena, input);
    try testing.expectEqual(@as(usize, 1), b.objects.len);
    return b.objects[0].?;
}

test "a member is its field's by exact name, then by Go's folding" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("b", (try first(a, "{\"objects\":[{\"OID\":\"a\",\"oid\":\"b\",\"Size\":3}]}")).oid);
    try testing.expectEqual(@as(i64, 3), (try first(a, "{\"objects\":[{\"OID\":\"a\",\"oid\":\"b\",\"Size\":3}]}")).size);
    try testing.expectEqualStrings("z", (try first(a, "{\"objects\":[{\"Oid\":\"x\",\"oid\":\"y\",\"OID\":\"z\"}]}")).oid);
    // `ſ` folds with `s`; `İ` folds with no ASCII letter; `_` counts.
    const t = try first(a, "{\"Objects\":[{\"\u{17f}ize\":1,\"o\u{130}d\":\"z\",\"o_id\":\"q\"}]}");
    try testing.expectEqual(@as(i64, 1), t.size);
    try testing.expectEqualStrings("", t.oid);
    // A map's keys are its own: no folding.
    const d = try first(a, "{\"objects\":[{\"actions\":{\"Download\":{\"href\":\"x\"}}}]}");
    try testing.expectEqualStrings("Download", d.actions.items[0].key);
    // A field Go never reads (`json:"-"`) is not read.
    const s = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\",\"id\":\"i\"}}}]}");
    try testing.expectEqualStrings("", s.actions.items[0].value.?.id);
}

test "null leaves a value as it is and empties an optional, a slice and a map" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const t = try first(a, "{\"objects\":[{\"oid\":\"a\",\"oid\":null,\"size\":null,\"authenticated\":null}]}");
    try testing.expectEqualStrings("a", t.oid);
    try testing.expectEqual(@as(i64, 0), t.size);
    const n = try first(a, "{\"objects\":[{\"actions\":{\"download\":null}}]}");
    try testing.expect(n.actions.items[0].value == null);
    try testing.expect((try batch(a, "{\"objects\":[null]}")).objects[0] == null);
    try testing.expectEqual(@as(usize, 0), (try batch(a, "{\"objects\":[{}],\"objects\":null}")).objects.len);
    const h = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"header\":{\"B\":\"1\",\"B\":null}}}}]}");
    try testing.expectEqualStrings("", h.actions.items[0].value.?.header.items[0].value);
}

test "a member given twice is read into what the first left" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const e = try first(a, "{\"objects\":[{\"error\":{\"code\":1},\"error\":{\"message\":\"m\"}}]}");
    try testing.expectEqual(@as(i64, 1), e.@"error".?.code);
    try testing.expectEqualStrings("m", e.@"error".?.message);
    const m = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\"}},\"actions\":{\"upload\":{\"href\":\"y\"}}}]}");
    try testing.expectEqual(@as(usize, 2), m.actions.items.len);
    // A map's value is read afresh each time.
    const z = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\",\"expires_in\":5},\"download\":{\"href\":\"y\"}}}]}");
    try testing.expectEqual(@as(usize, 1), z.actions.items.len);
    try testing.expectEqual(@as(i64, 0), z.actions.items[0].value.?.expires_in);
    // A slice's elements are read into.
    const s = try batch(a, "{\"objects\":[{\"oid\":\"1\",\"size\":2},{\"oid\":\"3\"}],\"objects\":[{\"oid\":\"2\"}]}");
    try testing.expectEqual(@as(usize, 1), s.objects.len);
    try testing.expectEqualStrings("2", s.objects[0].?.oid);
    try testing.expectEqual(@as(i64, 2), s.objects[0].?.size);
}

test "numbers and kinds as Go's types take them" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqual(@as(i64, 0), (try first(a, "{\"objects\":[{\"size\":-0}]}")).size);
    for ([_][]const u8{ "1.0", "1e2", "\"3\"", "true" }) |bad| {
        const input = try a.print("{{\"objects\":[{{\"size\":{s}}}]}}", .{bad});
        try testing.expectError(error.UnexpectedType, batch(a, input));
    }
    try testing.expectError(error.NumberOutOfRange, batch(a, "{\"objects\":[{\"size\":9223372036854775808}]}"));
    try testing.expectError(error.UnexpectedType, batch(a, "{\"objects\":[{\"authenticated\":1}]}"));
    try testing.expectError(error.UnexpectedType, batch(a, "{\"transfer\":5}"));
    try testing.expectError(error.UnexpectedType, go.parseLeaky(struct { n: u8 = 0 }, a, "{\"n\":-0}", .{}));
    try testing.expectEqual(@as(f64, 1.5), (try go.parseLeaky(struct { f: f64 = 0 }, a, "{\"f\":1.5}", .{})).f);
    try testing.expectError(error.NumberOutOfRange, go.parseLeaky(struct { f: f64 = 0 }, a, "{\"f\":1e400}", .{}));
}

test "strings are made UTF-8 as Go makes them" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("\u{ff}\u{fffd}x", (try first(a, "{\"objects\":[{\"oid\":\"\\u00ff\\ud800x\"}]}")).oid);
    try testing.expectEqualStrings("bad\u{fffd}", (try first(a, "{\"objects\":[{\"oid\":\"bad\xff\"}]}")).oid);
    try testing.expectEqualStrings("\u{10000}\u{fffd}\u{fffd}A\x00", (try go.parseLeaky(struct { m: []const u8 = "" }, a, "{\"m\":\"\\ud800\\udc00\\udc00\\ud800A\\u0000\"}", .{})).m);
    try testing.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}", (try go.parseLeaky(struct { m: []const u8 = "" }, a, "{\"m\":\"\xed\xa0\x80\"}", .{})).m);
    // Outside a string a stray byte is still not JSON.
    try testing.expectError(error.SyntaxError, batch(a, "{\"objects\":[]}\xff"));
}

test "what follows the value: white space alone, or anything for a decoder" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectError(error.SyntaxError, batch(a, "{\"objects\":[]} trailing garbage"));
    const b = try go.parseLeaky(Batch, a, "{\"objects\":[]} trailing garbage", .{ .rest = .any });
    try testing.expectEqual(@as(usize, 0), b.objects.len);
}

pub const Stamp = struct {
    text: []const u8 = "zero",
    pub fn strandGoDecode(self: *Stamp, _: std.mem.Allocator, value: json.Value) go.MapError!void {
        switch (value) {
            .null_value => {},
            .string => |s| self.text = if (s.len == 0) return error.InvalidValue else s,
            else => return error.UnexpectedType,
        }
    }
};

test "a type of its own reads the value, null included" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const T = struct { at: Stamp = .{} };
    try testing.expectEqualStrings("zero", (try go.parseLeaky(T, a, "{\"at\":null}", .{})).at.text);
    try testing.expectEqualStrings("then", (try go.parseLeaky(T, a, "{\"AT\":\"then\"}", .{})).at.text);
    try testing.expectError(error.InvalidValue, go.parseLeaky(T, a, "{\"at\":\"\"}", .{}));
    var into: T = .{ .at = .{ .text = "kept" } };
    try go.parseIntoLeaky(T, a, "{\"other\":1}", &into, .{});
    try testing.expectEqualStrings("kept", into.at.text);
}

test "fuzz: any bytes are read into a type or refused, and a repaired text repairs to itself" {
    const examples = [_][]const u8{
        "{\"objects\":[{\"OID\":\"a\",\"size\":-0,\"actions\":{\"download\":{\"href\":\"x\",\"header\":{\"A\":null}}}}]}",
        "{\"objects\":[null],\"objects\":[{\"error\":{\"code\":1}}]} tail",
        "{\"transfer\":\"\\ud800\\udc00\\udc00\xff\xed\xa0\x80\"}",
    };
    const property = struct {
        fn holds(input: []const u8) !void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            // Refusing the bytes is an answer; only a crash is not.
            if (batch(a, input)) |_| {} else |_| {}
            var into: Batch = .{ .transfer = "kept" };
            // As above: any error is an answer.
            if (go.parseIntoLeaky(Batch, a, input, &into, .{ .rest = .any })) |_| {} else |_| {}
            const text = try go.repaired(a, input);
            try testing.expectEqualStrings(text, try go.repaired(a, text));
        }
        fn body(_: void, case: *shakedown.Case) !void {
            var buffer: [160]u8 = undefined;
            try holds(shakedown.gen.mutated(case.source, &buffer, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try shakedown.check(testing.allocator, {}, property.body, .{});
}
