//! A schema compiled once, to validate any number of instances. It owns the
//! documents it was compiled from and its program, in one arena.
const Schema = @This();
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const compiler = @import("compile.zig");
const Program = @import("Program.zig");

pub const Options = compiler.Options;
pub const Diagnostic = compiler.Diagnostic;
pub const CompileError = compiler.Error;

arena: *std.heap.ArenaAllocator,
program: Program,

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
    return .{ .arena = arena, .program = try compiler.compile(a, io, root, options) };
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
