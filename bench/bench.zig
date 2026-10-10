//! What the line layer costs, measured rather than asserted.
//!
//! `zig build bench` builds it in ReleaseFast and runs it; `zig build test`
//! runs it once with `--smoke`, over tiny inputs and without reading a
//! clock, so it keeps working. A number that varies with the machine is not
//! a thing to fail a build over, and these numbers exist to be read.
//!
//! Nine measurements:
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
//!    as a `strand.json.Raw` and as a `strand.json.Value`: the first stays on the
//!    direct path, the second takes the whole line to `std.json`.
//!
//! 7. Mixed lines against the same parse with framing removed, with a target
//!    of at most 1.10 times the parse on a quiet machine.
//! 8. Records written to a file synced after each one, which is what a
//!    durable log pays per record: the sync dominates, and the row says by
//!    how much.
//! 9. A follower's question "is this still my file?", asked of a handle:
//!    what each look at a quiet log costs before it waits again.
//!
//! `zig build bench` builds it in ReleaseFast, the mode for numbers worth
//! quoting.

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const size: Size = try .of(args[1..]);

    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    const stdout = &out.interface;

    const written = try benchWrite(gpa, io, stdout, size);
    defer gpa.free(written);
    try benchRead(gpa, io, stdout, size, written);
    try benchWriteAll(gpa, io, stdout, size);
    try benchTail(gpa, io, stdout, size, written);
    try benchBigLine(gpa, io, stdout, size);
    try benchCarried(gpa, io, stdout, size);
    try @import("read_cost.zig").run(gpa, io, stdout, size);
    try benchSyncedWrite(io, stdout, size);
    try benchIdentity(io, stdout, size);

    try stdout.flush();
}

/// A million values through a `Writer`, into memory.
fn benchWrite(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // The measurement is the encoding, not the growth of the destination.
    try out.ensureUnusedCapacity(size.lines * 64);

    var log: strand.jsonl.Writer(Event) = .init(&out.writer, .{ .encode = .{ .nulls = .omit } });
    const started = size.now(io);
    for (0..size.lines) |i| {
        try log.write(.{
            .kind = "request",
            .at = i,
            .level = if (i % 1000 == 0) .warn else .info,
        });
    }
    const elapsed = size.since(started, io);

    try report(stdout, "write", elapsed, size.lines, out.written().len);
    var list = out.toArrayList();
    return list.toOwnedSlice(gpa);
}

/// The same million back through a `Reader`.
fn benchRead(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size, input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.jsonl.Reader(Event) = .init(gpa, &source, .{});
    defer reader.deinit();

    var checksum: u64 = 0;
    var borrowed: u64 = 0;
    const started = size.now(io);
    while (try reader.next()) |line| {
        checksum +%= line.value.at +% line.value.kind.len;
        if (within(line.value.kind, line.line)) borrowed += 1;
    }
    const elapsed = size.since(started, io);

    try report(stdout, "read", elapsed, reader.lines.number, input.len);
    if (reader.lines.number != size.lines or borrowed != size.lines) return error.ReadMismatch;
    if (checksum != size.lines * (size.lines - 1) / 2 + 7 * size.lines) return error.ChecksumMismatch;
    try metric(stdout, "read", "borrowed", borrowed, "records");
}

/// The same million as one `writeAll`.
fn benchWriteAll(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    const events = try gpa.alloc(Event, size.lines);
    defer gpa.free(events);
    for (events, 0..) |*event, i| event.* = .{ .kind = "request", .at = i };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureUnusedCapacity(size.lines * 64);

    var log: strand.jsonl.Writer(Event) = .init(&out.writer, .{ .encode = .{ .nulls = .omit } });
    const started = size.now(io);
    try log.writeAll(events);
    const elapsed = size.since(started, io);

    if (log.count != size.lines) return error.WriteCountMismatch;
    try report(stdout, "writeAll", elapsed, log.count, out.written().len);
}

/// The last hundred lines of the million, read backwards off a file.
fn benchTail(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size, input: []const u8) !void {
    var work = try Scratch.init(io, input);
    defer work.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = work.file.reader(io, &buffer);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var tail: strand.jsonl.Tail(Event) = try .init(gpa, &file_reader, .{});
    defer tail.deinit();

    const started = size.now(io);
    const last = try tail.last(arena.allocator(), 100);
    const elapsed = size.since(started, io);

    if (last.len != @min(size.lines, 100)) return error.TailCountMismatch;
    try metric(stdout, "tail(100)", "elapsed", elapsed.toNanoseconds(), "ns");
    try metric(stdout, "tail(100)", "returned", last.len, "records");
    try metric(stdout, "tail(100)", "bytes_touched", input.len - tail.lo, "bytes");
}

/// One line of a hundred megabytes, read off a file with a small buffer, so
/// the only thing holding the line is the reader.
fn benchBigLine(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    var work = try Scratch.initBigLine(io, gpa, size.big_line_bytes);
    defer work.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = work.file.reader(io, &buffer);

    // A line this long is a decision about every limit that scales with it.
    const big: usize = size.big_line_bytes + 1024;
    var reader: strand.jsonl.Reader(Event) = .init(gpa, &file_reader.interface, .{
        .max_line_bytes = big,
        .parse = .{ .ignore_unknown_fields = true, .limits = .{ .string_bytes = big, .work = 4 * big } },
    });
    defer reader.deinit();

    const started = size.now(io);
    const line = (try reader.next()) orelse return error.NoLine;
    const elapsed = size.since(started, io);

    if (line.value.kind.len != size.big_line_bytes or !within(line.value.kind, line.line)) return error.BigLineMismatch;
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
/// `strand.json.Raw` and then as a `strand.json.Value`.
fn benchCarried(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureUnusedCapacity(size.lines * 96);
    var log: strand.jsonl.Writer(Carried(strand.json.Raw)) = .init(&out.writer, .{ .encode = .{ .nulls = .omit } });
    for (0..size.lines) |i| try log.write(.{
        .kind = "mark",
        .at = i,
        .data = .{ .bytes = "{\"who\":\"ada\",\"beat\":3,\"tags\":[\"a\",\"b\"]}" },
    });

    inline for (.{ strand.json.Raw, strand.json.Value }, .{ "carried, Raw", "carried, Value" }) |Data, name| {
        var source: std.Io.Reader = .fixed(out.written());
        var reader: strand.jsonl.Reader(Carried(Data)) = .init(gpa, &source, .{});
        defer reader.deinit();
        var checksum: u64 = 0;
        const started = size.now(io);
        while (try reader.next()) |line| checksum +%= line.value.at;
        const elapsed = size.since(started, io);
        if (reader.lines.number != size.lines or checksum != size.lines * (size.lines - 1) / 2) return error.CarriedMismatch;
        try report(stdout, name, elapsed, reader.lines.number, out.written().len);
        std.mem.doNotOptimizeAway(checksum);
    }
}

/// Records through a `Writer` that syncs the file after each one.
fn benchSyncedWrite(io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    const records = size.synced_records;
    var work = try Scratch.init(io, "");
    defer work.deinit(io);
    const file = try work.scratch.dir.openFile(io, "log.jsonl", .{ .mode = .write_only });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var log: strand.jsonl.Writer(Event) = .initFile(&file_writer, .{ .sync = .per_record });
    const started = size.now(io);
    for (0..records) |i| try log.write(.{ .kind = "request", .at = i });
    const elapsed = size.since(started, io);

    if (log.count != records) return error.WriteCountMismatch;
    try report(stdout, "write, sync per record", elapsed, log.count, try file.length(io));
}

/// `Identity.take` under `.file_id`, asked of one handle again and again.
fn benchIdentity(io: std.Io, stdout: *std.Io.Writer, size: Size) !void {
    const looks = size.identity_looks;
    var work = try Scratch.init(io, "{\"kind\":\"open\"}\n");
    defer work.deinit(io);

    const first = try strand.jsonl.Identity.take(.file_id, io, work.file);
    const started = size.now(io);
    var same: usize = 0;
    for (0..looks) |_| {
        if ((try strand.jsonl.Identity.take(.file_id, io, work.file)).eql(first)) same += 1;
    }
    const elapsed = size.since(started, io);

    if (same != looks) return error.IdentityMismatch;
    try metric(stdout, "identity", "elapsed", elapsed.toNanoseconds(), "ns");
    try metric(stdout, "identity", "per_look", @as(u64, @intCast(elapsed.toNanoseconds())) / looks, "ns/look");
}

const Scratch = @import("bench_scratch.zig").Scratch;
const Size = @import("size.zig").Size;

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
