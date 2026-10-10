//! ZON against `std.zon`, the oracle for the grammar and for what a value is:
//! every source below is read by both, and they must agree on whether it is a
//! value of the type and, if it is, on which. Where strand deliberately says
//! otherwise, the test says so in its name.
const std = @import("std");
const zon = @import("strand.zon");
const core = @import("strand.core");
const shakedown = @import("shakedown");
const testing = std.testing;

const Reading = union(enum) { failed, value: []u8 };

/// What `std.zon` makes of `source` as a `T`, as the bytes `std.zon` writes the value as.
fn stdReading(comptime T: type, source: []const u8) !Reading {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const terminated = try arena.allocator().allocSentinel(u8, source.len, 0);
    @memcpy(terminated, source);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const value = std.zon.parse.fromSlice(T, .{
        .gpa = testing.allocator,
        .arena = arena.allocator(),
        .source = terminated,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .failed,
    };
    return .{ .value = try spell(T, value) };
}

fn ownReading(comptime T: type, source: []const u8) !Reading {
    var result = zon.parse(T, testing.allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .failed,
    };
    defer result.deinit();
    return .{ .value = try spell(T, result.value) };
}

fn spell(comptime T: type, value: T) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try std.zon.stringify.serialize(value, .{ .whitespace = false }, &out.writer);
    return out.toOwnedSlice();
}

var accepted_by_both: usize = 0;
fn agree(comptime T: type, source: []const u8) !void {
    const expected = try stdReading(T, source);
    if (expected == .value) accepted_by_both += 1;
    defer if (expected == .value) testing.allocator.free(expected.value);
    const actual = try ownReading(T, source);
    defer if (actual == .value) testing.allocator.free(actual.value);
    switch (expected) {
        .failed => if (actual != .failed) {
            std.debug.print("\nstd refuses, strand accepts as {s}:\n{s}\n", .{ @typeName(T), source });
            return error.TestExpectedEqual;
        },
        .value => |bytes| {
            if (actual != .value) {
                std.debug.print("\nstd accepts as {s}, strand refuses:\n{s}\n", .{ @typeName(T), source });
                return error.TestExpectedEqual;
            }
            if (!std.mem.eql(u8, bytes, actual.value)) {
                std.debug.print("\nas {s}:\n{s}\nstd:    {s}\nstrand: {s}\n", .{ @typeName(T), source, bytes, actual.value });
                return error.TestExpectedEqual;
            }
        },
    }
}

fn all(comptime T: type, sources: []const []const u8) !void {
    for (sources) |source| try agree(T, source);
}

const Color = enum { red, green, blue, @"with space" };
const Point = struct { x: i32, y: i32 };
const Settings = struct {
    name: []const u8,
    retries: u8 = 3,
    verbose: bool = false,
    mode: ?Color = null,
    tags: []const []const u8 = &.{},
};
const Shape = union(enum) {
    empty,
    circle: f32,
    rect: struct { w: u16, h: u16 },
    pair: struct { u8, u8 },
    named: []const u8,
};

test "booleans, null and the words" {
    try all(bool, &.{ "true", "false", " true ", "// c\ntrue", "true // c", "/", "tru", "True", "1", "\"true\"", "null", ".true", "true true", "true,", "" });
    try all(?bool, &.{ "null", "true", "false", "nul", "undefined" });
    try all(?u8, &.{ "null", "5", ".{}", "-0" });
}

test "integers in every spelling and width" {
    try all(u8, &.{ "0", "255", "256", "-1", "-0", "0x7f", "0xFF", "0o17", "0b1010", "1_0", "1__0", "_1", "1_", "0x", "0b2", "0o8", "01", "00", "0X1", "1e2", "1.0", "1.5", "2e0", "0x1p0", "1e-1", "100e-2", "1.0e1", "+1", "- 1", "-\n1", "'a'", "'\\n'", "'\\x41'", "'\\u{41}'", "'ab'", "''", "0xff_ff", "0x_f", "inf", "nan" });
    try all(i8, &.{ "-128", "127", "128", "-129", "-0x80", "-0b10000000", "- 5", "-  0x5", "-.5", "--5", "-5-", "-+5" });
    try all(u16, &.{ "65535", "65536", "0xffff", "0x10000" });
    try all(i64, &.{ "-9223372036854775808", "9223372036854775807", "9223372036854775808", "-9223372036854775809" });
    try all(u128, &.{ "340282366920938463463374607431768211455", "340282366920938463463374607431768211456", "0xffffffffffffffffffffffffffffffff", "0x100000000000000000000000000000000", "1e38", "3.4e38", "1.0", "1_000_000_000_000_000_000_000_000_000_000_000_000", "123456789012345678901234567890123456789" });
    try all(i128, &.{ "-170141183460469231731687303715884105728", "170141183460469231731687303715884105727", "170141183460469231731687303715884105728", "-0x80000000000000000000000000000000" });
    try all(u0, &.{ "0", "1", "-0" });
    try all(i1, &.{ "0", "-1", "1" });
    try all(u3, &.{ "7", "8", "0b111", "0b1000" });
}

test "floats in every spelling and width" {
    try all(f64, &.{ "0", "1", "-1", "1.5", "-1.5", "1e3", "1E3", "1e+3", "1e-3", "1.5e3", "0x1p3", "0x1.8p3", "0x1.8", "0x1P-3", "inf", "-inf", "nan", "-nan", "+inf", "1_000.5", "1._5", "1_.5", "1.", ".5", "1.5.5", "1e", "1e+", "e1", "0x", "0xg", "- 1.5", "-\n1.5", "'a'", "5", "0b101", "0o17", "340282366920938463463374607431768211456", "1e-999", "'\\u{1F600}'", "infinity", "Inf", "-Inf" });
    try all(f32, &.{
        "3.4028235e38",
        "1.17549435e-38",
        "1e-46",
        "0.1",
        "16777217",
    });
    try all(f16, &.{ "65504", "6.1e-5", "0.1" });
    try all(f128, &.{ "1e4932", "0.1", "1.5" });
}

test "characters are numbers" {
    try all(u8, &.{ "'a'", "'\\''", "'\\\\'", "'\\t'", "'\\x7f'", "'\\xff'", "'\\xFF'", "'\\u{ff}'", "'\\u{100}'", "'é'", "'\\q'", "'\\x4'", "'\\u{}'", "'\\u{110000}'", "'\\u{d800}'", "'" });
    try all(u21, &.{ "'\\u{10ffff}'", "'😀'", "'\\u{1F600}'" });
    try all(f32, &.{ "'a'", "'\\u{1F600}'" });
}

test "strings, escapes and multiline strings" {
    try all([]const u8, &.{
        "\"\"",
        "\"abc\"",
        "\"a\\nb\"",
        "\"\\\"\\\\\\'\\t\\r\"",
        "\"\\x41\\x7a\"",
        "\"\\u{1F600}\"",
        "\"\\u{41}\"",
        "\"é\"",
        "\"\\u{d800}\"",
        "\"\\u{110000}\"",
        "\"\\u{}\"",
        "\"\\u41\"",
        "\"\\q\"",
        "\"\\x4\"",
        "\"abc",
        "\"a\nb\"",
        "\"a\tb\"",
        "\"a\x01b\"",
        "\"a\x7fb\"",
        "\"a\x00b\"",
        "\\\\abc",
        "\\\\abc\n",
        "\\\\abc\n\\\\def",
        "\\\\abc\n  \\\\def\n   \\\\ghi",
        "\\\\\n\\\\\n",
        "\\\\ a // not a comment",
        "\\\\abc\r\n\\\\def",
        "\\\\abc\r",
        "\\\\a\tb",
        "\\\\abc\n// comment\n\\\\def",
        "\\\\é",
        ".{ .a = \\\\x\n}",
        "'a'",
        "1",
        ".a",
        ".{ \"a\" }",
    });
    try all(?[]const u8, &.{ "null", "\"x\"", "\\\\y" });
    try all([]const []const u8, &.{ ".{}", ".{ \"a\", \"b\" }", ".{ \"a\", \"b\", }", ".{ \\\\a\n, \\\\b\n }", ".{ \"a\" \"b\" }", ".{ \"a\", , }", ".{ , }", ".{ \"a\",, \"b\" }" });
}

test "enum literals and quoted names" {
    try all(Color, &.{ ".red", ".blue", ".yellow", "red", "\"red\"", ".@\"with space\"", ".@\"red\"", ". red", ".\nred", ".@\"re\\x64\"", ".@ \"red\"", "@\"red\"", ".{}", ".{ .red }", ".red ", ".red,", "1", ".@\"\"", ".@\"a", ".1", ".r-ed", ".Red" });
    try all(?Color, &.{ "null", ".red", "red", ".{}" });
    try all([]const Color, &.{ ".{ .red, .green }", ".{}", ".{ .red, \"green\" }", ".{ .red, .green, .blue, }" });
}

test "arrays, tuples, vectors and slices" {
    try all([3]u8, &.{ ".{ 1, 2, 3 }", ".{ 1, 2, 3, }", ".{ 1, 2 }", ".{ 1, 2, 3, 4 }", ".{}", ".{ 1, 2, 300 }", ".{ .a = 1 }", "\"abc\"", "1", ".{ 1 2 3 }", ".{1,2,3}", ".{\n1,\n2,\n3\n}", ".{ 1, 2, 3 } " });
    try all([0]u8, &.{ ".{}", ".{ 1 }", "\"\"" });
    try all([2][2]i8, &.{ ".{ .{ 1, 2 }, .{ 3, 4 } }", ".{ .{ 1, 2 }, .{ 3 } }", ".{ .{}, .{} }" });
    try all([]const i32, &.{ ".{}", ".{ 1 }", ".{ 1, -2, 3 }", ".{ 1, 2, }", ".{ -1, 0x10, 1e2 }", ".{ 1.5 }", ".{ \"x\" }" });
    try all(struct { u8, bool }, &.{ ".{ 1, true }", ".{ 1 }", ".{ 1, true, 2 }", ".{}", ".{ true, 1 }", ".{ 1, true, }" });
    try all(@Vector(3, i32), &.{ ".{ 1, 2, 3 }", ".{ 1, 2 }", ".{ 1, 2, 3, 4 }", ".{ 1, 2, 3.5 }" });
    try all([3]bool, &.{ ".{ true, false, true }", ".{ true, 1, false }" });
    try all([3]f32, &.{ ".{ 1, 2.5, inf }", ".{ nan, -inf, 0 }" });
}

test "structs, defaults and unknown fields" {
    try all(Point, &.{
        ".{ .x = 1, .y = 2 }",
        ".{ .y = 2, .x = 1 }",
        ".{ .x = 1, .y = 2, }",
        ".{ .x = 1 }",
        ".{ .x = 1, .y = 2, .z = 3 }",
        ".{ .x = 1, .x = 2, .y = 3 }",
        ".{ .x = 1, .y = 2 } // trailing",
        ".{ .x = 1, .y = 2 } .{}",
        ".{}",
        ".{ 1, 2 }",
        ".{ .x = 1 .y = 2 }",
        ".{ .x 1, .y = 2 }",
        ".{ .x == 1, .y = 2 }",
        ".{ x = 1, y = 2 }",
        ".{ .x = 1, y = 2 }",
        ".{ . x = 1, . y = 2 }",
        ".{ .\nx\n=\n1,\n.y\n=\n2\n}",
        ".{ .@\"x\" = 1, .@\"y\" = 2 }",
        ".{ .@\"x\" = 1, .y = 2, .@\"y\" = 3 }",
        ".{ .x = -1, .y = - 2 }",
        ".{ .x = 'a', .y = 0x10 }",
        ".{ .x = 1, .y = 2 ",
        ".{ .x = 1, .y = 2 }}",
        ".{ .x = 1, .y = 2 })",
        " \n\t.{ .x = 1, .y = 2 }\n\n",
        ".{ .x = 1, // one\n .y = 2 // two\n }",
        ".{ .x = 1, /* no */ .y = 2 }",
        ".{ .x = 1, /// doc\n .y = 2 }",
        "//! container doc\n.{ .x = 1, .y = 2 }",
        "/// doc\n.{ .x = 1, .y = 2 }",
        ".{ .x = null, .y = 2 }",
        ".{ .x = 1, .y = 2, .@\"z z\" = 3 }",
        ".{ .x = @import(\"x\"), .y = 2 }",
        ".{ .x = 1 + 1, .y = 2 }",
        ".{ .x = (1), .y = 2 }",
        ".{ .x = f(), .y = 2 }",
        ".{ .x = Point, .y = 2 }",
        "Point{ .x = 1, .y = 2 }",
        "@as(Point, .{ .x = 1, .y = 2 })",
        ".{ .x = 1, .y = 2 }.x",
        ".{ .x = if (true) 1 else 2, .y = 2 }",
        "undefined",
        "{ .x = 1, .y = 2 }",
        "[ 1, 2 ]",
        ".[1]",
        ".( 1 )",
    });
    try all(Settings, &.{
        ".{ .name = \"a\" }",
        ".{ .name = \"a\", .retries = 9, .verbose = true, .mode = .blue, .tags = .{ \"x\", \"y\" } }",
        ".{ .name = \"a\", .mode = null }",
        ".{ .name = \"a\", .mode = .teal }",
        ".{ .name = \"a\", .retries = 256 }",
        ".{ .retries = 1 }",
        ".{ .name = \\\\multi\n \\\\line\n, .retries = 1 }",
        ".{ .name = .a }",
        ".{ .name = 5 }",
        ".{ .name = \"a\", .tags = \"abc\" }",
        ".{ .name = \"a\", .tags = .{ .a = 1 } }",
        ".{ .name = \"a\", .verbose = 1 }",
    });
    try all(struct {}, &.{ ".{}", ".{ .a = 1 }", ".{ 1 }", " .{ } ", ".{\n}", ".{ // c\n }" });
    try all(struct { a: struct { b: struct { c: u8 } } }, &.{ ".{ .a = .{ .b = .{ .c = 1 } } }", ".{ .a = .{ .b = .{} } }", ".{ .a = .{ .b = .{ .c = 1 }, } }" });
}

test "unions are an arm, or a struct of one field" {
    try all(Shape, &.{
        ".empty",
        ".{ .empty = {} }",
        ".{ .empty = null }",
        ".{ .circle = 1.5 }",
        ".circle",
        ".{ .circle = .{} }",
        ".{ .rect = .{ .w = 1, .h = 2 } }",
        ".{ .rect = .{ .w = 1 } }",
        ".{ .pair = .{ 1, 2 } }",
        ".{ .named = \"n\" }",
        ".{ .named = \\\\n\n }",
        ".{ .circle = 1, .empty = {} }",
        ".{ .circle = 1, }",
        ".{ .circle = 1, .circle = 2 }",
        ".{ .nope = 1 }",
        ".nope",
        ".{}",
        ".{ 1 }",
        ".{ .circle }",
        ".{ .@\"circle\" = 1 }",
        ".@\"empty\"",
        "empty",
        "\"empty\"",
        ". empty",
    });
    try all(?Shape, &.{ "null", ".empty", ".{ .circle = 2 }" });
    try all([]const Shape, &.{ ".{ .empty, .{ .circle = 1 }, .empty }", ".{}", ".{ .{ .empty = {} } }" });
    try all(struct { shape: Shape, tail: u8 }, &.{ ".{ .shape = .empty, .tail = 1 }", ".{ .shape = .{ .circle = 1 }, .tail = 1 }", ".{ .tail = 1, .shape = .empty }" });
}

test "pointers follow" {
    try all(*const u8, &.{ "5", "300", "null" });
    try all(*const Point, &.{ ".{ .x = 1, .y = 2 }", ".{}" });
    try all(?*const Point, &.{ "null", ".{ .x = 1, .y = 2 }" });
    try all([]const *const u8, &.{ ".{ 1, 2 }", ".{}" });
    try all(struct { p: *const []const u8 }, &.{".{ .p = \"x\" }"});
}

test "documents are one value" {
    try all(u8, &.{ "1 2", "1\n// c\n", "1 /", "//", "", " ", "// only a comment", "1,", ",1" });
}

test "ZON written by std.zon is read back by strand" {
    const Whole = struct { a: i64, b: ?[]const u8, c: [3]u8, d: Color, e: Shape, f: []const Point, g: f64, h: bool, i: u128 };
    const value: Whole = .{
        .a = -5,
        .b = "text \"with\" \\ escapes\n\t\x01 é 😀",
        .c = .{ 1, 2, 3 },
        .d = .@"with space",
        .e = .{ .rect = .{ .w = 3, .h = 4 } },
        .f = &.{ .{ .x = 1, .y = 2 }, .{ .x = -3, .y = 4 }, .{ .x = 5, .y = 6 } },
        .g = 0.1,
        .h = true,
        .i = std.math.maxInt(u128),
    };
    inline for (.{ true, false }) |whitespace| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try std.zon.stringify.serialize(value, .{ .whitespace = whitespace }, &out.writer);
        var back = try zon.parse(Whole, testing.allocator, out.written(), .{});
        defer back.deinit();
        try testing.expectEqualDeep(value, back.value);
    }
}

fn written(value: anytype, whitespace: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try zon.write(&out.writer, value, .{ .whitespace = whitespace });
    return out.toOwnedSlice();
}

fn stdWritten(value: anytype, whitespace: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try std.zon.stringify.serialize(value, .{ .whitespace = whitespace }, &out.writer);
    return out.toOwnedSlice();
}

/// Strand writes what std writes, byte for byte, with or without its layout.
fn sameBytes(value: anytype) !void {
    inline for (.{ true, false }) |whitespace| {
        const expected = try stdWritten(value, whitespace);
        defer testing.allocator.free(expected);
        const actual = try written(value, whitespace);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
        var back = try zon.parse(@TypeOf(value), testing.allocator, actual, .{});
        defer back.deinit();
        const again = try stdWritten(back.value, whitespace);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(expected, again);
    }
}

test "written ZON is std's, byte for byte" {
    try sameBytes(@as(u8, 5));
    try sameBytes(@as(i128, std.math.minInt(i128)));
    try sameBytes(@as(u128, std.math.maxInt(u128)));
    try sameBytes(true);
    try sameBytes(@as(?u8, null));
    try sameBytes(@as(?u8, 3));
    try sameBytes(@as(f64, 0.1));
    try sameBytes(@as(f64, -0.0));
    try sameBytes(@as(f64, 1e300));
    try sameBytes(@as(f64, 5e-324));
    try sameBytes(@as(f64, 123456789.125));
    try sameBytes(@as(f32, 3.4028235e38));
    try sameBytes(@as(f32, 1.17549435e-38));
    try sameBytes(@as(f16, 65504));
    try sameBytes(@as(f128, 0.1));
    try sameBytes(std.math.inf(f64));
    try sameBytes(-std.math.inf(f32));
    try sameBytes(Color.red);
    try sameBytes(Color.@"with space");
    try sameBytes(@as([]const u8, ""));
    try sameBytes(@as([]const u8, "plain"));
    try sameBytes(@as([]const u8, "quote \" backslash \\ tab \t newline \n return \r nul \x00 del \x7f"));
    try sameBytes(@as([]const u8, "caf\u{e9} \u{1f600} \u{feff} \u{85} \u{2028} \u{2029} end"));
    try sameBytes(@as([]const u8, "single ' quote"));
    try sameBytes(@as([3]u8, .{ 1, 2, 3 }));
    try sameBytes(@as([0]u8, .{}));
    try sameBytes(@as([1]i8, .{-1}));
    try sameBytes(@as([2]i8, .{ -1, 2 }));
    try sameBytes(@as([]const i32, &.{}));
    try sameBytes(@as([]const i32, &.{7}));
    try sameBytes(@as([]const i32, &.{ 1, 2, 3, 4 }));
    try sameBytes(@as([]const []const u8, &.{ "a", "b", "c" }));
    try sameBytes(@as(@Vector(3, i32), .{ 1, 2, 3 }));
    try sameBytes(Point{ .x = 1, .y = -2 });
    try sameBytes(struct { u8, bool, []const u8 }{ 1, true, "x" });
    try sameBytes(struct {}{});
    try sameBytes(struct { only: u8 }{ .only = 1 });
    try sameBytes(struct { a: u8, b: u8, c: u8 }{ .a = 1, .b = 2, .c = 3 });
    try sameBytes(Settings{ .name = "n", .retries = 5, .verbose = true, .mode = .green, .tags = &.{ "a", "b" } });
    try sameBytes(Settings{ .name = "n" });
    try sameBytes(Shape{ .empty = {} });
    try sameBytes(Shape{ .circle = 2.5 });
    try sameBytes(Shape{ .rect = .{ .w = 1, .h = 2 } });
    try sameBytes(Shape{ .pair = .{ 3, 4 } });
    try sameBytes(Shape{ .named = "x" });
    try sameBytes(@as([]const Shape, &.{ .{ .empty = {} }, .{ .circle = 1 }, .{ .named = "n" } }));
    try sameBytes(struct { a: struct { b: struct { c: []const Point } } }{ .a = .{ .b = .{ .c = &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 } } } } });
    const keyword_named = struct { @"error": u8, @"while": u8, type: u8, _: u8 = 0, @"two words": u8, u8: u8 };
    try sameBytes(keyword_named{ .@"error" = 1, .@"while" = 2, .type = 3, .@"two words" = 4, .u8 = 5 });
    const pointed: u8 = 9;
    try sameBytes(@as(*const u8, &pointed));
    try sameBytes(@as(?*const u8, &pointed));
}

fn owned(comptime T: type, source: []const u8, options: zon.ParseOptions) !zon.Parsed(T) {
    return zon.parseOwned(T, testing.allocator, source, options);
}

test "strand differs from std.zon here, and says so" {
    // A byte slice is text, or bytes when it says so; a tuple of numbers is a list of numbers.
    try testing.expectError(error.UnexpectedType, zon.parse([]const u8, testing.allocator, ".{ 97, 98 }", .{}));
    try testing.expectError(error.UnexpectedType, zon.parse([]const u8, testing.allocator, ".{}", .{}));
    try testing.expectError(error.InvalidUtf8, zon.parse([]const u8, testing.allocator, "\"\\xff\"", .{}));
    const Raw = struct {
        data: []const u8,
        pub const strand = .{ .fields = .{ .data = .{ .as = .bytes } } };
    };
    var bytes = try zon.parse(Raw, testing.allocator, ".{ .data = \"\\xff\\x00a\" }", .{});
    defer bytes.deinit();
    try testing.expectEqualSlices(u8, "\xff\x00a", bytes.value.data);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try zon.write(&out.writer, bytes.value, .{});
    try testing.expectEqualStrings(".{ .data = \"\\xff\\x00a\" }", out.written());
    // A literal past the width of the type is refused, not rounded to infinity.
    try testing.expectError(error.NumberOutOfRange, zon.parse(f64, testing.allocator, "1e999", .{}));
    try testing.expectError(error.NumberOutOfRange, zon.parse(f32, testing.allocator, "3.5e38", .{}));
    try testing.expectError(error.NumberOutOfRange, zon.parse(f16, testing.allocator, "65520", .{}));
    // A float is read once, to the destination's width: no f128 in between. This
    // decimal is a hair above the midpoint of 1 and the f32 after it, which f128 cannot see.
    const hair = "1.00000005960464477539062500000000000001";
    const direct = try std.fmt.parseFloat(f32, hair);
    const through: f32 = @floatCast(try std.fmt.parseFloat(f128, hair));
    try testing.expect(direct != through);
    var narrow = try zon.parse(f32, testing.allocator, hair, .{});
    defer narrow.deinit();
    try testing.expectEqual(direct, narrow.value);
    // Nothing with no meaning in ZON is derived: not a nested optional, not a name.
    try testing.expectEqual(core.Support.unsupported, core.describe(??u8, zon.capabilities).support);
    try testing.expectEqual(core.Support.unsupported, core.describe(core.NamedUnit("n"), zon.capabilities).support);
}

test "ZON takes the shared policy: names, aliases, defaults, unknown fields, bytes, scalars" {
    const Config = struct {
        id: u32,
        label: []const u8 = "none",
        mode: Color = .red,
        pub const strand = .{
            .rename_all = .kebab_case,
            .fields = .{ .id = .{ .name = "ident", .aliases = &.{"id"} }, .label = .{ .max_len = 8 } },
        };
    };
    var one = try owned(Config, ".{ .ident = 7 }", .{});
    defer one.deinit();
    try testing.expectEqual(@as(u32, 7), one.value.id);
    try testing.expectEqualStrings("none", one.value.label);
    var alias = try owned(Config, ".{ .id = 8, .label = \"short\", .mode = .blue }", .{});
    defer alias.deinit();
    try testing.expectEqual(@as(u32, 8), alias.value.id);
    try testing.expectError(error.LengthLimit, owned(Config, ".{ .id = 8, .label = \"much too long\" }", .{}));
    try testing.expectError(error.UnknownField, owned(Config, ".{ .id = 8, .extra = 1 }", .{}));
    try testing.expectError(error.DuplicateField, owned(Config, ".{ .id = 8, .ident = 9 }", .{}));
    var lenient = try owned(Config, ".{ .id = 8, .extra = .{ 1, .{ .nested = \"x\" } }, .more = \\\\text\n }", .{ .ignore_unknown_fields = true });
    defer lenient.deinit();
    var settings_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer settings_out.deinit();
    try zon.write(&settings_out.writer, one.value, .{});
    try testing.expectEqualStrings(".{\n    .ident = 7,\n    .label = \"none\",\n    .mode = .red,\n}", settings_out.written());

    const Letters = struct { first: core.Scalar, second: core.Scalar };
    var letters = try owned(Letters, ".{ .first = 'a', .second = '\\u{1F600}' }", .{});
    defer letters.deinit();
    try testing.expectEqual(@as(u21, 0x1f600), letters.value.second.value);
    var letters_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer letters_out.deinit();
    try zon.write(&letters_out.writer, letters.value, .{});
    try testing.expectEqualStrings(".{ .first = 'a', .second = '\u{1f600}' }", letters_out.written());
    try testing.expectError(error.UnexpectedType, owned(Letters, ".{ .first = \"a\", .second = 'b' }", .{}));
}

test "ZON maps, tagged unions and raw values" {
    const Table = struct { entries: core.Pairs([]const u8, u8) };
    var table = try owned(Table, ".{ .entries = .{ .a = 1, .@\"b c\" = 2 } }", .{});
    defer table.deinit();
    try testing.expectEqual(@as(usize, 2), table.value.entries.items.len);
    try testing.expectEqualStrings("b c", table.value.entries.items[1].key);
    var table_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer table_out.deinit();
    try zon.write(&table_out.writer, table.value, .{ .whitespace = false });
    try testing.expectEqualStrings(".{.entries=.{.a=1,.@\"b c\"=2}}", table_out.written());
    try testing.expectError(error.DuplicateField, owned(Table, ".{ .entries = .{ .a = 1, .a = 2 } }", .{}));
    const dup_keys: core.Pairs([]const u8, u8) = .{ .items = &.{ .{ .key = "k", .value = 1 }, .{ .key = "k", .value = 2 } } };
    var dup_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dup_out.deinit();
    try testing.expectError(error.DuplicateField, zon.write(&dup_out.writer, dup_keys, .{}));

    const Event = union(enum) {
        opened: struct { path: []const u8 },
        closed,
        pub const strand = .{ .tag = "type" };
    };
    var event = try owned(Event, ".{ .path = \"/tmp\", .type = \"opened\" }", .{});
    defer event.deinit();
    try testing.expectEqualStrings("/tmp", event.value.opened.path);
    var closed = try owned(Event, ".{ .type = \"closed\" }", .{});
    defer closed.deinit();
    try testing.expect(closed.value == .closed);
    var event_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer event_out.deinit();
    try zon.write(&event_out.writer, event.value, .{});
    try testing.expectEqualStrings(".{ .type = \"opened\", .path = \"/tmp\" }", event_out.written());
    const Adjacent = union(enum) {
        point: Point,
        label: []const u8,
        pub const strand = .{ .tag = "kind", .content = "value" };
    };
    var adjacent = try owned(Adjacent, ".{ .value = .{ .x = 1, .y = 2 }, .kind = \"point\" }", .{});
    defer adjacent.deinit();
    try testing.expectEqual(@as(i32, 2), adjacent.value.point.y);

    const Holder = struct { before: u8, kept: zon.Raw, after: u8 };
    var holder = try zon.parse(Holder, testing.allocator, ".{ .before = 1, .kept = // c\n .{ 1, .{ .deep = \"x\" } } , .after = 2 }", .{});
    defer holder.deinit();
    try testing.expectEqualStrings(".{ 1, .{ .deep = \"x\" } }", holder.value.kept.bytes);
    try testing.expectError(error.SyntaxError, zon.parse(Holder, testing.allocator, ".{ .before = 1, .kept = .{ 1, , }, .after = 2 }", .{}));
    var raw_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer raw_out.deinit();
    try zon.write(&raw_out.writer, holder.value, .{ .whitespace = false });
    try testing.expectEqualStrings(".{.before=1,.kept=.{ 1, .{ .deep = \"x\" } },.after=2}", raw_out.written());
    const bad: Holder = .{ .before = 1, .kept = .{ .bytes = ".{ 1, " }, .after = 2 };
    var bad_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer bad_out.deinit();
    try testing.expectError(error.InvalidRaw, zon.write(&bad_out.writer, bad, .{}));
}

test "borrowed text points into the input and owned text does not" {
    const Doc = struct { plain: []const u8, escaped: []const u8, lines: []const u8, one: []const u8 };
    var source = ".{ .plain = \"plain text\", .escaped = \"two\\nlines\", .lines = \\\\a\n\\\\b\n, .one = \\\\single\n }".*;
    var borrowed = try zon.parse(Doc, testing.allocator, &source, .{});
    defer borrowed.deinit();
    const range = @intFromPtr(&source);
    const inside = struct {
        fn within(bytes: []const u8, base: usize, len: usize) bool {
            const at = @intFromPtr(bytes.ptr);
            return at >= base and at + bytes.len <= base + len;
        }
    }.within;
    try testing.expect(inside(borrowed.value.plain, range, source.len));
    try testing.expect(inside(borrowed.value.one, range, source.len));
    try testing.expect(!inside(borrowed.value.escaped, range, source.len));
    try testing.expect(!inside(borrowed.value.lines, range, source.len));
    try testing.expectEqualStrings("two\nlines", borrowed.value.escaped);
    try testing.expectEqualStrings("a\nb", borrowed.value.lines);
    try testing.expectEqualStrings("single", borrowed.value.one);
    // The borrowed text is exactly the part of the input it was.
    try testing.expectEqual(@as(usize, 0), borrowed.requested_peak - borrowed.value.escaped.len - borrowed.value.lines.len);
    var copy = try zon.parseOwned(Doc, testing.allocator, &source, .{});
    defer copy.deinit();
    @memset(&source, 'x');
    try testing.expectEqualStrings("plain text", copy.value.plain);
    try testing.expectEqualStrings("single", copy.value.one);
    try testing.expect(!inside(copy.value.plain, range, source.len));
}

fn nested(gpa: std.mem.Allocator, levels: usize, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..levels) |_| try out.appendSlice(gpa, ".{ ");
    try out.appendSlice(gpa, inner);
    for (0..levels) |_| try out.appendSlice(gpa, " }");
    return out.toOwnedSlice(gpa);
}

test "every limit holds at its boundary, and reaches ignored and raw data" {
    // Depth: the container that would be one too many fails, wherever it is.
    const Skipper = struct { a: u8 };
    for ([_]usize{ 1, 2, 5, 127, 128 }) |levels| {
        const source = try nested(testing.allocator, levels, "1");
        defer testing.allocator.free(source);
        var raw = try zon.parse(zon.Raw, testing.allocator, source, .{ .limits = .{ .depth = levels } });
        raw.deinit();
        try testing.expectError(error.DepthLimit, zon.parse(zon.Raw, testing.allocator, source, .{ .limits = .{ .depth = levels - 1 } }));
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(testing.allocator);
        try wrapped.appendSlice(testing.allocator, ".{ .a = 1, .skipped = ");
        try wrapped.appendSlice(testing.allocator, source);
        try wrapped.appendSlice(testing.allocator, " }");
        try testing.expectError(error.DepthLimit, zon.parse(Skipper, testing.allocator, wrapped.items, .{ .ignore_unknown_fields = true, .limits = .{ .depth = levels } }));
        var passed = try zon.parse(Skipper, testing.allocator, wrapped.items, .{ .ignore_unknown_fields = true, .limits = .{ .depth = levels + 1 } });
        passed.deinit();
    }
    // Far past any limit: refused at the limit, not after reading it all.
    const deep = try nested(testing.allocator, 100_000, "1");
    defer testing.allocator.free(deep);
    try testing.expectError(error.DepthLimit, zon.parse(zon.Raw, testing.allocator, deep, .{}));
    const hidden = try std.mem.concat(testing.allocator, u8, &.{ ".{ .a = 1, .z = ", deep, " }" });
    defer testing.allocator.free(hidden);
    try testing.expectError(error.DepthLimit, zon.parse(struct { a: u8 }, testing.allocator, hidden, .{ .ignore_unknown_fields = true }));
    // Input bytes, at the byte.
    try testing.expectError(error.InputLimit, zon.parse(u8, testing.allocator, "12", .{ .limits = .{ .input_bytes = 1 } }));
    var two = try zon.parse(u8, testing.allocator, "12", .{ .limits = .{ .input_bytes = 2 } });
    two.deinit();
    try testing.expectError(error.InputLimit, zon.parseLeaky(u8, testing.allocator, "12", .{ .limits = .{ .input_bytes = 1 } }));
    // Strings: decoded length, whether the literal is escaped or not.
    try testing.expectError(error.LengthLimit, zon.parse([]const u8, testing.allocator, "\"abc\"", .{ .limits = .{ .string_bytes = 2 } }));
    var abc = try zon.parse([]const u8, testing.allocator, "\"abc\"", .{ .limits = .{ .string_bytes = 3 } });
    abc.deinit();
    try testing.expectError(error.LengthLimit, zon.parse([]const u8, testing.allocator, "\"a\\nb\"", .{ .limits = .{ .string_bytes = 2 } }));
    var escaped = try zon.parse([]const u8, testing.allocator, "\"a\\nb\"", .{ .limits = .{ .string_bytes = 3 } });
    escaped.deinit();
    try testing.expectError(error.LengthLimit, zon.parse([]const u8, testing.allocator, "\\\\ab\n\\\\cd", .{ .limits = .{ .string_bytes = 4 } }));
    // Keys: ignored fields have keys too.
    try testing.expectError(error.LengthLimit, zon.parse(Skipper, testing.allocator, ".{ .a = 1, .long_name = 2 }", .{ .ignore_unknown_fields = true, .limits = .{ .key_bytes = 5 } }));
    try testing.expectError(error.LengthLimit, zon.parse(Skipper, testing.allocator, ".{ .a = 1, .@\"escaped\\x20name\" = 2 }", .{ .ignore_unknown_fields = true, .limits = .{ .key_bytes = 5 } }));
    // Numbers: the spelling.
    try testing.expectError(error.LengthLimit, zon.parse(u64, testing.allocator, "1_000_000", .{ .limits = .{ .numeric_bytes = 8 } }));
    var spelled = try zon.parse(u64, testing.allocator, "1_000_000", .{ .limits = .{ .numeric_bytes = 9 } });
    spelled.deinit();
    try testing.expectError(error.LengthLimit, zon.parse(i64, testing.allocator, "-1_000_000", .{ .limits = .{ .numeric_bytes = 9 } }));
    try testing.expectError(error.LengthLimit, zon.parse(i64, testing.allocator, "- 1_000_000", .{ .limits = .{ .numeric_bytes = 8 } }));
    // Items and work, which a skipped list still counts.
    try testing.expectError(error.ItemLimit, zon.parse([]const u8, testing.allocator, "\"x\"", .{ .limits = .{ .items = 0 } }));
    try testing.expectError(error.ItemLimit, zon.parse(Skipper, testing.allocator, ".{ .a = 1, .z = .{ 1, 2, 3, 4 } }", .{ .ignore_unknown_fields = true, .limits = .{ .items = 6 } }));
    try testing.expectError(error.ItemLimit, zon.parse(zon.Raw, testing.allocator, ".{ 1, 2 }", .{ .limits = .{ .container_items = 1 } }));
    var one_item = try zon.parse(zon.Raw, testing.allocator, ".{ 1 }", .{ .limits = .{ .container_items = 1 } });
    one_item.deinit();
    try testing.expectError(error.WorkLimit, zon.parse(zon.Raw, testing.allocator, ".{ 1, 2, 3 }", .{ .limits = .{ .work = 10 } }));
    // Requested allocation.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.AllocationLimit, zon.parseLeaky([]const u8, arena.allocator(), "\"a\\nb\"", .{ .limits = .{ .allocation_bytes = 2 } }));
    try testing.expectEqualStrings("a\nb", try zon.parseLeaky([]const u8, arena.allocator(), "\"a\\nb\"", .{ .limits = .{ .allocation_bytes = 3 } }));
    try testing.expectError(error.AllocationLimit, zon.parse([]const u8, testing.allocator, "\"a\\nb\"", .{ .limits = .{ .allocation_bytes = 0 } }));
    // Output.
    var memory: [16]u8 = undefined;
    var out = std.Io.Writer.fixed(&memory);
    try testing.expectError(error.OutputLimit, zon.write(&out, @as([]const u8, "abcdef"), .{ .limits = .{ .output_bytes = 7 } }));
    out = std.Io.Writer.fixed(&memory);
    try zon.write(&out, @as([]const u8, "abcdef"), .{ .limits = .{ .output_bytes = 8 } });
    try testing.expectEqualStrings("\"abcdef\"", out.buffered());
    // Written depth.
    const NestedOut = struct {
        const Self = @This();
        next: ?*const Self = null,
    };
    const leaf: NestedOut = .{};
    const middle: NestedOut = .{ .next = &leaf };
    const top: NestedOut = .{ .next = &middle };
    var depth_memory: [256]u8 = undefined;
    out = std.Io.Writer.fixed(&depth_memory);
    try testing.expectError(error.DepthLimit, zon.write(&out, top, .{ .limits = .{ .depth = 2 } }));
}

test "a document cut anywhere, or mutated anywhere, is a value or an error and never worse" {
    const Doc = struct {
        name: []const u8,
        list: []const i32,
        shape: Shape,
        nested: struct { color: Color, ratio: f64, tag: ?[]const u8 },
    };
    const source =
        \\.{
        \\    // a comment
        \\    .name = "caf\u{e9} \"quoted\"",
        \\    .list = .{ 1, -2, 0x30, 1_000, 'a' },
        \\    .shape = .{ .rect = .{ .w = 3, .h = 4 } },
        \\    .nested = .{ .color = .@"with space", .ratio = -1.5e-3, .tag = \\multi
        \\        \\line
        \\    },
        \\}
    ;
    var whole = try zon.parse(Doc, testing.allocator, source, .{});
    whole.deinit();
    for (0..source.len) |n| {
        // A prefix is a document only if the cut fell where the value ended.
        if (zon.parse(Doc, testing.allocator, source[0..n], .{})) |value| {
            var owner = value;
            owner.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    var mutated: [source.len]u8 = undefined;
    const bytes = "}{,.=\\\"' \n/-_@0aAe\x00\x01\x7f";
    for (0..source.len) |at| for (bytes) |byte| {
        @memcpy(&mutated, source);
        mutated[at] = byte;
        try agree(Doc, &mutated);
    };
}

fn parseSweep(gpa: std.mem.Allocator) !void {
    var no_resize: shakedown.alloc.NoResize = .init(gpa);
    const Doc = struct { name: []const u8, list: []const []const u8, shape: Shape, pairs: core.Pairs([]const u8, u8) };
    var owner = try zon.parseOwned(Doc, no_resize.allocator(),
        \\.{ .name = "a\nb", .list = .{ "x", \\y
        \\\\z
        \\, "q\x41" }, .shape = .{ .named = "n\tm" }, .pairs = .{ .@"k k" = 1, .plain = 2 } }
    , .{});
    defer owner.deinit();
    try testing.expectEqualStrings("a\nb", owner.value.name);
}
fn writeSweep(gpa: std.mem.Allocator) !void {
    var no_resize: shakedown.alloc.NoResize = .init(gpa);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    // Scratch: the frames past 128 levels live in it, so they allocate from it.
    const scratch = try gpa.alloc(u8, 8192);
    defer gpa.free(scratch);
    _ = &no_resize;
    try zon.write(&out, Settings{ .name = "a\nb", .tags = &.{ "x", "y" } }, .{ .scratch = scratch });
}
test "every allocation of a parse rolls back" {
    try testing.checkAllAllocationFailures(testing.allocator, parseSweep, .{});
    try testing.checkAllAllocationFailures(testing.allocator, writeSweep, .{});
    var generated: [1]u8 = .{0};
    _ = &generated;
}

const Generated = struct {
    small: u8,
    wide: i128,
    big: u64,
    flag: bool,
    ratio: f64,
    narrow: f32,
    text: []const u8,
    color: Color,
    pick: ?Color,
    list: []const i16,
    fixed: [3]u16,
    shape: Shape,
    points: []const Point,
    nested: struct { a: ?u8, b: []const []const u8 },
};

fn generatedValue(arena: std.mem.Allocator, case: *shakedown.Case) !Generated {
    const gen = shakedown.gen;
    const source = case.source;
    var ratio = gen.float(source, f64);
    if (!std.math.isFinite(ratio)) ratio = 0.5;
    var narrow = gen.float(source, f32);
    if (!std.math.isFinite(narrow)) narrow = -0.25;
    const list = try arena.alloc(i16, gen.intRange(source, usize, 0, 5));
    for (list) |*item| item.* = gen.int(source, i16);
    const points = try arena.alloc(Point, gen.intRange(source, usize, 0, 4));
    for (points) |*point| point.* = .{ .x = gen.int(source, i32), .y = gen.int(source, i32) };
    const words = try arena.alloc([]const u8, gen.intRange(source, usize, 0, 3));
    for (words) |*word| word.* = try gen.string(source, arena, .{ .kind = .utf8, .max_len = 12 });
    const shape: Shape = switch (gen.intRange(source, u8, 0, 4)) {
        0 => .empty,
        1 => .{ .circle = ratio32(source) },
        2 => .{ .rect = .{ .w = gen.int(source, u16), .h = gen.int(source, u16) } },
        3 => .{ .pair = .{ gen.int(source, u8), gen.int(source, u8) } },
        else => .{ .named = try gen.string(source, arena, .{ .kind = .utf8, .max_len = 12 }) },
    };
    return .{
        .small = gen.int(source, u8),
        .wide = gen.int(source, i128),
        .big = gen.int(source, u64),
        .flag = gen.boolean(source),
        .ratio = ratio,
        .narrow = narrow,
        .text = try gen.string(source, arena, .{ .kind = .utf8, .max_len = 24 }),
        .color = gen.enumValue(source, Color),
        .pick = if (gen.boolean(source)) gen.enumValue(source, Color) else null,
        .list = list,
        .fixed = .{ gen.int(source, u16), gen.int(source, u16), gen.int(source, u16) },
        .shape = shape,
        .points = points,
        .nested = .{ .a = if (gen.boolean(source)) gen.int(source, u8) else null, .b = words },
    };
}
fn ratio32(source: *shakedown.Source) f32 {
    const value = shakedown.gen.float(source, f32);
    return if (std.math.isFinite(value)) value else 1.5;
}

fn generatedZon(_: void, case: *shakedown.Case) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena.deinit();
    const value = try generatedValue(arena.allocator(), case);
    inline for (.{ true, false }) |whitespace| {
        const mine = try written(value, whitespace);
        defer testing.allocator.free(mine);
        const theirs = try stdWritten(value, whitespace);
        defer testing.allocator.free(theirs);
        try testing.expectEqualStrings(theirs, mine);
        var back = try zon.parseOwned(Generated, case.gpa, mine, .{});
        defer back.deinit();
        try testing.expectEqualDeep(value, back.value);
        // And std reads what strand wrote, as the same value.
        try agree(Generated, mine);
    }
}
test "generated values are written as std writes them and read back equal" {
    try shakedown.check(testing.allocator, {}, generatedZon, .{ .cases = 256, .seed = 0x7a6f6e53335f3031 });
}

test "a failure says where it was" {
    var diagnostics: core.Diagnostics = .{};
    const source = ".{\n    .x = 1,\n    .y = \"two\",\n}";
    try testing.expectError(error.UnexpectedType, zon.parse(Point, testing.allocator, source, .{ .diagnostics = &diagnostics }));
    try testing.expectEqualStrings("zon", diagnostics.format);
    try testing.expectEqual(@as(?usize, 3), diagnostics.line);
    try testing.expectEqual(@as(?usize, 10), diagnostics.column);
    try testing.expectEqual(@as(usize, 1), diagnostics.path.len);
    try testing.expectEqualStrings("y", diagnostics.path.frames()[0].name.view());
    var unknown: core.Diagnostics = .{};
    try testing.expectError(error.UnknownField, zon.parse(Point, testing.allocator, ".{ .x = 1, .y = 2, .evil\\x0a\\x1b = 3 }".*[0..], .{ .diagnostics = &unknown }) catch |err| switch (err) {
        error.SyntaxError => error.UnknownField,
        else => err,
    });
}

const tokens = [_][]const u8{
    ".{", ".{", "}", "}",         ",",     ",",  ".x",     ".y", ".a", ".@\"y\"", "=", "=", "1", "-2", "0x10", "300", "1.5", "1e2", "-", " ", "\n", "\"a\"", "\"\\n\"", "\"\\xff\"", "\\\\ml\n", ".red", ".empty", ".circle", ".rect", "true", "null", "inf", "'a'", "// c\n", "/// d\n", ".w", ".h", "x", "(", ")", "@import",
    "\"é\"",
    "{",  "[",  "]", "undefined", "0b1_1", "1_", ".named",
};

/// Token soup from `tokens`, and that soup cut from a document std writes.
fn soup(arena: std.mem.Allocator, case: *shakedown.Case) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const count = shakedown.gen.intRange(case.source, usize, 0, 18);
    for (0..count) |_| try out.appendSlice(arena, shakedown.gen.oneOf(case.source, []const u8, &tokens));
    return out.items;
}

fn soupAgrees(_: void, case: *shakedown.Case) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena.deinit();
    const source = try soup(arena.allocator(), case);
    // Wrapped as a struct, a tuple and a union too: soup rarely makes a whole document.
    const wrapped = [_][]const u8{
        source,
        try std.mem.concat(arena.allocator(), u8, &.{ ".{ ", source, " }" }),
        try std.mem.concat(arena.allocator(), u8, &.{ ".{ .x = ", source, " }" }),
        try std.mem.concat(arena.allocator(), u8, &.{ ".{ .circle = ", source, " }" }),
        try std.mem.concat(arena.allocator(), u8, &.{ ".{ .x = 1, .y = 2, ", source, " }" }),
    };
    for (wrapped) |text| {
        try agree(Point, text);
        try agree(Shape, text);
        try agree([]const i32, text);
        try agree(struct { x: ?u8 = null, y: []const u8 = "" }, text);
        try agree([2]f32, text);
        try agree(Color, text);
    }
}
test "token soup is read as std.zon reads it, or refused where strand differs" {
    try shakedown.check(testing.allocator, {}, soupAgrees, .{ .cases = 1500, .seed = 0x7a6f6e536f757031 });
    // The soup is not all nonsense: a good part of it is a value of some type here.
    try testing.expect(accepted_by_both > 100);
}

/// What strand reads, `std.zon` reads as the same value: strand is the stricter.
fn sound(comptime T: type, source: []const u8) !void {
    const mine = try ownReading(T, source);
    defer if (mine == .value) testing.allocator.free(mine.value);
    if (mine == .failed) return;
    const theirs = try stdReading(T, source);
    defer if (theirs == .value) testing.allocator.free(theirs.value);
    try testing.expect(theirs == .value);
    try testing.expectEqualStrings(theirs.value, mine.value);
}

test "fuzz: whatever strand reads of arbitrary bytes is what std.zon reads" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const data = input[0..smith.slice(&input)];
            try sound(Settings, data);
            try sound(Shape, data);
            try sound([]const i64, data);
            try sound([3]f32, data);
            try sound(struct { u: u128, i: i128, n: ?[]const u8 }, data);
            // And bounded, whatever it is: no limit is a thing it can run past.
            var owner = zon.parseOwned(zon.Raw, testing.allocator, data, .{ .limits = .{ .depth = 8, .work = 4096, .allocation_bytes = 4096 } }) catch return;
            owner.deinit();
        }
    }.run, .{});
}

test "an exact float refuses what its width cannot hold" {
    const Exact = struct {
        x: f32,
        pub const strand = .{ .fields = .{ .x = .{ .exact = true } } };
    };
    for ([_][]const u8{ ".{ .x = 0.5 }", ".{ .x = 16777216 }", ".{ .x = 0x1.8p1 }", ".{ .x = -2 }", ".{ .x = 'a' }", ".{ .x = inf }" }) |source| {
        var ok = try zon.parse(Exact, testing.allocator, source, .{});
        ok.deinit();
    }
    for ([_][]const u8{ ".{ .x = 0.1 }", ".{ .x = 16777217 }", ".{ .x = 1e-50 }" }) |source| {
        try testing.expectError(error.InexactNumber, zon.parse(Exact, testing.allocator, source, .{}));
    }
    try testing.expectError(error.NumberOutOfRange, zon.parse(Exact, testing.allocator, ".{ .x = 1e50 }", .{}));
}
