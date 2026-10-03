//! The same operations as zig_cover.zig with what `std` offers instead.
//! Rows and checksums are named as strand's are, so the harness compares them.
const std = @import("std");
const common = @import("zig_common.zig");
const Record = common.Record;
const Tagged = common.Tagged;
const Data = common.Data;
const smoke = @import("bench_options").smoke;
const Init = std.process.Init;
const side = "zig-std-json";

pub fn run(init: Init, mode: []const u8, args: []const [:0]const u8, out: *std.Io.Writer) !bool {
    const Mode = enum { keep, skip, @"write-pretty", @"object-open", route, @"route-tag", leading, control, split, @"resume", hook, carried, @"file-id", sync };
    const which = std.meta.stringToEnum(Mode, mode) orelse return false;
    const arg = args[0];
    switch (which) {
        .keep => try readOwned(init, arg, out),
        .skip => try skip(init, arg, out),
        .@"write-pretty" => try writePretty(init, arg, out),
        .@"object-open" => try objectOpen(init, arg, out),
        .route => try route(init, arg, out),
        .@"route-tag" => try routeTag(init, arg, out),
        .leading => try leading(init, arg, out),
        .control => try control(init, arg, out),
        .split => try split(init, arg, out),
        .@"resume" => try resumeAt(init, arg, out),
        .hook => try hook(init, arg, out),
        .carried => try carried(init, arg, out),
        .@"file-id" => try fileId(init, arg, out),
        .sync => try sync(init, arg, out),
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

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };

/// Lines framed by the file reader and handed to `body` with an arena reset
/// per line, as the existing typed-read side does.
fn eachLine(init: Init, path: []const u8, ctx: anytype, comptime body: fn (@TypeOf(ctx), std.mem.Allocator, []const u8) anyerror!void) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fr = file.reader(io, buf);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (fr.interface.takeDelimiterInclusive('\n')) |framed| {
        _ = arena.reset(.retain_capacity);
        try body(ctx, arena.allocator(), framed[0 .. framed.len - 1]);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

/// Every record parsed with every string copied (`alloc_always`), the values
/// living 1024 records at a time: what `Reader.keep` leaves the caller.
fn readOwned(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    const State = struct {
        kept: std.heap.ArenaAllocator,
        held: usize = 0,
        sum: u64 = 0,
        lines: u64 = 0,
        fn body(s: *@This(), _: std.mem.Allocator, line: []const u8) !void {
            const v = try std.json.parseFromSliceLeaky(Record, s.kept.allocator(), line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            s.sum += v.count + v.message.len + v.tags.len + v.meta.region.len;
            s.lines += 1;
            s.held += 1;
            if (s.held == 1024) {
                _ = s.kept.reset(.retain_capacity);
                s.held = 0;
            }
        }
    };
    var state: State = .{ .kept = .init(gpa) };
    defer state.kept.deinit();
    const started = common.now(io);
    for (0..reps(2)) |_| try eachLine(init, path, &state, State.body);
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "keep", state.lines, elapsed);
    try common.megabytes(out, side, "keep", size * reps(2), elapsed);
    try common.check(out, side, "keep", "lines", state.lines);
    try common.check(out, side, "keep", "sum", state.sum);
}

fn skip(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io = init.io;
    const size = try fileSize(io, path);
    const State = struct {
        sum: u64 = 0,
        lines: u64 = 0,
        skipped: u64 = 0,
        fn body(s: *@This(), arena: std.mem.Allocator, line: []const u8) !void {
            const v = std.json.parseFromSliceLeaky(Record, arena, line, parse_options) catch {
                s.skipped += 1;
                return;
            };
            s.sum += v.count;
            s.lines += 1;
        }
    };
    var state: State = .{};
    const started = common.now(io);
    for (0..reps(2)) |_| try eachLine(init, path, &state, State.body);
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "skip-malformed", state.lines + state.skipped, elapsed);
    try common.megabytes(out, side, "skip-malformed", size * reps(2), elapsed);
    try common.check(out, side, "skip-malformed", "lines", state.lines);
    try common.check(out, side, "skip-malformed", "skipped", state.skipped);
    try common.check(out, side, "skip-malformed", "sum", state.sum);
}

fn writePretty(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const n: usize = if (smoke) 1 else 200_000;
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    var fw = file.writer(io, buf);
    const started = common.now(io);
    for (0..n) |i| {
        try std.json.Stringify.value(common.sample(i), .{ .whitespace = .indent_2 }, &fw.interface);
        try fw.interface.writeByte('\n');
    }
    try fw.interface.flush();
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "write-pretty", n, elapsed);
    try common.megabytes(out, side, "write-pretty", (try file.stat(io)).size, elapsed);
}

/// The record's members written one by one through `Stringify`, then `c`.
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
        var jw: std.json.Stringify = .{ .writer = &record.writer, .options = .{} };
        const value = common.sample(i);
        try jw.beginObject();
        inline for (@typeInfo(Record).@"struct".fields) |field| {
            try jw.objectField(field.name);
            try jw.write(@field(value, field.name));
        }
        const so_far = record.written().len;
        try jw.objectField("c");
        try jw.write(so_far);
        try jw.endObject();
        try record.writer.writeByte('\n');
        try fw.interface.writeAll(record.written());
    }
    try fw.interface.flush();
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "object-open", n, elapsed);
    try common.megabytes(out, side, "object-open", (try file.stat(io)).size, elapsed);
}

/// The first key, from `std.json.Scanner`'s first two tokens.
fn firstKey(scanner: *std.json.Scanner) ?[]const u8 {
    if ((scanner.next() catch return null) != .object_begin) return null;
    return switch (scanner.next() catch return null) {
        .string => |s| s,
        else => null,
    };
}

fn route(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var hits: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        var scanner: std.json.Scanner = .initCompleteInput(gpa, line);
        defer scanner.deinit();
        const key = firstKey(&scanner) orelse continue;
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
        var scanner: std.json.Scanner = .initCompleteInput(gpa, line);
        defer scanner.deinit();
        const key = firstKey(&scanner) orelse continue;
        const tag = std.meta.stringToEnum(std.meta.Tag(Tagged), key) orelse continue;
        counts[@intFromEnum(tag)] += 1;
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "route-tag", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "route-tag", "open", counts[0]);
    try common.check(out, side, "route-tag", "retry", counts[1]);
    try common.check(out, side, "route-tag", "close", counts[2]);
}

/// The leading `id`, by parsing the line into a struct holding only it.
fn leading(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sum: u64 = 0;
    const rounds = reps(4);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        _ = arena.reset(.retain_capacity);
        const v = try std.json.parseFromSliceLeaky(struct { id: u64 }, arena.allocator(), line, parse_options);
        sum += v.id;
    };
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "leading-ints", loaded.lines.len * rounds, elapsed);
    try common.check(out, side, "leading-ints", "sum", sum);
}

const controls = blk: {
    var set: [31]u8 = undefined;
    var n: usize = 0;
    for (0..0x20) |b| if (b != '\t') {
        set[n] = b;
        n += 1;
    };
    break :blk set;
};

fn control(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    var loaded: common.Loaded = try .init(gpa, io, path);
    defer loaded.deinit(gpa);
    var hits: u64 = 0;
    var scanned: u64 = 0;
    const rounds = reps(10);
    const started = common.now(io);
    for (0..rounds) |_| for (loaded.lines) |line| {
        if (std.mem.indexOfAny(u8, line, &controls)) |at| {
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
        // A buffer ending in a terminator yields an empty last piece.
        const body = if (std.mem.endsWith(u8, loaded.bytes, "\n")) loaded.bytes[0 .. loaded.bytes.len - 1] else loaded.bytes;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            lines += 1;
            bytes += line.len;
        }
    }
    const elapsed = common.ns(io, started);
    try common.megabytes(out, side, "split-lines", loaded.bytes.len * rounds, elapsed);
    try common.check(out, side, "split-lines", "lines", lines);
    try common.check(out, side, "split-lines", "bytes", bytes);
}

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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sum: u64 = 0;
    const started = common.now(io);
    var k = starts.len;
    while (k > 0) {
        k -= 1;
        const offset = starts[k];
        try fr.seekTo(offset);
        _ = arena.reset(.retain_capacity);
        const framed = try fr.interface.takeDelimiterInclusive('\n');
        const v = try std.json.parseFromSliceLeaky(Record, arena.allocator(), framed[0 .. framed.len - 1], parse_options);
        sum += v.id;
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "resume", starts.len, elapsed);
    try common.check(out, side, "resume", "sum", sum);
}

const Hooked = struct {
    inner: Record,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Hooked {
        return .{ .inner = try std.json.innerParse(Record, allocator, source, options) };
    }
};

fn hook(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io = init.io;
    const size = try fileSize(io, path);
    const State = struct {
        sum: u64 = 0,
        lines: u64 = 0,
        fn body(s: *@This(), arena: std.mem.Allocator, line: []const u8) !void {
            const v = try std.json.parseFromSliceLeaky(Hooked, arena, line, parse_options);
            s.sum += v.inner.count;
            s.lines += 1;
        }
    };
    var state: State = .{};
    const started = common.now(io);
    for (0..reps(2)) |_| try eachLine(init, path, &state, State.body);
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "custom-hook", state.lines, elapsed);
    try common.megabytes(out, side, "custom-hook", size * reps(2), elapsed);
    try common.check(out, side, "custom-hook", "lines", state.lines);
    try common.check(out, side, "custom-hook", "sum", state.sum);
}

/// The carried object as `std.json.Value`, std's only "hold it unread"
/// type (it builds the tree); then a parse of held bytes into the type and
/// an encode of a value into fresh bytes.
fn carried(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io, const gpa = .{ init.io, init.gpa };
    const size = try fileSize(io, path);
    const State = struct {
        at: u64 = 0,
        lines: u64 = 0,
        fn body(s: *@This(), arena: std.mem.Allocator, line: []const u8) !void {
            const v = try std.json.parseFromSliceLeaky(struct { kind: []const u8, at: u64, data: std.json.Value }, arena, line, parse_options);
            s.at += v.at;
            s.lines += 1;
        }
    };
    var state: State = .{};
    const started = common.now(io);
    try eachLine(init, path, &state, State.body);
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "carried", state.lines, elapsed);
    try common.megabytes(out, side, "carried", size, elapsed);
    try common.check(out, side, "carried", "at", state.at);

    // The same held bytes strand's side parses: each line's `data` member.
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(gpa);
    {
        var loaded: common.Loaded = try .init(gpa, io, path);
        defer loaded.deinit(gpa);
        for (loaded.lines) |line| {
            const from = std.mem.indexOf(u8, line, "\"data\":").? + "\"data\":".len;
            try held.appendSlice(gpa, line[from .. line.len - 1]);
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
        const value = try std.json.parseFromSliceLeaky(Data, arena.allocator(), held.items[from..end], parse_options);
        beats += value.beat + value.tags.len;
        from = end;
    }
    const parse_elapsed = common.ns(io, parse_started);
    try common.rate(out, side, "raw-parse", ends.items.len, parse_elapsed);
    try common.check(out, side, "raw-parse", "sum", beats);

    var encoded: u64 = 0;
    const encode_started = common.now(io);
    for (0..ends.items.len) |i| {
        const bytes = try std.json.Stringify.valueAlloc(gpa, Data{ .who = "ada", .beat = i % 7, .tags = &.{ "a", "b" } }, .{});
        encoded += bytes.len;
        gpa.free(bytes);
    }
    const encode_elapsed = common.ns(io, encode_started);
    try common.rate(out, side, "raw-encode", ends.items.len, encode_elapsed);
    try common.check(out, side, "raw-encode", "bytes", encoded);
}

/// `File.stat` and `Dir.statFile`: the inode, which is what std exposes.
fn fileId(init: Init, path: []const u8, out: *std.Io.Writer) !void {
    const io = init.io;
    const rounds = reps(100_000);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const first = (try file.stat(io)).inode;
    {
        var same: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |_| {
            if ((try file.stat(io)).inode == first) same += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "file-id", rounds, elapsed);
        try common.check(out, side, "file-id", "same", same);
    }
    {
        const dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path).?, .{});
        defer dir.close(io);
        const name = std.fs.path.basename(path);
        var same: u64 = 0;
        const started = common.now(io);
        for (0..rounds) |_| {
            if ((try dir.statFile(io, name, .{})).inode == first) same += 1;
        }
        const elapsed = common.ns(io, started);
        try common.rate(out, side, "file-id-path", rounds, elapsed);
        try common.check(out, side, "file-id-path", "same", same);
    }
}

/// `std.Io.File.sync`: `fsync`, which on Darwin does not wait for the media
/// (strand asks for `F_FULLFSYNC` there). Reported, not equal work.
fn sync(init: Init, dir_path: []const u8, out: *std.Io.Writer) !void {
    const io = init.io;
    const rounds = reps(100);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    const chunk = "x" ** 127 ++ "\n";
    const file = try dir.createFile(io, "std-sync.dat", .{});
    defer file.close(io);
    const started = common.now(io);
    for (0..rounds) |i| {
        try file.writePositionalAll(io, chunk, i * chunk.len);
        try file.sync(io);
    }
    const elapsed = common.ns(io, started);
    try common.rate(out, side, "sync-fsync", rounds, elapsed);
}
