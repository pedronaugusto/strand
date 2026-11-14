//! CSV: RFC 4180's own examples, rows as structs by the header and as tuples
//! by position, nulls as empty fields, the dialects, streaming rows, and what
//! the writer writes read back as it was.
const std = @import("std");
const csv = @import("csv.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Mode = enum { fast, careful };
const Row = struct {
    name: []const u8,
    count: u32,
    ratio: f64 = 0,
    mode: Mode = .fast,
    note: ?[]const u8 = null,
    limit: ?u16 = null,
};

test "rows by the header's names: quoted fields, doubled quotes, line breaks inside quotes" {
    const input = "count,name,limit,note\r\n" ++
        "1,plain,,\r\n" ++
        "2,\"with, comma\",7,\"\"\r\n" ++
        "3,\"quote \"\"inside\"\"\",,\"two\r\nlines\"\n";
    var parsed = try csv.parse([]const Row, gpa, input, .{});
    defer parsed.deinit();
    const rows = parsed.value;
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqualStrings("plain", rows[0].name);
    try std.testing.expectEqual(null, rows[0].limit);
    try std.testing.expectEqual(null, rows[0].note);
    try std.testing.expectEqualStrings("with, comma", rows[1].name);
    try std.testing.expectEqual(7, rows[1].limit);
    // A quoted empty field is the empty text, not a null.
    try std.testing.expectEqualStrings("", rows[1].note.?);
    try std.testing.expectEqualStrings("quote \"inside\"", rows[2].name);
    try std.testing.expectEqualStrings("two\r\nlines", rows[2].note.?);
    // An unquoted field with no doubled quote is a span of the input.
    try std.testing.expect(rows[0].name.ptr == input[std.mem.find(u8, input, "plain").?..].ptr);
}

test "rows by position, with no header" {
    const Pair = struct { []const u8, i32 };
    var parsed = try csv.parse([]const Pair, gpa, "a,1\nb,-2\n\nc,3", .{ .dialect = .{ .header = false } });
    defer parsed.deinit();
    try std.testing.expectEqual(3, parsed.value.len);
    try std.testing.expectEqualStrings("c", parsed.value[2][0]);
    try std.testing.expectEqual(-2, parsed.value[1][1]);
    var arrays = try csv.parse([]const [3]u8, gpa, "1,2,3\r\n4,5,6\r\n", .{ .dialect = .{ .header = false } });
    defer arrays.deinit();
    try std.testing.expectEqual(6, arrays.value[1][2]);
}

test "what CSV cannot mean is refused" {
    const cases = [_]struct { input: []const u8, err: anyerror }{
        // A row with fewer or more fields than the header.
        .{ .input = "name,count\na\n", .err = error.SyntaxError },
        .{ .input = "name,count\na,1,extra\n", .err = error.SyntaxError },
        // A quote inside an unquoted field, text after a closing quote, a
        // quote never closed, a carriage return alone.
        .{ .input = "name,count\na\"b,1\n", .err = error.SyntaxError },
        .{ .input = "name,count\n\"a\"b,1\n", .err = error.SyntaxError },
        .{ .input = "name,count\n\"a,1\n", .err = error.SyntaxError },
        .{ .input = "name,count\na\rb,1\n", .err = error.SyntaxError },
        // Numbers in JSON's spelling, an empty field where no null is taken.
        .{ .input = "name,count\na,01\n", .err = error.UnexpectedType },
        .{ .input = "name,count\na,\n", .err = error.UnexpectedType },
        .{ .input = "name,count\na,-1\n", .err = error.NumberOutOfRange },
        .{ .input = "name,count,mode\na,1,slow\n", .err = error.UnknownVariant },
        .{ .input = "name,count,extra\na,1,x\n", .err = error.UnknownField },
        .{ .input = "name,name,count\na,b,1\n", .err = error.DuplicateField },
        .{ .input = "count\n1\n", .err = error.MissingField },
        .{ .input = "name,count\n\xff,1\n", .err = error.InvalidUtf8 },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, csv.parse([]const Row, gpa, case.input, .{}));
    }
    // A struct row needs the header's names.
    try std.testing.expectError(error.UnexpectedType, csv.parse([]const Row, gpa, "a,1\n", .{ .dialect = .{ .header = false } }));
    // Unknown columns are skipped when asked.
    var parsed = try csv.parse([]const Row, gpa, "extra,name,count\nx,a,1\n", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a", parsed.value[0].name);
}

test "a dialect: semicolons and single quotes, LF endings written" {
    const dialect: csv.Dialect = .{ .delimiter = ';', .quote = '\'', .line_ending = .lf };
    const rows = [_]Row{
        .{ .name = "it's; here", .count = 1, .ratio = 0.5, .mode = .careful, .note = "", .limit = 3 },
        .{ .name = "b", .count = 2 },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try csv.write(&out.writer, &rows, .{ .dialect = dialect });
    try std.testing.expectEqualStrings("name;count;ratio;mode;note;limit\n'it''s; here';1;0.5;careful;'';3\nb;2;0;fast;;\n", out.written());
    var parsed = try csv.parse([]const Row, gpa, out.written(), .{ .dialect = dialect });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("it's; here", parsed.value[0].name);
    try std.testing.expectEqualStrings("", parsed.value[0].note.?);
    try std.testing.expectEqual(null, parsed.value[1].note);
    try std.testing.expectEqual(null, parsed.value[1].limit);
}

test "RFC 4180's examples write and read as the RFC writes them" {
    const Quoted = struct { aaa: []const u8, bbb: []const u8, ccc: []const u8 };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try csv.write(&out.writer, &[_]Quoted{
        .{ .aaa = "zzz", .bbb = "yyy", .ccc = "xxx" },
        .{ .aaa = "b\r\nbb", .bbb = "b\"bb", .ccc = "ccc" },
    }, .{});
    try std.testing.expectEqualStrings("aaa,bbb,ccc\r\nzzz,yyy,xxx\r\n\"b\r\nbb\",\"b\"\"bb\",ccc\r\n", out.written());
    var parsed = try csv.parse([]const Quoted, gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("b\r\nbb", parsed.value[1].aaa);
    try std.testing.expectEqualStrings("b\"bb", parsed.value[1].bbb);
}

test "rows streamed off a reader, across line breaks in quotes, numbered and placed" {
    const input = "\xef\xbb\xbfname,count,note\r\n" ++
        "a,1,\"first\r\nsecond\"\r\n" ++
        "\r\n" ++
        "b,x,\r\n" ++
        "c,3,\r\n";
    var source: std.Io.Reader = .fixed(input);
    var rows: csv.Reader(Row) = .init(gpa, &source, .{});
    defer rows.deinit();
    const first = (try rows.next()).?;
    try std.testing.expectEqualStrings("a", first.value.name);
    try std.testing.expectEqualStrings("first\r\nsecond", first.value.note.?);
    try std.testing.expectEqual(1, first.number);
    try std.testing.expectEqual(2, first.line);
    // A row that is not a `Row` is refused, and the reader reads on.
    try std.testing.expectError(error.MalformedRow, rows.next());
    try std.testing.expectEqual(error.UnexpectedType, rows.fault.err.?);
    try std.testing.expectEqual(5, rows.fault.line);
    const third = (try rows.next()).?;
    try std.testing.expectEqualStrings("c", third.value.name);
    try std.testing.expectEqual(null, third.value.note);
    try std.testing.expectEqual(null, try rows.next());
}

test "rows written one at a time, the header first" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var rows: csv.Writer(Row) = .init(&out.writer, .{});
    try rows.write(.{ .name = "a", .count = 1 });
    try rows.write(.{ .name = "b,c", .count = 2, .note = "n" });
    try std.testing.expectEqualStrings("name,count,ratio,mode,note,limit\r\na,1,0,fast,,\r\n\"b,c\",2,0,fast,n,\r\n", out.written());
    // A field holds a value alone.
    const Nested = struct { inner: struct { a: u8 } };
    var nested: csv.Writer(Nested) = .init(&out.writer, .{});
    try std.testing.expectError(error.UnsupportedValue, nested.write(.{ .inner = .{ .a = 1 } }));
}

const Generated = struct {
    text: []const u8,
    raw: []const u8,
    number: i64,
    real: f64,
    flag: bool,
    mode: Mode,
    maybe: ?u32 = null,
    maybe_text: ?[]const u8 = null,
    pub const strand = .{ .fields = .{ .raw = .{ .as = .bytes } } };
};

fn generated(case: *shakedown.Case) !Generated {
    const s = case.source;
    const real = gen.float(s, f64);
    return .{
        .text = try gen.string(s, case.gpa, .{ .max_len = 16 }),
        .raw = try gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 16 }),
        .number = gen.int(s, i64),
        .real = if (std.math.isFinite(real)) real else 1,
        .flag = gen.boolean(s),
        .mode = gen.enumValue(s, Mode),
        .maybe = if (gen.boolean(s)) gen.int(s, u32) else null,
        .maybe_text = if (gen.boolean(s)) try gen.string(s, case.gpa, .{ .max_len = 6 }) else null,
    };
}

fn expectSame(want: Generated, got: Generated) !void {
    try std.testing.expectEqualStrings(want.text, got.text);
    try std.testing.expectEqualStrings(want.raw, got.raw);
    try std.testing.expectEqual(want.number, got.number);
    try std.testing.expectEqual(want.real, got.real);
    try std.testing.expectEqual(want.flag, got.flag);
    try std.testing.expectEqual(want.mode, got.mode);
    try std.testing.expectEqual(want.maybe, got.maybe);
    if (want.maybe_text) |t| try std.testing.expectEqualStrings(t, got.maybe_text.?) else try std.testing.expectEqual(null, got.maybe_text);
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const rows = try case.gpa.alloc(Generated, gen.intRange(case.source, usize, 0, 4));
    for (rows) |*r| r.* = try generated(case);
    const dialect: csv.Dialect = .{
        .delimiter = gen.oneOf(case.source, u8, &.{ ',', ';', '\t', '|' }),
        .quote = gen.oneOf(case.source, u8, &.{ '"', '\'' }),
        .line_ending = if (gen.boolean(case.source)) .crlf else .lf,
    };
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try csv.write(&out.writer, rows, .{ .dialect = dialect });
    case.note("csv: {any}", .{out.written()});
    var parsed = try csv.parse([]const Generated, case.gpa, out.written(), .{ .dialect = dialect });
    defer parsed.deinit();
    try std.testing.expectEqual(rows.len, parsed.value.len);
    for (rows, parsed.value) |want, got| try expectSame(want, got);
    // The same rows streamed off a reader.
    var source: std.Io.Reader = .fixed(out.written());
    var reader: csv.Reader(Generated) = .init(case.gpa, &source, .{ .parse = .{ .dialect = dialect } });
    defer reader.deinit();
    for (rows) |want| try expectSame(want, (try reader.next()).?.value);
    try std.testing.expectEqual(null, try reader.next());
}

test "what the writer writes of generated rows reads back as it was, whole and streamed" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 400 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const input = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 96 });
    case.note("input: {any}", .{input});
    const options: csv.ParseOptions = .{ .ignore_unknown_fields = true, .limits = .{ .work = 1 << 16 } };
    if (csv.parse([]const Generated, case.gpa, input, options)) |p| {
        var parsed = p;
        parsed.deinit();
    } else |_| {}
    if (csv.parse([]const []const []const u8, case.gpa, input, .{ .dialect = .{ .header = false } })) |p| {
        var parsed = p;
        // A table of text, written again, reads back as the same table.
        var out: std.Io.Writer.Allocating = .init(case.gpa);
        try csv.write(&out.writer, parsed.value, .{ .dialect = .{ .header = false } });
        var again = try csv.parse([]const []const []const u8, case.gpa, out.written(), .{ .dialect = .{ .header = false } });
        defer again.deinit();
        try std.testing.expectEqual(parsed.value.len, again.value.len);
        for (parsed.value, again.value) |a, b| {
            try std.testing.expectEqual(a.len, b.len);
            for (a, b) |x, y| try std.testing.expectEqualStrings(x, y);
        }
        parsed.deinit();
    } else |_| {}
    var source: std.Io.Reader = .fixed(input);
    var reader: csv.Reader(Generated) = .init(case.gpa, &source, .{ .max_row_bytes = .fromRaw(64) });
    defer reader.deinit();
    var budget: usize = 64;
    while (budget > 0) : (budget -= 1) {
        const row = reader.next() catch |err| switch (err) {
            error.MalformedRow, error.LineTooLong => continue,
            else => return err,
        };
        if (row == null) break;
    }
}

test "any bytes are rows or refused, within the limits, whole and streamed" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 2000 });
}

test "fuzz: a number in a CSV field or a form value reads as its JSON spelling says" {
    const examples = [_][]const u8{ "0", "-12", "9223372036854775807", "-9223372036854775808", "1.5e1", "2e3", "1.0", "01", "+1", "1e400", "-0" };
    const property = struct {
        fn holds(input: []const u8) !void {
            try agrees(@import("csv/Decoder.zig"), input);
            try agrees(@import("urlencoded/Decoder.zig"), input);
        }
        fn agrees(comptime Decoder: type, input: []const u8) !void {
            var c: @import("core.zig").Context = .init(gpa, .{}, .borrowed);
            const value = Decoder.parseInteger(i64, input, &c) catch {
                // Refused: a plain decimal in range, spelled as JSON spells it, never is.
                const digits = if (input.len > 0 and input[0] == '-') input[1..] else input;
                const plain = digits.len > 0 and (digits[0] != '0' or digits.len == 1) and for (digits) |byte| {
                    if (!std.ascii.isDigit(byte)) break false;
                } else true;
                if (plain) if (std.fmt.parseInt(i64, input, 10)) |_| return error.TestUnexpectedResult else |_| {};
                return;
            };
            // Read: the spelling is a JSON number, and it is this integer exactly.
            try std.testing.expectEqual(@as(f128, @floatFromInt(value)), try std.fmt.parseFloat(f128, input));
            if (std.fmt.parseInt(i64, input, 10)) |plain| try std.testing.expectEqual(plain, value) else |_| {}
        }
        fn body(_: void, case: *shakedown.Case) !void {
            var buffer: [48]u8 = undefined;
            try holds(gen.mutated(case.source, &buffer, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try shakedown.check(gpa, {}, property.body, .{});
}
