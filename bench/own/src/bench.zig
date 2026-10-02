//! What the line layer costs, measured rather than asserted.
//!
//! `bench/own/run.sh` builds and runs this on the bench branch.
//! It is not part of `zig build test`: a number that varies with the machine is not a thing to fail a
//! build over, and these numbers exist to be read.
//!
//! Seven measurements, each one a claim the README makes:
//!
//! 1. A million small values written, minified, one line each.
//! 2. The same million read back and parsed, with strings borrowing from the
//!    line rather than being copied.
//! 3. The same million written again as one batch, to show `writeAll` is the
//!    loop and not another format.
//! 4. The last hundred lines of the million, read backwards off a file, to
//!    show that it costs a block and not a file.
//! 5. One line of a hundred megabytes, read with the borrow intact.
//! 6. A million lines each carrying a value the reader does not read, typed
//!    as a `strand.Raw` and as a `std.json.Value`: the first stays on the
//!    direct path, the second takes the whole line to `std.json`.
//!
//! 7. Mixed lines against the same parse with framing removed, with a target
//!    of at most 1.10 times the parse on a quiet machine.
//!
//! Run it in ReleaseFast for numbers worth quoting:
//!
//! ```sh
//! ./bench/own/run.sh
//! ```

const std = @import("std");
const strand = @import("strand");

/// One line of the log being measured: small, mixed, and the shape a real one
/// has — a string, a number, an enum, an omitted optional.
const Event = struct {
    kind: []const u8,
    at: u64,
    level: enum { info, warn } = .info,
    note: ?[]const u8 = null,
};

const smoke = @import("bench_options").smoke;
const line_count = if (smoke) 1 else 1_000_000;
const big_line_bytes = if (smoke) 64 else 100 << 20;

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    const stdout = &out.interface;

    const written = try benchWrite(gpa, io, stdout);
    defer gpa.free(written);
    try benchRead(gpa, io, stdout, written);
    try benchWriteAll(gpa, io, stdout);
    try benchTail(gpa, io, stdout, written);
    try benchBigLine(gpa, io, stdout);
    try benchCarried(gpa, io, stdout);
    try @import("read_cost.zig").run(gpa, io, stdout);

    try stdout.flush();
}

/// A million values through a `Writer`, into memory.
fn benchWrite(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // The measurement is the encoding, not the growth of the destination.
    try out.ensureUnusedCapacity(line_count * 64);

    var log: strand.Writer(Event) = .init(&out.writer, .{});
    const started = benchmarkNow(io);
    for (0..line_count) |i| {
        try log.write(.{
            .kind = "request",
            .at = i,
            .level = if (i % 1000 == 0) .warn else .info,
        });
    }
    const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));

    try report(stdout, "write", elapsed, line_count, out.written().len);
    var list = out.toArrayList();
    return list.toOwnedSlice(gpa);
}

/// The same million back through a `Reader`.
fn benchRead(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(gpa, &source, .{});
    defer reader.deinit();

    var checksum: u64 = 0;
    var borrowed: u64 = 0;
    const started = benchmarkNow(io);
    while (try reader.next()) |line| {
        checksum +%= line.value.at +% line.value.kind.len;
        if (within(line.value.kind, line.line)) borrowed += 1;
    }
    const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));

    try report(stdout, "read", elapsed, reader.lines.number, input.len);
    if (reader.lines.number != line_count or borrowed != line_count) return error.ReadMismatch;
    if (checksum != line_count * (line_count - 1) / 2 + 7 * line_count) return error.ChecksumMismatch;
    try metric(stdout, "read", "borrowed", borrowed, "records");
}

/// The same million as one `writeAll`.
fn benchWriteAll(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !void {
    const events = try gpa.alloc(Event, line_count);
    defer gpa.free(events);
    for (events, 0..) |*event, i| event.* = .{ .kind = "request", .at = i };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureUnusedCapacity(line_count * 64);

    var log: strand.Writer(Event) = .init(&out.writer, .{});
    const started = benchmarkNow(io);
    try log.writeAll(events);
    const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));

    if (log.count != line_count) return error.WriteCountMismatch;
    try report(stdout, "writeAll", elapsed, log.count, out.written().len);
}

/// The last hundred lines of the million, read backwards off a file.
fn benchTail(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, input: []const u8) !void {
    var work = try Scratch.init(io, input);
    defer work.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = work.file.reader(io, &buffer);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var tail: strand.Tail(Event) = try .init(gpa, &file_reader, .{});
    defer tail.deinit();

    const started = benchmarkNow(io);
    const last = try tail.last(arena.allocator(), 100);
    const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));

    if (last.len != @min(line_count, 100)) return error.TailCountMismatch;
    try metric(stdout, "tail(100)", "elapsed", elapsed.toNanoseconds(), "ns");
    try metric(stdout, "tail(100)", "returned", last.len, "records");
    try metric(stdout, "tail(100)", "bytes_touched", input.len - tail.lo, "bytes");
}

/// One line of a hundred megabytes, read off a file with a small buffer, so
/// the only thing holding the line is the reader.
fn benchBigLine(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !void {
    var work = try Scratch.initBigLine(io, gpa, big_line_bytes);
    defer work.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = work.file.reader(io, &buffer);

    var reader: strand.Reader(Event) = .init(gpa, &file_reader.interface, .{
        .max_line_bytes = big_line_bytes + 1024,
    });
    defer reader.deinit();

    const started = benchmarkNow(io);
    const line = (try reader.next()) orelse return error.NoLine;
    const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));

    if (line.value.kind.len != big_line_bytes or !within(line.value.kind, line.line)) return error.BigLineMismatch;
    try metric(stdout, "big_line", "elapsed", elapsed.toNanoseconds(), "ns");
    try metric(stdout, "big_line", "arena_capacity", reader.arena.queryCapacity(), "bytes");
}

/// A line of a log that carries another program's record, passed along.
fn Carried(comptime Data: type) type {
    return struct {
        kind: []const u8,
        at: u64,
        data: Data,
    };
}

/// A million lines with a small object in each that nobody reads, typed as a
/// `strand.Raw` and then as a `std.json.Value`.
fn benchCarried(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureUnusedCapacity(line_count * 96);
    var log: strand.Writer(Carried(strand.Raw)) = .init(&out.writer, .{});
    for (0..line_count) |i| try log.write(.{
        .kind = "mark",
        .at = i,
        .data = .{ .bytes = "{\"who\":\"ada\",\"beat\":3,\"tags\":[\"a\",\"b\"]}" },
    });

    inline for (.{ strand.Raw, std.json.Value }, .{ "carried, Raw", "carried, Value" }) |Data, name| {
        var source: std.Io.Reader = .fixed(out.written());
        var reader: strand.Reader(Carried(Data)) = .init(gpa, &source, .{});
        defer reader.deinit();
        var checksum: u64 = 0;
        const started = benchmarkNow(io);
        while (try reader.next()) |line| checksum +%= line.value.at;
        const elapsed = (if (@import("bench_options").smoke) std.Io.Duration.fromNanoseconds(1) else started.untilNow(io, .awake));
        if (reader.lines.number != line_count or checksum != line_count * (line_count - 1) / 2) return error.CarriedMismatch;
        try report(stdout, name, elapsed, reader.lines.number, out.written().len);
        std.mem.doNotOptimizeAway(checksum);
    }
}

const Scratch = @import("bench_scratch.zig").Scratch;

/// One line of output: how long, how many lines a second, how many bytes a
/// second, and how long one line took.
fn report(
    stdout: *std.Io.Writer,
    what: []const u8,
    elapsed: std.Io.Duration,
    lines: u64,
    bytes: usize,
) !void {
    const ns: u64 = @intCast(@max(elapsed.toNanoseconds(), 1));
    const per_second = lines * std.time.ns_per_s / ns;
    const bytes_per_second = bytes * std.time.ns_per_s / ns;
    try metric(stdout, what, "elapsed", ns, "ns");
    try metric(stdout, what, "lines", per_second, "lines/s");
    try metric(stdout, what, "bytes", bytes_per_second, "bytes/s");
    try metric(stdout, what, "per_line", ns / @max(lines, 1), "ns/line");
}

/// True when `inner` points into `outer`: the borrow, checked rather than
/// assumed.
fn within(inner: []const u8, outer: []const u8) bool {
    return @intFromPtr(inner.ptr) >= @intFromPtr(outer.ptr) and // safe: addresses compared as numbers, never read through
        @intFromPtr(inner.ptr) + inner.len <= @intFromPtr(outer.ptr) + outer.len; // safe: the same comparison, the far end
}

fn metric(stdout: *std.Io.Writer, work: []const u8, name: []const u8, value: anytype, unit: []const u8) !void {
    try stdout.print("strand\t{s}\t{s}\t{}\t{s}\n", .{ work, name, value, unit });
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
