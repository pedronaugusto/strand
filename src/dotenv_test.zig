//! .env files: read as python-dotenv reads them, with nothing interpolated,
//! typed as INI's values are, and written to read back as themselves.
const std = @import("std");
const strand = @import("strand.zig");
const dotenv = strand.dotenv;
const core = strand.core;
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Env = core.Pairs([]const u8, ?[]const u8);

const Service = struct {
    DATABASE_URL: []const u8,
    PORT: u16,
    DEBUG: bool,
    GREETING: []const u8,
    KEY: []const u8,
    PRICE: []const u8,
    NOTE: ?[]const u8,
    EMPTY: []const u8,
};

test "a service's environment, as python-dotenv reads it" {
    const input = "\u{feff}# the service\r\n" ++
        "export DATABASE_URL=postgres://db:5432/app  # where the data is\r\n" ++
        "PORT = 8443\n" ++
        "DEBUG=yes\n" ++
        "GREETING=\"Hello,\\n\\tworld \\\"!\\\"\"\n" ++
        "KEY='-----BEGIN KEY-----\nabc\n-----END KEY-----'\n" ++
        "PRICE=${COST}$5 #not a comment#\n" ++
        "NOTE\n" ++
        "EMPTY=\n";
    var parsed = try dotenv.parse(Service, gpa, input, .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("postgres://db:5432/app", v.DATABASE_URL);
    try std.testing.expectEqual(8443, v.PORT);
    try std.testing.expect(v.DEBUG);
    try std.testing.expectEqualStrings("Hello,\n\tworld \"!\"", v.GREETING);
    try std.testing.expectEqualStrings("-----BEGIN KEY-----\nabc\n-----END KEY-----", v.KEY);
    // No interpolation: `$` is text.
    try std.testing.expectEqualStrings("${COST}$5", v.PRICE);
    try std.testing.expect(v.NOTE == null);
    try std.testing.expectEqualStrings("", v.EMPTY);
}

test "python-dotenv's readings: keys, quotes, comments and escapes" {
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "'a b'=c", "a b", "c" },
        .{ "[=b", "[", "b" },
        .{ "a.b-c/d=1", "a.b-c/d", "1" },
        .{ "export=1", "export", "1" },
        .{ "a= # note", "a", "" },
        .{ "a=#v", "a", "#v" },
        .{ "a=b#c", "a", "b#c" },
        .{ "a=b\t#c", "a", "b" },
        .{ "a=\"b\" # c", "a", "b" },
        .{ "a=\"b\"#c", "a", "b" },
        .{ "a=\"\\d\\$\"", "a", "\\d\\$" },
        .{ "a='it\\'s \\\\ \\n'", "a", "it's \\ \\n" },
        .{ "a=\"\\a\\b\\f\\r\\v\\'\"", "a", "\x07\x08\x0c\r\x0b'" },
        .{ "a=b c  ", "a", "b c" },
        .{ "a=\xc2\xa0b\xc2\xa0", "a", "b" },
        .{ "a  # just a key", "a", null },
        .{ "a=C:\\dir\\new", "a", "C:\\dir\\new" },
    };
    for (cases) |case| {
        var parsed = try dotenv.parse(Env, gpa, case[0], .{});
        defer parsed.deinit();
        try std.testing.expectEqual(1, parsed.value.items.len);
        try std.testing.expectEqualStrings(case[1], parsed.value.items[0].key);
        if (case[2]) |value| try std.testing.expectEqualStrings(value, parsed.value.items[0].value.?) else try std.testing.expect(parsed.value.items[0].value == null);
    }
    // A line end in quotes is a line feed, as Python reads a text file.
    var ends = try dotenv.parse(Env, gpa, "'a\r\nb\\'=\"x\r\ny\rz\\\r\"\r\nc='p\rq'", .{});
    defer ends.deinit();
    try std.testing.expectEqualStrings("a\nb\\", ends.value.items[0].key);
    try std.testing.expectEqualStrings("x\ny\nz\\\n", ends.value.items[0].value.?);
    try std.testing.expectEqualStrings("p\nq", ends.value.items[1].value.?);
    var none = try dotenv.parse(Env, gpa, "\n  # only a comment\n\r\n", .{});
    defer none.deinit();
    try std.testing.expectEqual(0, none.value.items.len);
}

test "what python-dotenv skips as an error, a key given twice and bytes not UTF-8 are refused" {
    const bad = [_][]const u8{ "=v", "a b=1", "a=\"x\" y", "a='open", "a=\"open\\\"", "''=v", "export =1", "a=b\n=c" };
    for (bad) |input| try std.testing.expectError(error.SyntaxError, dotenv.parse(Env, gpa, input, .{}));
    try std.testing.expectError(error.DuplicateField, dotenv.parse(Env, gpa, "a=1\na=2\n", .{}));
    try std.testing.expectError(error.DuplicateField, dotenv.parse(Env, gpa, "a\n'a'=2\n", .{}));
    try std.testing.expectError(error.InvalidUtf8, dotenv.parse(Env, gpa, "a=\xff\n", .{}));
    try std.testing.expectError(error.UnexpectedType, dotenv.parse(struct { a: []const u8 }, gpa, "a\n", .{}));
    try std.testing.expectError(error.UnknownField, dotenv.parse(struct { a: u8 }, gpa, "a=1\nb=2\n", .{}));
    var ignored = try dotenv.parse(struct { a: u8 }, gpa, "a=1\nb=2\n", .{ .ignore_unknown_fields = true });
    defer ignored.deinit();
    var diagnostics: core.Diagnostics = .{};
    try std.testing.expectError(error.SyntaxError, dotenv.parse(Env, gpa, "a=1\nb=2\nc d\n", .{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(3, diagnostics.line);
}

test "written: quoted only where it must be, a null a key alone" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const S = struct { A: []const u8, B: []const u8, C: []const u8, D: []const u8, E: ?[]const u8, F: u16, G: bool, H: []const u8 };
    const value: S = .{ .A = "plain #1", .B = " padded ", .C = "it's", .D = "two\nlines \\ \"q\"", .E = null, .F = 80, .G = true, .H = "" };
    try dotenv.write(&out.writer, value, .{});
    try std.testing.expectEqualStrings("A='plain #1'\nB=' padded '\nC=it's\nD=\"two\\nlines \\\\ \\\"q\\\"\"\nE\nF=80\nG=true\nH=\n", out.written());
    var back = try dotenv.parse(S, gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expectEqualStrings(value.D, back.value.D);
    try std.testing.expect(back.value.E == null);
    try std.testing.expectEqualStrings(value.B, back.value.B);
    // What would not read back as itself.
    try std.testing.expectError(error.UnsupportedValue, dotenv.write(&out.writer, struct { @"'a": u8 }{ .@"'a" = 1 }, .{}));
    try std.testing.expectError(error.UnsupportedValue, dotenv.write(&out.writer, struct { @"a b'": u8 }{ .@"a b'" = 1 }, .{}));
    // A key python-dotenv reads only in quotes is written in them.
    out.clearRetainingCapacity();
    try dotenv.write(&out.writer, struct { @"a b": u8, @"a=b": u8 }{ .@"a b" = 1, .@"a=b" = 2 }, .{});
    try std.testing.expectEqualStrings("'a b'=1\n'a=b'=2\n", out.written());
    try std.testing.expectError(error.UnsupportedValue, dotenv.write(&out.writer, struct { s: struct { a: u8 } }{ .s = .{ .a = 1 } }, .{}));
    try std.testing.expectError(error.UnsupportedValue, dotenv.write(&out.writer, struct { l: []const u16 }{ .l = &.{1} }, .{}));
    try std.testing.expectError(error.UnsupportedValue, dotenv.write(&out.writer, struct { f: f64 }{ .f = std.math.nan(f64) }, .{}));
    const twice = [_]core.Pair([]const u8, ?[]const u8){ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = null } };
    try std.testing.expectError(error.DuplicateField, dotenv.write(&out.writer, Env{ .items = &twice }, .{}));
}

const alphabet = "ab_ -=#'\"\\$\t\n\r.:";
fn generatedText(case: *shakedown.Case, max: usize, unicode: bool) ![]const u8 {
    const n = gen.intRange(case.source, usize, 0, max);
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| {
        if (unicode and gen.intRange(case.source, u8, 0, 9) == 0) {
            try out.appendSlice(case.gpa, gen.oneOf(case.source, []const u8, &.{ "\u{a0}", "\u{2028}", "\u{85}", "é", "\u{feff}" }));
        } else try out.append(case.gpa, alphabet[gen.intRange(case.source, usize, 0, alphabet.len - 1)]);
    }
    return out.items;
}
/// A generated file that writes reads back as itself.
fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const n = gen.intRange(case.source, usize, 0, 5);
    const items = try case.gpa.alloc(core.Pair([]const u8, ?[]const u8), n);
    for (items) |*item| item.* = .{
        .key = try generatedText(case, 5, true),
        .value = if (gen.weighted(case.source, &.{ 5, 1 }) == 0) try generatedText(case, 12, true) else null,
    };
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    defer out.deinit();
    dotenv.write(&out.writer, Env{ .items = items }, .{}) catch |err| switch (err) {
        error.UnsupportedValue, error.DuplicateField => return,
        else => return err,
    };
    case.note("written:\n{s}", .{out.written()});
    var back = try dotenv.parse(Env, case.gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expectEqual(items.len, back.value.items.len);
    for (items, back.value.items) |w, r| {
        try std.testing.expectEqualStrings(w.key, r.key);
        if (w.value) |text| try std.testing.expectEqualStrings(text, r.value.?) else try std.testing.expect(r.value == null);
    }
}

test "generated files that write read back as themselves" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 2000 });
}

const examples = [_][]const u8{
    "# c\nexport A=1 # n\nB = 'x\ny'\nC=\"a\\nb\\\"\" # d\nD\nE=\n",
    "'k k'=v\r\nF=G=H\r\nI=  #j\r\nK=\"\\d\\'\"\n",
    "\u{feff}L='it\\'s'\n  M=\u{a0}n o\u{2028}\nexport=x\n",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [160]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {f}", .{std.zig.fmtString(input)});
    var parsed = dotenv.parse(Env, case.gpa, input, .{ .limits = .{ .work = 1 << 16 } }) catch return;
    defer parsed.deinit();
    // What is read writes, and reads back as itself.
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    defer out.deinit();
    try dotenv.write(&out.writer, parsed.value, .{});
    var back = try dotenv.parse(Env, case.gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expectEqual(parsed.value.items.len, back.value.items.len);
    for (parsed.value.items, back.value.items) |w, r| {
        try std.testing.expectEqualStrings(w.key, r.key);
        if (w.value) |text| try std.testing.expectEqualStrings(text, r.value.?) else try std.testing.expect(r.value == null);
    }
}

test "fuzz: any bytes are a .env file or refused, and a file read writes and reads back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
