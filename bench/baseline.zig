//! Own legacy kernels, for explicit manual baseline observations only.
const std = @import("std");
const strand = @import("strand");
const previous = @import("previous-main");
const shakedown = @import("shakedown");
const paired = @import("paired.zig");
const Scratch = @import("bench_scratch.zig").Scratch;
const Event = struct { id: u64, label: []const u8, data: strand.Raw };
const prefix = "{\"id\":18446744073709551615,\"label\":\"";
const suffix = "\",\"data\":[1,true]}";
const input = prefix ++ @as([512 - prefix.len - suffix.len]u8, @splat('a')) ++ suffix;
comptime {
    std.debug.assert(input.len == 512);
}
const Context = struct { io: std.Io, file: std.Io.File, gpa: std.mem.Allocator, arena: std.heap.ArenaAllocator, value: Event, buffer: [1024]u8 = undefined };
fn parseBorrowed(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try strand.parseLine(Event, c.arena.allocator(), input, .{});
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
// Isolate the paired Raw specialization from the legacy workload below.
// Both revisions get the same factory, options and number of parse call sites;
// extra current-only callers otherwise prevent inlining on just one side.
fn PairedEvent(comptime Raw: type) type {
    return struct { id: u64, label: []const u8, data: Raw };
}
fn pairedCurrent(c: *Context, units: u64) !void {
    try pairedParse(strand, PairedEvent(strand.Raw), c, units);
}
fn pairedPrevious(c: *Context, units: u64) !void {
    try pairedParse(previous, PairedEvent(previous.Raw), c, units);
}
fn pairedParse(comptime Api: type, comptime T: type, c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try Api.parseLine(T, c.arena.allocator(), input, .{});
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn parseStd(c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try std.json.parseFromSliceLeaky(PairedEvent(strand.Raw), c.arena.allocator(), input, .{});
        sum +%= value.id +% value.label.len +% value.data.bytes.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
// This control uses one nominal schema in both own-main modules. Raw remains
// separately measured above because its marker type belongs to each module.
const SharedEvent = struct { id: u64, label: []const u8, data: [2]u8 };
const shared_suffix = "\",\"data\":[1,2]}";
const shared_input = prefix ++ @as([512 - prefix.len - shared_suffix.len]u8, @splat('a')) ++ shared_suffix;
fn sharedCurrent(c: *Context, units: u64) !void {
    try sharedParse(.current, c, units);
}
fn sharedPrevious(c: *Context, units: u64) !void {
    try sharedParse(.previous, c, units);
}
fn sharedStd(c: *Context, units: u64) !void {
    try sharedParse(.stdlib, c, units);
}
fn sharedParse(comptime which: enum { current, previous, stdlib }, c: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = switch (which) {
            .current => try strand.parseLine(SharedEvent, c.arena.allocator(), shared_input, .{}),
            .previous => try previous.parseLine(SharedEvent, c.arena.allocator(), shared_input, .{}),
            .stdlib => try std.json.parseFromSliceLeaky(SharedEvent, c.arena.allocator(), shared_input, .{}),
        };
        sum +%= value.id +% value.label.len +% value.data[0] +% value.data[1];
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

fn sharedWrite(comptime Api: type, c: *Context, units: u64) !void {
    const value: SharedEvent = .{ .id = std.math.maxInt(u64), .label = shared_input[prefix.len .. shared_input.len - shared_suffix.len], .data = .{ 1, 2 } };
    var sum: usize = 0;
    for (0..units) |_| {
        var output = std.Io.Writer.fixed(&c.buffer);
        try Api.writeLine(&output, value);
        sum +%= output.buffered().len;
        std.mem.doNotOptimizeAway(output.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}
fn writeCurrent(c: *Context, units: u64) !void {
    return sharedWrite(strand, c, units);
}
fn writePrevious(c: *Context, units: u64) !void {
    return sharedWrite(previous, c, units);
}
fn sharedRead(comptime Api: type, c: *Context, units: u64) !void {
    var sum: usize = 0;
    for (0..units) |_| {
        var source = std.Io.Reader.fixed(shared_input ++ "\n");
        var reader = Api.Reader(SharedEvent).init(c.gpa, &source, .{});
        defer reader.deinit();
        sum +%= (try reader.next()).?.value.label.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn readerCurrent(c: *Context, units: u64) !void {
    return sharedRead(strand, c, units);
}
fn readerPrevious(c: *Context, units: u64) !void {
    return sharedRead(previous, c, units);
}
fn routing(comptime Api: type, _: *Context, units: u64) !void {
    var sum: u64 = 0;
    for (0..units) |_| {
        const v = Api.leadingIntMembers(struct { id: u64 }, input).?;
        sum +%= v.value.id +% v.end;
        std.mem.doNotOptimizeAway(v);
    }
    std.mem.doNotOptimizeAway(sum);
}
fn routeCurrent(c: *Context, units: u64) !void {
    return routing(strand, c, units);
}
fn routePrevious(c: *Context, units: u64) !void {
    return routing(previous, c, units);
}
fn tailRows(comptime Api: type, c: *Context, units: u64) !void {
    var sum: usize = 0;
    var buffer: [65536]u8 = undefined;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        var source = c.file.reader(c.io, &buffer);
        var tail = try Api.Tail(SharedEvent).init(c.gpa, &source, .{});
        defer tail.deinit();
        const last = try tail.last(c.arena.allocator(), 1000);
        if (last.len != 1000) return error.SemanticMismatch;
        sum +%= last[0].label.len;
        std.mem.doNotOptimizeAway(last);
    }
    std.mem.doNotOptimizeAway(sum);
}
fn tailCurrent(c: *Context, units: u64) !void {
    return tailRows(strand, c, units);
}
fn tailPrevious(c: *Context, units: u64) !void {
    return tailRows(previous, c, units);
}
fn followRows(comptime Api: type, c: *Context, units: u64) !void {
    var sum: usize = 0;
    var buffer: [65536]u8 = undefined;
    for (0..units) |_| {
        var source = c.file.reader(c.io, &buffer);
        try source.seekTo(0);
        var follower = Api.Follower(SharedEvent).init(c.gpa, &source, .{});
        defer follower.deinit(c.io);
        for (0..1000) |_| sum +%= (try follower.next(c.io)).value.label.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn followCurrent(c: *Context, units: u64) !void {
    return followRows(strand, c, units);
}
fn followPrevious(c: *Context, units: u64) !void {
    return followRows(previous, c, units);
}
fn prepare(io: std.Io, smoke: bool) !Scratch {
    var scratch = try Scratch.init(io, "");
    errdefer scratch.deinit(io);
    const file = try scratch.scratch.dir.createFile(io, "log.jsonl", .{});
    defer file.close(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const count: usize = if (smoke) 1000 else (1 << 30) / (shared_input.len + 1);
    for (0..count) |_| try writer.interface.writeAll(shared_input ++ "\n");
    try writer.interface.flush();
    return scratch;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var scratch = try prepare(init.io, smoke);
    defer scratch.deinit(init.io);
    var c: Context = .{ .io = init.io, .file = scratch.file, .gpa = std.heap.smp_allocator, .arena = .init(std.heap.smp_allocator), .value = undefined };
    defer c.arena.deinit();
    const current_value = try strand.parseLine(PairedEvent(strand.Raw), c.arena.allocator(), input, .{});
    const previous_value = try previous.parseLine(PairedEvent(previous.Raw), c.arena.allocator(), input, .{});
    if (current_value.id != previous_value.id or
        !std.mem.eql(u8, current_value.label, previous_value.label) or
        !std.mem.eql(u8, current_value.data.bytes, previous_value.data.bytes)) return error.SemanticMismatch;
    c.value = try strand.parseLine(Event, c.arena.allocator(), input, .{});
    const WorkError = strand.ParseLineError || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error || std.Io.Writer.Error || strand.Reader(Event).NextError || strand.Tail(SharedEvent).InitError || strand.Tail(SharedEvent).NextError || strand.Follower(SharedEvent).NextError || std.Io.File.Reader.SeekError || error{SemanticMismatch};
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "paired.current.a", .unit = "record", .initial = 1024, .run = pairedCurrent },
        .{ .name = "paired.previous.a", .unit = "record", .initial = 1024, .run = pairedPrevious },
        .{ .name = "paired.std.a", .unit = "record", .initial = 1024, .run = parseStd },
        .{ .name = "paired.std.b", .unit = "record", .initial = 1024, .run = parseStd },
        .{ .name = "paired.previous.b", .unit = "record", .initial = 1024, .run = pairedPrevious },
        .{ .name = "paired.current.b", .unit = "record", .initial = 1024, .run = pairedCurrent },
        .{ .name = "shared.current.a", .unit = "record", .initial = 1024, .run = sharedCurrent },
        .{ .name = "shared.previous.a", .unit = "record", .initial = 1024, .run = sharedPrevious },
        .{ .name = "shared.std.a", .unit = "record", .initial = 1024, .run = sharedStd },
        .{ .name = "shared.std.b", .unit = "record", .initial = 1024, .run = sharedStd },
        .{ .name = "shared.previous.b", .unit = "record", .initial = 1024, .run = sharedPrevious },
        .{ .name = "shared.current.b", .unit = "record", .initial = 1024, .run = sharedCurrent },
        .{ .name = "legacy.parse.borrowed.512", .unit = "record", .initial = 1024, .run = parseBorrowed },
        .{ .name = "legacy.parse.copied.arena.512", .unit = "record", .initial = 1024, .run = parseCopied },
        .{ .name = "legacy.copyOwned.free.512", .unit = "record", .initial = 1024, .run = owned },
        .{ .name = "legacy.write.fixed.512", .unit = "record", .initial = 1024, .run = write },
        .{ .name = "legacy.reader.512", .unit = "record", .initial = 1024, .run = read },
        .{ .name = "legacy.routing.header.512", .unit = "record", .initial = 1024, .run = route },
        .{ .name = "shared.write.current", .unit = "record", .initial = 1024, .run = writeCurrent },
        .{ .name = "shared.write.previous", .unit = "record", .initial = 1024, .run = writePrevious },
        .{ .name = "shared.reader.current", .unit = "record", .initial = 1024, .run = readerCurrent },
        .{ .name = "shared.reader.previous", .unit = "record", .initial = 1024, .run = readerPrevious },
        .{ .name = "shared.routing.current", .unit = "record", .initial = 1024, .run = routeCurrent },
        .{ .name = "shared.routing.previous", .unit = "record", .initial = 1024, .run = routePrevious },
        .{ .name = "shared.tail.current", .unit = "1000_records", .initial = 1, .run = tailCurrent },
        .{ .name = "shared.tail.previous", .unit = "1000_records", .initial = 1, .run = tailPrevious },
        .{ .name = "shared.follow.current", .unit = "1000_records", .initial = 1, .run = followCurrent },
        .{ .name = "shared.follow.previous", .unit = "1000_records", .initial = 1, .run = followPrevious },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
