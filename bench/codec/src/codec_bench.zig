//! chronicle's record codec against strand's, on chronicle's own record shape
//! and on synthetic event shapes.
//!
//!   codec-bench <side> <synthetic_events.jsonl>
//!
//! side: `chronicle` (its stringify.zig/parse.zig as of bde5a26, copied here,
//! and its envelope reader from chronicle.zig) or `strand` (the package's
//! public API, the containing repository).
//!
//! Prints `side\tshape\top\tns_per_op\tns` rows (no checksum is computed in
//! any op: the CRC is chronicle's either way). Every op is timed over the
//! same prepared values for at least 200 ms after one untimed pass. Before
//! timing, the strand side checks that it writes every value byte for byte as
//! chronicle does, and reads back what chronicle reads; a difference is an
//! exit, not a row.

const std = @import("std");
const strand = @import("strand");
const cs = @import("chronicle_stringify");
const cp = @import("chronicle_parse");

const Allocator = std.mem.Allocator;
const smoke = @import("bench_options").smoke;

// ---------------------------------------------------------------- shapes

/// chronicle's own bench record (bench/chronicle): 200 bytes a line.
const Bench = struct { value: u64, padding: []const u8 };

/// A tagged union of structs, chronicle's expected event shape, with the
/// bodies using invented strings with escapes and non-ASCII.
const Typed = struct {
    node: u64,
    conversation: u64,
    body: union(enum) {
        text: struct {
            item: struct { node: u64, vendor: []const u8 },
            role: []const u8,
            content: []const u8,
            done: bool,
            kind: []const u8,
        },
        spawned: struct {
            backend: []const u8,
            role: []const u8,
            task: []const u8,
            by: []const u8,
            model: []const u8,
            until: i64,
            repo: []const u8,
            resumed: bool,
        },
        turn_end: struct {
            usage: struct { input: u64, output: u64, cache_read: u64, cache_write: u64, reasoning: u64 },
            stop: []const u8,
        },
        exited: struct { code: i32, retired: bool, natural: bool },
    },
};

/// 128-bit integers: the type chronicle's std.json guard is for.
const Wide = struct { id: u128, amount: i128, note: []const u8 };

fn LineOf(comptime Event: type) type {
    return struct { seq: u64, at: i64, v: u32, p: u32, ev: Event };
}

/// The envelope read whole by strand, the event kept as its bytes.
const Envelope = struct { seq: u64, at: i64, v: u32, p: u32, ev: strand.Raw, c: u32 };

// ---------------------------------------------------------------- timing

var sink: usize = 0;

fn report(io: std.Io, side: []const u8, shape: []const u8, op: []const u8, ns: f64) void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    out.interface.print("{s}\t{s}\t{s}\t{d:.2}\tns\n", .{ side, shape, op, ns }) catch {};
    out.interface.flush() catch {};
}

/// Runs `body(ctx, i)` for i over 0..n repeatedly, one untimed pass first,
/// until at least 200 ms have gone; ns per call.
fn time(io: std.Io, n: usize, ctx: anytype, comptime body: fn (@TypeOf(ctx), usize) anyerror!void) !f64 {
    if (!smoke) for (0..n) |i| try body(ctx, i);
    var calls: u64 = 0;
    const started = benchmarkNow(io);
    var ns: i96 = 0;
    while (calls == 0 or (!smoke and ns < 200 * std.time.ns_per_ms)) {
        for (0..n) |i| try body(ctx, i);
        calls += n;
        ns = started.durationTo(benchmarkNow(io)).toNanoseconds();
    }
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(calls));
}

// ---------------------------------------------------------------- codecs

const Side = enum { chronicle, strand };

/// The event's JSON as chronicle writes it (std.json's bytes, null
/// optionals included).
fn encodeEvent(comptime side: Side, value: anytype, w: *std.Io.Writer) !void {
    switch (side) {
        .chronicle => try cs.value(value, w),
        .strand => {
            if (comptime @hasDecl(strand, "writeValue")) {
                try strand.writeValue(w, value, .{ .emit_null_optional_fields = true });
            } else {
                var writer: strand.Writer(@TypeOf(value)) = .init(w, .{ .emit_null_optional_fields = true });
                try writer.write(value);
                w.end -= 1;
            }
        },
    }
}

/// The record up to the checksum: `{"seq":..,"at":..,"v":..,"p":..,"ev":<event>`.
fn encodeRecord(comptime side: Side, seq: u64, at: i64, event: anytype, w: *std.Io.Writer) !void {
    switch (side) {
        .chronicle => {
            var head: [cs.envelope_head_max]u8 = undefined;
            try w.writeAll(cs.envelopeHead(&head, seq, at, 1, 0x9e3779b9));
            try cs.value(event, w);
        },
        .strand => {
            const Line = LineOf(@TypeOf(event));
            try encodeEvent(.strand, Line{ .seq = seq, .at = at, .v = 1, .p = 0x9e3779b9, .ev = event }, w);
            w.end -= 1; // the object's closing brace: the checksum goes there
        },
    }
}

fn decodeEvent(comptime side: Side, comptime T: type, arena: Allocator, bytes: []const u8) !T {
    return switch (side) {
        .chronicle => cp.fromSlice(T, arena, bytes, .{}),
        .strand => strand.parseLine(T, arena, bytes, .{ .ignore_unknown_fields = false }),
    };
}

// chronicle.zig's envelope reader (bde5a26), as it stands there.
const Header = struct { seq: u64, at: i64, version: u32, p: u32, c: u32, from: usize, to: usize };

fn coveredBytes(line: []const u8) ?[]const u8 {
    const opening = ",\"c\":";
    if (line.len < opening.len + 2 or line[line.len - 1] != '}') return null;
    var at = line.len - 1;
    var digits: usize = 0;
    while (at > 0 and std.ascii.isDigit(line[at - 1])) : (digits += 1) at -= 1;
    if (digits == 0 or at < opening.len) return null;
    if (!std.mem.eql(u8, line[at - opening.len .. at], opening)) return null;
    return line[0 .. at - opening.len];
}

fn member(line: []const u8, at: *usize, comptime opening: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, line[at.*..], opening)) return null;
    var end = at.* + opening.len;
    const from = end;
    if (end < line.len and line[end] == '-') end += 1;
    const digits = end;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == digits) return null;
    const value = std.fmt.parseInt(i64, line[from..end], 10) catch return null;
    at.* = end;
    return value;
}

fn quickHeader(line: []const u8) !Header {
    const covered = coveredBytes(line) orelse return error.Corrupt;
    const claimed = std.fmt.parseInt(u32, line[covered.len + ",\"c\":".len .. line.len - 1], 10) catch return error.Corrupt;
    var at: usize = 0;
    const seq = member(covered, &at, "{\"seq\":") orelse return error.Corrupt;
    const stamp = member(covered, &at, ",\"at\":") orelse return error.Corrupt;
    const version = member(covered, &at, ",\"v\":") orelse return error.Corrupt;
    const link = member(covered, &at, ",\"p\":") orelse return error.Corrupt;
    const ev_prefix = ",\"ev\":";
    if (!std.mem.startsWith(u8, covered[at..], ev_prefix)) return error.Corrupt;
    return .{
        .seq = @intCast(seq),
        .at = stamp,
        .version = @intCast(version),
        .p = @intCast(link),
        .c = claimed,
        .from = at + ev_prefix.len,
        .to = covered.len,
    };
}

// ---------------------------------------------------------------- one shape

fn Shape(comptime Event: type) type {
    return struct {
        name: []const u8,
        values: []const Event,
        /// The event's bytes, as chronicle writes them.
        events: []const []const u8,
        /// The event's bytes with a space after every member's colon: not
        /// the written shape, so chronicle's reader hands it to std.json
        /// (behind its guard when `Event` holds a wide integer).
        spaced: []const []const u8,
        /// Whole records, checksum included.
        records: []const []const u8,
    };
}

fn prepare(comptime Event: type, a: Allocator, name: []const u8, values: []const Event) !Shape(Event) {
    const events = try a.alloc([]const u8, values.len);
    const spaced = try a.alloc([]const u8, values.len);
    const records = try a.alloc([]const u8, values.len);
    for (values, 0..) |value, i| {
        var out: std.Io.Writer.Allocating = .init(a);
        try cs.value(value, &out.writer);
        events[i] = out.written();
        // A space after each `":` outside strings, which is between tokens.
        var sp: std.ArrayList(u8) = .empty;
        var in_string = false;
        var escaped = false;
        for (events[i]) |b| {
            try sp.append(a, b);
            if (in_string) {
                if (escaped) escaped = false else if (b == '\\') escaped = true else if (b == '"') in_string = false;
            } else if (b == '"') in_string = true else if (b == ':' or b == ',') try sp.append(a, ' ');
        }
        spaced[i] = sp.items;
        var rec: std.Io.Writer.Allocating = .init(a);
        try encodeRecord(.chronicle, i + 1, 1_789_076_525_400 + @as(i64, @intCast(i)), value, &rec.writer);
        const sum = std.hash.crc.Crc32Iscsi.hash(rec.written());
        try rec.writer.print(",\"c\":{d}}}", .{sum});
        records[i] = rec.written();
    }
    return .{ .name = name, .values = values, .events = events, .spaced = spaced, .records = records };
}

/// The strand side writes what chronicle writes and reads what it reads.
fn check(comptime Event: type, a: Allocator, shape: Shape(Event)) !void {
    for (shape.values, shape.events, shape.spaced, shape.records, 0..) |value, event, spaced, record, i| {
        var out: std.Io.Writer.Allocating = .init(a);
        try encodeEvent(.strand, value, &out.writer);
        if (!std.mem.eql(u8, out.written(), event)) {
            std.debug.print("{s}[{d}] strand wrote\n  {s}\nchronicle wrote\n  {s}\n", .{ shape.name, i, out.written(), event });
            return error.BytesDiffer;
        }
        var rec: std.Io.Writer.Allocating = .init(a);
        try encodeRecord(.strand, i + 1, 1_789_076_525_400 + @as(i64, @intCast(i)), value, &rec.writer);
        if (!std.mem.startsWith(u8, record, rec.written()) or record[rec.written().len] != ',') return error.RecordBytesDiffer;
        for ([_][]const u8{ event, spaced }) |bytes| {
            const theirs = try std.json.parseFromSliceLeaky(Event, a, bytes, .{});
            const ours = try decodeEvent(.strand, Event, a, bytes);
            var x: std.Io.Writer.Allocating = .init(a);
            var y: std.Io.Writer.Allocating = .init(a);
            try cs.value(ours, &x.writer);
            try cs.value(theirs, &y.writer);
            if (!std.mem.eql(u8, x.written(), y.written())) return error.ReadDiffers;
        }
    }
}

fn run(comptime side: Side, comptime Event: type, io: std.Io, gpa: Allocator, shape: Shape(Event)) !void {
    const tag = @tagName(side);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureTotalCapacity(64 * 1024);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const Ctx = struct {
        shape: Shape(Event),
        out: *std.Io.Writer.Allocating,
        arena: *std.heap.ArenaAllocator,

        fn encEvent(c: @This(), i: usize) anyerror!void {
            c.out.clearRetainingCapacity();
            try encodeEvent(side, c.shape.values[i], &c.out.writer);
            sink +%= c.out.written().len;
        }
        fn encRecord(c: @This(), i: usize) anyerror!void {
            c.out.clearRetainingCapacity();
            try encodeRecord(side, i + 1, 1_789_076_525_400 + @as(i64, @intCast(i)), c.shape.values[i], &c.out.writer);
            sink +%= c.out.written().len;
        }
        fn decEvent(c: @This(), i: usize) anyerror!void {
            _ = c.arena.reset(.retain_capacity);
            const v = try decodeEvent(side, Event, c.arena.allocator(), c.shape.events[i]);
            sink +%= @intFromPtr(&v) & 1;
        }
        fn decSpaced(c: @This(), i: usize) anyerror!void {
            _ = c.arena.reset(.retain_capacity);
            const v = try decodeEvent(side, Event, c.arena.allocator(), c.shape.spaced[i]);
            sink +%= @intFromPtr(&v) & 1;
        }
        fn decRecord(c: @This(), i: usize) anyerror!void {
            _ = c.arena.reset(.retain_capacity);
            const line = c.shape.records[i];
            const h = try quickHeader(line);
            const v = try decodeEvent(side, Event, c.arena.allocator(), line[h.from..h.to]);
            sink +%= h.seq + (@intFromPtr(&v) & 1);
        }
        /// strand only: the envelope read whole, the event from its bytes.
        fn decEnvelope(c: @This(), i: usize) anyerror!void {
            _ = c.arena.reset(.retain_capacity);
            const line = c.shape.records[i];
            const covered = coveredBytes(line) orelse return error.Corrupt;
            const e = try strand.parseLine(Envelope, c.arena.allocator(), line, .{ .ignore_unknown_fields = false });
            sink +%= covered.len;
            const v = try strand.parseLine(Event, c.arena.allocator(), e.ev.bytes, .{ .ignore_unknown_fields = false });
            sink +%= e.seq + (@intFromPtr(&v) & 1);
        }
    };
    const ctx: Ctx = .{ .shape = shape, .out = &out, .arena = &arena };
    const n = shape.values.len;
    report(io, tag, shape.name, "encode_event", try time(io, n, ctx, Ctx.encEvent));
    report(io, tag, shape.name, "encode_record", try time(io, n, ctx, Ctx.encRecord));
    report(io, tag, shape.name, "decode_event", try time(io, n, ctx, Ctx.decEvent));
    report(io, tag, shape.name, "decode_spaced", try time(io, n, ctx, Ctx.decSpaced));
    report(io, tag, shape.name, "decode_record", try time(io, n, ctx, Ctx.decRecord));
    if (side == .strand) report(io, tag, shape.name, "decode_envelope", try time(io, n, ctx, Ctx.decEnvelope));
}

fn runShape(comptime Event: type, side: Side, io: std.Io, gpa: Allocator, a: Allocator, shape: Shape(Event), check_only: bool) !void {
    if (check_only) return check(Event, a, shape);
    switch (side) {
        .chronicle => try run(.chronicle, Event, io, gpa, shape),
        .strand => {
            try check(Event, a, shape);
            try run(.strand, Event, io, gpa, shape);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const side = std.meta.stringToEnum(Side, args.next() orelse return error.MissingSide) orelse return error.UnknownSide;
    const corpus_path = args.next() orelse return error.MissingCorpus;
    const option = args.next();
    const check_only = if (option) |flag| std.mem.eql(u8, flag, "--check-only") else false;
    if (option != null and !check_only) return error.UnknownOption;
    if (args.next() != null) return error.ExtraArgument;

    var setup: std.heap.ArenaAllocator = .init(gpa);
    defer setup.deinit();
    const a = setup.allocator();

    const corpus = try std.Io.Dir.cwd().readFileAlloc(io, corpus_path, a, .limited(64 << 20));
    var raws: std.ArrayList(strand.Raw) = .empty;
    var typed: std.ArrayList(Typed) = .empty;
    var it = std.mem.splitScalar(u8, corpus, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try raws.append(a, .{ .bytes = line });
        const Kind = struct { body: std.json.Value };
        const kind = try std.json.parseFromSliceLeaky(Kind, a, line, .{ .ignore_unknown_fields = true });
        const arm = kind.body.object.keys()[0];
        inline for (.{ "text", "spawned", "turn_end", "exited" }) |known| {
            if (std.mem.eql(u8, arm, known)) {
                try typed.append(a, try std.json.parseFromSliceLeaky(Typed, a, line, .{ .ignore_unknown_fields = true }));
            }
        }
    }

    const padding = "x" ** (200 - "{\"value\":1,\"padding\":\"\"}\n".len);
    const bench = try a.alloc(Bench, if (smoke) 1 else 512);
    for (bench) |*b| b.* = .{ .value = 1, .padding = padding };

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const wide = try a.alloc(Wide, if (smoke) 1 else 512);
    for (wide, 0..) |*w, i| w.* = .{
        .id = prng.random().int(u128),
        .amount = prng.random().int(i128),
        .note = if (i % 2 == 0) "settled" else "carried forward",
    };

    try runShape(Bench, side, io, gpa, a, try prepare(Bench, a, "bench", bench), check_only);
    try runShape(strand.Raw, side, io, gpa, a, try prepare(strand.Raw, a, "synthetic", raws.items), check_only);
    try runShape(Typed, side, io, gpa, a, try prepare(Typed, a, "typed", typed.items), check_only);
    try runShape(Wide, side, io, gpa, a, try prepare(Wide, a, "wide", wide), check_only);
    if (sink == 42) std.debug.print("", .{});
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}
