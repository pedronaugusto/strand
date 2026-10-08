//! Own legacy kernels, for explicit manual baseline observations only.
const std = @import("std");
const strand = @import("strand");
const shakedown = @import("shakedown");
const Event = struct { id: u64, label: []const u8, data: strand.Raw };
const prefix = "{\"id\":18446744073709551615,\"label\":\"";
const suffix = "\",\"data\":[1,true]}";
const input = prefix ++ @as([512 - prefix.len - suffix.len]u8, @splat('a')) ++ suffix;
comptime {
    std.debug.assert(input.len == 512);
}
const Context = struct { gpa: std.mem.Allocator, arena: std.heap.ArenaAllocator, value: Event, buffer: [1024]u8 = undefined };
fn parseBorrowed(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try strand.parseLine(Event, c.arena.allocator(), input, .{});
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn parseCopied(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try strand.parseLine(Event, c.arena.allocator(), input, .{ .copy_strings = true });
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn owned(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        const value = try strand.copyOwned(c.gpa, c.value);
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
        strand.freeOwned(c.gpa, value);
    }
    std.mem.doNotOptimizeAway(sum);
}
fn write(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        var w: std.Io.Writer = .fixed(&c.buffer);
        try strand.writeLine(&w, c.value);
        sum +%= w.buffered().len;
        std.mem.doNotOptimizeAway(w.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}
fn read(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        var source: std.Io.Reader = .fixed(input ++ "\n");
        var reader: strand.Reader(Event) = .init(c.gpa, &source, .{});
        defer reader.deinit();
        const record = (try reader.next()).?;
        sum +%= record.value.id +% record.value.label.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn route(_: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        const v = strand.leadingIntMembers(struct { id: u64 }, input).?;
        sum +%= v.value.id +% v.end;
        std.mem.doNotOptimizeAway(v);
    }
    std.mem.doNotOptimizeAway(sum);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var c: Context = .{ .gpa = std.heap.smp_allocator, .arena = .init(std.heap.smp_allocator), .value = undefined };
    defer c.arena.deinit();
    c.value = try strand.parseLine(Event, c.arena.allocator(), input, .{});
    const rows = [_]shakedown.bench.Row(Context){
        .{ .name = "legacy.parse.borrowed.512", .unit = "record", .initial = 1024, .run = parseBorrowed },
        .{ .name = "legacy.parse.copied.arena.512", .unit = "record", .initial = 1024, .run = parseCopied },
        .{ .name = "legacy.copyOwned.free.512", .unit = "record", .initial = 1024, .run = owned },
        .{ .name = "legacy.write.fixed.512", .unit = "record", .initial = 1024, .run = write },
        .{ .name = "legacy.reader.512", .unit = "record", .initial = 1024, .run = read },
        .{ .name = "legacy.routing.header.512", .unit = "record", .initial = 1024, .run = route },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try shakedown.bench.run(init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = "753bfaf82309b760138d1e7f7746c02cdbdcf072" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke") });
    try output.interface.flush();
}
