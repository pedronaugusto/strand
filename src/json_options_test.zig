//! JSON's reading choices beyond the strict defaults: names by case folding, a
//! member given twice merged, `null` keeping a value, integers by their
//! digits, text that is not Unicode as U+FFFD, and one value read off the front
//! of its input. Together they read as Go's `encoding/json` reads into the
//! matching Go type; the answers here are Go 1.27's.
const std = @import("std");
const shakedown = @import("shakedown");
const core = @import("core.zig");
const json = @import("json.zig");

const testing = std.testing;

/// What Go's `encoding/json` reads as.
const lenient: json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicates = .merge,
    .names = .fold_case,
    .nulls = .keep,
    .integers = .digits,
    .invalid_unicode = .replace,
};

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

fn batch(arena: std.mem.Allocator, input: []const u8) json.ParseError(Batch)!Batch {
    return json.parseLeaky(Batch, arena, input, lenient);
}

fn first(arena: std.mem.Allocator, input: []const u8) !Transfer {
    const b = try batch(arena, input);
    try testing.expectEqual(@as(usize, 1), b.objects.len);
    return b.objects[0].?;
}

test "a member finds its field by exact name, then by case folding" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("b", (try first(a, "{\"objects\":[{\"OID\":\"a\",\"oid\":\"b\",\"Size\":3}]}")).oid);
    try testing.expectEqual(@as(i64, 3), (try first(a, "{\"objects\":[{\"OID\":\"a\",\"oid\":\"b\",\"Size\":3}]}")).size);
    try testing.expectEqualStrings("z", (try first(a, "{\"objects\":[{\"Oid\":\"x\",\"oid\":\"y\",\"OID\":\"z\"}]}")).oid);
    // `ſ` folds with `s` and the Kelvin sign with `k`; `İ` folds with no
    // ASCII letter; `_` counts.
    const t = try first(a, "{\"Objects\":[{\"\u{17f}ize\":1,\"o\u{130}d\":\"z\",\"o_id\":\"q\"}]}");
    try testing.expectEqual(@as(i64, 1), t.size);
    try testing.expectEqualStrings("", t.oid);
    const K = struct { kind: u8 = 0 };
    try testing.expectEqual(@as(u8, 4), (try json.parseLeaky(K, a, "{\"\u{212a}IND\":4}", .{ .names = .fold_case })).kind);
    // A map's keys are its own: no folding.
    const d = try first(a, "{\"objects\":[{\"actions\":{\"Download\":{\"href\":\"x\"}}}]}");
    try testing.expectEqualStrings("Download", d.actions.items[0].key);
    // A field never read is not read under any name.
    const s = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\",\"ID\":\"i\"}}}]}");
    try testing.expectEqualStrings("", s.actions.items[0].value.?.id);
    // By default a name is exact.
    try testing.expectError(error.UnknownField, json.parseLeaky(K, a, "{\"KIND\":4}", .{}));
    try testing.expectEqual(@as(u8, 0), (try json.parseLeaky(K, a, "{\"KIND\":4}", .{ .ignore_unknown_fields = true })).kind);
    // A letter outside ASCII folds as Unicode's simple folding has it, as
    // Go's `encoding/json` matches it: `É` with `é`, the three sigmas with
    // one another; `ß` folds to no `ss` (that is full folding).
    const E = struct {
        name: u8 = 0,
        sigma: u8 = 0,
        strasse: u8 = 0,
        pub const strand = .{ .fields = .{
            .name = .{ .name = "\u{e9}t\u{e9}" },
            .sigma = .{ .name = "\u{3c3}" },
            .strasse = .{ .name = "stra\u{df}e" },
        } };
    };
    try testing.expectEqual(@as(u8, 1), (try json.parseLeaky(E, a, "{\"\u{e9}T\u{e9}\":1}", .{ .names = .fold_case })).name);
    try testing.expectEqual(@as(u8, 2), (try json.parseLeaky(E, a, "{\"\u{c9}T\u{c9}\":2}", .{ .names = .fold_case })).name);
    try testing.expectEqual(@as(u8, 3), (try json.parseLeaky(E, a, "{\"\u{3a3}\":3}", .{ .names = .fold_case })).sigma);
    try testing.expectEqual(@as(u8, 4), (try json.parseLeaky(E, a, "{\"\u{3c2}\":4}", .{ .names = .fold_case })).sigma);
    try testing.expectEqual(@as(u8, 5), (try json.parseLeaky(E, a, "{\"STRA\u{df}E\":5}", .{ .names = .fold_case })).strasse);
    try testing.expectError(error.UnknownField, json.parseLeaky(E, a, "{\"STRASSE\":6}", .{ .names = .fold_case }));
}

test "null keeps a value as it is and empties an optional, a sequence and a map" {
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
    // A map's value read fresh is its type's zero.
    const h = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"header\":{\"B\":\"1\",\"B\":null}}}}]}");
    try testing.expectEqualStrings("", h.actions.items[0].value.?.header.items[0].value);
    // A record's field keeps its default; an element read fresh is its zero.
    const D = struct { port: u16 = 22, list: []const u32 = &.{7}, codes: []const u32 = &.{} };
    const kept = try json.parseLeaky(D, a, "{\"port\":null,\"list\":null,\"codes\":[null,1]}", .{ .nulls = .keep });
    try testing.expectEqual(@as(u16, 22), kept.port);
    try testing.expectEqual(@as(usize, 0), kept.list.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, kept.codes);
    // At the root, a type's zero; a type with none still refuses null.
    try testing.expectEqualStrings("", (try json.parseLeaky(Batch, a, "null", lenient)).transfer);
    const Mode = enum { on, off };
    try testing.expectError(error.UnexpectedType, json.parseLeaky([]const Mode, a, "[null]", .{ .nulls = .keep }));
    // By default null is no value of a type without one.
    try testing.expectError(error.UnexpectedType, json.parseLeaky(D, a, "{\"port\":null}", .{}));
}

test "a type that holds null itself reads it; one with its own reading keeps its value" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const T = struct {
        raw: json.Raw = .null,
        value: json.Value = .{ .boolean = true },
        stamp: Stamp = .{},
    };
    const t = try json.parseLeaky(T, a, "{\"raw\":null,\"value\":null,\"stamp\":null}", .{ .nulls = .keep });
    try testing.expectEqualStrings("null", t.raw.bytes);
    try testing.expect(t.value == .null_value);
    try testing.expectEqualStrings("zero", t.stamp.text);
    const merged = try json.parseLeaky(T, a, "{\"stamp\":\"then\",\"stamp\":null}", lenient);
    try testing.expectEqualStrings("then", merged.stamp.text);
    // A type of its own is read afresh when its member comes again.
    const again = try json.parseLeaky(T, a, "{\"stamp\":\"then\",\"STAMP\":\"now\"}", lenient);
    try testing.expectEqualStrings("now", again.stamp.text);
}

/// A type with a reading of its own: a non-empty string.
pub const Stamp = struct {
    text: []const u8 = "zero",
    pub fn strandDeserialize(access: anytype) (@TypeOf(access.*).Error || error{EmptyStamp})!Stamp {
        const text = try access.read([]const u8);
        if (text.len == 0) return error.EmptyStamp;
        return .{ .text = text };
    }
};

test "a member given twice is read into what the first left" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const e = try first(a, "{\"objects\":[{\"error\":{\"code\":1},\"error\":{\"message\":\"m\"}}]}");
    try testing.expectEqual(@as(i64, 1), e.@"error".?.code);
    try testing.expectEqualStrings("m", e.@"error".?.message);
    const m = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\"}},\"actions\":{\"upload\":{\"href\":\"y\"}}}]}");
    try testing.expectEqual(@as(usize, 2), m.actions.items.len);
    // A map's key given again takes its later value, read afresh.
    const z = try first(a, "{\"objects\":[{\"actions\":{\"download\":{\"href\":\"x\",\"expires_in\":5},\"download\":{\"href\":\"y\"}}}]}");
    try testing.expectEqual(@as(usize, 1), z.actions.items.len);
    try testing.expectEqual(@as(i64, 0), z.actions.items[0].value.?.expires_in);
    // A sequence's elements are read into by position.
    const s = try batch(a, "{\"objects\":[{\"oid\":\"1\",\"size\":2},{\"oid\":\"3\"}],\"objects\":[{\"oid\":\"2\"}]}");
    try testing.expectEqual(@as(usize, 1), s.objects.len);
    try testing.expectEqualStrings("2", s.objects[0].?.oid);
    try testing.expectEqual(@as(i64, 2), s.objects[0].?.size);
    // An array's too.
    const A = struct { pair: [2]struct { x: u8 = 0, y: u8 = 0 } = .{ .{}, .{} } };
    const p = try json.parseLeaky(A, a, "{\"pair\":[{\"x\":1},{\"y\":2}],\"pair\":[{\"y\":3},{}]}", .{ .duplicates = .merge });
    try testing.expectEqual(@as(u8, 1), p.pair[0].x);
    try testing.expectEqual(@as(u8, 3), p.pair[0].y);
    try testing.expectEqual(@as(u8, 2), p.pair[1].y);
}

test "a member given twice: refused by default, or the first, the last, or as its type declares" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const P = struct { p: struct { x: u8 = 0, y: u8 = 0 } = .{} };
    const input = "{\"p\":{\"x\":1},\"p\":{\"y\":2}}";
    try testing.expectError(error.DuplicateField, json.parseLeaky(P, a, input, .{}));
    try testing.expectEqual(@as(u8, 1), (try json.parseLeaky(P, a, input, .{ .duplicates = .first })).p.x);
    const last = try json.parseLeaky(P, a, input, .{ .duplicates = .last });
    try testing.expectEqual(@as(u8, 0), last.p.x);
    try testing.expectEqual(@as(u8, 2), last.p.y);
    const Merging = struct {
        p: struct { x: u8 = 0, y: u8 = 0 } = .{},
        pub const strand = .{ .duplicates = .merge };
    };
    const declared = try json.parseLeaky(Merging, a, input, .{ .duplicates = null });
    try testing.expectEqual(@as(u8, 1), declared.p.x);
    try testing.expectEqual(@as(u8, 2), declared.p.y);
    // A map's keys: refused, or the first or the last.
    const M = core.Pairs([]const u8, u8);
    try testing.expectError(error.DuplicateField, json.parseLeaky(M, a, "{\"k\":1,\"k\":2}", .{}));
    try testing.expectEqual(@as(u8, 1), (try json.parseLeaky(M, a, "{\"k\":1,\"k\":2}", .{ .duplicates = .first })).items[0].value);
    try testing.expectEqual(@as(u8, 2), (try json.parseLeaky(M, a, "{\"k\":1,\"k\":2}", .{ .duplicates = .last })).items[0].value);
    try testing.expectEqual(@as(usize, 2), (try json.parseLeaky(M, a, "{\"k\":1,\"k\":2}", .{ .duplicates = null })).items.len);
}

test "an integer is a whole number, or under .digits one written as an integer" {
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
    const N = struct { n: u8 = 0 };
    try testing.expectError(error.UnexpectedType, json.parseLeaky(N, a, "{\"n\":-0}", lenient));
    try testing.expectError(error.UnexpectedType, json.parseLeaky(struct { n: u128 = 0 }, a, "{\"n\":-0}", lenient));
    try testing.expectError(error.UnexpectedType, json.parseLeaky(struct { n: i128 = 0 }, a, "{\"n\":1e2}", lenient));
    try testing.expectEqual(@as(f64, 1.5), (try json.parseLeaky(struct { f: f64 = 0 }, a, "{\"f\":1.5}", lenient)).f);
    try testing.expectError(error.NumberOutOfRange, json.parseLeaky(struct { f: f64 = 0 }, a, "{\"f\":1e400}", lenient));
    // By default a whole number in any spelling is an integer.
    try testing.expectEqual(@as(u8, 100), (try json.parseLeaky(N, a, "{\"n\":1e2}", .{})).n);
    try testing.expectEqual(@as(u8, 0), (try json.parseLeaky(N, a, "{\"n\":-0}", .{})).n);
}

test "text that is not Unicode is refused, or read with U+FFFD" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("\u{ff}\u{fffd}x", (try first(a, "{\"objects\":[{\"oid\":\"\\u00ff\\ud800x\"}]}")).oid);
    try testing.expectEqualStrings("bad\u{fffd}", (try first(a, "{\"objects\":[{\"oid\":\"bad\xff\"}]}")).oid);
    const M = struct { m: []const u8 = "" };
    try testing.expectEqualStrings("\u{10000}\u{fffd}\u{fffd}A\x00", (try json.parseLeaky(M, a, "{\"m\":\"\\ud800\\udc00\\udc00\\ud800A\\u0000\"}", lenient)).m);
    try testing.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}", (try json.parseLeaky(M, a, "{\"m\":\"\xed\xa0\x80\"}", lenient)).m);
    // Keys too: a map's, and a member's, which then names no field.
    const keys = try json.parseLeaky(core.Pairs([]const u8, u8), a, "{\"k\xff\":1,\"\\udc00\":2}", lenient);
    try testing.expectEqualStrings("k\u{fffd}", keys.items[0].key);
    try testing.expectEqualStrings("\u{fffd}", keys.items[1].key);
    try testing.expectEqualStrings("", (try json.parseLeaky(M, a, "{\"m\xff\":\"x\",\"skipped\":\"\xff\\udc00\",\"n\":{\"\xff\":[\"\xff\"]}}", lenient)).m);
    // Outside a string a stray byte is still not JSON.
    try testing.expectError(error.SyntaxError, batch(a, "{\"objects\":[]}\xff"));
    // By default each is refused.
    try testing.expectError(error.SyntaxError, json.parseLeaky(M, a, "{\"m\":\"bad\xff\"}", .{}));
    try testing.expectError(error.SyntaxError, json.parseLeaky(M, a, "{\"m\":\"\\ud800\"}", .{}));
}

test "one value read off the front, the rest left" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const input = "{\"objects\":[]} trailing garbage";
    try testing.expectError(error.SyntaxError, batch(a, input));
    const read = try json.parsePrefixLeaky(Batch, a, input, lenient);
    try testing.expectEqual(@as(usize, 0), read.value.objects.len);
    try testing.expectEqualStrings(" trailing garbage", input[read.end..]);
}

test "fuzz: any bytes are read or refused under every reading choice" {
    const examples = [_][]const u8{
        "{\"objects\":[{\"OID\":\"a\",\"size\":-0,\"actions\":{\"download\":{\"href\":\"x\",\"header\":{\"A\":null}}}}]}",
        "{\"objects\":[null],\"objects\":[{\"error\":{\"code\":1}}]} tail",
        "{\"transfer\":\"\\ud800\\udc00\\udc00\xff\xed\xa0\x80\",\"\u{17f}\":[1,null]}",
    };
    const property = struct {
        fn holds(input: []const u8) !void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            // Refusing the bytes is an answer; only a crash is not.
            if (batch(a, input)) |_| {} else |_| {}
            if (json.parsePrefixLeaky(Batch, a, input, lenient)) |_| {} else |_| {}
            if (json.parseLeaky(json.Value, a, input, lenient)) |_| {} else |_| {}
            // What the reading took is text: it reads again as it was read.
            if (json.parseLeaky(Batch, a, input, lenient)) |b| {
                var out: std.Io.Writer.Allocating = .init(a);
                try json.write(&out.writer, b, .{});
                const again = try json.parseLeaky(Batch, a, out.written(), .{});
                var twice: std.Io.Writer.Allocating = .init(a);
                try json.write(&twice.writer, again, .{});
                try testing.expectEqualStrings(out.written(), twice.written());
            } else |_| {}
        }
        fn body(_: void, case: *shakedown.Case) !void {
            var buffer: [160]u8 = undefined;
            try holds(shakedown.gen.mutated(case.source, &buffer, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try shakedown.check(testing.allocator, {}, property.body, .{});
}
