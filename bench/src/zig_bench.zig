const std = @import("std");
const strand = @import("strand");
const common = @import("zig_common.zig");
const Record = common.Record;
const smoke = @import("bench_options").smoke;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    var obuf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(init.io, &obuf);
    const out = &ow.interface;
    if (std.mem.eql(u8, args[1], "read")) try read(init, args[2], out, false) else if (std.mem.eql(u8, args[1], "raw")) try read(init, args[2], out, true) else if (std.mem.eql(u8, args[1], "write")) try write(init, args[2], out, false) else if (std.mem.eql(u8, args[1], "write-flush")) try write(init, args[2], out, true) else if (std.mem.eql(u8, args[1], "tail")) try tail(init, args[2], out) else return error.Usage;
    try out.flush();
}

fn read(init: std.process.Init, path: []const u8, out: *std.Io.Writer, raw: bool) !void {
    const stat_file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
    defer stat_file.close(init.io);
    const size = (try stat_file.stat(init.io)).size;
    var checksum: u64 = 0;
    var lines: u64 = 0;
    const reps: usize = if (smoke) 1 else if (raw) 12 else 2;
    const started = std.Io.Clock.awake.now(init.io);
    for (0..reps) |_| {
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
        defer file.close(init.io);
        const buf = try init.gpa.alloc(u8, 1 << 20);
        defer init.gpa.free(buf);
        var fr = file.reader(init.io, buf);
        var r: strand.Reader(Record) = .init(init.gpa, &fr.interface, .{ .max_line_bytes = 2 << 20 });
        defer r.deinit();
        if (raw) {
            while (try r.nextRaw()) |line| {
                checksum +%= line.line.len;
                lines += 1;
            }
        } else {
            while (try r.next()) |line| {
                checksum +%= line.value.count;
                lines += 1;
            }
        }
    }
    const elapsed = common.ns(init.io, started);
    std.mem.doNotOptimizeAway(checksum);
    const workload = if (raw) "raw-frame" else "typed-read";
    if (!raw) try common.report(out, "strand", workload, "lines", @as(f64, @floatFromInt(lines)) * 1e9 / @as(f64, @floatFromInt(elapsed)), "lines/s");
    try common.report(out, "strand", workload, "bytes", @as(f64, @floatFromInt(size * reps)) * 1e3 / @as(f64, @floatFromInt(elapsed)), "MB/s");
}

fn write(init: std.process.Init, path: []const u8, out: *std.Io.Writer, per_record: bool) !void {
    const file = try std.Io.Dir.createFileAbsolute(init.io, path, .{});
    defer file.close(init.io);
    const buf = try init.gpa.alloc(u8, 1 << 20);
    defer init.gpa.free(buf);
    var fw = file.writer(init.io, buf);
    var w: strand.Writer(Record) = .initFile(&fw, .{ .flush = if (per_record) .per_record else .never });
    const started = std.Io.Clock.awake.now(init.io);
    for (0..(if (smoke) @as(usize, 1) else 1_000_000)) |i| try w.write(common.sample(i));
    try fw.interface.flush();
    const elapsed = common.ns(init.io, started);
    const size = (try file.stat(init.io)).size;
    try common.report(out, "strand", if (per_record) "typed-write-flush" else "typed-write", "bytes", @as(f64, @floatFromInt(size)) * 1e3 / @as(f64, @floatFromInt(elapsed)), "MB/s");
}

fn tail(init: std.process.Init, path: []const u8, out: *std.Io.Writer) !void {
    const reps: usize = if (smoke) 1 else 500;
    const started = std.Io.Clock.awake.now(init.io);
    for (0..reps) |_| {
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
        defer file.close(init.io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(init.io, &buf);
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        var t: strand.Tail(Record) = try .init(init.gpa, &fr, .{ .max_line_bytes = 2 << 20 });
        defer t.deinit();
        const values = try t.last(arena.allocator(), if (smoke) 1 else 1000);
        std.mem.doNotOptimizeAway(values.len);
    }
    const elapsed = common.ns(init.io, started);
    try common.report(out, "strand", "tail-1000", "latency", @as(f64, @floatFromInt(elapsed)) / (1e6 * @as(f64, @floatFromInt(reps))), "ms");
}
