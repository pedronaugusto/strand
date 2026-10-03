const std = @import("std");
const common = @import("zig_common.zig");
const Record = common.Record;
const smoke = @import("bench_options").smoke;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    var obuf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(init.io, &obuf);
    if (std.mem.eql(u8, args[1], "read")) try read(init, args[2], &ow.interface) else if (std.mem.eql(u8, args[1], "write")) try write(init, args[2], &ow.interface, false) else if (std.mem.eql(u8, args[1], "write-flush")) try write(init, args[2], &ow.interface, true) else if (!try @import("zig_stdcover.zig").run(init, args[1], args[2..], &ow.interface)) return error.Usage;
    try ow.interface.flush();
}

fn read(init: std.process.Init, path: []const u8, out: *std.Io.Writer) !void {
    const stat_file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
    defer stat_file.close(init.io);
    const size = (try stat_file.stat(init.io)).size;
    var lines: u64 = 0;
    var checksum: u64 = 0;
    const started = benchmarkNow(init.io);
    for (0..(if (smoke) @as(usize, 1) else 2)) |_| {
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
        defer file.close(init.io);
        const buf = try init.gpa.alloc(u8, 1 << 20);
        defer init.gpa.free(buf);
        var fr = file.reader(init.io, buf);
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        while (fr.interface.takeDelimiterInclusive('\n')) |framed| {
            _ = arena.reset(.retain_capacity);
            const v = try std.json.parseFromSliceLeaky(Record, arena.allocator(), framed[0 .. framed.len - 1], .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed });
            checksum +%= v.count;
            lines += 1;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }
    const elapsed = common.ns(init.io, started);
    std.mem.doNotOptimizeAway(checksum);
    try common.report(out, "zig-std-json", "typed-read", "lines", @as(f64, @floatFromInt(lines)) * 1e9 / @as(f64, @floatFromInt(elapsed)), "lines/s");
    try common.report(out, "zig-std-json", "typed-read", "bytes", @as(f64, @floatFromInt(size * (if (smoke) @as(u64, 1) else 2))) * 1e3 / @as(f64, @floatFromInt(elapsed)), "MB/s");
}

fn write(init: std.process.Init, path: []const u8, out: *std.Io.Writer, per_record: bool) !void {
    const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
    defer file.close(init.io);
    const buf = try init.gpa.alloc(u8, 1 << 20);
    defer init.gpa.free(buf);
    var fw = file.writer(init.io, buf);
    const started = benchmarkNow(init.io);
    for (0..(if (smoke) @as(usize, 1) else 1_000_000)) |i| {
        try std.json.Stringify.value(common.sample(i), .{}, &fw.interface);
        try fw.interface.writeByte('\n');
        if (per_record) try fw.interface.flush();
    }
    try fw.interface.flush();
    const elapsed = common.ns(init.io, started);
    const size = (try file.stat(init.io)).size;
    try common.report(out, "zig-std-json", if (per_record) "typed-write-flush" else "typed-write", "bytes", @as(f64, @floatFromInt(size)) * 1e3 / @as(f64, @floatFromInt(elapsed)), "MB/s");
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
