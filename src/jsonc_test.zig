//! JSONC: JSON with comments and trailing commas, as a reading option.
const std = @import("std");
const json = @import("json.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Settings = struct {
    name: []const u8,
    sizes: []const u32,
    nested: struct { on: bool },
    note: ?[]const u8 = null,
};

test "JSONC: comments where whitespace may be, and a comma after the last member" {
    const input =
        \\// settings
        \\{
        \\  /* the name */ "name": "a // b /* c */",
        \\  "sizes": [1, 2, 3,], // trailing
        \\  "nested" /* before the colon */ : { "on": true, },
        \\}
        \\// done
    ;
    var parsed = try json.jsonc.parse(Settings, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a // b /* c */", parsed.value.name);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, parsed.value.sizes);
    try std.testing.expect(parsed.value.nested.on);
    // Plain JSON has neither.
    try std.testing.expectError(error.SyntaxError, json.parse(Settings, gpa, input, .{}));
    try std.testing.expectError(error.SyntaxError, json.parse([]const u32, gpa, "[1,]", .{}));
    try std.testing.expectError(error.SyntaxError, json.parse([]const u32, gpa, "[1] // x", .{}));
}

test "JSONC refuses what JSONC does not allow" {
    const options: json.ParseOptions = .{};
    const cases = [_][]const u8{
        "[1,,]",
        "[,]",
        "[1,],",
        "[1] /* never closed",
        "[1 / 2]",
        "[1] # not a comment",
    };
    for (cases) |input| {
        try std.testing.expectError(error.SyntaxError, json.jsonc.parse([]const u32, gpa, input, options));
    }
    try std.testing.expectError(error.SyntaxError, json.jsonc.parse(struct { a: u8 }, gpa, "{\"a\":1,,}", options));
    try std.testing.expectError(error.SyntaxError, json.jsonc.parse(struct { a: u8 = 0 }, gpa, "{,}", options));
    // A comment alone is no value.
    try std.testing.expectError(error.SyntaxError, json.jsonc.parse(u8, gpa, "// nothing", options));
    var empty = try json.jsonc.parse([]const u32, gpa, "[ /* none */ ]", options);
    defer empty.deinit();
    try std.testing.expectEqual(0, empty.value.len);
    var line_end = try json.jsonc.parse(u8, gpa, "7 // no newline", options);
    defer line_end.deinit();
    try std.testing.expectEqual(7, line_end.value);
}

test "a Raw read from JSONC keeps its comments, and parses as JSONC" {
    const Carrier = struct { payload: json.Raw };
    var parsed = try json.jsonc.parse(Carrier, gpa, "{\"payload\": [1, /* two */ 2,],}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[1, /* two */ 2,]", parsed.value.payload.bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const values = try json.jsonc.parseLeaky([]const u32, arena.allocator(), parsed.value.payload.bytes, .{});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, values);
}

const Generated = struct {
    text: []const u8,
    numbers: []const i32,
    inner: struct { flag: bool, words: []const []const u8 },
    empty: []const u8,
};

/// `plain` with a comment or a comma added where JSONC allows one, wherever
/// the generator chooses: after every `{`, `[`, `,` and `:` outside a string,
/// and a comma before a close that follows a member.
fn decorate(case: *shakedown.Case, plain: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    var escaped = false;
    var last: u8 = 0;
    for (plain) |byte| {
        if (in_string) {
            try out.append(case.gpa, byte);
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            last = byte;
            continue;
        }
        if ((byte == '}' or byte == ']') and last != '{' and last != '[' and gen.boolean(case.source)) try out.append(case.gpa, ',');
        try out.append(case.gpa, byte);
        if (byte == '"') in_string = true;
        if (byte == '{' or byte == '[' or byte == ',' or byte == ':') switch (gen.intRange(case.source, u8, 0, 3)) {
            0 => try out.appendSlice(case.gpa, " /* a comment, // not a line */ "),
            1 => try out.appendSlice(case.gpa, "// a line, /* not a block\n"),
            else => {},
        };
        last = byte;
    }
    return out.items;
}

fn sameAsPlain(_: void, case: *shakedown.Case) anyerror!void {
    const words = try case.gpa.alloc([]const u8, gen.intRange(case.source, usize, 0, 3));
    for (words) |*w| w.* = try gen.string(case.source, case.gpa, .{ .max_len = 8 });
    const numbers = try case.gpa.alloc(i32, gen.intRange(case.source, usize, 0, 4));
    for (numbers) |*n| n.* = gen.int(case.source, i32);
    const value: Generated = .{
        .text = try gen.string(case.source, case.gpa, .{ .max_len = 16 }),
        .numbers = numbers,
        .inner = .{ .flag = gen.boolean(case.source), .words = words },
        .empty = "",
    };
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try json.write(&out.writer, value, .{ .whitespace = if (gen.boolean(case.source)) .indent_2 else .minified });
    const input = try decorate(case, out.written());
    case.note("input: {s}", .{input});
    var parsed = try json.jsonc.parse(Generated, case.gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value.text, parsed.value.text);
    try std.testing.expectEqualSlices(i32, value.numbers, parsed.value.numbers);
    try std.testing.expectEqual(value.inner.flag, parsed.value.inner.flag);
    for (value.inner.words, parsed.value.inner.words) |w, g| try std.testing.expectEqualStrings(w, g);
    // The same text without the dialect is plain JSON exactly when nothing was added.
    const plain = json.parse(Generated, case.gpa, input, .{});
    if (plain) |p| {
        var held = p;
        held.deinit();
        try std.testing.expectEqualStrings(out.written(), input);
    } else |_| try std.testing.expect(!std.mem.eql(u8, out.written(), input));
}

test "JSONC with comments and commas anywhere they may be reads as the plain JSON does" {
    try shakedown.check(gpa, {}, sameAsPlain, .{ .cases = 500 });
}
