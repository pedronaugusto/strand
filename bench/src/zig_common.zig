const std = @import("std");

pub const Record = struct {
    id: u64,
    name: []const u8,
    count: u64,
    meta: struct { region: []const u8, score: u64 },
    tags: []const []const u8,
    message: []const u8,
};

pub fn sample(i: u64) Record {
    _ = i;
    return .{
        .id = 123456,
        .name = "user-3456",
        .count = 987654,
        .meta = .{ .region = "eu", .score = 73 },
        .tags = &.{ "jsonl", "benchmark", "g42" },
        .message = "abcdefghij" ** 25 ++ "abcdef",
    };
}

/// The arms of `tagged.jsonl`, as std.json encodes a tagged union.
pub const Tagged = union(enum) {
    open: struct { at: u64, who: []const u8 },
    retry: struct { at: u64, attempt: u64 },
    close: struct { at: u64, code: i64 },
};

/// The object each `carried.jsonl` line carries.
pub const Data = struct { who: []const u8, beat: u64, tags: []const []const u8 };

pub fn ns(io: std.Io, started: std.Io.Timestamp) u64 {
    return @intCast(@max((if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake)).toNanoseconds(), 1));
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
pub fn now(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}

pub fn report(out: *std.Io.Writer, side: []const u8, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    try out.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ side, workload, metric, value, unit });
}

/// Items per second and nanoseconds per item over `elapsed` nanoseconds.
pub fn rate(out: *std.Io.Writer, side: []const u8, workload: []const u8, items: u64, elapsed: u64) !void {
    const n: f64 = @floatFromInt(@max(items, 1));
    const t: f64 = @floatFromInt(elapsed);
    try report(out, side, workload, "items", n * 1e9 / t, "items/s");
    try report(out, side, workload, "per_item", t / n, "ns");
}

pub fn megabytes(out: *std.Io.Writer, side: []const u8, workload: []const u8, bytes: u64, elapsed: u64) !void {
    try report(out, side, workload, "bytes", @as(f64, @floatFromInt(bytes)) * 1e3 / @as(f64, @floatFromInt(elapsed)), "MB/s");
}

/// A value every side computes from the same input: the harness compares
/// these across sides and refuses a job where they differ.
pub fn check(out: *std.Io.Writer, side: []const u8, workload: []const u8, metric: []const u8, value: u64) !void {
    try out.print("{s}\t{s}\t{s}\t{d}\tchecksum\n", .{ side, workload, metric, value });
}

/// The whole file, and its lines without terminators (built untimed).
pub const Loaded = struct {
    bytes: []u8,
    lines: [][]const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| if (line.len != 0) try list.append(gpa, line);
        return .{ .bytes = bytes, .lines = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        gpa.free(self.lines);
        gpa.free(self.bytes);
    }
};

/// Byte offsets of every `every`th line start (the first included).
pub fn offsets(gpa: std.mem.Allocator, bytes: []const u8, every: usize) ![]u64 {
    var list: std.ArrayList(u64) = .empty;
    errdefer list.deinit(gpa);
    var at: usize = 0;
    var n: usize = 0;
    while (at < bytes.len) : (n += 1) {
        if (n % every == 0) try list.append(gpa, at);
        const end = std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse bytes.len;
        at = end + 1;
    }
    return list.toOwnedSlice(gpa);
}
