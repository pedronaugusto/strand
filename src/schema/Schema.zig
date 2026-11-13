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
/// validation is the expected use), within `limits`. An invalid instance is
/// `false`; an error is a malformed instance, a limit, or memory.
pub fn validate(s: *const Schema, scratch: std.mem.Allocator, comptime Format: type, instance: aegis.input.Untrusted([]const u8)) !bool {
    const bytes = instance.readForParse();
    var e: evaluate.Evaluator = .{ .program = &s.program, .scratch = scratch, .limits = s.limits };
    const at = try e.open(&.{s.program.root});
    defer e.close(at);
    var options: Format.ParseOptions = .{ .codec_state = &e };
    options.limits.depth = s.limits.depth;
    if (at.wantsEncoding(&s.program)) {
        // The root's own `const` or `enum`: the instance read whole once.
        const whole = try Format.parseLeaky(strand.json.Value, scratch, bytes, options);
        at.encoding = canonical.encodeAlloc(scratch, whole, s.limits.exponent) catch |err| return switch (err) {
            error.Invalid => error.TooLarge,
            else => |x| x,
        };
    }
    e.next = at;
    _ = try Format.parseLeaky(evaluate.Instance, scratch, bytes, options);
    return at.outcome(0);
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
        const valid = try s.validate(state.allocator(), strand.json, .init(case[0]));
        testing.expectEqual(case[1], valid) catch |err| {
            std.debug.print("instance {s}\n", .{case[0]});
            return err;
        };
    }
}
