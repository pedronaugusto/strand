//! JSON5: JSONC with identifier keys, single quotes, ECMAScript's escapes and
//! numbers, and Unicode's white space, read with JSON's options and promises,
//! and written as JSON with its nonfinite floats.
const std = @import("std");
const json = @import("json.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Server = struct {
    name: []const u8,
    port: u16,
    mask: u32,
    ratio: f64,
    limit: f64,
    tags: []const []const u8,
    motd: []const u8,
};

test "JSON5: a document with every addition, read as a record" {
    const input =
        \\// a server's settings
        \\{
        \\  name: 'relay',          /* unquoted key, single quotes */
        \\  "port": +8443,
        \\  'mask': 0xFFFF_0000,
        \\  ratio: .5,
        \\  limit: Infinity,
        \\  tags: ['a', "b",],
        \\  motd: 'Welcome \
        \\to relay\x21',
        \\}
    ;
    // An underscore is no digit: the mask is refused.
    try std.testing.expectError(error.SyntaxError, json.json5.parse(Server, gpa, input, .{}));
    const fixed = try std.mem.replaceOwned(u8, gpa, input, "0xFFFF_0000", "0xFFFF0000");
    defer gpa.free(fixed);
    var parsed = try json.json5.parse(Server, gpa, fixed, .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("relay", v.name);
    try std.testing.expectEqual(8443, v.port);
    try std.testing.expectEqual(0xFFFF0000, v.mask);
    try std.testing.expectEqual(0.5, v.ratio);
    try std.testing.expect(std.math.isPositiveInf(v.limit));
    try std.testing.expectEqual(2, v.tags.len);
    try std.testing.expectEqualStrings("b", v.tags[1]);
    try std.testing.expectEqualStrings("Welcome to relay!", v.motd);
    // JSON and JSONC have none of it.
    try std.testing.expectError(error.SyntaxError, json.parse(Server, gpa, fixed, .{}));
    try std.testing.expectError(error.SyntaxError, json.jsonc.parse(Server, gpa, fixed, .{}));
}

test "JSON5 keys: identifier names, either quote, escapes, and one given twice" {
    const Keys = struct { @"$a_1": u8, @"σ": u8, @"sigΣma": u8, @"while": u8, @"a-b": u8 };
    var parsed = try json.json5.parse(Keys, gpa, "{$a_1: 1, σ: 2, sig\\u03A3ma: 3, while: 4, 'a-b': 5}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Keys{ .@"$a_1" = 1, .@"σ" = 2, .@"sigΣma" = 3, .@"while" = 4, .@"a-b" = 5 }, parsed.value);
    const bad = [_][]const u8{
        "{1a: 1}",
        "{a-b: 1}",
        "{\\u0031: 1}",
        "{a\\x62: 1}",
        "{\\ud835\\udc00: 1}",
        "{a\xff: 1}",
        "{'a': 1 'b': 2}",
        "{,}",
        "{a: 1,,}",
    };
    for (bad) |input| try std.testing.expectError(error.SyntaxError, json.json5.parse(json.Value, gpa, input, .{}));
    // The same key however it is spelled is one key, refused twice.
    for ([_][]const u8{ "{a: 1, 'a': 2}", "{a: 1, \\u0061: 2}", "{\"a\": 1, 'a': 2}" }) |input| {
        try std.testing.expectError(error.DuplicateField, json.json5.parse(json.Value, gpa, input, .{}));
        try std.testing.expectError(error.DuplicateField, json.json5.parse(json.Raw, gpa, input, .{}));
    }
    var last = try json.json5.parse(struct { a: u8 }, gpa, "{a: 1, 'a': 2}", .{ .duplicates = .last });
    defer last.deinit();
    try std.testing.expectEqual(2, last.value.a);
}

test "JSON5 strings: either quote, escapes, continued lines, and what stands as itself" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "'it\\'s \"q\"'", "it's \"q\"" },
        .{ "\"\\v\\0\\x41\\xE9\\q\\/\"", "\x0b\x00A\u{e9}q/" },
        .{ "'one \\\ntwo \\\r\nthree \\\rfour \\\xe2\x80\xa8five'", "one two three four five" },
        .{ "'\\ud83d\\ude00'", "\u{1f600}" },
        // A control character, U+2028 and U+2029 may stand in a string as themselves.
        .{ "'tab\tnul\x00ls\xe2\x80\xa8ps\xe2\x80\xa9'", "tab\tnul\x00ls\u{2028}ps\u{2029}" },
    };
    for (cases) |case| {
        var parsed = try json.json5.parse([]const u8, gpa, case[0], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case[1], parsed.value);
        var raw = try json.json5.parse(json.Raw, gpa, case[0], .{});
        defer raw.deinit();
        try std.testing.expectEqualStrings(case[0], raw.value.bytes);
    }
    for ([_][]const u8{ "'a\nb'", "'a\rb'", "'\\01'", "'\\1'", "'\\x4'", "'\\ud800'", "'open", "'bad\xff'" }) |input| {
        try std.testing.expectError(error.SyntaxError, json.json5.parse([]const u8, gpa, input, .{}));
        try std.testing.expectError(error.SyntaxError, json.json5.parse(json.Raw, gpa, input, .{}));
    }
    var replaced = try json.json5.parse([]const u8, gpa, "'\\ud800 bad\xff'", .{ .invalid_unicode = .replace });
    defer replaced.deinit();
    try std.testing.expectEqualStrings("\u{fffd} bad\u{fffd}", replaced.value);
}

test "JSON5 numbers: hexadecimal, signs, bare points, Infinity and NaN" {
    const Ints = struct { i8, u8, i64, u16, i32 };
    var ints = try json.json5.parse(Ints, gpa, "[-0x80, 0xff, +15, 5.e2, -0x0]", .{});
    defer ints.deinit();
    try std.testing.expectEqual(Ints{ -128, 255, 15, 500, 0 }, ints.value);
    const Floats = struct { f64, f64, f64, f64, f64, f64 };
    var floats = try json.json5.parse(Floats, gpa, "[.5, -5., 0XC8, -Infinity, NaN, +.0e1]", .{});
    defer floats.deinit();
    try std.testing.expectEqual(0.5, floats.value[0]);
    try std.testing.expectEqual(-5.0, floats.value[1]);
    try std.testing.expectEqual(200.0, floats.value[2]);
    try std.testing.expect(std.math.isNegativeInf(floats.value[3]));
    try std.testing.expect(std.math.isNan(floats.value[4]));
    try std.testing.expectEqual(0.0, floats.value[5]);
    try std.testing.expectError(error.NumberOutOfRange, json.json5.parse(u8, gpa, "0x100", .{}));
    try std.testing.expectError(error.NumberOutOfRange, json.json5.parse(u8, gpa, "-0x1", .{}));
    try std.testing.expectError(error.NumberOutOfRange, json.json5.parse(i64, gpa, "Infinity", .{}));
    try std.testing.expectError(error.UnexpectedType, json.json5.parse(i64, gpa, "NaN", .{}));
    // As in JSON, a number past a float's range is out of it, not infinite.
    try std.testing.expectError(error.NumberOutOfRange, json.json5.parse(f64, gpa, "1e400", .{}));
    try std.testing.expectError(error.UnexpectedType, json.json5.parse(u8, gpa, "-0x0", .{ .integers = .digits }));
    for ([_][]const u8{ "01", "0x", ".", "+", "-.e1", "1e", "+-1", "Inf", "infinity", "nan", "0x1.8", "1.5.2", "0b1", "0o7" }) |input| {
        try std.testing.expectError(error.SyntaxError, json.json5.parse(json.Value, gpa, input, .{}));
        try std.testing.expectError(error.SyntaxError, json.json5.parse(json.Raw, gpa, input, .{}));
    }
    // A Value keeps each number as it was written.
    var value = try json.json5.parse(json.Value, gpa, "[0x1F, +1, .5, -Infinity, NaN]", .{});
    defer value.deinit();
    for (value.value.array, [_][]const u8{ "0x1F", "+1", ".5", "-Infinity", "NaN" }) |item, lexeme| try std.testing.expectEqualStrings(lexeme, item.number);
}

test "JSON5 white space and comments" {
    // The vertical tab, the form feed, U+00A0, U+FEFF, U+2028, U+2029 and the
    // space separators; a line comment ends at a carriage return or U+2028 too.
    const input = "\xef\xbb\xbf\x0b\x0c[\xc2\xa01,\xe2\x80\x82// one\r2,// two\xe2\x80\xa83\xe3\x80\x80/* three */]\xe2\x80\xa9";
    var list = try json.json5.parse([]const u32, gpa, input, .{});
    defer list.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, list.value);
    // U+180E was a space separator once, and U+0085 never was one.
    try std.testing.expectError(error.SyntaxError, json.json5.parse(u8, gpa, "\xe1\xa0\x8e1", .{}));
    try std.testing.expectError(error.SyntaxError, json.json5.parse(u8, gpa, "\xc2\x851", .{}));
    try std.testing.expectError(error.SyntaxError, json.json5.parse(u8, gpa, "// only", .{}));
    try std.testing.expectError(error.SyntaxError, json.json5.parse(u8, gpa, "1 /* open", .{}));
}

test "JSON5 values passed over and read on demand: every kind of member" {
    const input = "{skip: {'q': [0x1, +.5, NaN, 'x\\\ny'], \\u0061b: -Infinity}, \"also\": 'it''s', keep: 0x2A, after: 1}";
    // `'it''s'` is two strings: refused wherever it is.
    try std.testing.expectError(error.SyntaxError, json.json5.parse(struct { keep: u8 }, gpa, input, .{ .ignore_unknown_fields = true }));
    const fixed = "{skip: {'q': [0x1, +.5, NaN, 'x\\\ny'], \\u0061b: -Infinity}, \"also\": 'it\\'s', keep: 0x2A, after: 1}";
    var parsed = try json.json5.parse(struct { keep: u8 }, gpa, fixed, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(42, parsed.value.keep);
    var raw = try json.json5.parse(struct { skip: json.Raw, keep: u8 }, gpa, fixed, .{ .ignore_unknown_fields = true });
    defer raw.deinit();
    try std.testing.expectEqualStrings("{'q': [0x1, +.5, NaN, 'x\\\ny'], \\u0061b: -Infinity}", raw.value.skip.bytes);
    // A Raw's bytes are JSON5, and read again as JSON5.
    var again = try json.json5.parse(json.Value, gpa, raw.value.skip.bytes, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("ab", again.value.object[1].key);
}

test "JSON5 written: JSON, but for the floats JSON cannot spell" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const Floats = struct { a: f64, b: f32, c: f64, d: f64, e: []const u8 };
    try json.json5.write(&out.writer, Floats{ .a = std.math.inf(f64), .b = -std.math.inf(f32), .c = std.math.nan(f64), .d = 1.5, .e = "it's" }, .{});
    try std.testing.expectEqualStrings("{\"a\":Infinity,\"b\":-Infinity,\"c\":NaN,\"d\":1.5,\"e\":\"it's\"}", out.written());
    var back = try json.json5.parse(Floats, gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expect(std.math.isNegativeInf(back.value.b));
    // JSON refuses them.
    var plain: std.Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    try std.testing.expectError(error.UnsupportedValue, json.write(&plain.writer, std.math.inf(f64), .{}));
    // A Value's JSON5 number writes as JSON5, and is refused as JSON.
    var value = try json.json5.parse(json.Value, gpa, "{n: 0x1F, m: -Infinity}", .{});
    defer value.deinit();
    out.clearRetainingCapacity();
    try json.json5.write(&out.writer, value.value, .{ .whitespace = .indent_2 });
    try std.testing.expectEqualStrings("{\n  \"n\": 0x1F,\n  \"m\": -Infinity\n}", out.written());
    try std.testing.expectError(error.InvalidRaw, json.write(&plain.writer, value.value, .{}));
    try std.testing.expectError(error.InvalidRaw, json.json5.write(&plain.writer, json.Value{ .number = "0x" }, .{}));
    try std.testing.expectError(error.InvalidRaw, json.json5.write(&plain.writer, json.Value{ .number = "[1]" }, .{}));
    // A Raw is checked as JSON5.
    try json.json5.write(&plain.writer, json.Raw{ .bytes = "{a: 'b', /* c */}" }, .{});
    try std.testing.expectError(error.InvalidRaw, json.write(&plain.writer, json.Raw{ .bytes = "{a: 'b'}" }, .{}));
}

test "any JSON document reads as the same value as JSON5" {
    try shakedown.check(gpa, {}, jsonIsJson5, .{ .cases = 2000 });
}
const json_examples = [_][]const u8{
    "{\"a\": [1, -2.5e3, true, null, \"s\\u00e9\\n\"], \"b\": {\"c\": {}}, \"d\": []}",
    "[0, -0, 1E+2, \"\\ud83d\\ude00\", \"\\/\", {\"x\": \"y\"}]",
    " \t\r\n\"top\" ",
};
fn jsonIsJson5(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [160]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &json_examples);
    case.note("input: {f}", .{std.zig.fmtString(input)});
    var plain = json.parse(json.Value, case.gpa, input, .{}) catch return;
    defer plain.deinit();
    var five = try json.json5.parse(json.Value, case.gpa, input, .{});
    defer five.deinit();
    try std.testing.expect(same(plain.value, five.value));
}

/// Whether two values are the same, members in order and numbers as written.
fn same(a: json.Value, b: json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null_value => true,
        .boolean => |x| x == b.boolean,
        .number => |x| std.mem.eql(u8, x, b.number),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| x.len == b.array.len and for (x, b.array) |p, q| {
            if (!same(p, q)) break false;
        } else true,
        .object => |x| x.len == b.object.len and for (x, b.object) |p, q| {
            if (!std.mem.eql(u8, p.key, q.key) or !same(p.value, q.value)) break false;
        } else true,
    };
}

const examples = [_][]const u8{
    "// c\n{a: 'b\\\nc', \"d\": [0x1F, +.5, 5., -Infinity, NaN,], \\u0065: {'f': \"g\\x41\\v\"},}",
    "[\xe2\x80\x82'\\ud83d\\ude00', σ, \"\\'\", /* x */ 1e3, true, null]",
    "{ünïcode_key\xe2\x80\x8d: '\t', $: 0, _1: -0x0, sig\\u03A3ma: 'line\\\r\nnext' }",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [200]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {f}", .{std.zig.fmtString(input)});
    const options: json.ParseOptions = .{ .limits = .{ .work = 1 << 16 } };
    // A value passed over is checked as one read is: it is read exactly when
    // the value is, and as the same value.
    var read = json.json5.parse(json.Value, case.gpa, input, options) catch |err| {
        if (err == error.WorkLimit) return;
        var raw = json.json5.parse(json.Raw, case.gpa, input, options) catch return;
        raw.deinit();
        case.note("refused as a value ({s}), passed over as one", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer read.deinit();
    var raw = try json.json5.parse(json.Raw, case.gpa, input, options);
    defer raw.deinit();
    var raw_value = try json.json5.parse(json.Value, case.gpa, raw.value.bytes, options);
    defer raw_value.deinit();
    try std.testing.expect(same(read.value, raw_value.value));
    // What is read writes, and reads back as itself.
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    defer out.deinit();
    try json.json5.write(&out.writer, read.value, .{});
    var back = try json.json5.parse(json.Value, case.gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expect(same(read.value, back.value));
}

test "fuzz: any bytes are a JSON5 value or refused, passed over as they are read, and a value written reads back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
