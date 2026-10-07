//! The mixed-line reader against the same parse with framing removed.
//! Run on a quiet machine in ReleaseFast; elapsed time is never a unit test.
const std = @import("std");
const strand = @import("strand");

/// The shape the figures were measured over: a short string, a number, an
/// enum, and one line in seven carrying a note with escapes in it.
const Timed = struct {
    kind: []const u8,
    at: u64 = 0,
    level: enum { info, warn } = .info,
    note: ?[]const u8 = null,
};

const Size = @import("size.zig").Size;

/// The budget, as a fraction of what the same parse costs with no line layer
/// at all.
pub const budget = 1.10;

fn timedInput(gpa: std.mem.Allocator, size: Size) ![]u8 {
    const kinds: []const []const u8 = &.{ "request", "open", "retry", "close", "flush" };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(size.mixed_lines * 80);

    var log: strand.Writer(Timed) = .init(&out.writer, .{});
    for (0..size.mixed_lines) |i| try log.write(.{
        .kind = kinds[i % kinds.len],
        .at = i,
        .level = if (i % 1000 == 0) .warn else .info,
        .note = if (i % 7 == 0) "user \"ada\" said \"no\"" else null,
    });

    var list = out.toArrayList();
    return list.toOwnedSlice(gpa);
}

/// This package's reader over `input`, in nanoseconds.
fn timeReader(gpa: std.mem.Allocator, io: std.Io, size: Size, input: []const u8) !u64 {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Timed) = .init(gpa, &source, .{});
    defer reader.deinit();

    var checksum: u64 = 0;
    const started = size.now(io);
    while (try reader.next()) |line| checksum +%= line.value.at +% line.value.kind.len;
    const elapsed = size.since(started, io);

    if (reader.lines.number != size.mixed_lines) return error.MissingLines;
    std.mem.doNotOptimizeAway(checksum);
    return @intCast(@max(elapsed.toNanoseconds(), 1));
}

/// The same parse with no line layer over it: the frame is a slice of the
/// input reader's own buffer, and nothing is copied or checked.
fn timeFloor(gpa: std.mem.Allocator, io: std.Io, size: Size, input: []const u8) !u64 {
    var source: std.Io.Reader = .fixed(input);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var checksum: u64 = 0;
    var seen: u64 = 0;
    const started = size.now(io);
    while (source.takeDelimiterInclusive('\n')) |framed| {
        const line = framed[0 .. framed.len - 1];
        _ = arena.reset(.retain_capacity);
        const value = try strand.parseLine(Timed, arena.allocator(), line, .{});
        checksum +%= value.at +% value.kind.len;
        seen += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const elapsed = size.since(started, io);

    if (seen != size.mixed_lines) return error.MissingLines;
    std.mem.doNotOptimizeAway(checksum);
    return @intCast(@max(elapsed.toNanoseconds(), 1));
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    const input = try timedInput(gpa, size);
    defer gpa.free(input);
    var reader_ns: u64 = std.math.maxInt(u64);
    var floor_ns: u64 = std.math.maxInt(u64);
    // Interleave the reader and its floor, retaining the best of each.
    for (0..size.mixed_rounds) |_| {
        reader_ns = @min(reader_ns, try timeReader(gpa, io, size, input));
        floor_ns = @min(floor_ns, try timeFloor(gpa, io, size, input));
    }
    const ratio = @as(f64, @floatFromInt(reader_ns)) / @as(f64, @floatFromInt(floor_ns));
    try stdout.print("strand\tmixed_read\treader\t{d}\tns/line\n", .{reader_ns / size.mixed_lines});
    try stdout.print("strand\tmixed_read\tparse_alone\t{d}\tns/line\n", .{floor_ns / size.mixed_lines});
    try stdout.print("strand\tmixed_read\treader_over_parse\t{d:.6}\tratio\n", .{ratio});
    try stdout.print("strand\tmixed_read\ttarget\t{d:.2}\tratio\n", .{budget});
}
