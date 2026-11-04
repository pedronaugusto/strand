//! The tape and the streamed input held to the same answers: the corpora and
//! generated JSON, JSONC and JSON5 read both ways into `Value` and into typed
//! shapes, under drawn options and limits.
//!
//! The contract: where the tape is written, both read the same value, or fail
//! with the same error and the same diagnostics. Where it is not (the input is
//! malformed, or past a wire limit: depth, a string's, a key's or a number's
//! length), the tape fails with what writing it found, and streaming fails
//! too, with the first error in input order. Work and allocation are charged
//! as each spends them, so the limits drawn here leave both alone.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Source = shakedown.Source;
const api = @import("../json/api.zig");
const json = @import("../json.zig");
const core = @import("../core.zig");
const Grammar = @import("../json/Decoder.zig").Grammar;
const json_suite = @import("json_suite.zig");
const json5_suite = @import("json5_suite.zig");

const Inner = struct { b: ?i32 = null, c: []const u8 = "" };
/// A record with a field of each kind, defaults throughout, so that a
/// generated object can be read as one, or fail in more than one way.
const Shape = struct {
    a: ?i64 = null,
    b: []const u8 = "",
    c: []const f64 = &.{},
    d: ?Inner = null,
    e: json.Raw = .null,
    f: bool = false,
};
/// Routed by a member, whose payload is read again where it lay.
const Tagged = union(enum) {
    x: Inner,
    y: struct { e: ?[]const ?u8 = null },
    pub const strand = .{ .tag = "a" };
};
/// Its tag and content in members of their own, in either order.
const Adjacent = union(enum) {
    x: i32,
    y: []const []const u8,
    pub const strand = .{ .tag = "a", .content = "c" };
};
const Small = enum { x, y };

const targets = .{ json.Value, Shape, Tagged, Adjacent, []const ?i64, [2]u8, u8, f32, Small, []const u8, core.Pairs([]const u8, ?Inner) };

/// What a read gave: the value written back as JSON5, or the error and its
/// diagnostics.
const Outcome = struct {
    text: []const u8 = "",
    err: ?anyerror = null,
    diagnostics: []const u8 = "",
};

fn outcome(comptime T: type, comptime grammar: Grammar, comptime backend: api.Backend, arena: std.mem.Allocator, input: []const u8, options: json.ParseOptions) !Outcome {
    var diagnostics: core.Diagnostics = .{};
    var with = options;
    with.diagnostics = &diagnostics;
    const value = api.parseLeakyWith(T, grammar, backend, arena, input, with) catch |err| {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("offset {d} expected {t} code {?d} path ", .{ diagnostics.offset, diagnostics.expected, diagnostics.custom_code });
        try diagnostics.path.format(&out.writer);
        return .{ .err = err, .diagnostics = out.written() };
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    json.json5.write(&out.writer, value, .{ .scratch = try arena.alloc(u8, 1 << 16) }) catch |err| return .{ .err = err, .text = "unwritable" };
    return .{ .text = out.written() };
}

fn expectSame(comptime T: type, comptime grammar: Grammar, input: []const u8, options: json.ParseOptions) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const streamed = try outcome(T, grammar, .stream, arena, input, options);
    const taped = try outcome(T, grammar, .tape, arena, input, options);
    errdefer std.debug.print("{s} {t} over {f}\n  streamed {any}\n  taped    {any}\n", .{ @typeName(T), grammar, std.ascii.hexEscape(input, .lower), streamed, taped });
    if (api.writeTapeOnly(grammar, arena, input, options)) {
        if (streamed.err) |err| {
            try testing.expectEqual(err, taped.err orelse return error.TestExpectedError);
            try testing.expectEqualStrings(streamed.diagnostics, taped.diagnostics);
        } else {
            try testing.expectEqual(@as(?anyerror, null), taped.err);
            try testing.expectEqualStrings(streamed.text, taped.text);
        }
    } else |wire| {
        try testing.expectEqual(@as(?anyerror, wire), taped.err);
        if (streamed.err == null) return error.TestExpectedError;
    }
}

fn expectSameEverywhere(comptime grammar: Grammar, input: []const u8, options: json.ParseOptions) !void {
    inline for (targets) |T| try expectSame(T, grammar, input, options);
}

test "the tape reads the JSON suite as streaming reads it" {
    for (json_suite.cases) |case| {
        try expectSameEverywhere(.json, case.input, .{});
        try expectSameEverywhere(.json, case.input, .{ .duplicates = .last, .invalid_unicode = .replace, .ignore_unknown_fields = true });
        try expectSameEverywhere(.jsonc, case.input, .{});
    }
}

test "the tape reads the JSON5 suite as streaming reads it" {
    for (json5_suite.cases) |case| {
        try expectSameEverywhere(.json5, case.input, .{ .duplicates = .last });
        try expectSameEverywhere(.json5, case.input, .{ .invalid_unicode = .replace, .nulls = .keep, .ignore_unknown_fields = true });
    }
}

test "the tape and streaming stand at the same offset when a typed read fails" {
    // A wrong type, an item past the limit and a key given twice, deep in.
    try expectSameEverywhere(.json, "{\"a\": 1, \"d\": {\"b\": \"no\"}}", .{});
    try expectSameEverywhere(.json, "[1, 2, 3, 4]", .{ .limits = .{ .container_items = 3 } });
    try expectSameEverywhere(.json, "{\"q\": {\"k\": 1, \"k\": 2}}", .{ .ignore_unknown_fields = true });
    try expectSameEverywhere(.jsonc, "{\"a\": \"y\", /* c */ \"e\": [1, 2,],}", .{});
    try expectSameEverywhere(.json5, "{a: 'x', b: 0x1F, c: [Infinity, -.5,], d: {c: 'it\\'s'},}", .{ .ignore_unknown_fields = true });
    // A Raw ends where its token ends, an escaped string's included.
    try expectSameEverywhere(.json, "{\"e\": \"a\\u00e9\" , \"f\": true}", .{});
    try expectSameEverywhere(.json5, "{e: {x: 'a\\x41'} // after\n}", .{});
}

test "fuzz: the tape and streaming read generated JSON alike" {
    try shakedown.check(testing.allocator, {}, fuzzSame, .{ .cases = 256 });
}

fn fuzzSame(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [512]u8 = undefined;
    const grammar: Grammar = switch (gen.intRange(s, u8, 0, 2)) {
        0 => .json,
        1 => .jsonc,
        else => .json5,
    };
    var writer: Generator = .{ .s = s, .buffer = &buffer, .grammar = grammar };
    writer.value(0);
    writer.damage();
    const input = buffer[0..writer.len];
    const options = drawOptions(s);
    switch (grammar) {
        inline else => |g| try expectSameEverywhere(g, input, options),
    }
}

fn drawOptions(s: *Source) json.ParseOptions {
    var options: json.ParseOptions = .{
        .ignore_unknown_fields = gen.boolean(s),
        .duplicates = switch (gen.intRange(s, u8, 0, 4)) {
            0 => .reject,
            1 => .first,
            2 => .last,
            3 => .merge,
            else => null,
        },
        .names = if (gen.boolean(s)) .exact else .fold_case,
        .nulls = if (gen.boolean(s)) .refuse else .keep,
        .integers = if (gen.boolean(s)) .whole else .digits,
        .invalid_unicode = if (gen.boolean(s)) .refuse else .replace,
    };
    if (gen.intRange(s, u8, 0, 3) == 0) options.limits = .{
        .depth = gen.intRange(s, usize, 1, 4),
        .items = gen.intRange(s, usize, 1, 24),
        .container_items = gen.intRange(s, usize, 1, 4),
        .string_bytes = .fromRaw(gen.intRange(s, usize, 0, 6)),
        .key_bytes = .fromRaw(gen.intRange(s, usize, 0, 3)),
        .numeric_bytes = .fromRaw(gen.intRange(s, usize, 1, 4)),
    };
    return options;
}

/// JSON of one dialect, drawn from the pieces that tell readers apart: the
/// keys a shape knows and keys it does not, given twice; escapes, invalid
/// UTF-8 and every spelling of a number; comments, final commas and JSON5's
/// quotes and names where the dialect has them.
const Generator = struct {
    s: *Source,
    buffer: []u8,
    len: usize = 0,
    grammar: Grammar,

    fn put(g: *Generator, bytes: []const u8) void {
        const n = @min(bytes.len, g.buffer.len - g.len);
        @memcpy(g.buffer[g.len..][0..n], bytes[0..n]);
        g.len += n;
    }
    fn pick(g: *Generator, comptime pieces: []const []const u8) void {
        g.put(pieces[gen.intRange(g.s, usize, 0, pieces.len - 1)]);
    }
    fn space(g: *Generator) void {
        switch (gen.intRange(g.s, u8, 0, 7)) {
            0 => g.put(" "),
            1 => g.put("\n\t"),
            2 => if (g.grammar != .json) g.put("/* c */") else g.put("  "),
            3 => if (g.grammar != .json) g.put("// c\n"),
            4 => if (g.grammar == .json5) g.put("\u{a0}"),
            else => {},
        }
    }
    fn string(g: *Generator) void {
        const quote: []const u8 = if (g.grammar == .json5 and gen.boolean(g.s)) "'" else "\"";
        g.put(quote);
        g.pick(&.{ "x", "y", "z", "", "a\\nb", "\\u00e9t\\u00e9", "\\ud83d\\ude00", "\xff", "caf\xc3\xa9", "\\\"", "ab\\/c", "\\uD800" });
        if (g.grammar == .json5) g.pick(&.{ "", "\\x41", "\\v", "it\\'s", "\\\n" });
        g.put(quote);
    }
    fn key(g: *Generator) void {
        if (g.grammar == .json5 and gen.boolean(g.s)) return g.pick(&.{ "a", "b", "c", "d", "e", "f", "k", "\\u0061", "$_" });
        const quote: []const u8 = if (g.grammar == .json5 and gen.boolean(g.s)) "'" else "\"";
        g.put(quote);
        g.pick(&.{ "a", "b", "c", "d", "e", "f", "k", "A", "\\u0061", "b\\u0000", "\xff" });
        g.put(quote);
    }
    fn number(g: *Generator) void {
        g.pick(&.{ "0", "-0", "1", "-7", "255", "256", "1.5", "-2.25e3", "1e400", "12345678901234567890", "1E2", "0.000001" });
        if (g.grammar == .json5) g.pick(&.{ "", "", "0x1F" ++ "", "+1", ".5", "5.", "Infinity", "-Infinity", "NaN" });
    }
    fn value(g: *Generator, depth: usize) void {
        g.space();
        const choice = gen.intRange(g.s, u8, 0, if (depth > 3) 5 else 8);
        switch (choice) {
            0 => g.put("null"),
            1 => g.put(if (gen.boolean(g.s)) "true" else "false"),
            2, 3 => g.number(),
            4, 5 => g.string(),
            6 => g.container(depth, false),
            else => g.container(depth, true),
        }
        g.space();
    }
    fn container(g: *Generator, depth: usize, object: bool) void {
        g.put(if (object) "{" else "[");
        const n = gen.intRange(g.s, u8, 0, 4);
        for (0..n) |i| {
            if (i != 0) g.put(",");
            if (object) {
                g.space();
                g.key();
                g.space();
                g.put(":");
            }
            g.value(depth + 1);
        }
        if (n != 0 and g.grammar != .json and gen.intRange(g.s, u8, 0, 3) == 0) g.put(",");
        g.space();
        g.put(if (object) "}" else "]");
    }
    /// Now and then one byte dropped, doubled or changed, so that
    /// malformed input is read too.
    fn damage(g: *Generator) void {
        if (g.len == 0 or gen.intRange(g.s, u8, 0, 3) != 0) return;
        const at = gen.intRange(g.s, usize, 0, g.len - 1);
        switch (gen.intRange(g.s, u8, 0, 2)) {
            0 => {
                std.mem.copyForwards(u8, g.buffer[at .. g.len - 1], g.buffer[at + 1 .. g.len]);
                g.len -= 1;
            },
            1 => if (g.len < g.buffer.len) {
                std.mem.copyBackwards(u8, g.buffer[at + 1 .. g.len + 1], g.buffer[at..g.len]);
                g.len += 1;
            },
            else => g.buffer[at] = "{}[],:\"'/x0 "[gen.intRange(g.s, usize, 0, 12)],
        }
    }
};
