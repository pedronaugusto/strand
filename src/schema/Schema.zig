//! A schema compiled once, to validate any number of instances. It owns the
//! documents it was compiled from and its program, in one arena.
const Schema = @This();
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const compiler = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const canonical = @import("canonical.zig");
const Limits = @import("Limits.zig");
const Program = @import("Program.zig");

pub const Options = compiler.Options;
pub const Record = evaluate.Record;

pub const Downgrade = Program.Downgrade;

/// What a validation reports beside its verdict. Either way the keywords
/// compiled as annotations (`unsupported_pattern = .downgrade`) that it
/// passed through are named, so a verdict says what it did not check.
pub const Output = union(enum) {
    /// The verdict, and where given, the downgraded keywords it passed.
    flag: ?*Report,
    /// The verdict and, for an invalid instance, why: each failing keyword
    /// on the path to the verdict, up to `Limits.errors`.
    basic: *Errors,
};

/// A `flag` output's report, held in the validation's `scratch`.
pub const Report = struct {
    downgraded: []const Downgrade = &.{},
};

/// A `basic` output's errors, held in the validation's `scratch`.
pub const Errors = struct {
    records: []const Record = &.{},
    downgraded: []const Downgrade = &.{},
};

/// The keywords compiled as annotations under `.downgrade`, with their
/// locations and the construct spectra refused.
pub fn downgrades(s: *const Schema) []const Downgrade {
    return s.program.downgrades;
}
pub const Diagnostic = compiler.Diagnostic;
pub const CompileError = compiler.Error;

arena: *std.heap.ArenaAllocator,
program: Program,
limits: Limits,

/// The schema `document` holds, written in any format strand reads
/// (`strand.json`, `strand.yaml`, `strand.toml`, ...), compiled. `io` is
/// the loader's, for a remote document.
pub fn compile(gpa: std.mem.Allocator, io: std.Io, comptime Format: type, document: aegis.input.Untrusted([]const u8), options: Options) CompileError!Schema {
    const bytes = document.readForParse();
    if (bytes.len > options.limits.schema_bytes.raw()) return error.TooLarge;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const a = arena.allocator();
    const root = try a.create(strand.json.Value);
    root.* = Format.parseLeaky(strand.json.Value, a, bytes, .{}) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    return .{ .arena = arena, .program = try compiler.compile(a, io, root, options), .limits = options.limits };
}

/// Whether `instance`, in `Format`, is valid: streamed through the program
/// with no tree, its slots and state from `scratch` (an arena per
/// validation is the expected use), within `limits`. `io` keys
/// `uniqueItems`' hashes from its random source, and is checked for
/// cancellation once per MiB of instance read. An invalid instance is
/// `false`; an error is a malformed instance, a limit, or memory.
pub fn validate(s: *const Schema, io: std.Io, scratch: std.mem.Allocator, comptime Format: type, instance: aegis.input.Untrusted([]const u8), output: Output) !bool {
    const bytes = instance.readForParse();
    var e: evaluate.Evaluator = .{ .program = &s.program, .scratch = scratch, .limits = s.limits, .hash_key = undefined, .collect = output == .basic, .io = io };
    io.random(&e.hash_key);
    const at = e.open(&.{.{ .node = s.program.root, .scope = null }}) catch |err| {
        aegis.assert.invariant(e.state == 0, "no state is charged before the instance is read");
        return err;
    };
    // Every slot and byte of state charged is given back, whatever ended
    // the validation: the recount.
    defer {
        e.close(at);
        aegis.assert.invariant(e.frames == 0 and e.state == 0, "a validation gives back every slot and byte of state it charged");
    }
    var options: Format.ParseOptions = .{};
    options.limits.depth = s.limits.depth;
    if (at.wantsEncoding(&s.program)) {
        // The root's own `const` or `enum`: the instance read whole once.
        const whole = try Format.parseLeaky(strand.json.Value, scratch, bytes, options);
        at.encoding = canonical.encodeAlloc(scratch, whole, s.limits.exponent) catch |err| return switch (err) {
            error.Invalid => error.TooLarge,
            else => |x| x,
        };
    }
    try Format.parseLeakySeeded(evaluate.Read{ .e = &e, .at = at }, scratch, bytes, options);
    const valid = at.outcome(0);
    const passed = try scratch.alloc(Downgrade, e.passed.count());
    for (e.passed.keys(), passed) |d, *out| out.* = s.program.downgrades[d];
    switch (output) {
        .flag => |report| if (report) |r| {
            r.* = .{ .downgraded = passed };
        },
        .basic => |errors| {
            errors.* = .{ .downgraded = passed };
            if (!valid and s.limits.errors > 0) {
                const indices = at.slots.items[at.roots.items[0]].errors.items;
                if (indices.len == 0) {
                    // Every record was made and dropped before the one that
                    // decided: an invalid instance still says it is.
                    const one = try scratch.alloc(Record, 1);
                    one[0] = .{ .instance_location = "", .keyword_location = "", .absolute_keyword_location = s.program.node(s.program.root).location, .message = "the instance is invalid; the errors that say why went past Limits.errors" };
                    errors.records = one;
                } else {
                    const records = try scratch.alloc(Record, @min(indices.len, s.limits.errors));
                    for (records, indices[0..records.len]) |*r, i| r.* = e.records.items[i];
                    errors.records = records;
                }
            }
        },
    }
    return valid;
}

pub fn deinit(s: *Schema) void {
    const gpa = s.arena.child_allocator;
    s.arena.deinit();
    gpa.destroy(s.arena);
    s.* = undefined;
}

const testing = std.testing;

test "a schema compiles from any format strand reads, and owns what it compiled" {
    var json = try compile(testing.allocator, testing.io, strand.json, .init("{\"type\": \"object\", \"properties\": {\"a\": {\"minimum\": 1}}}"), .{});
    defer json.deinit();
    var yaml = try compile(testing.allocator, testing.io, strand.yaml, .init(
        \\type: object
        \\properties:
        \\  a:
        \\    minimum: 1
    ), .{});
    defer yaml.deinit();
    try testing.expectEqual(json.program.nodes.len, yaml.program.nodes.len);
    try testing.expectEqual(json.program.instructions.len, yaml.program.instructions.len);
    try testing.expectError(error.Invalid, compile(testing.allocator, testing.io, strand.json, .init("{\"type\": "), .{}));
    try testing.expectError(error.TooLarge, compile(testing.allocator, testing.io, strand.json, .init("{\"type\": \"object\"}"), .{ .limits = .{ .schema_bytes = .fromRaw(8) } }));
    var d: Diagnostic = .{};
    try testing.expectError(error.ReferenceCycle, compile(testing.allocator, testing.io, strand.json, .init("{\"$ref\": \"#\"}"), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("urn:strand:schema#", d.location());
}

test "an instance streams through the schema: valid, invalid, and every branch at once" {
    var s = try compile(testing.allocator, testing.io, strand.json, .init(
        \\{"type": "object", "required": ["a"], "properties": {"a": {"type": "integer", "minimum": 1},
        \\ "b": {"anyOf": [{"type": "string", "maxLength": 3}, {"type": "null"}]}},
        \\ "additionalProperties": false, "enum": [{"a": 1}, {"a": 2, "b": null}, {"a": 2, "b": "xyz"}, {"a": 5, "c": 1}]}
    ), .{});
    defer s.deinit();
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const cases = [_]struct { []const u8, bool }{
        .{ "{\"a\": 1}", true },
        .{ "{\"a\": 1.0}", true },
        .{ "{\"a\": 2, \"b\": null}", true },
        .{ "{\"b\": \"xyz\", \"a\": 2}", true },
        .{ "{\"a\": 0}", false },
        .{ "{\"a\": 2, \"b\": \"wxyz\"}", false },
        .{ "{\"a\": 5, \"c\": 1}", false },
        .{ "{}", false },
        .{ "[]", false },
        .{ "{\"a\": 3}", false },
    };
    for (cases) |case| {
        const valid = try s.validate(testing.io, state.allocator(), strand.json, .init(case[0]), .{ .flag = null });
        testing.expectEqual(case[1], valid) catch |err| {
            std.debug.print("instance {s}\n", .{case[0]});
            return err;
        };
    }
}

test "a basic output says where an instance failed: the instance location, the keyword's, and its absolute location" {
    var s = try compile(testing.allocator, testing.io, strand.json, .init(
        \\{"$id": "http://example.com/s.json", "type": "object",
        \\ "properties": {"a": {"$ref": "#/$defs/positive"}, "b": {"anyOf": [{"type": "string"}, {"type": "null"}]}},
        \\ "required": ["c"], "$defs": {"positive": {"minimum": 1}}}
    ), .{});
    defer s.deinit();
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    var errors: Errors = .{};
    try testing.expect(!try s.validate(testing.io, state.allocator(), strand.json, .init("{\"a\": 0, \"b\": 5}"), .{ .basic = &errors }));
    const expected = [_][3][]const u8{
        .{ "", "/required", "http://example.com/s.json#/required" },
        .{ "/a", "/properties/a/$ref/minimum", "http://example.com/s.json#/$defs/positive/minimum" },
        .{ "/b", "/properties/b/anyOf", "http://example.com/s.json#/properties/b/anyOf" },
        .{ "/b", "/properties/b/anyOf/0/type", "http://example.com/s.json#/properties/b/anyOf/0/type" },
        .{ "/b", "/properties/b/anyOf/1/type", "http://example.com/s.json#/properties/b/anyOf/1/type" },
    };
    var found: usize = 0;
    for (expected) |want| for (errors.records) |r| {
        if (std.mem.eql(u8, r.instance_location, want[0]) and std.mem.eql(u8, r.keyword_location, want[1]) and std.mem.eql(u8, r.absolute_keyword_location, want[2])) found += 1;
    };
    testing.expectEqual(expected.len, found) catch |err| {
        for (errors.records) |r| std.debug.print("{s} | {s} | {s} | {s}\n", .{ r.instance_location, r.keyword_location, r.absolute_keyword_location, r.message });
        return err;
    };
    try testing.expectEqual(expected.len, errors.records.len);
    // A valid instance has none.
    try testing.expect(try s.validate(testing.io, state.allocator(), strand.json, .init("{\"a\": 2, \"c\": 1}"), .{ .basic = &errors }));
    try testing.expectEqual(0, errors.records.len);
}

test "per-container state is charged to Limits.state, and past it the validation stops" {
    var s = try compile(testing.allocator, testing.io, strand.json, .init("{\"uniqueItems\": true}"), .{ .limits = .{ .state = .fromRaw(64) } });
    defer s.deinit();
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    try testing.expect(try s.validate(testing.io, state.allocator(), strand.json, .init("[1, 2]"), .{ .flag = null }));
    try testing.expect(!try s.validate(testing.io, state.allocator(), strand.json, .init("[1, 1.0]"), .{ .flag = null }));
    try testing.expectError(error.TooLarge, s.validate(testing.io, state.allocator(), strand.json, .init("[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]"), .{ .flag = null }));
}

test "a pattern spectra cannot run in linear time: refused, or downgraded and reported by every validation through it" {
    var d: Diagnostic = .{};
    const text = "{\"properties\": {\"a\": {\"pattern\": \"(a)\\\\1\"}}}";
    try testing.expectError(error.UnsupportedPattern, compile(testing.allocator, testing.io, strand.json, .init(text), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("urn:strand:schema#/properties/a/pattern", d.location());
    var s = try compile(testing.allocator, testing.io, strand.json, .init(text), .{ .unsupported_pattern = .downgrade });
    defer s.deinit();
    try testing.expectEqual(1, s.downgrades().len);
    try testing.expectEqualStrings("urn:strand:schema#/properties/a/pattern", s.downgrades()[0].location);
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    var report: Report = .{};
    // Through the downgraded keyword: valid, and saying what it did not check.
    try testing.expect(try s.validate(testing.io, state.allocator(), strand.json, .init("{\"a\": \"xyz\"}"), .{ .flag = &report }));
    try testing.expectEqual(1, report.downgraded.len);
    // Not through it: nothing to say.
    try testing.expect(try s.validate(testing.io, state.allocator(), strand.json, .init("{\"b\": 1}"), .{ .flag = &report }));
    try testing.expectEqual(0, report.downgraded.len);
}

test "a validation checks for cancellation once per MiB, and a cancel stops it midway" {
    const shakedown = @import("shakedown");
    var s = try compile(testing.allocator, testing.io, strand.json, .init("{\"items\": {\"type\": \"string\"}}"), .{});
    defer s.deinit();
    // 6 MiB of strings, as the validation counts what it reads.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.append(testing.allocator, '[');
    for (0..6 * 1024) |i| {
        if (i > 0) try text.append(testing.allocator, ',');
        try text.append(testing.allocator, '"');
        try text.appendNTimes(testing.allocator, 'x', 1022);
        try text.append(testing.allocator, '"');
    }
    try text.append(testing.allocator, ']');
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .checkCancel, .n = 3 } }, .fault = .cancel },
    } });
    defer fio.deinit();
    try testing.expectError(error.Canceled, s.validate(fio.io(), state.allocator(), strand.json, .init(text.items), .{ .flag = null }));
    try testing.expectEqual(3, fio.count(.checkCancel));
    // Uncanceled, the whole instance is read and checked six times.
    fio.reset();
    try fio.setPlan(&.{});
    try testing.expect(try s.validate(fio.io(), state.allocator(), strand.json, .init(text.items), .{ .flag = null }));
    try testing.expectEqual(6, fio.count(.checkCancel));
}
