//! Forms and query strings: the WHATWG parser's pairs, bracketed paths read
//! as the type asks, and what the writer writes read back as it was.
const std = @import("std");
const core = @import("core.zig");
const form = @import("urlencoded.zig");

const gpa = std.testing.allocator;

const Mode = enum { fast, careful };
const Signup = struct {
    name: []const u8,
    age: u8,
    admin: bool = false,
    mode: Mode = .fast,
    ratio: f64 = 1,
    nickname: ?[]const u8 = null,
};

test "a form's pairs: plus for a space, percent-encoding, typed values" {
    var parsed = try form.parse(Signup, gpa, "name=Ada+Lovelace&age=36&admin=true&mode=careful&ratio=0.5", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Ada Lovelace", parsed.value.name);
    try std.testing.expectEqual(36, parsed.value.age);
    try std.testing.expect(parsed.value.admin);
    try std.testing.expectEqual(Mode.careful, parsed.value.mode);
    try std.testing.expectEqual(0.5, parsed.value.ratio);
    try std.testing.expectEqual(null, parsed.value.nickname);
    // A name and a value are percent-decoded, `&&` and a trailing `&` are no pair.
    var again = try form.parse(Signup, gpa, "&n%61me=%E2%82%AC%20%2B&&age=1&", .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("\u{20ac} +", again.value.name);
    // A text that decodes to nothing changed is borrowed from the input.
    const input = "name=plain&age=2";
    var borrowed = try form.parse(Signup, gpa, input, .{});
    defer borrowed.deinit();
    try std.testing.expect(borrowed.value.name.ptr == input[5..].ptr);
}

const Account = struct {
    id: u64,
    user: struct { name: []const u8, age: u8 = 0, address: struct { city: []const u8 } },
    tags: []const []const u8 = &.{},
    scores: []const u16 = &.{},
};

test "bracketed paths are records and sequences, wherever their pairs stand" {
    // The brackets as a browser sends them, and as people write them.
    const input = "user%5Bname%5D=ada&tags=x&id=7&user[address][city]=London&tags=y&scores[]=3&user[age]=36&scores[]=4";
    var parsed = try form.parse(Account, gpa, input, .{});
    defer parsed.deinit();
    const a = parsed.value;
    try std.testing.expectEqual(7, a.id);
    try std.testing.expectEqualStrings("ada", a.user.name);
    try std.testing.expectEqual(36, a.user.age);
    try std.testing.expectEqualStrings("London", a.user.address.city);
    try std.testing.expectEqual(2, a.tags.len);
    try std.testing.expectEqualStrings("y", a.tags[1]);
    try std.testing.expectEqualSlices(u16, &.{ 3, 4 }, a.scores);
}

test "what a form cannot mean is refused" {
    const cases = [_]struct { input: []const u8, err: anyerror }{
        // A name given twice where one value belongs.
        .{ .input = "name=a&name=b&age=1", .err = error.DuplicateField },
        // A `%` with no two hexadecimal digits, a broken path.
        .{ .input = "name=100%&age=1", .err = error.SyntaxError },
        .{ .input = "name=a&age[=1", .err = error.SyntaxError },
        .{ .input = "name=a&[age]=1", .err = error.SyntaxError },
        // A number in JSON's spelling only, and a bool spelled out.
        .{ .input = "name=a&age=007", .err = error.UnexpectedType },
        .{ .input = "name=a&age=1&admin=yes", .err = error.UnexpectedType },
        .{ .input = "name=a&age=300", .err = error.NumberOutOfRange },
        // Text is UTF-8.
        .{ .input = "name=%FF&age=1", .err = error.InvalidUtf8 },
        // A record's members are named; a value is no record.
        .{ .input = "name[]=a&age=1", .err = error.UnexpectedType },
        .{ .input = "name=a&age=1&mode[x]=fast", .err = error.UnexpectedType },
        .{ .input = "name=a&age=1&extra=1", .err = error.UnknownField },
        .{ .input = "age=1", .err = error.MissingField },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, form.parse(Signup, gpa, case.input, .{}));
    }
    // A sequence holds values, not records.
    try std.testing.expectError(error.UnexpectedType, form.parse(Account, gpa, "id=1&user[name]=a&user[address][city]=b&tags[][x]=1", .{}));
    // Unknown fields, nested and repeated, are skipped when asked.
    var parsed = try form.parse(Signup, gpa, "x[a][b]=1&name=a&x[a][c]=2&age=1&y=1&y=2&z[]=3", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a", parsed.value.name);
}

const Shape = union(enum) { circle: struct { radius: f32 }, square: u8, empty };
const Everything = struct {
    title: []const u8,
    count: i32,
    shape: Shape,
    other: Shape,
    blob: []const u8,
    tags: []const []const u8,
    nested: struct { flag: bool, mode: Mode },
    missing: ?u8 = null,
    present: ?u8 = null,
    pub const strand = .{ .fields = .{ .blob = .{ .as = .bytes } } };
};

test "what the writer writes reads back as it was" {
    const value: Everything = .{
        .title = "a b&c=d[e]\u{e9}",
        .count = -12,
        .shape = .{ .circle = .{ .radius = 1.5 } },
        .other = .empty,
        .blob = "\x00\xff",
        .tags = &.{ "one", "two" },
        .nested = .{ .flag = true, .mode = .careful },
        .present = 4,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try form.write(&out.writer, value, .{});
    try std.testing.expectEqualStrings("title=a+b%26c%3Dd%5Be%5D%C3%A9&count=-12&shape%5Bcircle%5D%5Bradius%5D=1.5&other%5Bempty%5D=&blob=%00%FF&tags=one&tags=two&nested%5Bflag%5D=true&nested%5Bmode%5D=careful&present=4", out.written());
    var parsed = try form.parse(Everything, gpa, out.written(), .{});
    defer parsed.deinit();
    const got = parsed.value;
    try std.testing.expectEqualStrings(value.title, got.title);
    try std.testing.expectEqual(value.count, got.count);
    try std.testing.expectEqual(value.shape.circle.radius, got.shape.circle.radius);
    try std.testing.expectEqual(Shape.empty, got.other);
    try std.testing.expectEqualStrings(value.blob, got.blob);
    try std.testing.expectEqualStrings("two", got.tags[1]);
    try std.testing.expectEqual(Mode.careful, got.nested.mode);
    try std.testing.expectEqual(null, got.missing);
    try std.testing.expectEqual(4, got.present);
}

test "a form holds no sequence of records, and its root is a record" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const Rows = struct { rows: []const struct { a: u8 } };
    try std.testing.expectError(error.UnsupportedValue, form.write(&out.writer, Rows{ .rows = &.{.{ .a = 1 }} }, .{}));
    try std.testing.expectError(error.UnexpectedType, form.parse([]const u8, gpa, "a=1", .{}));
}

test "a map of names to values" {
    var parsed = try form.parse(core.Pairs([]const u8, u32), gpa, "b=2&a=1", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(2, parsed.value.items.len);
    try std.testing.expectEqualStrings("b", parsed.value.items[0].key);
    try std.testing.expectEqual(1, parsed.value.items[1].value);
}

test "limits hold on forms" {
    try std.testing.expectError(error.InputLimit, form.parse(Signup, gpa, "name=a&age=1", .{ .limits = .{ .input_bytes = 4 } }));
    try std.testing.expectError(error.LengthLimit, form.parse(Signup, gpa, "name=abcdef&age=1", .{ .limits = .{ .string_bytes = 3 } }));
    try std.testing.expectError(error.DepthLimit, form.parse(Account, gpa, "id=1&user[name]=a&user[address][city]=b", .{ .limits = .{ .depth = 2 } }));
}

const shakedown = @import("shakedown");
const gen = shakedown.gen;

const Generated = struct {
    text: []const u8,
    raw: []const u8,
    number: i64,
    real: f64,
    flag: bool,
    mode: Mode,
    // An empty sequence, a null and a record of nothing write no pair, so
    // they read back through their defaults.
    words: []const []const u8 = &.{},
    inner: struct { label: []const u8, values: []const u32 = &.{}, deeper: struct { note: ?[]const u8 = null } = .{} },
    choice: Shape,
    pub const strand = .{ .fields = .{ .raw = .{ .as = .bytes } } };
};

fn generated(case: *shakedown.Case) !Generated {
    const s = case.source;
    const a = case.gpa;
    const words = try a.alloc([]const u8, gen.intRange(s, usize, 0, 4));
    for (words) |*w| w.* = try gen.string(s, a, .{ .max_len = 12 });
    const values = try a.alloc(u32, gen.intRange(s, usize, 0, 4));
    for (values) |*v| v.* = gen.int(s, u32);
    const real = gen.float(s, f64);
    return .{
        .text = try gen.string(s, a, .{ .max_len = 24 }),
        .raw = try gen.string(s, a, .{ .kind = .bytes, .max_len = 24 }),
        .number = gen.int(s, i64),
        .real = if (std.math.isFinite(real)) real else 0,
        .flag = gen.boolean(s),
        .mode = gen.enumValue(s, Mode),
        .words = words,
        .inner = .{ .label = try gen.string(s, a, .{ .max_len = 8 }), .values = values, .deeper = .{ .note = if (gen.boolean(s)) try gen.string(s, a, .{ .max_len = 8 }) else null } },
        .choice = switch (gen.intRange(s, u8, 0, 2)) {
            0 => .{ .circle = .{ .radius = 2.25 } },
            1 => .{ .square = gen.int(s, u8) },
            else => .empty,
        },
    };
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value = try generated(case);
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try form.write(&out.writer, value, .{});
    case.note("form: {s}", .{out.written()});
    // A form's text has only the bytes it writes as themselves.
    for (out.written()) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte) or std.mem.findScalar(u8, "*-._%+=&", byte) != null);
    var parsed = try form.parse(Generated, case.gpa, out.written(), .{});
    defer parsed.deinit();
    const got = parsed.value;
    try std.testing.expectEqualStrings(value.text, got.text);
    try std.testing.expectEqualStrings(value.raw, got.raw);
    try std.testing.expectEqual(value.number, got.number);
    try std.testing.expectEqual(value.real, got.real);
    try std.testing.expectEqual(value.flag, got.flag);
    try std.testing.expectEqual(value.mode, got.mode);
    try std.testing.expectEqual(value.words.len, got.words.len);
    for (value.words, got.words) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expectEqualStrings(value.inner.label, got.inner.label);
    try std.testing.expectEqualSlices(u32, value.inner.values, got.inner.values);
    if (value.inner.deeper.note) |note| try std.testing.expectEqualStrings(note, got.inner.deeper.note.?) else try std.testing.expectEqual(null, got.inner.deeper.note);
    try std.testing.expectEqual(std.meta.activeTag(value.choice), std.meta.activeTag(got.choice));
}

test "what the writer writes of generated values reads back as it was" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 300 });
}

/// The WHATWG parser's pairs, plainly: split on `&`, drop the empty ones,
/// split each at its first `=`, `+` a space, and percent-decoding.
fn whatwg(a: std.mem.Allocator, input: []const u8) ![]const [2][]const u8 {
    var pairs: std.ArrayList([2][]const u8) = .empty;
    var it = std.mem.splitScalar(u8, input, '&');
    while (it.next()) |sequence| {
        if (sequence.len == 0) continue;
        const equals = std.mem.findScalar(u8, sequence, '=') orelse sequence.len;
        var both: [2][]const u8 = undefined;
        for (&both, [2][]const u8{ sequence[0..equals], if (equals == sequence.len) "" else sequence[equals + 1 ..] }) |*out, raw| {
            var bytes: std.ArrayList(u8) = .empty;
            var at: usize = 0;
            while (at < raw.len) : (at += 1) switch (raw[at]) {
                '+' => try bytes.append(a, ' '),
                '%' => {
                    try bytes.append(a, try std.fmt.parseInt(u8, raw[at + 1 .. at + 3], 16));
                    at += 2;
                },
                else => |byte| try bytes.append(a, byte),
            };
            out.* = bytes.items;
        }
        try pairs.append(a, both);
    }
    return pairs.items;
}

fn flatPairs(_: void, case: *shakedown.Case) anyerror!void {
    // Names and values from pieces a query string is made of, brackets left
    // out of the names.
    var input: std.ArrayList(u8) = .empty;
    const pieces = [_][]const u8{ "a", "b", "x1", "=", "&", "+", "%20", "%3D", "%26", "%C3%A9", "%5B", "~", "-", ".", "_", "*", "&&", "==" };
    while (input.items.len < 64 and case.source.more(6)) try input.appendSlice(case.gpa, gen.oneOf(case.source, []const u8, &pieces));
    case.note("input: {s}", .{input.items});
    const want = try whatwg(case.gpa, input.items);
    var parsed = form.parse(core.Pairs([]const u8, []const u8), case.gpa, input.items, .{}) catch |err| {
        // A name may decode to a bracket, or be empty: not a path.
        for (want) |p| {
            if (p[0].len == 0 or std.mem.findAny(u8, p[0], "[]") != null) return;
        }
        return err;
    };
    defer parsed.deinit();
    try std.testing.expectEqual(want.len, parsed.value.items.len);
    for (want, parsed.value.items) |w, got| {
        try std.testing.expectEqualStrings(w[0], got.key);
        try std.testing.expectEqualStrings(w[1], got.value);
    }
}

test "flat names are the WHATWG parser's pairs" {
    try shakedown.check(gpa, {}, flatPairs, .{ .cases = 500 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const input = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 96 });
    case.note("input: {any}", .{input});
    const options: form.ParseOptions = .{ .ignore_unknown_fields = true, .limits = .{ .work = 1 << 16 } };
    inline for (.{ Generated, Account, core.Pairs([]const u8, []const u8) }) |T| {
        if (form.parse(T, case.gpa, input, options)) |p| {
            var parsed = p;
            parsed.deinit();
        } else |_| {}
    }
}

test "any bytes are a form or refused, within the limits" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 2000 });
}

test "fuzz: percent-decoding any bytes is refused at a stray %, or gives what was encoded" {
    const examples = [_][]const u8{ "plain", "a+b%20c", "%41%7e", "%", "%4", "%zz", "100%25+sure", "\xff%FF" };
    const property = struct {
        fn holds(raw: []const u8) !void {
            const percent = @import("urlencoded/text.zig");
            // Refused exactly where a `%` lacks its two hexadecimal digits.
            const stray = for (raw, 0..) |byte, i| {
                if (byte == '%' and (i + 2 >= raw.len or !std.ascii.isHex(raw[i + 1]) or !std.ascii.isHex(raw[i + 2]))) break true;
            } else false;
            const d = percent.decodedLength(raw) catch {
                try std.testing.expect(stray);
                return;
            };
            try std.testing.expect(!stray);
            try std.testing.expectEqual(std.mem.findAny(u8, raw, "%+") != null, d.changes);
            var buffer: [96]u8 = undefined;
            const decoded = buffer[0..d.len];
            percent.decode(raw, decoded);
            if (!d.changes) try std.testing.expectEqualStrings(raw, decoded);
            // Encoded again, it decodes to the same bytes.
            var encoded_buffer: [288]u8 = undefined;
            const encoded = encoded_buffer[0..percent.encodedLength(decoded)];
            percent.encode(decoded, encoded);
            const again = try percent.decodedLength(encoded);
            var again_buffer: [96]u8 = undefined;
            percent.decode(encoded, again_buffer[0..again.len]);
            try std.testing.expectEqualStrings(decoded, again_buffer[0..again.len]);
        }
        fn body(_: void, case: *shakedown.Case) !void {
            var buffer: [96]u8 = undefined;
            try holds(gen.mutated(case.source, &buffer, &examples));
        }
    };
    for (examples) |example| try property.holds(example);
    try shakedown.check(gpa, {}, property.body, .{});
}
