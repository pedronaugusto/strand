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

pub fn ns(io: std.Io, started: std.Io.Timestamp) u64 {
    return @intCast(@max(started.untilNow(io, .awake).toNanoseconds(), 1));
}

pub fn report(out: *std.Io.Writer, side: []const u8, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    try out.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ side, workload, metric, value, unit });
}
