//! TOML: documents read as types and as values, the specification's rules for
//! defining tables, what TOML 1.0 and 1.1 each accept, dates and times as
//! their own types, optional fields and the missing null, a union tagged
//! inside its table (read twice), documents written as they are spelled and
//! read back, failures placed in the text, limits at their edges, allocation
//! failures, and properties over generated values and over any bytes.
//! toml-test runs in `testing/toml_suite.zig`.
const std = @import("std");
const toml = @import("toml.zig");
const core = @import("core.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;
const Value = toml.Value;

const Server = struct {
    host: []const u8,
    port: u16,
    tags: []const []const u8 = &.{},
    ratio: f64 = 1,
    started: ?toml.OffsetDateTime = null,
};
const Config = struct {
    title: []const u8,
    server: Server,
    replicas: []const Server = &.{},
    mode: enum { fast, careful } = .fast,
};

fn written(value: anytype, options: toml.WriteOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try toml.write(&out.writer, value, options);
    return out.toOwnedSlice();
}

test "a document read as a type: tables, dotted keys, arrays of tables, dates" {
    const input =
        \\title = "example"  # a comment
        \\mode = "careful"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8_080
        \\tags = [ "a", 'b',
        \\  """c""", ] # trailing comma
        \\started = 1979-05-27 07:32:00Z
        \\
        \\[[replicas]]
        \\host = "r1"
        \\port = 1
        \\ratio = 0.5
        \\
        \\[[replicas]]
        \\host = "r2"
        \\port = 0x10
    ;
    var parsed = try toml.parse(Config, gpa, input, .{});
    defer parsed.deinit();
    const config = parsed.value;
    try std.testing.expectEqualStrings("example", config.title);
    try std.testing.expectEqual(.careful, config.mode);
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqual(3, config.server.tags.len);
    try std.testing.expectEqualStrings("c", config.server.tags[2]);
    try std.testing.expectEqual(@as(u8, 7), config.server.started.?.time.hour);
    try std.testing.expectEqual(2, config.replicas.len);
    try std.testing.expectEqual(@as(f64, 0.5), config.replicas[0].ratio);
    try std.testing.expectEqual(@as(u16, 16), config.replicas[1].port);
    // Nothing is kept from the input in an owned parse.
    const copy = try gpa.dupe(u8, input);
    var owned = try toml.parseOwned(Config, gpa, copy, .{});
    defer owned.deinit();
    @memset(copy, 'x');
    gpa.free(copy);
    try std.testing.expectEqualStrings("localhost", owned.value.server.host);
}

test "a document read as a value: every kind of value, and its tables however they were written" {
    const input =
        \\a.b.c = 1
        \\a.d = [1, 2.5, "x", true, 1979-05-27, 07:32:00, 1979-05-27T07:32:00, 1979-05-27T07:32:00-07:00]
        \\[x.y.z.w]
        \\[x]
        \\v = 1
        \\[t]
        \\"quoted key" = { x = 1, y = { z = -inf } }
        \\[[t.list]]
        \\n = 1
        \\[t.list.sub]
        \\m = 2
        \\[[t.list]]
        \\n = 3
    ;
    var parsed = try toml.parse(Value, gpa, input, .{});
    defer parsed.deinit();
    const value = parsed.value;
    try std.testing.expectEqual(@as(i64, 1), value.get("a").?.get("b").?.get("c").?.integer);
    const d = value.get("a").?.get("d").?.array;
    try std.testing.expectEqual(@as(f64, 2.5), d[1].float);
    try std.testing.expectEqual(@as(u16, 1979), d[4].local_date.year);
    try std.testing.expectEqual(@as(u8, 7), d[5].local_time.hour);
    try std.testing.expectEqual(@as(u8, 32), d[6].local_date_time.time.minute);
    try std.testing.expectEqual(@as(i16, -420), d[7].offset_date_time.offset_minutes);
    try std.testing.expectEqual(@as(i64, 1), value.get("x").?.get("v").?.integer);
    try std.testing.expect(value.get("x").?.get("y").?.get("z").?.get("w") != null);
    try std.testing.expect(std.math.isNegativeInf(value.get("t").?.get("quoted key").?.get("y").?.get("z").?.float));
    const list = value.get("t").?.get("list").?.array;
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(@as(i64, 2), list[0].get("sub").?.get("m").?.integer);
    try std.testing.expectEqual(@as(i64, 3), list[1].get("n").?.integer);
}

test "tables are defined once: the specification's invalid documents are refused" {
    const invalid = [_][]const u8{
        "name = \"Tom\"\nname = \"Pradyun\"",
        "spelling = \"favorite\"\n\"spelling\" = \"favourite\"",
        "fruit.apple = 1\nfruit.apple.smooth = true",
        "[fruit]\napple = \"red\"\n[fruit]\norange = \"orange\"",
        "[fruit]\napple = \"red\"\n[fruit.apple]\ntexture = \"smooth\"",
        "[fruit]\napple.color = \"red\"\n[fruit.apple]",
        "[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.taste]",
        "[product]\ntype = { name = \"Nail\" }\ntype.edible = false",
        "[product]\ntype.name = \"Nail\"\ntype = { edible = false }",
        "[fruit.physical]\ncolor = \"red\"\n[[fruit]]\nname = \"apple\"",
        "fruits = []\n[[fruits]]",
        "[[fruits]]\nname = \"apple\"\n[[fruits.varieties]]\nname = \"red delicious\"\n[fruits.varieties]\nname = \"granny smith\"",
        "[[fruits]]\n[fruits.physical]\ncolor = \"red\"\n[[fruits.physical]]\ncolor = \"green\"",
        "[a.b]\nx = 1\n[a]\nb.y = 2",
        "a = { b = 1 }\n[a.c]",
        "first = \"Tom\" last = \"Preston-Werner\"",
        "key = # no value",
        "= \"no key name\"",
        "\"\"\"key\"\"\" = \"not allowed\"",
    };
    for (invalid) |input| {
        if (toml.parse(Value, gpa, input, .{})) |p| {
            var read = p;
            read.deinit();
            std.debug.print("read: {s}\n", .{input});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.SyntaxError, err);
    }
    // And the valid ones beside them.
    const valid = [_][]const u8{
        "fruit.apple.smooth = true\nfruit.orange = 2",
        "apple.type = \"fruit\"\norange.type = \"fruit\"\napple.skin = \"thin\"",
        "[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true",
        "[x.y.z.w]\n[x]",
        "[fruit.apple]\n[animal]\n[fruit.orange]",
        "3.14159 = \"pi\"",
        "\"\" = \"blank\"",
        "[[a]]\n[[a.b]]\n[a.b.c]\n[[a]]\n[a.b]",
    };
    for (valid) |input| {
        var read = toml.parse(Value, gpa, input, .{}) catch |err| {
            std.debug.print("refused ({t}): {s}\n", .{ err, input });
            return err;
        };
        read.deinit();
    }
}

test "TOML 1.1 accepts what 1.0 refuses: inline tables across lines, \\e and \\x, seconds left off" {
    const newer = [_][]const u8{
        "t = {\n  a = 1,\n  b = 2, # comment\n}",
        "t = { a = 1, }",
        "s = \"\\e[0m\"",
        "s = \"\\x41\"",
        "t = 07:32",
        "d = 1979-05-27 07:32Z",
        "d = 1979-05-27T07:32",
        "s = \"\"\"a\rb\"\"\"",
    };
    for (newer, 0..) |input, i| {
        // The last is the other way round: 1.1 refuses a lone carriage return.
        const last = i == newer.len - 1;
        const v1_1 = toml.parse(Value, gpa, input, .{ .version = .v1_1 });
        const v1_0 = toml.parse(Value, gpa, input, .{ .version = .v1_0 });
        if (v1_1) |p| {
            var x = p;
            x.deinit();
        } else |_| {}
        if (v1_0) |p| {
            var x = p;
            x.deinit();
        } else |_| {}
        try std.testing.expectEqual(!last, std.meta.isError(v1_0));
        try std.testing.expectEqual(last, std.meta.isError(v1_1));
    }
    var parsed = try toml.parse(Value, gpa, "s = \"\\e\\x41\"\nt = 07:32", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\x1bA", parsed.value.get("s").?.string);
    try std.testing.expectEqual(@as(u8, 0), parsed.value.get("t").?.local_time.second);
}

test "each date and time is its own type: never read as another, nor as text" {
    const Dates = struct {
        odt: toml.OffsetDateTime,
        ldt: toml.LocalDateTime,
        ld: toml.LocalDate,
        lt: toml.LocalTime,
    };
    const input = "odt = 1979-05-27T00:32:00.999999999-07:00\nldt = 1979-05-27T07:32:00.5\nld = 1979-05-27\nlt = 00:32:00.1234567891";
    var parsed = try toml.parse(Dates, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 999_999_999), parsed.value.odt.time.nanosecond);
    try std.testing.expectEqual(@as(u32, 500_000_000), parsed.value.ldt.time.nanosecond);
    try std.testing.expectEqual(@as(u8, 27), parsed.value.ld.day);
    // A finer fraction than nanoseconds is truncated, never rounded.
    try std.testing.expectEqual(@as(u32, 123_456_789), parsed.value.lt.nanosecond);
    const out = try written(parsed.value, .{ .allocator = gpa });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("odt = 1979-05-27T00:32:00.999999999-07:00\nldt = 1979-05-27T07:32:00.5\nld = 1979-05-27\nlt = 00:32:00.123456789\n", out);

    // A local date where an offset date-time belongs, a date where text does,
    // text where a date does: each refused where it stands.
    try std.testing.expectError(error.UnexpectedType, toml.parse(struct { d: toml.OffsetDateTime }, gpa, "d = 1979-05-27", .{}));
    try std.testing.expectError(error.UnexpectedType, toml.parse(struct { d: []const u8 }, gpa, "d = 1979-05-27", .{}));
    try std.testing.expectError(error.UnexpectedType, toml.parse(struct { d: toml.LocalDate }, gpa, "d = \"1979-05-27\"", .{}));
    // In another format a date is its text.
    const json = @import("json.zig");
    var from_json = try json.parse(struct { d: toml.LocalDate }, gpa, "{\"d\":\"1979-05-27\"}", .{});
    defer from_json.deinit();
    try std.testing.expectEqual(@as(u16, 1979), from_json.value.d.year);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try json.write(&text.writer, parsed.value, .{});
    try std.testing.expectEqualStrings("{\"odt\":\"1979-05-27T00:32:00.999999999-07:00\",\"ldt\":\"1979-05-27T07:32:00.5\",\"ld\":\"1979-05-27\",\"lt\":\"00:32:00.123456789\"}", text.written());
    // A date that is no date is refused when written.
    try std.testing.expectError(error.UnsupportedValue, written(struct { d: toml.LocalDate }{ .d = .{ .year = 2001, .month = 2, .day = 29 } }, .{ .allocator = gpa }));
}

test "no null: an optional is absent or refused, unless the write leaves it out" {
    const Options = struct { name: []const u8, limit: ?u32 = null, note: ?[]const u8 = null };
    var parsed = try toml.parse(Options, gpa, "name = \"x\"\nlimit = 3", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, 3), parsed.value.limit);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.note);
    try std.testing.expectError(error.UnsupportedValue, written(parsed.value, .{ .allocator = gpa }));
    const out = try written(parsed.value, .{ .allocator = gpa, .nulls = .omit });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("name = \"x\"\nlimit = 3\n", out);
    // A field's own omission policy is explicit too.
    const Declared = struct {
        note: ?[]const u8 = null,
        pub const strand = .{ .fields = .{ .note = .{ .omit = .null_value } } };
    };
    const declared = try written(Declared{}, .{ .allocator = gpa });
    defer gpa.free(declared);
    try std.testing.expectEqualStrings("", declared);
}

test "numbers: TOML's signed 64 bits, floats as binary64, an integer where a float belongs" {
    const Numbers = struct { small: u8 = 0, wide: i64 = 0, float: f64 = 0, narrow: f32 = 0 };
    var parsed = try toml.parse(Numbers, gpa, "small = 0b1111_1111\nwide = -9223372036854775808\nfloat = 5\nnarrow = 0.1", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 255), parsed.value.small);
    try std.testing.expectEqual(std.math.minInt(i64), parsed.value.wide);
    try std.testing.expectEqual(@as(f64, 5), parsed.value.float);
    try std.testing.expectEqual(@as(f32, 0.1), parsed.value.narrow);
    try std.testing.expectError(error.NumberOutOfRange, toml.parse(Numbers, gpa, "small = 256", .{}));
    try std.testing.expectError(error.NumberOutOfRange, toml.parse(Value, gpa, "big = 9223372036854775808", .{}));
    try std.testing.expectError(error.NumberOutOfRange, toml.parse(Value, gpa, "big = 1e400", .{}));
    try std.testing.expectError(error.UnexpectedType, toml.parse(Numbers, gpa, "small = 1.0", .{}));
    // Past TOML's integers, a write is refused rather than spelled.
    try std.testing.expectError(error.NumberOutOfRange, written(struct { n: u64 }{ .n = std.math.maxInt(u64) }, .{ .allocator = gpa }));
    const floats = try written(struct { a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f32 }{ .a = 1, .b = -0.0, .c = 1e300, .d = 5e-324, .e = std.math.inf(f64), .f = -std.math.nan(f64), .g = 0.1 }, .{ .allocator = gpa });
    defer gpa.free(floats);
    try std.testing.expectEqualStrings("a = 1.0\nb = -0.0\nc = 1e300\nd = 5e-324\ne = inf\nf = -nan\ng = 0.10000000149011612\n", floats);
}

test "a union tagged inside its table is read by walking its part of the document again" {
    const Step = union(enum) {
        run: struct { cmd: []const u8, retries: u8 = 0 },
        wait: struct { seconds: u32 },
        stop,
        pub const strand = .{ .tag = "kind" };
    };
    const Pipeline = struct { steps: []const Step };
    const input =
        \\[[steps]]
        \\cmd = "make"
        \\kind = "run"
        \\
        \\[[steps]]
        \\kind = "wait"
        \\seconds = 3
        \\
        \\[[steps]]
        \\kind = "stop"
    ;
    var parsed = try toml.parse(Pipeline, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("make", parsed.value.steps[0].run.cmd);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.steps[1].wait.seconds);
    try std.testing.expectEqual(.stop, std.meta.activeTag(parsed.value.steps[2]));
    const out = try written(parsed.value, .{ .allocator = gpa });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("[[steps]]\nkind = \"run\"\ncmd = \"make\"\nretries = 0\n\n[[steps]]\nkind = \"wait\"\nseconds = 3\n\n[[steps]]\nkind = \"stop\"\n", out);
    // A union tagged outside is a table of its one arm.
    const Outer = struct { step: union(enum) { wait: struct { seconds: u32 }, stop } };
    var outer = try toml.parse(Outer, gpa, "step.wait.seconds = 2", .{});
    defer outer.deinit();
    try std.testing.expectEqual(@as(u32, 2), outer.value.step.wait.seconds);
    var unit = try toml.parse(Outer, gpa, "step = { stop = {} }", .{});
    defer unit.deinit();
    try std.testing.expectEqual(.stop, std.meta.activeTag(unit.value.step));
}

test "a document written: values first, then each table under its header, arrays of tables as sections" {
    const Doc = struct {
        title: []const u8 = "t",
        owner: struct { name: []const u8 = "Tom", dob: toml.OffsetDateTime = .{ .date = .{ .year = 1979, .month = 5, .day = 27 }, .time = .{ .hour = 7, .minute = 32 }, .offset_minutes = -480 } } = .{},
        empty: struct {} = .{},
        nested: struct { deeper: struct { x: u8 = 1 } = .{} } = .{},
        points: []const struct { x: i32, y: i32 } = &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } },
        mixed: []const Value = &.{ .{ .integer = 1 }, .{ .table = &.{.{ .key = "a b", .value = .{ .string = "q\"\n" } }} } },
        last: bool = true,
    };
    const out = try written(Doc{}, .{ .allocator = gpa });
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\title = "t"
        \\mixed = [1, { "a b" = "q\"\n" }]
        \\last = true
        \\
        \\[owner]
        \\name = "Tom"
        \\dob = 1979-05-27T07:32:00-08:00
        \\
        \\[empty]
        \\
        \\[nested.deeper]
        \\x = 1
        \\
        \\[[points]]
        \\x = 1
        \\y = 2
        \\
        \\[[points]]
        \\x = 3
        \\y = 4
        \\
    , out);
    var back = try toml.parse(Doc, gpa, out, .{ .version = .v1_0 });
    defer back.deinit();
    try std.testing.expectEqual(@as(i32, 4), back.value.points[1].y);
    // A map's key given twice has no spelling.
    const Pair = core.Pairs([]const u8, u8);
    try std.testing.expectError(error.DuplicateField, written(Pair{ .items = &.{ .{ .key = "a", .value = 1 }, .{ .key = "a", .value = 2 } } }, .{ .allocator = gpa }));
    // Nor has a document that is no table.
    try std.testing.expectError(error.UnsupportedValue, written(@as(u8, 1), .{ .allocator = gpa }));
}

test "unknown keys are refused unless skipped, and a failure says where it is" {
    const Small = struct { a: u8 };
    var d: core.Diagnostics = .{};
    try std.testing.expectError(error.UnknownField, toml.parse(Small, gpa, "a = 1\n[b]\nc = 2", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(?usize, 2), d.line);
    var skipped = try toml.parse(Small, gpa, "a = 1\n[b]\nc = 2", .{ .ignore_unknown_fields = true });
    skipped.deinit();
    try std.testing.expectError(error.SyntaxError, toml.parse(Small, gpa, "a = 1\nb = [1,\n2,,]", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(?usize, 3), d.line);
    try std.testing.expectEqual(@as(?usize, 3), d.column);
    try std.testing.expectEqualStrings("toml", d.format);
    try std.testing.expectError(error.MissingField, toml.parse(Small, gpa, "# nothing", .{ .diagnostics = &d }));
    try std.testing.expectError(error.InvalidUtf8, toml.parse(Small, gpa, "a = \"\xff\"", .{}));
}

test "limits at their edges: a document exactly at a limit is read, one past it refused" {
    // Four levels: the root, then a, b and c; the document is refused as it
    // is read, before any of it is handed on.
    const deep = "[a.b.c]\nx = 1";
    const Deep = struct { a: struct { b: struct { c: struct { x: u8 } } } };
    try std.testing.expectError(error.DepthLimit, toml.parse(Deep, gpa, deep, .{ .limits = .{ .depth = 3 } }));
    try std.testing.expectError(error.DepthLimit, toml.parse(core.Pairs([]const u8, u8), gpa, deep, .{ .limits = .{ .depth = 3 } }));
    var at_depth = try toml.parse(Deep, gpa, deep, .{ .limits = .{ .depth = 4 } });
    at_depth.deinit();
    const nested = "a = [[[1]]]";
    const Nested = struct { a: []const []const []const u16 };
    try std.testing.expectError(error.DepthLimit, toml.parse(Nested, gpa, nested, .{ .limits = .{ .depth = 3 } }));
    var at_nested = try toml.parse(Nested, gpa, nested, .{ .limits = .{ .depth = 4 } });
    at_nested.deinit();
    const text = "s = \"abc\\t\"";
    try std.testing.expectError(error.LengthLimit, toml.parse(Value, gpa, text, .{ .limits = .{ .string_bytes = .fromRaw(3) } }));
    var at_text = try toml.parse(Value, gpa, text, .{ .limits = .{ .string_bytes = .fromRaw(4) } });
    at_text.deinit();
    try std.testing.expectError(error.LengthLimit, toml.parse(Value, gpa, "abcd = 1", .{ .limits = .{ .key_bytes = .fromRaw(3) } }));
    var at_key = try toml.parse(Value, gpa, "abc = 1", .{ .limits = .{ .key_bytes = .fromRaw(3) } });
    at_key.deinit();
    const four = "a = [1, 2, 3, 4]";
    try std.testing.expectError(error.ItemLimit, toml.parse(Value, gpa, four, .{ .limits = .{ .container_items = 3 } }));
    var at_items = try toml.parse(Value, gpa, four, .{ .limits = .{ .container_items = 4 } });
    at_items.deinit();
    try std.testing.expectError(error.ItemLimit, toml.parse(Value, gpa, "a = 1\nb = 2\nc = 3\nd = 4", .{ .limits = .{ .container_items = 3 } }));
    try std.testing.expectError(error.LengthLimit, toml.parse(Value, gpa, "n = 1_000", .{ .limits = .{ .numeric_bytes = .fromRaw(3) } }));
    var at_number = try toml.parse(Value, gpa, "n = 1_000", .{ .limits = .{ .numeric_bytes = .fromRaw(4) } });
    at_number.deinit();
    try std.testing.expectError(error.InputLimit, toml.parse(Value, gpa, four, .{ .limits = .{ .input_bytes = .fromRaw(four.len - 1) } }));
    var at_input = try toml.parse(Value, gpa, four, .{ .limits = .{ .input_bytes = .fromRaw(four.len) } });
    at_input.deinit();
    // Dotted keys and implicit tables are work like any other.
    try std.testing.expectError(error.WorkLimit, toml.parse(Value, gpa, "a.b.c.d.e.f.g.h = 1", .{ .limits = .{ .work = 40 } }));
    try std.testing.expectError(error.AllocationLimit, toml.parse(Value, gpa, four, .{ .limits = .{ .allocation_bytes = .fromRaw(64) } }));
    var buffer: [16]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.OutputLimit, toml.write(&fixed, .{ .a = 1 }, .{ .allocator = gpa, .limits = .{ .output_bytes = .fromRaw(5) } }));
    fixed = .fixed(&buffer);
    try toml.write(&fixed, .{ .a = 1 }, .{ .allocator = gpa, .limits = .{ .output_bytes = .fromRaw(6) } });
    try std.testing.expectEqualStrings("a = 1\n", fixed.buffered());
}

fn sweep(a: std.mem.Allocator) !void {
    const input = "t = \"x\\ty\"\n[a.b]\nc = [1, 2.5, { d = 1979-05-27 }]\n[[e]]\nf = true";
    var parsed = try toml.parseOwned(Value, a, input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // The writer's own allocation failing is its write failing.
    toml.write(&out.writer, parsed.value, .{ .allocator = a }) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

test "every allocation failure while reading and writing is an error, never a leak" {
    try std.testing.checkAllAllocationFailures(gpa, sweep, .{});
}

/// A generated value: every kind, nested a few levels, tables with keys of
/// any text.
fn item(case: *shakedown.Case, depth: u8) error{OutOfMemory}!Value {
    const s = case.source;
    const a = case.gpa;
    const kinds: u8 = if (depth == 0) 9 else 11;
    return switch (gen.intRange(s, u8, 0, kinds)) {
        0 => .{ .integer = gen.int(s, i64) },
        1 => .{ .integer = gen.intRange(s, i64, -300, 300) },
        2 => .{ .string = try gen.string(s, a, .{ .max_len = 24 }) },
        3 => .{ .boolean = gen.boolean(s) },
        4 => .{ .float = @bitCast(gen.int(s, u64)) },
        5 => .{ .float = gen.oneOf(s, f64, &.{ 0.0, -0.0, 1.5, 0.1, 1e300, 5e-324, std.math.inf(f64), -std.math.inf(f64) }) },
        6 => .{ .local_date = .{ .year = gen.intRange(s, u16, 0, 9999), .month = 2, .day = gen.intRange(s, u8, 1, 28) } },
        7 => .{ .local_time = .{ .hour = gen.intRange(s, u8, 0, 23), .minute = gen.intRange(s, u8, 0, 59), .second = gen.intRange(s, u8, 0, 60), .nanosecond = gen.intRange(s, u32, 0, 999_999_999) } },
        8 => .{ .offset_date_time = .{ .date = .{ .year = 2024, .month = 12, .day = 31 }, .time = .{ .hour = 23, .minute = 59 }, .offset_minutes = gen.intRange(s, i16, -1439, 1439) } },
        9 => .{ .local_date_time = .{ .date = .{ .year = 1, .month = 1, .day = 1 }, .time = .{ .hour = 0, .minute = 0, .nanosecond = gen.intRange(s, u32, 0, 999_999_999) } } },
        10 => blk: {
            const items = try a.alloc(Value, gen.intRange(s, usize, 0, 4));
            for (items) |*v| v.* = try item(case, depth - 1);
            break :blk .{ .array = items };
        },
        else => try table(case, depth - 1),
    };
}
fn table(case: *shakedown.Case, depth: u8) error{OutOfMemory}!Value {
    const s = case.source;
    const a = case.gpa;
    const entries = try a.alloc(toml.Entry, gen.intRange(s, usize, 0, 4));
    var n: usize = 0;
    for (entries) |_| {
        const key = try gen.string(s, a, .{ .max_len = 8 });
        // A table's keys are its own: a repeat is left out.
        for (entries[0..n]) |e| {
            if (std.mem.eql(u8, e.key, key)) break;
        } else {
            entries[n] = .{ .key = key, .value = try item(case, depth) };
            n += 1;
        }
    }
    return .{ .table = entries[0..n] };
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value = try table(case, 3);
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try toml.write(&out.writer, value, .{ .allocator = case.gpa });
    case.note("toml:\n{s}", .{out.written()});
    // Written, it is TOML 1.0 and 1.1, and it reads back as itself.
    for ([_]toml.Version{ .v1_0, .v1_1 }) |version| {
        var parsed = try toml.parse(Value, case.gpa, out.written(), .{ .version = version });
        defer parsed.deinit();
        try std.testing.expect(parsed.value.eql(value));
    }
    // Cut anywhere, it is refused or read as some document, never a crash;
    // a document read is written and read back as itself.
    for (0..out.written().len) |end| {
        var cut = toml.parse(Value, case.gpa, out.written()[0..end], .{}) catch continue;
        defer cut.deinit();
        try rewritten(case, cut.value);
    }
}
fn rewritten(case: *shakedown.Case, value: Value) !void {
    var again: std.Io.Writer.Allocating = .init(case.gpa);
    defer again.deinit();
    try toml.write(&again.writer, value, .{ .allocator = case.gpa });
    var back = try toml.parse(Value, case.gpa, again.written(), .{ .version = .v1_0 });
    defer back.deinit();
    try std.testing.expect(back.value.eql(value));
}

test "generated documents read back as they were, in TOML 1.0 and 1.1, truncated anywhere" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 400 });
}

const examples = [_][]const u8{
    "a = 1\nb = \"x\"\n[t]\nc = [1, 2]\n",
    "[[a]]\nb.c = 1979-05-27T07:32:00Z\n[[a]]\n[a.d]\ne = -inf\n",
    "s = \"\"\"\nline \\\n  end\"\"\"\nl = '''raw\\'''\n",
    "t = { a = 1, b = { c = [true, 07:32:00] } }\n",
    "x = 0xff_ff\ny = 1e-7\nz = 2000-02-29\n'k k' = 1\n",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [160]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {s}", .{input});
    for ([_]toml.Version{ .v1_0, .v1_1 }) |version| {
        const options: toml.ParseOptions = .{ .version = version, .limits = .{ .work = 1 << 16, .depth = 32 } };
        var parsed = toml.parse(Value, case.gpa, input, options) catch continue;
        defer parsed.deinit();
        // A document read is a document a write spells, and reads back as itself.
        try rewritten(case, parsed.value);
    }
}

test "fuzz: any bytes are a document or refused, and a document read is written and read back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
