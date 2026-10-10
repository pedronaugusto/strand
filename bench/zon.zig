//! Explicit paired ZON observations against `std.zon`; compilation and smoke are
//! correctness gates, timing is a manual run. Both sides read the same documents
//! into the same types with the same arena discipline.
const std = @import("std");
const strand = @import("strand");
const zon = strand.zon;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Mode = enum { fast, slow, auto };
const Entry = struct {
    id: u32,
    name: []const u8,
    weight: f64,
    flags: [3]bool,
    mode: Mode,
    note: ?[]const u8 = null,
    tags: []const []const u8,
};
const Config = struct { title: []const u8, entries: []const Entry };
const Text = struct { text: []const u8 };
const text_source: [:0]const u8 = ".{ .text = \"" ++ @as([8192]u8, @splat('a')) ++ "\" }";

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || error{ OutOfMemory, ParseZon, PolicyMismatch };
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Holds `value`, which the rows that reset `arena` must not disturb.
    fixture: std.heap.ArenaAllocator,
    small: [:0]u8,
    large: [:0]u8,
    value: Config,
    buffer: []u8,
};

fn document(gpa: std.mem.Allocator, entries: usize, whitespace: bool) ![:0]u8 {
    const names = [_][]const u8{ "alpha", "beta \"quoted\"", "gamma\twith tab", "delta", "epsilon caf\u{e9}" };
    const tags = [_][]const u8{ "red", "green", "blue" };
    const list = try gpa.alloc(Entry, entries);
    defer gpa.free(list);
    for (list, 0..) |*entry, i| entry.* = .{
        .id = @intCast(i * 7919 % 100_000), // safe: reduced below 100,000.
        .name = names[i % names.len],
        .weight = @as(f64, @floatFromInt(i)) * 0.37,
        .flags = .{ i % 2 == 0, i % 3 == 0, i % 5 == 0 },
        .mode = @fromBackingInt(@intCast(i % 3)),
        .note = if (i % 4 == 0) "a note" else null,
        .tags = tags[0 .. 1 + i % 3],
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try zon.write(&out.writer, Config{ .title = "benchmark document", .entries = list }, .{ .whitespace = whitespace });
    return out.toOwnedSliceSentinel(0);
}

fn parseRow(comptime strict: bool, source: [:0]const u8, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = if (strict) try zon.parseLeaky(Config, c.arena.allocator(), source, .{}) else blk: {
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            break :blk try std.zon.parse.fromSlice(Config, .{ .gpa = c.gpa, .arena = c.arena.allocator(), .source = source, .diagnostics = &diagnostics });
        };
        sum +%= value.entries.len +% value.title.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn strictSmall(c: *Context, units: u64) WorkError!void {
    return parseRow(true, c.small, c, units);
}
fn stdSmall(c: *Context, units: u64) WorkError!void {
    return parseRow(false, c.small, c, units);
}
fn strictLarge(c: *Context, units: u64) WorkError!void {
    return parseRow(true, c.large, c, units);
}
fn stdLarge(c: *Context, units: u64) WorkError!void {
    return parseRow(false, c.large, c, units);
}
fn strictOwned(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var result = try zon.parseOwned(Config, c.gpa, c.small, .{});
        sum +%= result.value.entries.len;
        result.deinit();
    }
    std.mem.doNotOptimizeAway(sum);
}
fn stdOwned(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const value = try std.zon.parse.fromSlice(Config, .{ .gpa = c.gpa, .arena = arena.allocator(), .source = c.small, .diagnostics = &diagnostics });
        sum +%= value.entries.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn textRow(comptime strict: bool, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = if (strict) try zon.parseLeaky(Text, c.arena.allocator(), text_source, .{}) else blk: {
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            break :blk try std.zon.parse.fromSlice(Text, .{ .gpa = c.gpa, .arena = c.arena.allocator(), .source = text_source, .diagnostics = &diagnostics });
        };
        sum +%= value.text.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn strictText(c: *Context, units: u64) WorkError!void {
    return textRow(true, c, units);
}
fn stdText(c: *Context, units: u64) WorkError!void {
    return textRow(false, c, units);
}
fn writeRow(comptime strict: bool, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(c.buffer);
        if (strict) try zon.write(&writer, c.value, .{}) else try std.zon.stringify.serialize(c.value, .{}, &writer);
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}
fn strictWrite(c: *Context, units: u64) WorkError!void {
    return writeRow(true, c, units);
}
fn stdWrite(c: *Context, units: u64) WorkError!void {
    return writeRow(false, c, units);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var c: Context = .{ .gpa = init.gpa, .arena = .init(init.gpa), .fixture = .init(init.gpa), .small = undefined, .large = undefined, .value = undefined, .buffer = undefined };
    defer c.arena.deinit();
    defer c.fixture.deinit();
    c.small = try document(c.gpa, if (smoke) 2 else 12, true);
    defer c.gpa.free(c.small);
    c.large = try document(c.gpa, if (smoke) 4 else 1100, true);
    defer c.gpa.free(c.large);
    c.buffer = try c.gpa.alloc(u8, c.large.len * 2);
    defer c.gpa.free(c.buffer);
    c.value = try zon.parseLeaky(Config, c.fixture.allocator(), c.large, .{});
    // Both sides must read the same value, and write the same bytes.
    var reference: std.heap.ArenaAllocator = .init(c.gpa);
    defer reference.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const expected = try std.zon.parse.fromSlice(Config, .{ .gpa = c.gpa, .arena = reference.allocator(), .source = c.large, .diagnostics = &diagnostics });
    if (!std.meta.eql(c.value.entries.len, expected.entries.len)) return error.PolicyMismatch;
    for (c.value.entries, expected.entries) |mine, theirs| {
        if (mine.id != theirs.id or !std.mem.eql(u8, mine.name, theirs.name) or mine.mode != theirs.mode or mine.weight != theirs.weight) return error.PolicyMismatch;
    }
    var mine_out = std.Io.Writer.fixed(c.buffer);
    try zon.write(&mine_out, c.value, .{});
    if (!std.mem.eql(u8, mine_out.buffered(), c.large)) return error.PolicyMismatch;
    // A plain string is a span of the input: nothing is allocated for it.
    var borrowed = try zon.parse(Text, c.gpa, text_source, .{});
    defer borrowed.deinit();
    if (borrowed.requested_peak != 0 or borrowed.value.text.ptr != text_source[".{ .text = \"".len..].ptr) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "zon.strict.4k", .unit = "document", .initial = 64, .run = strictSmall },
        .{ .name = "zon.std.4k", .unit = "document", .initial = 64, .run = stdSmall },
        .{ .name = "zon.strict.owned.4k", .unit = "document", .initial = 64, .run = strictOwned },
        .{ .name = "zon.std.owned.4k", .unit = "document", .initial = 64, .run = stdOwned },
        .{ .name = "zon.strict.256k", .unit = "document", .initial = 1, .run = strictLarge },
        .{ .name = "zon.std.256k", .unit = "document", .initial = 1, .run = stdLarge },
        .{ .name = "zon.strict.text.8192", .unit = "document", .initial = 256, .run = strictText },
        .{ .name = "zon.std.text.8192", .unit = "document", .initial = 256, .run = stdText },
        .{ .name = "zon.write.strict.256k", .unit = "document", .initial = 1, .run = strictWrite },
        .{ .name = "zon.write.std.256k", .unit = "document", .initial = 1, .run = stdWrite },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
