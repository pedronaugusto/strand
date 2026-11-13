//! strand_schema's observations: a 4 KiB structured result validated
//! against the schema strand generates for its type (an MCP client checking
//! a tool's `structuredContent`), the same result as YAML, and an array of
//! records with and without `uniqueItems`, the per-item state it adds. The
//! schema is compiled once; each row validates on a reset arena.
//! Compilation and smoke are correctness gates; timing is a manual run.
//! Rivals are compared in private trials.
const std = @import("std");
const strand = @import("strand");
const schema = @import("strand_schema");
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Item = struct { id: u32, name: []const u8, price: f64, tags: []const []const u8, stock: ?u16 = null };
const Result = struct { query: []const u8, total: u32, items: []const Item };

const WorkError = error{ OutOfMemory, Invalid } || anyerror;
const Context = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    result: schema.Schema,
    records: schema.Schema,
    unique: schema.Schema,
    json: []const u8,
    yaml: []const u8,
    array: []const u8,
};

fn document(gpa: std.mem.Allocator, items: usize) !Result {
    const list = try gpa.alloc(Item, items);
    const tags = [_][]const u8{ "new", "sale", "kept" };
    for (list, 0..) |*item, i| item.* = .{
        .id = @intCast(i),
        .name = "an item with a name of some length",
        .price = @as(f64, @floatFromInt(i)) * 1.25,
        .tags = tags[0 .. 1 + i % 3],
        .stock = if (i % 2 == 0) @intCast(i) else null,
    };
    return .{ .query = "everything", .total = @intCast(items), .items = list };
}

fn validateRow(c: *Context, s: *const schema.Schema, comptime Format: type, text: []const u8, units: u64) WorkError!void {
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        if (!try s.validate(c.io, c.arena.allocator(), Format, .init(text), .{ .flag = null })) return error.Invalid;
    }
}
fn resultJson(c: *Context, units: u64) WorkError!void {
    return validateRow(c, &c.result, strand.json, c.json, units);
}
fn resultYaml(c: *Context, units: u64) WorkError!void {
    return validateRow(c, &c.result, strand.yaml, c.yaml, units);
}
fn arrayPlain(c: *Context, units: u64) WorkError!void {
    return validateRow(c, &c.records, strand.json, c.array, units);
}
fn arrayUnique(c: *Context, units: u64) WorkError!void {
    return validateRow(c, &c.unique, strand.json, c.array, units);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const gpa = init.gpa;
    var fixture: std.heap.ArenaAllocator = .init(gpa);
    defer fixture.deinit();
    const f = fixture.allocator();
    const value = try document(f, if (smoke) 2 else 24);
    var json_out: std.Io.Writer.Allocating = .init(f);
    try strand.json.write(&json_out.writer, value, .{});
    var yaml_out: std.Io.Writer.Allocating = .init(f);
    try strand.yaml.write(&yaml_out.writer, value, .{ .nulls = .omit });
    const many = try document(f, if (smoke) 4 else 20_000);
    var array_out: std.Io.Writer.Allocating = .init(f);
    try strand.json.write(&array_out.writer, many.items, .{});
    const item_schema = comptime strand.json.schema.of(Item, .{ .dialect = false });
    var c: Context = .{
        .io = init.io,
        .arena = .init(gpa),
        .result = try .compile(gpa, init.io, strand.json, .init(comptime strand.json.schema.of(Result, .{ .direction = .encode })), .{}),
        .records = try .compile(gpa, init.io, strand.json, .init("{\"type\": \"array\", \"items\": " ++ item_schema ++ "}"), .{}),
        .unique = try .compile(gpa, init.io, strand.json, .init("{\"type\": \"array\", \"uniqueItems\": true, \"items\": " ++ item_schema ++ "}"), .{}),
        .json = json_out.written(),
        .yaml = yaml_out.written(),
        .array = array_out.written(),
    };
    defer c.arena.deinit();
    defer c.result.deinit();
    defer c.records.deinit();
    defer c.unique.deinit();
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "schema.validate.structured-content.json", .unit = "document", .initial = 64, .run = resultJson },
        .{ .name = "schema.validate.structured-content.yaml", .unit = "document", .initial = 64, .run = resultYaml },
        .{ .name = "schema.validate.records", .unit = "document", .initial = 1, .run = arrayPlain },
        .{ .name = "schema.validate.records.unique", .unit = "document", .initial = 1, .run = arrayUnique },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
