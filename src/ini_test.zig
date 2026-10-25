//! INI read and written: configparser's dialect and others, types and
//! `ini.Value`, what is refused, and properties over generated documents and
//! any bytes.
const std = @import("std");
const ini = @import("ini.zig");
const core = @import("core.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Service = struct {
    name: []const u8,
    port: u16,
    debug: bool = false,
    note: ?[]const u8 = null,
    database: struct { url: []const u8, pool: u8 },
    paths: struct { root: []const u8, motd: []const u8 = "" },
};

test "a configuration read as configparser reads it: comments, continued values, folded keys, booleans" {
    const text =
        \\# The service.
        \\name = relay
        \\Port: 8443
        \\debug = Yes
        \\note =
        \\
        \\[database]
        \\; where the data is
        \\url = postgres://db/relay
        \\pool=  4
        \\
        \\[paths]
        \\root = /srv/relay
        \\motd = Welcome
        \\    to relay
        \\
        \\    mind the gap
        \\
    ;
    var parsed = try ini.parse(Service, gpa, text, .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("relay", v.name);
    try std.testing.expectEqual(8443, v.port);
    try std.testing.expect(v.debug);
    // An empty value is null where the type takes one.
    try std.testing.expect(v.note == null);
    try std.testing.expectEqualStrings("postgres://db/relay", v.database.url);
    try std.testing.expectEqual(4, v.database.pool);
    try std.testing.expectEqualStrings("Welcome\nto relay\n\nmind the gap", v.paths.motd);
}

test "line endings, a byte-order mark and white space around keys and values" {
    const T = struct { a: []const u8, b: []const u8 };
    var parsed = try ini.parse(T, gpa, "\u{feff}  a   =  one two  \r\nb:x\r\n", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("one two", parsed.value.a);
    try std.testing.expectEqualStrings("x", parsed.value.b);
}

test "what configparser's strict reading refuses" {
    const T = struct { a: []const u8 = "", s: struct { b: []const u8 = "" } = .{ .b = "" } };
    try std.testing.expectError(error.DuplicateField, ini.parse(T, gpa, "a = 1\na = 2\n", .{}));
    try std.testing.expectError(error.DuplicateField, ini.parse(T, gpa, "[s]\nb = 1\n[s]\nb = 2\n", .{}));
    // A key folded onto another is that key again.
    try std.testing.expectError(error.DuplicateField, ini.parse(T, gpa, "a = 1\nA = 2\n", .{}));
    try std.testing.expectError(error.SyntaxError, ini.parse(T, gpa, "a\n", .{}));
    try std.testing.expectError(error.SyntaxError, ini.parse(T, gpa, " = 1\n", .{}));
    try std.testing.expectError(error.SyntaxError, ini.parse(T, gpa, "[]\n", .{}));
    try std.testing.expectError(error.UnexpectedType, ini.parse(T, gpa, "[a]\n", .{}));
    try std.testing.expectError(error.InvalidUtf8, ini.parse(T, gpa, "a = \xff\n", .{}));
}

test "section names as configparser reads them; [DEFAULT] is a section like any other; no interpolation" {
    var value = try ini.parse(ini.Value, gpa, "[a]b] tail\nx = 1\n[DEFAULT]\ny = %(x)s ${x}\n[ spaced ]\n", .{});
    defer value.deinit();
    const v = value.value;
    try std.testing.expectEqual(3, v.members.len);
    try std.testing.expectEqualStrings("1", ini.Value.text(v.section("a]b").?, "x").?);
    try std.testing.expectEqualStrings("%(x)s ${x}", ini.Value.text(v.section("DEFAULT").?, "y").?);
    try std.testing.expectEqual(0, v.section(" spaced ").?.len);
}

test "other dialects: inline comments, keys without values, no continuation, keys as written" {
    const inline_comments: ini.Dialect = .{ .inline_comment_prefixes = &.{ ";", "#" } };
    var a = try ini.parse(ini.Value, gpa, "k = v ; note\nl = a;b # c\n", .{ .dialect = inline_comments });
    defer a.deinit();
    try std.testing.expectEqualStrings("v", a.value.get("k").?);
    try std.testing.expectEqualStrings("a;b", a.value.get("l").?);

    const no_values: ini.Dialect = .{ .keys_without_values = true };
    const Flags = struct { verbose: ?[]const u8 = "unset", level: []const u8 };
    var b = try ini.parse(Flags, gpa, "verbose\nlevel = 2\n", .{ .dialect = no_values });
    defer b.deinit();
    try std.testing.expect(b.value.verbose == null);
    // A key with no value has none to continue.
    try std.testing.expectError(error.SyntaxError, ini.parse(ini.Value, gpa, "verbose\n  more\n", .{ .dialect = no_values }));

    const flat: ini.Dialect = .{ .continuation = false, .lowercase_keys = false };
    var c = try ini.parse(ini.Value, gpa, "Key = a\n  Other = b\n", .{ .dialect = flat });
    defer c.deinit();
    try std.testing.expectEqualStrings("a", c.value.get("Key").?);
    try std.testing.expectEqualStrings("b", c.value.get("Other").?);
}

test "keys lowercased by Unicode's full mapping, as Python's str.lower" {
    var value = try ini.parse(ini.Value, gpa, "ÉTÉ = summer\nΣΟΦΟΣ = wise\n", .{});
    defer value.deinit();
    try std.testing.expectEqualStrings("summer", value.value.get("été").?);
    // Final sigma.
    try std.testing.expectEqualStrings("wise", value.value.get("σοφος").?);
}

test "a value as the type asks: numbers in JSON's spelling, configparser's booleans, bytes" {
    const T = struct { i: i32, f: f64, b: bool, raw: []const u8 };
    var parsed = try ini.parse(T, gpa, "i = -12\nf = 2.5e3\nb = off\nraw = x\n", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(-12, parsed.value.i);
    try std.testing.expectEqual(2500, parsed.value.f);
    try std.testing.expect(!parsed.value.b);
    try std.testing.expectError(error.UnexpectedType, ini.parse(T, gpa, "i = 0x10\nf = 1\nb = on\nraw = x\n", .{}));
    try std.testing.expectError(error.UnexpectedType, ini.parse(T, gpa, "i = 1\nf = 1\nb = maybe\nraw = x\n", .{}));
}

test "written: keys, then sections; continued values on tab-indented lines; nulls left out" {
    const value: Service = .{
        .name = "relay",
        .port = 8443,
        .database = .{ .url = "postgres://db/relay", .pool = 4 },
        .paths = .{ .root = "/srv", .motd = "Welcome\n\nto relay" },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try ini.write(&out.writer, value, .{});
    try std.testing.expectEqualStrings("name = relay\nport = 8443\ndebug = false\n\n[database]\nurl = postgres://db/relay\npool = 4\n\n[paths]\nroot = /srv\nmotd = Welcome\n\t\n\tto relay\n", out.written());
    var back = try ini.parse(Service, gpa, out.written(), .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("Welcome\n\nto relay", back.value.paths.motd);
    try std.testing.expect(back.value.note == null);
}

test "what is not written, since it would not read back as itself" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // A key after a section would be read as the section's.
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { s: struct { a: u8 }, k: u8 }{ .s = .{ .a = 1 }, .k = 2 }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { s: struct { t: struct { a: u8 } } }{ .s = .{ .t = .{ .a = 1 } } }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { l: []const u8 = "x", s: []const u16 }{ .s = &.{ 1, 2 } }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: []const u8 }{ .k = "trailing " }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: []const u8 }{ .k = "a\n# b" }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: []const u8 }{ .k = "a\n" }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: []const u8 }{ .k = "a\nb" }, .{ .dialect = .{ .continuation = false } }));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { Key: u8 }{ .Key = 1 }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { @"a=b": u8 }{ .@"a=b" = 1 }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { @"[a": []const u8 }{ .@"[a" = "b]" }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: f64 }{ .k = std.math.inf(f64) }, .{}));
    try std.testing.expectError(error.UnsupportedValue, ini.write(&out.writer, struct { k: []const u8 }{ .k = "a ;b" }, .{ .dialect = .{ .inline_comment_prefixes = &.{";"} } }));
    // As written where the dialect keeps keys.
    out.clearRetainingCapacity();
    try ini.write(&out.writer, struct { Key: u8 }{ .Key = 1 }, .{ .dialect = .{ .lowercase_keys = false } });
    try std.testing.expectEqualStrings("Key = 1\n", out.written());
}

test "ini.Value written and read back, keys with no value where the dialect takes them" {
    const d: ini.Dialect = .{ .keys_without_values = true };
    var value = try ini.parse(ini.Value, gpa, "top = 1\nflag\n\n[s]\nk = a\n  b\nempty =\n", .{ .dialect = d });
    defer value.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try ini.write(&out.writer, value.value, .{ .dialect = d });
    try std.testing.expectEqualStrings("top = 1\nflag\n\n[s]\nk = a\n\tb\nempty =\n", out.written());
    var back = try ini.parse(ini.Value, gpa, out.written(), .{ .dialect = d });
    defer back.deinit();
    try std.testing.expect(back.value.eql(value.value));
}

test "a failure's place: its line and column" {
    var diagnostics: core.Diagnostics = .{};
    try std.testing.expectError(error.SyntaxError, ini.parse(ini.Value, gpa, "a = 1\n[s]\nnot a pair\n", .{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(3, diagnostics.line);
}

//=========================================================================
// Properties.
//=========================================================================

const dialects = [_]ini.Dialect{
    .{},
    .{ .inline_comment_prefixes = &.{ ";", "#" }, .keys_without_values = true },
    .{ .continuation = false, .lowercase_keys = false, .delimiters = ":" },
};
const alphabet = "ab_ -[]=:;#\t\nÉé.%$";

fn generatedText(case: *shakedown.Case, max: usize) ![]const u8 {
    const n = gen.intRange(case.source, usize, 0, max);
    const out = try case.gpa.alloc(u8, n * 2);
    var len: usize = 0;
    for (0..n) |_| {
        const c = alphabet[gen.intRange(case.source, usize, 0, alphabet.len - 1)];
        // É and é are two bytes each: a byte of either is a whole one of them.
        if (c >= 0x80) {
            const ch: []const u8 = if (gen.boolean(case.source)) "É" else "é";
            @memcpy(out[len..][0..ch.len], ch);
            len += ch.len;
        } else {
            out[len] = c;
            len += 1;
        }
    }
    return out[0..len];
}
fn generatedMembers(case: *shakedown.Case, sections: bool) ![]const ini.Member {
    const n = gen.intRange(case.source, usize, 0, 4);
    const members = try case.gpa.alloc(ini.Member, n);
    for (members) |*m| {
        m.key = try generatedText(case, 6);
        m.value = switch (gen.weighted(case.source, if (sections) &.{ 4, 1, 2 } else &.{ 4, 1, 0 })) {
            0 => .{ .text = try generatedText(case, 12) },
            1 => .none,
            else => .{ .section = try generatedMembers(case, false) },
        };
    }
    return members;
}

/// A generated document that writes reads back as itself, in each dialect.
fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value: ini.Value = .{ .members = try generatedMembers(case, true) };
    for (dialects) |d| {
        var out: std.Io.Writer.Allocating = .init(case.gpa);
        defer out.deinit();
        ini.write(&out.writer, value, .{ .dialect = d }) catch |err| switch (err) {
            error.UnsupportedValue, error.DuplicateField => continue,
            else => return err,
        };
        case.note("written:\n{s}", .{out.written()});
        var back = try ini.parse(ini.Value, case.gpa, out.written(), .{ .dialect = d });
        defer back.deinit();
        var expected = value;
        if (!d.keys_without_values) expected = try withoutNones(case.gpa, value);
        try std.testing.expect(back.value.eql(expected));
    }
}
/// `value` without its keys with no value, which a dialect without them leaves out.
fn withoutNones(a: std.mem.Allocator, value: ini.Value) !ini.Value {
    return .{ .members = try keep(a, value.members) };
}
fn keep(a: std.mem.Allocator, members: []const ini.Member) ![]const ini.Member {
    var kept: std.ArrayList(ini.Member) = .empty;
    for (members) |m| switch (m.value) {
        .none => {},
        .section => |s| try kept.append(a, .{ .key = m.key, .value = .{ .section = try keep(a, s) } }),
        .text => try kept.append(a, m),
    };
    return kept.items;
}

test "generated documents that write read back as themselves, in each dialect" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 1500 });
}

const examples = [_][]const u8{
    "# c\na = 1\nB: two\n\n[s]\nk = v\n  more\n\n  after blank\n; c\n[t]\n",
    "[a]b]\nx = %(y)s\n[DEFAULT]\nflag\n",
    "k = v ; not a comment\n\t[x]\n  y = z\n",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [200]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {s}", .{input});
    case.note("bytes: {x}", .{input});
    for (dialects) |d| {
        var parsed = ini.parse(ini.Value, case.gpa, input, .{ .dialect = d, .limits = .{ .work = 1 << 16 } }) catch continue;
        defer parsed.deinit();
        // What is read writes, and reads back as itself.
        var out: std.Io.Writer.Allocating = .init(case.gpa);
        defer out.deinit();
        try ini.write(&out.writer, parsed.value, .{ .dialect = d });
        var back = try ini.parse(ini.Value, case.gpa, out.written(), .{ .dialect = d });
        defer back.deinit();
        try std.testing.expect(back.value.eql(parsed.value));
    }
}

test "fuzz: any bytes are a document or refused, and a document read writes and reads back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
