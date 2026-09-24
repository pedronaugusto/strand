//! What the line layer costs, measured rather than asserted.
//!
//! `zig build bench` builds and runs this. It is not part of `zig build
//! test`: a number that varies with the machine is not a thing to fail a
//! build over, and these numbers exist to be read.
//!
//! Six measurements, each one a claim the README makes:
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
//! Run it in ReleaseFast for numbers worth quoting:
//!
//! ```sh
//! zig build bench -Doptimize=ReleaseFast
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

const line_count = 1_000_000;
const big_line_bytes = 100 << 20;

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    const stdout = &out.interface;

    try stdout.print("strand bench — {d} lines, {s}\n\n", .{
        line_count,
        @tagName(@import("builtin").mode),
    });

    const written = try benchWrite(gpa, io, stdout);
    defer gpa.free(written);
    try benchRead(gpa, io, stdout, written);
    try benchWriteAll(gpa, io, stdout);
    try benchTail(gpa, io, stdout, written);
    try benchBigLine(gpa, io, stdout);
    try benchCarried(gpa, io, stdout);

    // The scratch files live under `.zig-cache`, which a build already owns,
    // and they are not worth keeping once the numbers are printed.
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/bench") catch {};
    try stdout.flush();
}

/// A million values through a `Writer`, into memory.
fn benchWrite(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // The measurement is the encoding, not the growth of the destination.
    try out.ensureUnusedCapacity(line_count * 64);

    var log: strand.Writer(Event) = .init(&out.writer, .{});
    const started = std.Io.Clock.awake.now(io);
    for (0..line_count) |i| {
        try log.write(.{
            .kind = "request",
            .at = i,
            .level = if (i % 1000 == 0) .warn else .info,
        });
    }
    const elapsed = started.untilNow(io, .awake);

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
    const started = std.Io.Clock.awake.now(io);
    while (try reader.next()) |line| {
        checksum +%= line.value.at +% line.value.kind.len;
        if (within(line.value.kind, line.line)) borrowed += 1;
    }
    const elapsed = started.untilNow(io, .awake);

    try report(stdout, "read", elapsed, reader.number, input.len);
    try stdout.print(
        "                 {d} of {d} strings borrowed the line, checksum {d}\n",
        .{ borrowed, reader.number, checksum },
    );
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
    const started = std.Io.Clock.awake.now(io);
    try log.writeAll(events);
    const elapsed = started.untilNow(io, .awake);

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

    const started = std.Io.Clock.awake.now(io);
    const last = try tail.last(arena.allocator(), 100);
    const elapsed = started.untilNow(io, .awake);

    try stdout.print(
        "tail(100)        {f} for the last {d} of {d} lines, {B:.2} of {B:.2} touched\n",
        .{ elapsed, last.len, line_count, input.len - tail.lo, input.len },
    );
}

/// One line of a hundred megabytes, read off a file with a small buffer, so
/// the only thing holding the line is the reader.
fn benchBigLine(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer) !void {
    var work = try Scratch.initBigLine(io, gpa);
    defer work.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = work.file.reader(io, &buffer);

    var reader: strand.Reader(Event) = .init(gpa, &file_reader.interface, .{
        .max_line_bytes = big_line_bytes + 1024,
    });
    defer reader.deinit();

    const started = std.Io.Clock.awake.now(io);
    const line = (try reader.next()) orelse return error.NoLine;
    const elapsed = started.untilNow(io, .awake);

    try stdout.print(
        "big line         {f} for {B:.2}, borrowed: {}, arena {B:.2}\n",
        .{
            elapsed,
            line.line.len,
            within(line.value.kind, line.line),
            reader.arena.queryCapacity(),
        },
    );
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
        const started = std.Io.Clock.awake.now(io);
        while (try reader.next()) |line| checksum +%= line.value.at;
        const elapsed = started.untilNow(io, .awake);
        try report(stdout, name, elapsed, reader.number, out.written().len);
        std.mem.doNotOptimizeAway(checksum);
    }
}

/// A file under `.zig-cache`, which is where a build already puts things it
/// does not want to keep.
const Scratch = struct {
    dir: std.Io.Dir,
    file: std.Io.File,

    fn init(io: std.Io, bytes: []const u8) !Scratch {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/bench", .{});
        errdefer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = bytes });
        return .{ .dir = dir, .file = try dir.openFile(io, "log.jsonl", .{}) };
    }

    /// The same, for a line too big to want a second copy of in memory.
    fn initBigLine(io: std.Io, gpa: std.mem.Allocator) !Scratch {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/bench", .{});
        errdefer dir.close(io);
        {
            const file = try dir.createFile(io, "big.jsonl", .{});
            defer file.close(io);
            const buffer = try gpa.alloc(u8, 1 << 20);
            defer gpa.free(buffer);
            var file_writer = file.writer(io, buffer);
            const w = &file_writer.interface;
            try w.writeAll("{\"kind\":\"");
            try w.splatByteAll('x', big_line_bytes);
            try w.writeAll("\",\"at\":1}\n");
            try w.flush();
        }
        return .{ .dir = dir, .file = try dir.openFile(io, "big.jsonl", .{}) };
    }

    fn deinit(self: *Scratch, io: std.Io) void {
        self.file.close(io);
        self.dir.close(io);
        self.* = undefined;
    }
};

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
    try stdout.print("{s:<16} {f} — {d} lines/s, {B:.2}/s, {d} ns/line\n", .{
        what,
        elapsed,
        per_second,
        bytes_per_second,
        ns / @max(lines, 1),
    });
}

/// True when `inner` points into `outer`: the borrow, checked rather than
/// assumed.
fn within(inner: []const u8, outer: []const u8) bool {
    return @intFromPtr(inner.ptr) >= @intFromPtr(outer.ptr) and
        @intFromPtr(inner.ptr) + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}
