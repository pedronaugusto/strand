//! TOML observations of strand's own: a typed 4 KiB and 256 KiB document read
//! on a reset arena, the 4 KiB one into an owner of its own, the 256 KiB one as
//! `toml.Value`, and written. Compilation and smoke are correctness gates;
//! timing is a manual run. Rivals (Rust's toml, go-toml) are compared in
//! private trials.
const std = @import("std");
const strand = @import("strand");
const toml = strand.toml;
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
    seen: toml.OffsetDateTime,
};
const Config = struct { title: []const u8, entries: []const Entry };

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || error{ OutOfMemory, PolicyMismatch };
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Holds `value`, which the rows that reset `arena` must not disturb.
    fixture: std.heap.ArenaAllocator,
    small: []u8,
    large: []u8,
    value: Config,
    buffer: []u8,
};

fn document(gpa: std.mem.Allocator, entries: usize) ![]u8 {
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
        .seen = .{ .date = .{ .year = 2026, .month = 10, .day = @intCast(1 + i % 28) }, .time = .{ .hour = @intCast(i % 24), .minute = 30, .nanosecond = 500_000_000 }, .offset_minutes = 60 }, // safe: reduced below 29 and 24.
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try toml.write(&out.writer, Config{ .title = "benchmark document", .entries = list }, .{ .allocator = gpa, .nulls = .omit });
    return out.toOwnedSlice();
}

fn typedRow(source: []const u8, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try toml.parseLeaky(Config, c.arena.allocator(), source, .{});
        sum +%= value.entries.len +% value.title.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn typedSmall(c: *Context, units: u64) WorkError!void {
    return typedRow(c.small, c, units);
}
fn typedLarge(c: *Context, units: u64) WorkError!void {
    return typedRow(c.large, c, units);
}
fn ownedSmall(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var result = try toml.parseOwned(Config, c.gpa, c.small, .{});
        sum +%= result.value.entries.len;
        result.deinit();
    }
    std.mem.doNotOptimizeAway(sum);
}
fn valueLarge(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try toml.parseLeaky(toml.Value, c.arena.allocator(), c.large, .{});
        sum +%= value.table.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn writeLarge(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        var writer = std.Io.Writer.fixed(c.buffer);
        try toml.write(&writer, c.value, .{ .allocator = c.arena.allocator(), .nulls = .omit });
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var c: Context = .{ .gpa = init.gpa, .arena = .init(init.gpa), .fixture = .init(init.gpa), .small = undefined, .large = undefined, .value = undefined, .buffer = undefined };
    defer c.arena.deinit();
    defer c.fixture.deinit();
    c.small = try document(c.gpa, if (smoke) 2 else 24);
    defer c.gpa.free(c.small);
    c.large = try document(c.gpa, if (smoke) 4 else 1540);
    defer c.gpa.free(c.large);
    c.buffer = try c.gpa.alloc(u8, c.large.len * 2);
    defer c.gpa.free(c.buffer);
    c.value = try toml.parseLeaky(Config, c.fixture.allocator(), c.large, .{});
    // What is read is written back as the same document.
    var again = std.Io.Writer.fixed(c.buffer);
    try toml.write(&again, c.value, .{ .allocator = c.fixture.allocator(), .nulls = .omit });
    if (!std.mem.eql(u8, again.buffered(), c.large)) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "toml.typed.4k", .unit = "document", .initial = 64, .run = typedSmall },
        .{ .name = "toml.owned.4k", .unit = "document", .initial = 64, .run = ownedSmall },
        .{ .name = "toml.typed.256k", .unit = "document", .initial = 1, .run = typedLarge },
        .{ .name = "toml.value.256k", .unit = "document", .initial = 1, .run = valueLarge },
        .{ .name = "toml.write.256k", .unit = "document", .initial = 1, .run = writeLarge },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
