//! Manual observations: calibrate first, then interleave rows in every round.
const std = @import("std");
const shakedown = @import("shakedown");

pub fn run(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, context: anytype, rows: anytype, metadata: shakedown.bench.Metadata, options: shakedown.bench.Options) shakedown.bench.RunError!void {
    if (options.smoke) return shakedown.bench.run(gpa, io, writer, context, rows, metadata, options);
    if (options.samples == 0 or options.minimum.nanoseconds <= 0) return error.InvalidOptions;
    const resolution = (try std.Io.Clock.awake.resolution(io)).nanoseconds;
    if (resolution <= 0 or resolution > std.math.maxInt(u64)) return error.ClockUnavailable;
    const length = std.math.mul(usize, rows.len, options.samples) catch return error.InvalidOptions;
    const samples = try gpa.alloc(f64, length);
    defer gpa.free(samples);
    const batches = try gpa.alloc(u64, rows.len);
    defer gpa.free(batches);
    // A calibration margin allows every later sample to be retained honestly.
    const target = @max(options.minimum.nanoseconds + @divTrunc(options.minimum.nanoseconds, 2), resolution * options.resolution_multiple);
    for (rows, 0..) |row, index| {
        batches[index] = row.initial;
        for (0..options.warmup) |_| try row.run(context, row.initial);
        while (try elapsed(io, context, row.run, batches[index]) < target) {
            if (batches[index] >= options.max_batch) return error.Unmeasurable;
            batches[index] += @min(batches[index], options.max_batch - batches[index]);
        }
    }
    for (0..options.samples) |round| {
        for (0..rows.len) |slot| {
            const index = if (round % 2 == 0) slot else rows.len - 1 - slot;
            const ns = try elapsed(io, context, rows[index].run, batches[index]);
            if (ns <= 0) return error.NonMonotonicClock;
            samples[index * options.samples + round] = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(batches[index]));
        }
    }
    for (rows, 0..) |row, index| {
        const observed = samples[index * options.samples ..][0..options.samples];
        const stats = try shakedown.bench.statistics(gpa, observed);
        try shakedown.bench.write(writer, .{
            .row = row.name,
            .unit = row.unit,
            .samples = observed,
            .best = stats.best,
            .median = stats.median,
            .p99 = stats.p99,
            .ops_per_second = 1e9 / stats.median,
            .commit = metadata.commit,
            .zig = metadata.zig,
            .cpu = metadata.cpu,
            .os = metadata.os,
            .batch = batches[index],
            .clock_resolution_ns = @intCast(resolution), // safe: positive clock resolution checked against u64 before calibration.
        });
    }
}
fn elapsed(io: std.Io, context: anytype, function: anytype, batch: u64) shakedown.bench.RunError!i96 {
    const start = std.Io.Timestamp.now(io, .awake);
    try function(context, batch);
    const ns = start.durationTo(.now(io, .awake)).nanoseconds;
    if (ns < 0) return error.NonMonotonicClock;
    return ns;
}
