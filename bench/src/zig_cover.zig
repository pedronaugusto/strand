//! The rest of the public operations, one mode each, against the snapshot
//! this program is built from. An operation the snapshot does not have is
//! compiled out and refused at run time; the harness never asks for it.
//!
//! Every mode prints timing rows and `checksum` rows; the checksums are what
//! every other side of the same job computes from the same input.
const std = @import("std");
const strand = @import("strand");
const common = @import("zig_common.zig");
const Record = common.Record;
const Tagged = common.Tagged;
const Data = common.Data;
const smoke = @import("bench_options").smoke;
const Init = std.process.Init;
const side = "strand";

pub fn run(init: Init, mode: []const u8, args: []const [:0]const u8, out: *std.Io.Writer) !bool {
    const Mode = enum { keep, copy, skip, pretty, @"write-pretty", @"seq-read", @"seq-write", @"write-bounded", @"object-open", route, @"route-tag", leading, control, split, @"resume", hook, versioned, carried, backward, follow, @"file-id", sync, oversized };
    const which = std.meta.stringToEnum(Mode, mode) orelse return false;
    const arg = args[0];
    switch (which) {
        .keep => try keep(init, arg, out),
        .copy => if (comptime @hasDecl(strand, "copyOwned")) try copy(init, arg, out) else return error.Unavailable,
        .skip => try skip(init, arg, out),
        .pretty => try readFormatted(init, arg, out, .pretty),
        .@"seq-read" => try readFormatted(init, arg, out, .separated),
        .@"write-pretty" => try writeFormatted(init, arg, out, .pretty),
        .@"seq-write" => try writeFormatted(init, arg, out, .separated),
        .@"write-bounded" => if (comptime @hasDecl(strand.Writer(Record), "initFileBounded")) try writeBounded(init, arg, out) else return error.Unavailable,
        .@"object-open" => if (comptime @hasDecl(strand, "writeObjectOpen")) try objectOpen(init, arg, out) else return error.Unavailable,
        .route => try route(init, arg, out),
        .@"route-tag" => try routeTag(init, arg, out),
        .leading => if (comptime @hasDecl(strand, "leadingIntMembers")) try leading(init, arg, out) else return error.Unavailable,
        .control => try control(init, arg, out),
        .split => try split(init, arg, out),
        .@"resume" => try resumeAt(init, arg, out),
        .hook => if (comptime @hasDecl(strand, "innerParse")) try hook(init, arg, out) else return error.Unavailable,
        .versioned => try versioned(init, out),
        .carried => try carried(init, arg, out),
        .backward => try backward(init, arg, out),
        .follow => try follow(init, arg, args[1], out),
        .@"file-id" => try fileId(init, arg, out),
        .sync => try sync(init, arg, out),
        .oversized => try oversized(init, arg, out),
    }
    return true;
}

fn reps(full: usize) usize {
    return if (smoke) 1 else full;
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).size;
}

/// `Reader.next` and `Reader.keep` for every record, the kept values living
/// 1024 records at a time.
fn keep(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sum: u64 = 0;
    var lines: u64 = 0;
    var held: usize = 0;
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const started = common.now(io);
    for (0..reps(2)) |_| {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Record) = .init(gpa, &fr.interface, .{ .max_line_bytes = 2 << 20 });
        defer r.deinit();
        while (try r.next()) |line| {
            const v = try r.keep(arena.allocator(), line);
            sum += v.count + v.message.len + v.tags.len + v.meta.region.len;
            lines += 1;
            held += 1;
            if (held == 1024) {
                _ = arena.reset(.retain_capacity);
                held = 0;
            }
        }
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "keep", lines, elapsed);
    try common.megabytes(out, side, "keep", size * reps(2), elapsed);
    try common.check(out, side, "keep", "lines", lines);
    try common.check(out, side, "keep", "sum", sum);
}

/// `copyOwned` and `freeOwned` over values already parsed: the copy alone.
fn copy(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var values: std.ArrayList(Record) = .empty;
    defer values.deinit(gpa);
    {
        const buf = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(buf);
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Record) = .init(gpa, &fr.interface, .{ .max_line_bytes = 2 << 20 });
        defer r.deinit();
        while (try r.next()) |line| {
            try values.append(gpa, try r.keep(arena.allocator(), line));
            if (values.items.len == 100_000) break;
        }
    }
    var sum: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (values.items) |v| {
        const c = try strand.copyOwned(gpa, v);
        sum += c.count + c.message.len + c.tags.len + c.meta.region.len;
        strand.freeOwned(gpa, c);
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "copy", values.items.len * rounds, elapsed);
    try common.check(out, side, "copy", "sum", sum);
}

/// A log with damaged lines, read with `on_malformed = .skip`.
fn skip(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    var sum: u64 = 0;
    var lines: u64 = 0;
    var skipped: u64 = 0;
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const started = common.now(io);
    for (0..reps(2)) |_| {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Record) = .init(gpa, &fr.interface, .{ .max_line_bytes = 2 << 20, .on_malformed = .skip });
        defer r.deinit();
        while (try r.next()) |line| {
            sum += line.value.count;
            lines += 1;
        }
        skipped += r.lines.skipped;
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "skip-malformed", lines + skipped, elapsed);
    try common.megabytes(out, side, "skip-malformed", size * reps(2), elapsed);
    try common.check(out, side, "skip-malformed", "lines", lines);
    try common.check(out, side, "skip-malformed", "skipped", skipped);
    try common.check(out, side, "skip-malformed", "sum", sum);
}

const Layout = enum { pretty, separated };

fn readFormatted(init: Init, path: []const u8, out: *std.Io.Writer, comptime layout: Layout) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const work = if (layout == .pretty) "pretty-read" else "seq-read";
    const size = try fileSize(io, path);
    var sum: u64 = 0;
    var lines: u64 = 0;
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const started = common.now(io);
    {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Record) = .init(gpa, &fr.interface, .{
            .max_line_bytes = 2 << 20,
            .format = if (layout == .pretty) .pretty else .minified,
            .record_separator = layout == .separated,
        });
        defer r.deinit();
        while (try r.next()) |line| {
            sum += line.value.count;
            lines += 1;
        }
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, work, lines, elapsed);
    try common.megabytes(out, side, work, size, elapsed);
    try common.check(out, side, work, "lines", lines);
    try common.check(out, side, work, "sum", sum);
}

fn writeFormatted(init: Init, path: []const u8, out: *std.Io.Writer, comptime layout: Layout) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const work = if (layout == .pretty) "write-pretty" else "seq-write";
    const n: usize = if (smoke) 1 else if (layout == .pretty) 200_000 else 1_000_000;
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fw = file.writer(io, buf);
    var w: strand.Writer(Record) = .initFile(&fw, .{
        .format = if (layout == .pretty) .pretty else .minified,
        .record_separator = layout == .separated,
    });
    const started = common.now(io);
    for (0..n) |i| try w.write(common.sample(i));
    try fw.interface.flush();
    const elapsed = common.ns(io, started);
    try common.rate(out, side, work, n, elapsed);
    try common.megabytes(out, side, work, (try file.stat(io)).size, elapsed);
}

fn writeBounded(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const n: usize = if (smoke) 1 else 1_000_000;
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fw = file.writer(io, buf);
    var w: strand.Writer(Record) = .initFileBounded(gpa, &fw, 4096, .{});
    defer w.deinit();
    const started = common.now(io);
    for (0..n) |i| try w.write(common.sample(i));
    try fw.interface.flush();
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "write-bounded", n, elapsed);
    try common.megabytes(out, side, "write-bounded", (try file.stat(io)).size, elapsed);
}

/// A record written open, one member added after it (`c`, the length of the
/// object so far), then closed: the shape of a checksummed envelope.
fn objectOpen(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const n: usize = if (smoke) 1 else 1_000_000;
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fw = file.writer(io, buf);
    var record: std.Io.Writer.Allocating = .init(gpa);
    defer record.deinit();
    try record.ensureUnusedCapacity(4096);
    const started = common.now(io);
    for (0..n) |i| {
        record.clearRetainingCapacity();
        var object = try strand.writeObjectOpen(&record.writer, common.sample(i), .{});
        const so_far = record.written().len;
        try object.member("c", so_far);
        try object.close();
        try record.writer.writeByte('\n');
        try fw.interface.writeAll(record.written());
    }
    try fw.interface.flush();
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "object-open", n, elapsed);
    try common.megabytes(out, side, "object-open", (try file.stat(io)).size, elapsed);
}

fn route(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var hits: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        const key = strand.kindOf(line) orelse continue;
        if (std.mem.eql(u8, key, "id")) hits += 1;
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "route-kind", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "route-kind", "hits", hits);
}

fn routeTag(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var counts: [3]u64 = .{ 0, 0, 0 };
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        const tag = strand.tagOf(Tagged, line) orelse continue;
        counts[@intFromEnum(tag)] += 1;
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "route-tag", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "route-tag", "open", counts[0]);
    try common.check(out, side, "route-tag", "retry", counts[1]);
    try common.check(out, side, "route-tag", "close", counts[2]);
}

fn leading(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var sum: u64 = 0;
    const rounds = reps(4);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        const got = strand.leadingIntMembers(struct { id: u64 }, line) orelse return error.NotLeading;
        sum += got.value.id;
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "leading-ints", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "leading-ints", "sum", sum);
}

fn control(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var hits: u64 = 0;
    var scanned: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        if (strand.indexOfControl(line)) |at| {
            hits += 1;
            scanned += at;
        } else scanned += line.len;
    };
    const elapsed = common.ns(io, started);
    try common.megabytes(out, side, "control-scan", scanned, elapsed);
    try common.rate(out, side, "control-scan", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "control-scan", "hits", hits);
    try common.check(out, side, "control-scan", "scanned", scanned);
}

fn split(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var lines: u64 = 0;
    var bytes: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| {
        var it = strand.lines(loaded.bytes);
        while (it.next()) |line| {
            lines += 1;
            bytes += line.line.len;
        }
    }
    const elapsed = common.ns(io, started);
    try common.megabytes(out, side, "split-lines", loaded.bytes.len * rounds, elapsed);
    try common.check(out, side, "split-lines", "lines", lines);
    try common.check(out, side, "split-lines", "bytes", bytes);
}

/// `Reader.resumeAt` at every hundredth line start, last first, one record
/// read each.
fn resumeAt(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const starts = blk: {
        var loaded: common.Loaded = try .init(gpa, io, path);
        defer loaded.deinit(gpa);
        break :blk try common.offsets(gpa, loaded.bytes, 100);
    };
    defer gpa.free(starts);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    var sum: u64 = 0;
    const started = common.now(io);
    // Last place first: every seek lands outside what the last read
    // buffered, so every side reads afresh.
    var k = starts.len;
    while (k > 0) {
        k -= 1;
        const offset = starts[k];
        try fr.seekTo(offset);
        var r: strand.Reader(Record) = .resumeAt(gpa, &fr.interface, .{ .max_line_bytes = 2 << 20 }, .{ .offset = offset, .lines_before = k * 100 });
        defer r.deinit();
        const line = (try r.next()) orelse return error.NoLine;
        sum += line.value.id;
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "resume", starts.len, elapsed);
    try common.check(out, side, "resume", "sum", sum);
}

/// A type whose own `jsonParse` delegates its fields to `innerParse`.
const Hooked = struct {
    inner: Record,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Hooked {
        return .{ .inner = try strand.innerParse(Record, allocator, source, options) };
    }
};

fn hook(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    var sum: u64 = 0;
    var lines: u64 = 0;
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const started = common.now(io);
    for (0..reps(2)) |_| {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Hooked) = .init(gpa, &fr.interface, .{ .max_line_bytes = 2 << 20 });
        defer r.deinit();
        while (try r.next()) |line| {
            sum += line.value.inner.count;
            lines += 1;
        }
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "custom-hook", lines, elapsed);
    try common.megabytes(out, side, "custom-hook", size * reps(2), elapsed);
    try common.check(out, side, "custom-hook", "lines", lines);
    try common.check(out, side, "custom-hook", "sum", sum);
}

const EventV1 = struct {
    kind: []const u8,
    at: u64,
    pub const jsonl_version: u32 = 1;
};

const EventV2 = struct {
    kind: []const u8,
    at: u64,
    level: u8 = 0,
    pub const jsonl_version: u32 = 2;
    pub fn jsonlMigrate(allocator: std.mem.Allocator, from: u32, data: std.json.Value) std.json.ParseFromValueError!EventV2 {
        if (from != 1) return error.UnknownField;
        const old = try strand.payloadOf(EventV1, allocator, data);
        return .{ .kind = old.kind, .at = old.at, .level = 1 };
    }
};

/// `Versioned` written, then read back with every other line one version
/// old and migrated.
fn versioned(init: Init, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const n: usize = if (smoke) 2 else 1_000_000;
    var current: std.Io.Writer.Allocating = .init(gpa);
    defer current.deinit();
    try current.ensureUnusedCapacity(n * 64);
    var w: strand.Writer(strand.Versioned(EventV2)) = .init(&current.writer, .{});
    const write_started = common.now(io);
    for (0..n) |i| try w.write(.{ .value = .{ .kind = "request", .at = i } });
    const write_elapsed = common.ns(io, write_started);
    try common.rate(out, side, "versioned-write", n, write_elapsed);

    var mixed: std.Io.Writer.Allocating = .init(gpa);
    defer mixed.deinit();
    var old: strand.Writer(strand.Versioned(EventV1)) = .init(&mixed.writer, .{});
    var new: strand.Writer(strand.Versioned(EventV2)) = .init(&mixed.writer, .{});
    for (0..n) |i| {
        if (i % 2 == 0) try old.write(.{ .value = .{ .kind = "request", .at = i } }) else try new.write(.{ .value = .{ .kind = "request", .at = i } });
    }
    var source: std.Io.Reader = .fixed(mixed.written());
    var r: strand.Reader(strand.Versioned(EventV2)) = .init(gpa, &source, .{});
    defer r.deinit();
    var migrated: u64 = 0;
    var sum: u64 = 0;
    const started = common.now(io);
    while (try r.next()) |line| {
        if (line.value.migrated()) migrated += 1;
        sum += line.value.value.at + line.value.value.level;
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "versioned-read", n, elapsed);
    try common.check(out, side, "versioned-read", "migrated", migrated);
    try common.check(out, side, "versioned-read", "sum", sum);
}

fn Carried(comptime Payload: type) type {
    return struct { kind: []const u8, at: u64, data: Payload };
}

/// Lines carrying an object nobody reads, held as `Raw`; then `Raw.parse`
/// of each held value, and `Raw.encode` of a value.
fn carried(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    var at_sum: u64 = 0;
    var data_bytes: u64 = 0;
    var lines: u64 = 0;
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const started = common.now(io);
    {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Carried(strand.Raw)) = .init(gpa, &fr.interface, .{});
        defer r.deinit();
        while (try r.next()) |line| {
            at_sum += line.value.at;
            data_bytes += line.value.data.bytes.len;
            lines += 1;
        }
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "carried", lines, elapsed);
    try common.megabytes(out, side, "carried", size, elapsed);
    try common.check(out, side, "carried", "at", at_sum);
    try common.check(out, side, "carried", "data_bytes", data_bytes);

    // The carried values, held (untimed) for `Raw.parse`.
    {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, buf);
        var r: strand.Reader(Carried(strand.Raw)) = .init(gpa, &fr.interface, .{});
        defer r.deinit();
        while (try r.next()) |line| {
            try held.appendSlice(gpa, line.value.data.bytes);
            try ends.append(gpa, held.items.len);
            if (ends.items.len == 200_000) break;
        }
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var beats: u64 = 0;
    const parse_started = common.now(io);
    var from: usize = 0;
    for (ends.items) |end| {
        _ = arena.reset(.retain_capacity);
        const raw: strand.Raw = .{ .bytes = held.items[from..end] };
        const value = try raw.parse(Data, arena.allocator(), .{});
        beats += value.beat + value.tags.len;
        from = end;
    }
    const parse_elapsed = common.ns(io, parse_started);
    try common.rate(out, side, "raw-parse", ends.items.len, parse_elapsed);
    try common.check(out, side, "raw-parse", "sum", beats);

    var encoded: u64 = 0;
    const encode_started = common.now(io);
    for (0..ends.items.len) |i| {
        const raw = try strand.Raw.encode(gpa, Data{ .who = "ada", .beat = i % 7, .tags = &.{ "a", "b" } });
        encoded += raw.bytes.len;
        gpa.free(raw.bytes);
    }
    const encode_elapsed = common.ns(io, encode_started);
    try common.rate(out, side, "raw-encode", ends.items.len, encode_elapsed);
    try common.check(out, side, "raw-encode", "bytes", encoded);
}

/// The whole file read backwards, typed (`Tail.prev`) and as bytes
/// (`Tail.prevRaw`).
fn backward(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    {
        var fr = file.reader(io, &buf);
        var t: strand.Tail(Record) = try .init(gpa, &fr, .{ .max_line_bytes = 2 << 20 });
        defer t.deinit();
        var sum: u64 = 0;
        var lines: u64 = 0;
        const started = common.now(io);
        while (try t.prev()) |line| {
            sum += line.value.count;
            lines += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "backward", lines, elapsed);
        try common.megabytes(out, side, "backward", size, elapsed);
        try common.check(out, side, "backward", "lines", lines);
        try common.check(out, side, "backward", "sum", sum);
    }
    {
        var fr = file.reader(io, &buf);
        var t: strand.Tail(Record) = try .init(gpa, &fr, .{ .max_line_bytes = 2 << 20 });
        defer t.deinit();
        var bytes: u64 = 0;
        var lines: u64 = 0;
        const started = common.now(io);
        while (try t.prevRaw()) |line| {
            bytes += line.line.len;
            lines += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "backward-raw", lines, elapsed);
        try common.megabytes(out, side, "backward-raw", size, elapsed);
        try common.check(out, side, "backward-raw", "lines", lines);
        try common.check(out, side, "backward-raw", "bytes", bytes);
    }
}

/// What a follower is told by the producer: which record was sent when.
const Handoff = struct {
    sent_at: std.atomic.Value(i64) = .init(0),
    acked: std.atomic.Value(u64) = .init(0),
    latency: u64 = 0,
};

fn stamp(io: std.Io) i64 {
    return @intCast(common.now(io).nanoseconds);
}

fn consume(io: std.Io, gpa: std.mem.Allocator, source: *std.Io.File.Reader, options: strand.Follower(Record).Options, count: u64, handoff: *Handoff) !void {
    var follower: strand.Follower(Record) = .init(gpa, io, source, options);
    defer follower.deinit();
    for (0..count) |i| {
        const line = try follower.next();
        if (line.value.id != i) return error.WrongRecord;
        handoff.latency += @intCast(@max(stamp(io) - handoff.sent_at.load(.acquire), 0));
        handoff.acked.store(i + 1, .release);
    }
}

fn consumeRotating(io: std.Io, gpa: std.mem.Allocator, source: *std.Io.File.Reader, options: strand.Follower(Record).Options, count: u64, handoff: *Handoff) !void {
    var follower: strand.Follower(Record) = .init(gpa, io, source, options);
    defer follower.deinit();
    for (0..count) |i| {
        const line = try follower.next();
        if (line.value.id != i) return error.WrongRecord;
        handoff.latency += @intCast(@max(stamp(io) - handoff.sent_at.load(.acquire), 0));
        handoff.acked.store(i + 1, .release);
    }
    if (follower.rotations != count) return error.MissedRotation;
}

fn recordLine(gpa: std.mem.Allocator, i: u64) ![]u8 {
    var rec = common.sample(i);
    rec.id = i;
    var line: std.Io.Writer.Allocating = .init(gpa);
    errdefer line.deinit();
    try strand.writeLine(&line.writer, rec);
    return line.toOwnedSlice();
}

fn waitAck(handoff: *Handoff, want: u64) void {
    while (handoff.acked.load(.acquire) < want) std.atomic.spinLoopHint();
}

/// A follower catching up on a file, then woken (or polling) for lines
/// appended one at a time, then following the path across rotations.
fn follow(init: Init, dir_path: []const u8, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    // Catch-up: every line already in the file.
    {
        var loaded: common.Loaded = try .init(gpa, io, path);
        const total = loaded.lines.len;
        loaded.deinit(gpa);
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const buf = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(buf);
        var fr = file.reader(io, buf);
        var follower: strand.Follower(Record) = .init(gpa, io, &fr, .{ .reader = .{ .max_line_bytes = 2 << 20 } });
        defer follower.deinit();
        var sum: u64 = 0;
        const started = common.now(io);
        for (0..total) |_| sum += (try follower.next()).value.count;
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "follow-catchup", total, elapsed);
        try common.check(out, side, "follow-catchup", "lines", total);
        try common.check(out, side, "follow-catchup", "sum", sum);

        // A checkpoint taken and resumed from, as a restarted reader does.
        const rounds = reps(1000);
        const resume_started = common.now(io);
        for (0..rounds) |_| {
            const point = try follower.checkpoint();
            var again: strand.Follower(Record) = try .resumeFrom(gpa, io, &fr, .{}, point);
            again.deinit();
        }
        const resume_elapsed = common.ns(io, resume_started);
        try common.rate(out, side, "follow-checkpoint", rounds, resume_elapsed);
    }
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    var event: std.Io.Event = .unset;
    inline for (.{ "follow-append-wake", "follow-append-poll" }, 0..) |work, which| {
        const count: u64 = if (smoke) 2 else if (which == 0) 1000 else 50;
        const writer_file = try dir.createFile(io, "append.jsonl", .{});
        defer writer_file.close(io);
        const file = try dir.openFile(io, "append.jsonl", .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var handoff: Handoff = .{};
        const options: strand.Follower(Record).Options = .{ .wait = if (which == 0) .{ .wake = .{ .event = &event } } else .{ .poll = .fromMilliseconds(20) } };
        var task = try io.concurrent(consume, .{ io, gpa, &fr, options, count, &handoff });
        var offset: u64 = 0;
        for (0..count) |i| {
            const line = try recordLine(gpa, i);
            defer gpa.free(line);
            handoff.sent_at.store(stamp(io), .release);
            try writer_file.writePositionalAll(io, line, offset);
            offset += line.len;
            if (which == 0) event.set(io);
            waitAck(&handoff, i + 1);
        }
        try task.await(io);
        try common.report(out, side, work, "latency", @as(f64, @floatFromInt(handoff.latency)) / @as(f64, @floatFromInt(count)) / 1e3, "us");
        try common.check(out, side, work, "lines", count);
    }
    // Rotation: the path renamed away and created again, one line each.
    {
        const count: u64 = if (smoke) 1 else 5;
        {
            const first = try dir.createFile(io, "rotate.jsonl", .{});
            first.close(io);
        }
        const file = try dir.openFile(io, "rotate.jsonl", .{});
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var opener: strand.PathOpener = .{ .dir = dir, .sub_path = "rotate.jsonl" };
        var handoff: Handoff = .{};
        const options: strand.Follower(Record).Options = .{ .wait = .{ .poll = .fromMilliseconds(20) }, .reopen = opener.opener() };
        var task = try io.concurrent(consumeRotating, .{ io, gpa, &fr, options, count, &handoff });
        for (0..count) |i| {
            const line = try recordLine(gpa, i);
            defer gpa.free(line);
            try dir.rename("rotate.jsonl", dir, "rotate.jsonl.1", io);
            const next = try dir.createFile(io, "rotate.jsonl", .{});
            handoff.sent_at.store(stamp(io), .release);
            try next.writePositionalAll(io, line, 0);
            next.close(io);
            waitAck(&handoff, i + 1);
        }
        try task.await(io);
        file.close(io);
        try common.report(out, side, "follow-rotate", "latency", @as(f64, @floatFromInt(handoff.latency)) / @as(f64, @floatFromInt(count)) / 1e3, "us");
        try common.check(out, side, "follow-rotate", "lines", count);
    }
}

/// The identity a follower takes by default: `.file_id`, named `.inode`
/// before the pin moved.
const plain_identity: strand.Identity = if (@hasField(strand.Identity, "file_id")) .file_id else .inode;

/// File identity: by handle, by path, and as a follower takes it.
fn fileId(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io = init.io;
    const rounds = reps(100_000);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const first = try strand.FileId.of(file.handle);
    {
        var same: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |_| {
            if ((try strand.FileId.of(file.handle)).eql(first)) same += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "file-id", rounds, elapsed);
        try common.check(out, side, "file-id", "same", same);
    }
    if (comptime @hasDecl(strand.FileId, "ofPath")) {
        const dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path).?, .{});
        defer dir.close(io);
        const name = std.fs.path.basename(path);
        var same: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |_| {
            if ((try strand.FileId.ofPath(io, dir, name)).eql(first)) same += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "file-id-path", rounds, elapsed);
        try common.check(out, side, "file-id-path", "same", same);
    }
    inline for (.{ "identity-take", "identity-fingerprint" }, .{ plain_identity, strand.Identity{ .fingerprint = .{} } }) |work, tag| {
        const identity: strand.Identity = tag;
        const held = try identity.take(io, file);
        var same: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |_| {
            if ((try identity.take(io, file)).eql(held)) same += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, work, rounds, elapsed);
        try common.check(out, side, work, "same", same);
    }
}

/// Appends of 128 bytes, each followed by a sync at each level.
fn sync(init: Init, dir_path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const rounds = reps(100);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    const chunk = "x" ** 127 ++ "\n";
    inline for (.{ "sync-data", "sync-all" }, .{ strand.SyncLevel.data, strand.SyncLevel.all }) |work, level| {
        const file = try dir.createFile(io, "sync.dat", .{});
        defer file.close(io);
        var kinds: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |i| {
            try file.writePositionalAll(io, chunk, i * chunk.len);
            if (try strand.syncFile(file, io, level) == .full) kinds += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, work, rounds, elapsed);
        try common.check(out, side, work, "full", kinds);
    }
    if (comptime @hasDecl(strand, "syncDir")) {
        const started = common.now(io);
        for (0..rounds) |_| _ = try strand.syncDir(dir, io);
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "sync-dir", rounds, elapsed);
    }
    {
        const file = try dir.createFile(io, "writer-sync.jsonl", .{});
        defer file.close(io);
        const buf = try gpa.alloc(u8, 64 * 1024);
        defer gpa.free(buf);
        var fw = file.writer(io, buf);
        var w: strand.Writer(Record) = .initFile(&fw, .{ .sync = .per_record });
        const started = common.now(io);
        for (0..rounds) |i| try w.write(common.sample(i));
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "writer-sync", rounds, elapsed);
        try common.check(out, side, "writer-sync", "records", w.count);
    }
}

/// Every line over the bound: refused, read past, and (where the snapshot
/// can) its `id` kept from the refused bytes.
fn oversized(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    const Options = strand.Reader(Record).Options;
    inline for (.{ "oversized", "oversized-member" }, 0..) |work, which| {
        if (which == 0 or comptime @hasField(Options, "oversized_member")) {
            var options: Options = .{ .max_line_bytes = 512 };
            if (which == 1) options.oversized_member = "id";
            const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
            defer file.close(io);
            var fr = file.reader(io, buf);
            var r: strand.Reader(Record) = .init(gpa, &fr.interface, options);
            defer r.deinit();
            var refused: u64 = 0;
            var ids: u64 = 0;
            const started = common.now(io);
            while (true) {
                const line = r.next() catch |err| switch (err) {
                    error.LineTooLong => {
                        refused += 1;
                        if (which == 1) {
                            if (r.lines.oversizedMember()) |member| ids += try std.fmt.parseInt(u64, member.bytes, 10);
                        }
                        continue;
                    },
                    else => return err,
                };
                if (line == null) break;
            }
            const elapsed = common.ns(io, started);
            try common.rate(out, side, work, refused, elapsed);
            try common.megabytes(out, side, work, size, elapsed);
            try common.check(out, side, work, "refused", refused);
            if (which == 1) try common.check(out, side, work, "ids", ids);
        }
    }
}
