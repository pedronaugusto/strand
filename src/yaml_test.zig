//! YAML: streams read as types and as values, plain scalars resolved by the
//! type that reads them and otherwise by the core schema (and no YAML 1.1
//! forms), anchors and aliases and their expansion held to the limits, tags
//! outside the core schema refused, keys given twice refused, documents of a
//! stream, a union tagged inside its mapping (read twice, through an alias
//! too), documents written as they are spelled and read back, failures placed
//! in the text, limits at their edges, allocation failures, and properties
//! over generated values and over any bytes. yaml-test-suite runs in
//! `testing/yaml_suite.zig`.
const std = @import("std");
const yaml = @import("yaml.zig");
const core = @import("core.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;
const Value = yaml.Value;

const Server = struct {
    host: []const u8,
    port: u16,
    tags: []const []const u8 = &.{},
    ratio: f64 = 1,
    note: ?[]const u8 = null,
};
const Config = struct {
    title: []const u8,
    server: Server,
    replicas: []const Server = &.{},
    mode: enum { fast, careful } = .fast,
};

fn written(value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try yaml.write(&out.writer, value, .{});
    return out.toOwnedSlice();
}

test "a document read as a type: block and flow collections, every scalar style, comments" {
    const input =
        \\# a configuration
        \\title: example   # a comment
        \\mode: careful
        \\server: &main
        \\  host: localhost
        \\  port: 8080
        \\  tags: [a, 'b', "c\td"]
        \\  note: |
        \\    two
        \\    lines
        \\replicas:
        \\- host: >-
        \\    folded
        \\    text
        \\  port: 0x10
        \\  ratio: .5
        \\- *main
    ;
    var parsed = try yaml.parse(Config, gpa, input, .{});
    defer parsed.deinit();
    const config = parsed.value;
    try std.testing.expectEqualStrings("example", config.title);
    try std.testing.expectEqual(.careful, config.mode);
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqualStrings("c\td", config.server.tags[2]);
    try std.testing.expectEqualStrings("two\nlines\n", config.server.note.?);
    try std.testing.expectEqualStrings("folded text", config.replicas[0].host);
    try std.testing.expectEqual(@as(u16, 16), config.replicas[0].port);
    try std.testing.expectEqual(@as(f64, 0.5), config.replicas[0].ratio);
    // The alias is its anchor's node again.
    try std.testing.expectEqualStrings("localhost", config.replicas[1].host);
    try std.testing.expectEqualStrings("two\nlines\n", config.replicas[1].note.?);
    // Nothing is kept from the input in an owned parse.
    const copy = try gpa.dupe(u8, input);
    var owned = try yaml.parseOwned(Config, gpa, copy, .{});
    defer owned.deinit();
    @memset(copy, 'x');
    gpa.free(copy);
    try std.testing.expectEqualStrings("localhost", owned.value.replicas[1].host);
}

test "a plain scalar is what the type asks for, else what the core schema says, and never YAML 1.1's" {
    const Typed = struct { version: []const u8, float: f64, flag: bool, nothing: ?u8, text: ?[]const u8, word: []const u8 };
    var typed = try yaml.parse(Typed, gpa, "version: 1.10\nfloat: 1.10\nflag: TRUE\nnothing: ~\ntext: null\nword: true", .{});
    defer typed.deinit();
    try std.testing.expectEqualStrings("1.10", typed.value.version);
    try std.testing.expectEqual(@as(f64, 1.1), typed.value.float);
    try std.testing.expect(typed.value.flag);
    try std.testing.expectEqual(@as(?u8, null), typed.value.nothing);
    try std.testing.expectEqual(@as(?[]const u8, null), typed.value.text);
    try std.testing.expectEqualStrings("true", typed.value.word);
    // A quoted scalar is a string, and a string is no number nor boolean.
    try std.testing.expectError(error.UnexpectedType, yaml.parse(struct { n: u8 }, gpa, "n: \"1\"", .{}));
    // No YAML 1.1 forms: these are strings, never booleans or numbers.
    for ([_][]const u8{ "yes", "No", "on", "OFF", "y", "0b101", "1_000", "1:30", "0777x" }) |spelling| {
        var buffer: [32]u8 = undefined;
        const input = try std.mem.print(&buffer, "v: {s}", .{spelling});
        try std.testing.expectError(error.UnexpectedType, yaml.parse(struct { v: bool }, gpa, input, .{}));
        var value = try yaml.parse(Value, gpa, input, .{});
        defer value.deinit();
        try std.testing.expectEqualStrings(spelling, value.value.field("v").?.string);
    }
    // The core schema, for a type that asks for nothing in particular.
    var value = try yaml.parse(Value, gpa, "[~, null, '', True, 0o17, -0x1, .5, -.INF, .NaN, 1e3, 12, \"12\", !!str 12, !!float 12, ]", .{});
    defer value.deinit();
    const items = value.value.sequence;
    try std.testing.expectEqual(.null, std.meta.activeTag(items[0]));
    try std.testing.expectEqual(.null, std.meta.activeTag(items[1]));
    try std.testing.expectEqualStrings("", items[2].string);
    try std.testing.expect(items[3].boolean);
    try std.testing.expectEqual(@as(i128, 15), items[4].integer);
    try std.testing.expectEqualStrings("-0x1", items[5].string);
    try std.testing.expectEqual(@as(f64, 0.5), items[6].float);
    try std.testing.expect(std.math.isNegativeInf(items[7].float));
    try std.testing.expect(std.math.isNan(items[8].float));
    try std.testing.expectEqual(@as(f64, 1000), items[9].float);
    try std.testing.expectEqual(@as(i128, 12), items[10].integer);
    try std.testing.expectEqualStrings("12", items[11].string);
    try std.testing.expectEqualStrings("12", items[12].string);
    try std.testing.expectEqual(@as(f64, 12), items[13].float);
    // A tagged scalar is what its tag says, and one its tag does not fit is refused.
    try std.testing.expectError(error.SyntaxError, yaml.parse(Value, gpa, "!!int 1.5", .{}));
    try std.testing.expectError(error.SyntaxError, yaml.parse(Value, gpa, "!!bool yes", .{}));
    try std.testing.expectError(error.UnexpectedType, yaml.parse(Value, gpa, "!!map [a]", .{}));
}

test "a tag the core schema lacks is refused: no application type is read from one" {
    for ([_][]const u8{ "!foo bar", "!!binary aGk=", "--- !!set\n? a", "%TAG !e! tag:example.com,2000:\n--- !e!x 1", "!<tag:yaml.org,2002:python/object> {}", "a: !Ref b" }) |input| {
        try std.testing.expectError(error.UnsupportedValue, yaml.parse(Value, gpa, input, .{}));
    }
    // The core schema's own tags, in any spelling of them.
    var parsed = try yaml.parse(Value, gpa, "%TAG !y! tag:yaml.org,2002:\n--- !y!seq [!<tag:yaml.org,2002:int> 1, ! a]", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i128, 1), parsed.value.sequence[0].integer);
    try std.testing.expectEqualStrings("a", parsed.value.sequence[1].string);
}

test "a mapping's keys are given once, and a key may be any node" {
    for ([_][]const u8{ "a: 1\na: 2", "a: 1\n'a': 2", "{a: 1, \"a\": 2}", "&k a: 1\n*k : 2", "1: x\n0x1: y", "~: x\nnull: y", "1.0: x\n1e0: y", "true: x\nTrue: y" }) |input| {
        try std.testing.expectError(error.DuplicateField, yaml.parse(Value, gpa, input, .{}));
    }
    // An integer and a string spelled alike are two keys.
    var parsed = try yaml.parse(Value, gpa, "1: int\n'1': str\n? [a, b]\n: seq\n? {c: d}\n: map\n", .{});
    defer parsed.deinit();
    const m = parsed.value.mapping;
    try std.testing.expectEqual(4, m.len);
    try std.testing.expectEqualStrings("int", parsed.value.get(.{ .integer = 1 }).?.string);
    try std.testing.expectEqualStrings("str", parsed.value.field("1").?.string);
    try std.testing.expectEqualStrings("a", m[2].key.sequence[0].string);
    try std.testing.expectEqualStrings("map", m[3].value.string);
    // A typed map reads keys as the type asks.
    var numbered = try yaml.parse(core.Pairs(u16, []const u8), gpa, "1: a\n0x10: b", .{});
    defer numbered.deinit();
    try std.testing.expectEqual(@as(u16, 16), numbered.value.items[1].key);
    // A record's keys are text: a collection is none.
    try std.testing.expectError(error.UnexpectedType, yaml.parse(struct { a: u8 }, gpa, "? [a]\n: 1", .{}));
}

test "anchors and aliases: repeated where they are, never inside themselves, and their expansion bounded" {
    var parsed = try yaml.parse(Value, gpa, "base: &b {x: 1, list: &l [1, 2]}\ncopy: *b\nlist: *l\nscalar: &s text\nagain: *s\n", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.field("copy").?.eql(parsed.value.field("base").?));
    try std.testing.expectEqual(@as(i128, 2), parsed.value.field("list").?.sequence[1].integer);
    try std.testing.expectEqualStrings("text", parsed.value.field("again").?.string);
    // An anchor may be set again: an alias is the last one before it.
    var last = try yaml.parse([]const []const u8, gpa, "[&a x, &a y, *a]", .{});
    defer last.deinit();
    try std.testing.expectEqualStrings("y", last.value[2]);
    // An alias to no anchor, or to the node it is inside, is refused.
    try std.testing.expectError(error.SyntaxError, yaml.parse(Value, gpa, "a: *nothing", .{}));
    try std.testing.expectError(error.SyntaxError, yaml.parse(Value, gpa, "&a [1, *a]", .{}));
    // Anchors are a document's own.
    try std.testing.expectError(error.SyntaxError, yaml.parseStream(Value, gpa, "--- &a 1\n--- *a\n", .{}));
    // Aliases of aliases: nine levels of nine would be 387 million nodes.
    var bomb: std.Io.Writer.Allocating = .init(gpa);
    defer bomb.deinit();
    try bomb.writer.writeAll("a0: &a0 [x, x, x, x, x, x, x, x, x]\n");
    for (1..9) |level| {
        try bomb.writer.print("a{d}: &a{d} [", .{ level, level });
        for (0..9) |i| try bomb.writer.print("{s}*a{d}", .{ if (i == 0) "" else ", ", level - 1 });
        try bomb.writer.writeAll("]\n");
    }
    try std.testing.expectError(error.ItemLimit, yaml.parse(Value, gpa, bomb.written(), .{}));
    // Refused as read, before a value is made: also where the type skips it.
    try std.testing.expectError(error.ItemLimit, yaml.parse(struct {}, gpa, bomb.written(), .{ .ignore_unknown_fields = true }));
    // Three levels are 820 nodes: within a limit of 820, past one of 819.
    const small = "a0: &a0 [x, x, x, x, x, x, x, x, x]\na1: &a1 [*a0, *a0, *a0, *a0, *a0, *a0, *a0, *a0, *a0]\na2: [*a1, *a1, *a1, *a1, *a1, *a1, *a1, *a1, *a1]\n";
    var within = try yaml.parse(Value, gpa, small, .{ .limits = .{ .items = 4096 } });
    defer within.deinit();
    try std.testing.expectEqual(9, within.value.field("a2").?.sequence[8].sequence.len);
    try std.testing.expectError(error.ItemLimit, yaml.parse(Value, gpa, small, .{ .limits = .{ .items = 100 } }));
}

test "a stream's documents: one read by parse, all by parseStream" {
    const stream = "%YAML 1.2\n---\na: 1\n...\n--- [2]\n---\n# empty\n...\nbare: 3\n";
    var all = try yaml.parseStream(Value, gpa, stream, .{});
    defer all.deinit();
    try std.testing.expectEqual(4, all.value.len);
    try std.testing.expectEqual(@as(i128, 2), all.value[1].sequence[0].integer);
    try std.testing.expectEqual(.null, std.meta.activeTag(all.value[2]));
    try std.testing.expectEqual(@as(i128, 3), all.value[3].field("bare").?.integer);
    // A second document where one is read is refused.
    try std.testing.expectError(error.SyntaxError, yaml.parse(Value, gpa, stream, .{}));
    // No document at all is one empty document, null; a stream of none.
    var empty = try yaml.parse(?u8, gpa, "# nothing\n", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(?u8, null), empty.value);
    var none = try yaml.parseStream(Value, gpa, "", .{});
    defer none.deinit();
    try std.testing.expectEqual(0, none.value.len);
    // Written, a stream reads back as its documents.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try yaml.writeStream(&out.writer, all.value, .{});
    try std.testing.expectEqualStrings("a: 1\n---\n- 2\n---\nnull\n---\nbare: 3\n", out.written());
}

test "a union tagged inside its mapping is read by walking its part again, through an alias too" {
    const Step = union(enum) {
        run: struct { cmd: []const u8, retries: u8 = 0 },
        wait: struct { seconds: u32 },
        stop,
        pub const strand = .{ .tag = "kind" };
    };
    const Pipeline = struct { steps: []const Step };
    const input =
        \\steps:
        \\- cmd: make
        \\  kind: run
        \\- &w
        \\  seconds: 3
        \\  kind: wait
        \\- kind: stop
        \\- *w
    ;
    var parsed = try yaml.parse(Pipeline, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("make", parsed.value.steps[0].run.cmd);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.steps[1].wait.seconds);
    try std.testing.expectEqual(.stop, std.meta.activeTag(parsed.value.steps[2]));
    try std.testing.expectEqual(@as(u32, 3), parsed.value.steps[3].wait.seconds);
    const out = try written(parsed.value);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\steps:
        \\  - kind: run
        \\    cmd: make
        \\    retries: 0
        \\  - kind: wait
        \\    seconds: 3
        \\  - kind: stop
        \\  - kind: wait
        \\    seconds: 3
        \\
    , out);
    // A union tagged outside is a mapping of its one arm; an arm with
    // nothing in it holds null.
    const Outer = struct { step: union(enum) { wait: struct { seconds: u32 }, stop } };
    var outer = try yaml.parse(Outer, gpa, "step: {wait: {seconds: 2}}", .{});
    defer outer.deinit();
    try std.testing.expectEqual(@as(u32, 2), outer.value.step.wait.seconds);
    var unit = try yaml.parse(Outer, gpa, "step:\n  stop:\n", .{});
    defer unit.deinit();
    try std.testing.expectEqual(.stop, std.meta.activeTag(unit.value.step));
    const stop = try written(Outer{ .step = .stop });
    defer gpa.free(stop);
    try std.testing.expectEqualStrings("step:\n  stop: null\n", stop);
}

test "a document written: block style, strings plain only where they read back as themselves" {
    const Doc = struct {
        title: []const u8 = "plain text",
        quoted: []const []const u8 = &.{ "", "true", "null", "12", "1.5", "- dash", "a: b", "a #b", "tab\there", "line\nbreak", "é ok", "\u{85}", "~", "x:", "...", "[x]", " lead" },
        numbers: struct { i: i64 = -3, f: f64 = 1, g: f32 = 0.1, inf: f64 = -std.math.inf(f64), nan: f64 = std.math.nan(f64) } = .{},
        empty_map: struct {} = .{},
        empty_list: []const u16 = &.{},
        nested: []const []const u16 = &.{ &.{ 1, 2 }, &.{} },
        maybe: ?u8 = null,
        mixed: []const Value = &.{ .{ .integer = 1 }, .{ .mapping = &.{.{ .key = .{ .sequence = &.{ .{ .string = "k" }, .{ .integer = 2 } } }, .value = .{ .string = "v" } }} } },
    };
    const out = try written(Doc{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings(
        \\title: plain text
        \\quoted:
        \\  - ""
        \\  - "true"
        \\  - "null"
        \\  - "12"
        \\  - "1.5"
        \\  - "- dash"
        \\  - "a: b"
        \\  - "a #b"
        \\  - "tab\there"
        \\  - "line\nbreak"
        \\  - é ok
        \\  - "\N"
        \\  - "~"
        \\  - "x:"
        \\  - "..."
        \\  - "[x]"
        \\  - " lead"
        \\numbers:
        \\  i: -3
        \\  f: 1.0
        \\  g: 0.10000000149011612
        \\  inf: -.inf
        \\  nan: .nan
        \\empty_map: {}
        \\empty_list: []
        \\nested:
        \\  - - 1
        \\    - 2
        \\  - []
        \\maybe: null
        \\mixed:
        \\  - 1
        \\  - ? [k, 2]
        \\    : v
        \\
    , out);
    var back = try yaml.parse(Doc, gpa, out, .{});
    defer back.deinit();
    const quoted = (Doc{}).quoted;
    for (quoted, back.value.quoted) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(f32, 0.1), back.value.numbers.g);
    var value = try yaml.parse(Value, gpa, out, .{});
    defer value.deinit();
    try std.testing.expectEqualStrings("v", value.value.field("mixed").?.sequence[1].mapping[0].value.string);
    // A root scalar is a document too.
    const root = try written(@as([]const u8, "x"));
    defer gpa.free(root);
    try std.testing.expectEqualStrings("x\n", root);
    // A map's key given twice has no spelling.
    const Pair = core.Pairs([]const u8, u8);
    try std.testing.expectError(error.DuplicateField, written(Pair{ .items = &.{ .{ .key = "a", .value = 1 }, .{ .key = "a", .value = 2 } } }));
}

test "unknown keys are refused unless skipped, and a failure says where it is" {
    const Small = struct { a: u8 };
    var d: core.Diagnostics = .{};
    try std.testing.expectError(error.UnknownField, yaml.parse(Small, gpa, "a: 1\nb:\n  c: 2", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(?usize, 2), d.line);
    var skipped = try yaml.parse(Small, gpa, "a: 1\nb:\n  c: 2", .{ .ignore_unknown_fields = true });
    skipped.deinit();
    try std.testing.expectError(error.SyntaxError, yaml.parse(Small, gpa, "a: 1\nb: [1,\n  2,,]", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(?usize, 3), d.line);
    try std.testing.expectEqual(@as(?usize, 5), d.column);
    try std.testing.expectEqualStrings("yaml", d.format);
    try std.testing.expectError(error.NumberOutOfRange, yaml.parse(Small, gpa, "\n\na: 256", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(?usize, 3), d.line);
    try std.testing.expectEqual(@as(?usize, 4), d.column);
    try std.testing.expectError(error.MissingField, yaml.parse(Small, gpa, "{}", .{ .diagnostics = &d }));
    try std.testing.expectError(error.InvalidUtf8, yaml.parse(Small, gpa, "a: \"\xff\"", .{}));
}

test "limits at their edges: a stream exactly at a limit is read, one past it refused" {
    const nested = "a: [[[1]]]";
    const Nested = struct { a: []const []const []const u16 };
    try std.testing.expectError(error.DepthLimit, yaml.parse(Nested, gpa, nested, .{ .limits = .{ .depth = 3 } }));
    var at_nested = try yaml.parse(Nested, gpa, nested, .{ .limits = .{ .depth = 4 } });
    at_nested.deinit();
    const text = "s: \"abc\\t\"";
    try std.testing.expectError(error.LengthLimit, yaml.parse(Value, gpa, text, .{ .limits = .{ .string_bytes = 3 } }));
    var at_text = try yaml.parse(Value, gpa, text, .{ .limits = .{ .string_bytes = 4 } });
    at_text.deinit();
    try std.testing.expectError(error.LengthLimit, yaml.parse(struct { abcd: u8 }, gpa, "abcd: 1", .{ .limits = .{ .key_bytes = 3 } }));
    var at_key = try yaml.parse(struct { abc: u8 }, gpa, "abc: 1", .{ .limits = .{ .key_bytes = 3 } });
    at_key.deinit();
    const four = "a: [1, 2, 3, 4]";
    try std.testing.expectError(error.ItemLimit, yaml.parse(Value, gpa, four, .{ .limits = .{ .container_items = 3 } }));
    var at_items = try yaml.parse(Value, gpa, four, .{ .limits = .{ .container_items = 4 } });
    at_items.deinit();
    try std.testing.expectError(error.ItemLimit, yaml.parse(Value, gpa, "a: 1\nb: 2\nc: 3\nd: 4", .{ .limits = .{ .container_items = 3 } }));
    try std.testing.expectError(error.LengthLimit, yaml.parse(Value, gpa, "n: 1000", .{ .limits = .{ .numeric_bytes = 3 } }));
    var at_number = try yaml.parse(Value, gpa, "n: 1000", .{ .limits = .{ .numeric_bytes = 4 } });
    at_number.deinit();
    try std.testing.expectError(error.InputLimit, yaml.parse(Value, gpa, four, .{ .limits = .{ .input_bytes = four.len - 1 } }));
    var at_input = try yaml.parse(Value, gpa, four, .{ .limits = .{ .input_bytes = four.len } });
    at_input.deinit();
    try std.testing.expectError(error.WorkLimit, yaml.parse(Value, gpa, four, .{ .limits = .{ .work = 20 } }));
    try std.testing.expectError(error.AllocationLimit, yaml.parse(Value, gpa, four, .{ .limits = .{ .allocation_bytes = 64 } }));
    var buffer: [16]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.OutputLimit, yaml.write(&fixed, .{ .a = 1 }, .{ .limits = .{ .output_bytes = 4 } }));
    fixed = .fixed(&buffer);
    try yaml.write(&fixed, .{ .a = 1 }, .{ .limits = .{ .output_bytes = 5 } });
    try std.testing.expectEqualStrings("a: 1\n", fixed.buffered());
    // Past 64 levels a write holds its collections on the allocator given.
    const deep = try deepValue(gpa, 70);
    defer freeDeep(gpa, deep);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.DepthLimit, yaml.write(&sink.writer, deep, .{}));
    try yaml.write(&sink.writer, deep, .{ .allocator = gpa });
}
fn deepValue(a: std.mem.Allocator, depth: usize) !Value {
    var value: Value = .{ .integer = 1 };
    for (0..depth) |_| {
        const items = try a.alloc(Value, 1);
        items[0] = value;
        value = .{ .sequence = items };
    }
    return value;
}
fn freeDeep(a: std.mem.Allocator, value: Value) void {
    var at = value;
    while (at == .sequence) {
        const next = at.sequence[0];
        a.free(at.sequence);
        at = next;
    }
}

fn sweep(a: std.mem.Allocator) !void {
    const input = "t: \"x\\ty\"\na: &a {b: [1, 2.5, {d: null}]}\nc: *a\n? [k]\n: |\n  text\n";
    var parsed = try yaml.parseOwned(Value, a, input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // The writer's own allocation failing is its write failing.
    yaml.write(&out.writer, parsed.value, .{}) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

test "every allocation failure while reading and writing is an error, never a leak" {
    try std.testing.checkAllAllocationFailures(gpa, sweep, .{});
}

/// A generated value: every kind, nested a few levels, mappings with keys of
/// any kind.
fn item(case: *shakedown.Case, depth: u8) error{OutOfMemory}!Value {
    const s = case.source;
    const a = case.gpa;
    const kinds: u8 = if (depth == 0) 7 else 9;
    return switch (gen.intRange(s, u8, 0, kinds)) {
        0 => .{ .integer = if (gen.boolean(s)) gen.int(s, i64) else gen.int(s, u64) },
        1 => .{ .integer = gen.intRange(s, i16, -300, 300) },
        2, 3 => .{ .string = try gen.string(s, a, .{ .max_len = 24 }) },
        4 => .{ .boolean = gen.boolean(s) },
        5 => .{ .float = @bitCast(gen.int(s, u64)) },
        6 => .{ .float = gen.oneOf(s, f64, &.{ 0.0, -0.0, 1.5, 0.1, 1e300, 5e-324, std.math.inf(f64), -std.math.inf(f64) }) },
        7 => .null,
        8 => blk: {
            const items = try a.alloc(Value, gen.intRange(s, usize, 0, 4));
            for (items) |*v| v.* = try item(case, depth - 1);
            break :blk .{ .sequence = items };
        },
        else => try mapping(case, depth - 1),
    };
}
fn mapping(case: *shakedown.Case, depth: u8) error{OutOfMemory}!Value {
    const s = case.source;
    const a = case.gpa;
    const entries = try a.alloc(yaml.Entry, gen.intRange(s, usize, 0, 4));
    var n: usize = 0;
    for (entries) |_| {
        const key: Value = if (gen.intRange(s, u8, 0, 4) == 0) try item(case, depth) else .{ .string = try gen.string(s, a, .{ .max_len = 8 }) };
        // A mapping's keys are its own: a repeat is left out.
        for (entries[0..n]) |e| {
            if (e.key.eql(key)) break;
        } else {
            entries[n] = .{ .key = key, .value = try item(case, depth) };
            n += 1;
        }
    }
    return .{ .mapping = entries[0..n] };
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value = try item(case, 3);
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try yaml.write(&out.writer, value, .{});
    case.note("yaml:\n{s}", .{out.written()});
    var parsed = try yaml.parse(Value, case.gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(value));
    // Cut anywhere, it is refused or read as some document, never a crash;
    // a document read is written and read back as itself.
    for (0..out.written().len) |end| {
        var cut = yaml.parse(Value, case.gpa, out.written()[0..end], .{}) catch continue;
        defer cut.deinit();
        try rewritten(case, cut.value);
    }
}
fn rewritten(case: *shakedown.Case, value: Value) !void {
    var again: std.Io.Writer.Allocating = .init(case.gpa);
    defer again.deinit();
    try yaml.write(&again.writer, value, .{});
    var back = try yaml.parse(Value, case.gpa, again.written(), .{});
    defer back.deinit();
    try std.testing.expect(back.value.eql(value));
}

test "generated documents read back as they were, truncated anywhere" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 400 });
}

const examples = [_][]const u8{
    "a: 1\nb: \"x\"\nt:\n  c: [1, 2]\n",
    "- &a {b: c}\n- *a\n- ? [k]\n  : v\n",
    "s: |+\n  line\n\n  end\nl: >-\n  folded\n  text\n",
    "--- !!str x\n...\n%YAML 1.2\n--- [true, ~, .inf]\n",
    "{\"json\": [1, 2.5e3, null], plain: 'quo''te'}\n",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [160]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {s}", .{input});
    const options: yaml.ParseOptions = .{ .limits = .{ .work = 1 << 16, .depth = 32, .items = 1 << 12 } };
    var parsed = yaml.parseStream(Value, case.gpa, input, options) catch |err| {
        // Refused borrowed, refused owned and on an arena, alike.
        try std.testing.expectError(err, yaml.parseStreamOwned(Value, case.gpa, input, options));
        return;
    };
    defer parsed.deinit();
    // Read owned, and on an arena, the documents are the same.
    var owned = try yaml.parseStreamOwned(Value, case.gpa, input, options);
    defer owned.deinit();
    var arena: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena.deinit();
    const leaky = try yaml.parseStreamLeaky(Value, arena.allocator(), input, options);
    try std.testing.expectEqual(parsed.value.len, owned.value.len);
    try std.testing.expectEqual(parsed.value.len, leaky.len);
    for (parsed.value, owned.value, leaky) |a, b, c| {
        try std.testing.expect(a.eql(b));
        try std.testing.expect(a.eql(c));
    }
    // A document read is a document a write spells, and reads back as itself.
    for (parsed.value) |document| try rewritten(case, document);
}

test "fuzz: any bytes are a stream or refused, and a document read is written and read back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
