//! follow scenarios through the public API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const strand = @import("strand.zig");
const Follower = strand.Follower;
const Opener = strand.Opener;
const PathOpener = strand.PathOpener;
const Identity = strand.Identity;
const FileId = strand.FileId;
const testing = std.testing;

const fixtures = @import("testing/fixtures.zig");
const Fixture = fixtures.Fixture;
const Event = fixtures.Event;

/// Writes `count` events into `file`, a few bytes at a time, so that the
/// follower meets half-written lines rather than whole ones.
fn produce(io: std.Io, file: std.Io.File, buffer: []u8, count: u64) !void {
    var file_writer = file.writer(io, buffer);
    var log: strand.Writer(Event) = .init(&file_writer.interface, .{});
    for (0..count) |i| {
        try log.write(.{ .kind = "tick", .at = i });
        // Flushing mid-record is exactly the case the follower exists for:
        // half a line is on disk and the rest has not been written yet.
        try file_writer.interface.flush();
        if (i % 16 == 0) try io.sleep(.fromMicroseconds(200), .awake);
    }
    try file_writer.interface.flush();
}

/// Follows `source` until `count` lines have come off it, checking each one.
///
/// The consumer is the task and the producer is the caller, not the other way
/// round. A producer on a task that fails leaves a consumer waiting for lines
/// that will never be written, and a wait with nothing to wait for does not
/// end; a producer on the caller's own thread reports its failure as a failed
/// test.
fn consume(io: std.Io, source: *std.Io.File.Reader, count: u64) !void {
    var follower: Follower(Event) = .init(testing.allocator, source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(io);

    var seen: u64 = 0;
    while (seen < count) : (seen += 1) {
        const line = try follower.next(io);
        try testing.expectEqual(seen, line.value.at);
        try testing.expectEqualStrings("tick", line.value.kind);
        try testing.expectEqual(seen + 1, line.number);
    }
}

test "a producer task and a follower task over one growing file" {
    const count = 500;
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();

    var consumer = testing.io.concurrent(consume, .{
        testing.io,
        &fixture.reader,
        @as(u64, count),
    }) catch |err| switch (err) {
        // A single-threaded `Io` cannot run a producer and a consumer at
        // once, and this test is about what happens when it can.
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };

    produce(testing.io, fixture.write_file, fixture.write_buffer, count) catch |err| {
        // The consumer is waiting for lines that are not coming now, so it
        // has to be stopped before the failure is reported.
        _ = consumer.cancel(testing.io) catch |cause| {
            // Preserve the producer failure after joining the canceled consumer.
            std.log.debug("consumer stopped during cleanup: {s}", .{@errorName(cause)});
        };
        return err;
    };
    try consumer.await(testing.io);
}

/// Follows `source` until it is cancelled, which is the only way it ends.
fn followUntilCanceled(io: std.Io, source: *std.Io.File.Reader) Follower(Event).NextError!void {
    var follower: Follower(Event) = .init(testing.allocator, source, .{
        .wait = .{ .poll = .fromMilliseconds(1) },
    });
    defer follower.deinit(io);
    while (true) _ = try follower.next(io);
}

test "a follower checks cancellation before handing over a buffered record" {
    var fixture = try Fixture.init("{\"kind\":\"ready\"}\n", 64);
    defer fixture.deinit();
    _ = try fixture.reader.interface.peek(1);

    const Canceled = struct {
        fn check(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var vtable = testing.io.vtable.*;
    vtable.checkCancel = Canceled.check;
    const io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{});
    defer follower.deinit(io);
    try testing.expectError(error.Canceled, follower.next(io));
    try testing.expectEqual(@as(u64, 0), follower.reader.lines.number);
    try testing.expectEqualStrings("ready", (try follower.reader.next()).?.value.kind);
}

test "a follower waiting on a file that never grows is stopped by cancellation" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"only\"}\n");

    var task = testing.io.concurrent(followUntilCanceled, .{ testing.io, &fixture.reader }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    // The task reads the one line there is and then waits; cancelling it is
    // what gets it out of that wait.
    try testing.expectError(error.Canceled, task.cancel(testing.io));
}

test "a half-written line is not a line until it is finished" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"whole\"}\n{\"kind\":\"hal");

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{});
    defer follower.deinit(testing.io);

    try testing.expectEqualStrings("whole", (try follower.next(testing.io)).value.kind);

    // The rest of line two arrives, and only then is it a line.
    try fixture.write_file.writeStreamingAll(testing.io, "f\"}\n");
    const second = try follower.next(testing.io);
    try testing.expectEqualStrings("half", second.value.kind);
    try testing.expectEqual(@as(u64, 2), second.number);
}

/// An over-long record the writer has written only part of: the follower
/// meets the end of the file inside the line it refused.
const torn_long_head = "{\"kind\":\"" ++ @as([45]u8, @splat('a'));
const torn_long_tail = "aaa\"}\n{\"kind\":\"b\"}\n";

test "an over-long line finished after it was refused is not read twice" {
    var fixture = try Fixture.init(torn_long_head, 512);
    defer fixture.deinit();

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .reader = .{ .max_line_bytes = 16 },
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);

    try testing.expectError(error.LineTooLong, follower.next(testing.io));
    try fixture.write_file.writePositionalAll(testing.io, torn_long_tail, torn_long_head.len);

    const line = try follower.next(testing.io);
    try testing.expectEqualStrings("b", line.value.kind);
    try testing.expectEqual(@as(u64, 2), line.number);
    try testing.expectEqual(@as(u64, torn_long_head.len + "aaa\"}\n".len), line.offset);
    // Nothing else is on the file: the refused line is not read again.
    try testing.expectEqual(@as(?strand.Line(Event), null), try follower.reader.next());
    try testing.expectEqual(@as(u64, 0), follower.reader.lines.skipped);
}

test "an over-long line finished while the follower waits is not read twice" {
    var fixture = try Fixture.init(torn_long_head, 512);
    defer fixture.deinit();

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .reader = .{ .max_line_bytes = 16 },
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);
    try testing.expectError(error.LineTooLong, follower.next(testing.io));

    const Next = struct {
        fn run(active: *Follower(Event)) !void {
            const line = try active.next(testing.io);
            try testing.expectEqualStrings("b", line.value.kind);
            try testing.expectEqual(@as(u64, 2), line.number);
            try testing.expectEqual(@as(u64, torn_long_head.len + "aaa\"}\n".len), line.offset);
        }
    };
    var task = testing.io.concurrent(Next.run, .{&follower}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    // The follower reaches the end inside the refused line, rewinds to where
    // it stands and waits; the rest of the line and a whole one arrive.
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try fixture.write_file.writePositionalAll(testing.io, torn_long_tail, torn_long_head.len);
    try task.await(testing.io);
    try testing.expectEqual(@as(?strand.Line(Event), null), try follower.reader.next());
}

test "a follower still recognizes a byte-order mark after starting empty" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);

    // Reach the empty file once, as `Follower.next` does before it waits.
    try testing.expectEqual(@as(?strand.Line(Event), null), try follower.reader.next());
    try fixture.write_file.writeStreamingAll(testing.io, "\xEF\xBB\xBF{\"kind\":\"first\"}\n");

    try testing.expectEqualStrings("first", (try follower.next(testing.io)).value.kind);
}

test "a follower does not revisit a skipped complete line while waiting" {
    var fixture = try Fixture.init("not json\n", 512);
    defer fixture.deinit();

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .reader = .{ .on_malformed = .skip },
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);

    const Next = struct {
        fn run(active: *Follower(Event)) !void {
            const line = try active.next(testing.io);
            try testing.expectEqualStrings("after", line.value.kind);
            try testing.expectEqual(@as(u64, 2), line.number);
        }
    };
    var task = testing.io.concurrent(Next.run, .{&follower}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try fixture.write_file.writePositionalAll(testing.io, "{\"kind\":\"after\"}\n", "not json\n".len);
    try task.await(testing.io);

    try testing.expectEqual(@as(u64, 1), follower.reader.lines.skipped);
}

test "a wake is a way to wait that is not a sleep" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"first\"}\n");

    var event: std.Io.Event = .unset;
    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .wait = .{ .wake = .{ .event = &event, .timeout = .fromMilliseconds(50) } },
    });
    defer follower.deinit(testing.io);

    try testing.expectEqualStrings("first", (try follower.next(testing.io)).value.kind);
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"second\"}\n");
    event.set(testing.io);
    try testing.expectEqualStrings("second", (try follower.next(testing.io)).value.kind);
}

test "a truncated file is reported rather than spliced onto the old one" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"before\"}\n");

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);

    try testing.expectEqualStrings("before", (try follower.next(testing.io)).value.kind);
    try testing.expect(!try follower.truncated(testing.io));

    // Rotation, of the kind that empties the file in place.
    try fixture.write_file.setLength(testing.io, 0);
    try testing.expect(try follower.truncated(testing.io));
    try testing.expectError(error.Truncated, follower.next(testing.io));

    // Starting again is what there is to do about it.
    try fixture.write_file.writePositionalAll(testing.io, "{\"kind\":\"after\"}\n", 0);
    try follower.restart();
    const after = try follower.next(testing.io);
    try testing.expectEqualStrings("after", after.value.kind);
    try testing.expectEqual(@as(u64, 1), after.number);
}

//=========================================================================
// Checkpoints: the thing that crashes is the follower.
//=========================================================================

/// The lines a plain reader makes of `bytes`, as "number:line" strings.
fn readingOf(bytes: []const u8) !std.ArrayList([]const u8) {
    var source: std.Io.Reader = .fixed(bytes);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| testing.allocator.free(item);
        out.deinit(testing.allocator);
    }
    while (try reader.next()) |line| {
        try out.append(testing.allocator, try testing.allocator.print(
            "{d}:{s}",
            .{ line.number, line.line },
        ));
    }
    return out;
}

fn freeReading(items: *std.ArrayList([]const u8)) void {
    for (items.items) |item| testing.allocator.free(item);
    items.deinit(testing.allocator);
}

test "a follower resumed from a checkpoint reads every line exactly once" {
    const lines = 40;
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    var writer: strand.Writer(Event) = .init(&log.writer, .{});
    for (0..lines) |i| try writer.write(.{ .kind = "tick", .at = i });

    var want = try readingOf(log.written());
    defer freeReading(&want);
    try testing.expectEqual(@as(usize, lines), want.items.len);

    var fixture = try fixtures.Fixture.init(log.written(), 64);
    defer fixture.deinit();

    var got: std.ArrayList([]const u8) = .empty;
    defer freeReading(&got);

    // A follower that reads part of the file and is then interrupted, with
    // a checkpoint taken at the line it had reached.
    var point: Follower(Event).Checkpoint = undefined;
    {
        var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
            .wait = .{ .poll = .fromMicroseconds(100) },
            .identity = .{ .fingerprint = .{ .length = 32 } },
        });
        defer follower.deinit(testing.io);
        for (0..17) |_| {
            const line = try follower.next(testing.io);
            try got.append(testing.allocator, try testing.allocator.print(
                "{d}:{s}",
                .{ line.number, line.line },
            ));
        }
        point = try follower.checkpoint(testing.io);
    }

    // A second follower, built from the checkpoint over a handle of its own
    // — the first one is gone, as it would be after a crash.
    var again = fixture.file.reader(testing.io, fixture.write_buffer);
    var second: Follower(Event) = try .resumeFrom(
        testing.allocator,
        testing.io,
        &again,
        point,
        .{
            .wait = .{ .poll = .fromMicroseconds(100) },
            .identity = .{ .fingerprint = .{ .length = 32 } },
        },
    );
    defer second.deinit(testing.io);

    // The same file, so the numbering carries on rather than starting over.
    try testing.expectEqual(point.rotations, second.rotations);
    for (0..lines - 17) |_| {
        const line = try second.next(testing.io);
        try got.append(testing.allocator, try testing.allocator.print(
            "{d}:{s}",
            .{ line.number, line.line },
        ));
    }

    // Every line, once, in order, under the number and with the bytes one
    // uninterrupted reader gives it.
    try testing.expectEqual(want.items.len, got.items.len);
    for (want.items, got.items) |a, b| try testing.expectEqualStrings(a, b);
}

test "a checkpoint of a log that rotated while nothing read it begins the new file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.jsonl",
        .data = "{\"kind\":\"old\",\"at\":1}\n{\"kind\":\"old\",\"at\":2}\n",
    });

    const options: Follower(Event).Options = .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .identity = .{ .fingerprint = .{ .length = 20 } },
    };

    var point: Follower(Event).Checkpoint = undefined;
    {
        const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
        defer file.close(testing.io);
        var buffer: [128]u8 = undefined;
        var source = file.reader(testing.io, &buffer);

        var follower: Follower(Event) = .init(testing.allocator, &source, options);
        defer follower.deinit(testing.io);
        try testing.expectEqualStrings("old", (try follower.next(testing.io)).value.kind);
        point = try follower.checkpoint(testing.io);
    }

    // The log is rotated with nothing following it, which is the case a
    // recorded offset is dangerous in: the offset is still a place in the
    // new file, and it is not the place that line was.
    try tmp.dir.rename("log.jsonl", tmp.dir, "log.1", testing.io);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.jsonl",
        .data = "{\"kind\":\"new\",\"at\":1}\n{\"kind\":\"new\",\"at\":2}\n",
    });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [128]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var follower: Follower(Event) = try .resumeFrom(testing.allocator, testing.io, &source, point, options);
    defer follower.deinit(testing.io);

    // Not the file the checkpoint named, so it is read from its start and
    // numbered from 1, and the change is counted.
    try testing.expectEqual(point.rotations + 1, follower.rotations);
    const line = try follower.next(testing.io);
    try testing.expectEqualStrings("new", line.value.kind);
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 0), line.offset);
}

test "a checkpoint is a line like any other" {
    var fixture = try fixtures.Fixture.init("{\"kind\":\"one\"}\n{\"kind\":\"two\"}\n", 64);
    defer fixture.deinit();

    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit(testing.io);
    _ = try follower.next(testing.io);
    const point = try follower.checkpoint(testing.io);

    // A registry of these is a JSON Lines file, so this package writes and
    // reads one without being asked to do anything special about it.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try strand.writeLine(&out.writer, point);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const read = try strand.parseLine(
        Follower(Event).Checkpoint,
        arena.allocator(),
        out.written()[0 .. out.written().len - 1],
        .{},
    );
    try testing.expectEqual(point.offset, read.offset);
    try testing.expectEqual(point.number, read.number);
    try testing.expectEqual(point.rotations, read.rotations);
    try testing.expect(point.file.eql(read.file));
}

//=========================================================================
// Rotation: the path stops naming the file the follower holds.
//=========================================================================

/// An `Opener` a test drives itself: what the path holds is whichever staged
/// file `now` points at, and the test moves it. No filesystem, no race, and
/// the counters say how often the follower actually looked.
const Staged = struct {
    files: []const std.Io.File,
    now: usize = 0,
    opens: usize = 0,
    closes: usize = 0,

    fn opener(self: *Staged) Opener {
        return .{ .context = self, .openFn = open, .closeFn = close };
    }

    fn open(io: std.Io, context: *anyopaque) Opener.OpenError!std.Io.File {
        _ = io;
        const self: *Staged = @ptrCast(@alignCast(context)); // safe: `Staged.opener` is the only maker of this interface, with a *Staged as its context
        self.opens += 1;
        return self.files[self.now];
    }

    /// The staged handles belong to the test, so this counts and does not
    /// close. A real opener closes; see `PathOpener`.
    fn close(io: std.Io, context: *anyopaque, file: std.Io.File) void {
        _ = io;
        _ = file;
        const self: *Staged = @ptrCast(@alignCast(context)); // safe: `Staged.opener` is the only maker of this interface, with a *Staged as its context
        self.closes += 1;
    }
};

test "the opener is an interface, and a test hands over the files itself" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one", .data = "{\"kind\":\"one\"}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two", .data = "{\"kind\":\"two\"}\n" });

    const first = try tmp.dir.openFile(testing.io, "one", .{});
    defer first.close(testing.io);
    const second = try tmp.dir.openFile(testing.io, "two", .{});
    defer second.close(testing.io);

    var staged: Staged = .{ .files = &.{ first, second } };
    var buffer: [256]u8 = undefined;
    var source = first.reader(testing.io, &buffer);
    {
        var follower: Follower(Event) = .init(testing.allocator, &source, .{
            .wait = .{ .poll = .fromMicroseconds(100) },
            .reopen = staged.opener(),
        });
        defer follower.deinit(testing.io);

        try testing.expectEqualStrings("one", (try follower.next(testing.io)).value.kind);
        try testing.expectEqual(@as(u64, 0), follower.rotations);

        // What the path holds, changed by the test rather than by the
        // filesystem, is the whole of a rotation as the follower sees it.
        staged.now = 1;
        const line = try follower.next(testing.io);
        try testing.expectEqualStrings("two", line.value.kind);
        try testing.expectEqual(@as(u64, 1), line.number);
        try testing.expectEqual(@as(u64, 1), follower.rotations);
        try testing.expect(staged.opens >= 1);
    }
    // The handle the follower opened for itself goes back through the same
    // interface; the one it was given does not.
    try testing.expectEqual(@as(usize, 1), staged.closes);
}

test "what a file is, by its number or by what is on it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = fixtures.repeat("{\"kind\":\"open\",\"at\":1}\n", 60);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one", .data = header });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "copy", .data = header });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "short", .data = "{}\n" });

    const one = try tmp.dir.openFile(testing.io, "one", .{});
    defer one.close(testing.io);
    const copy = try tmp.dir.openFile(testing.io, "copy", .{});
    defer copy.close(testing.io);
    const short = try tmp.dir.openFile(testing.io, "short", .{});
    defer short.close(testing.io);

    const by_content: Identity = .{ .fingerprint = .{} };

    // A file is itself, whichever way the question is asked.
    try testing.expect((try Identity.take(.file_id, testing.io, one))
        .eql(try Identity.take(.file_id, testing.io, one)));
    try testing.expect((try by_content.take(testing.io, one)).eql(try by_content.take(testing.io, one)));

    // Two files with the same bytes on them are two files by number and one
    // file by content, which is the trade between the two answers.
    try testing.expect(!(try Identity.take(.file_id, testing.io, one))
        .eql(try Identity.take(.file_id, testing.io, copy)));
    try testing.expect((try by_content.take(testing.io, one)).eql(try by_content.take(testing.io, copy)));

    // A file with too few bytes to fingerprint is compared by number.
    const shortly = try by_content.take(testing.io, short);
    try testing.expectEqual(@as(?u64, null), shortly.fingerprint);
    try testing.expect(!shortly.eql(try by_content.take(testing.io, one)));
    try testing.expect(shortly.eql(try by_content.take(testing.io, short)));

    // An empty fingerprint window has no content with which to identify a
    // file, so distinct handles still fall back to their numbers.
    const empty_window: Identity = .{ .fingerprint = .{ .length = 0 } };
    const empty_one = try empty_window.take(testing.io, one);
    const empty_copy = try empty_window.take(testing.io, copy);
    try testing.expect(!empty_one.eql(empty_copy));

    // And the case no number can see: the same file, rewritten where it
    // stands with something else of the same length. Taken before and after,
    // the number says it is the file it was and the content says it is not.
    const before = try by_content.take(testing.io, one);
    const writer = try tmp.dir.openFile(testing.io, "one", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.writePositionalAll(testing.io, fixtures.repeat("{\"kind\":\"else\",\"at\":9}\n", 60), 0);
    const after = try by_content.take(testing.io, one);
    try testing.expect(before.id.eql(after.id));
    try testing.expect(!before.eql(after));
}

test "a file is its number on its volume, and one number on two volumes is two files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log", .data = "{}\n" });
    const file = try tmp.dir.openFile(testing.io, "log", .{});
    defer file.close(testing.io);

    // What the volume is, as the system numbers it.
    const taken = try Identity.take(.file_id, testing.io, file);
    try testing.expect(taken.id.eql(try FileId.of(file.handle)));
    try testing.expect(taken.eql(try Identity.take(.file_id, testing.io, file)));

    // The same number on another volume is another file. Two volumes to
    // hand are not something a test can count on, so the other volume's
    // file is stated.
    var elsewhere = taken;
    elsewhere.id.volume +%= 1;
    try testing.expect(!taken.eql(elsewhere));
    try testing.expect(!elsewhere.eql(taken));

    // Two fingerprints still settle it, whatever the numbers say.
    var copied = elsewhere;
    copied.fingerprint = 7;
    var original = taken;
    original.fingerprint = 7;
    try testing.expect(copied.eql(original));
}

test "a rotation that keeps the file's number is followed by its content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Long enough to fingerprint, and the same length before and after, so
    // that nothing but the bytes themselves can tell the two apart: not the
    // number the system gives it, and not its length either.
    const before = fixtures.repeat("{\"kind\":\"old\",\"at\":1}\n", 60);
    const after = fixtures.repeat("{\"kind\":\"new\",\"at\":2}\n", 60);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = before });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
        .identity = .{ .fingerprint = .{} },
    });
    defer follower.deinit(testing.io);

    for (0..60) |_| try testing.expectEqualStrings("old", (try follower.next(testing.io)).value.kind);

    // The log is rotated by being rewritten where it stands, which is what
    // a copy-and-truncate rotation looks like from here.
    const writer = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.writePositionalAll(testing.io, after, 0);

    const line = try follower.next(testing.io);
    try testing.expectEqualStrings("new", line.value.kind);
    // A different file is a different file: the numbering starts again.
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 1), follower.rotations);
}

test "a follower given an opener follows the path across a rename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"old\"}\n" });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit(testing.io);

    try testing.expectEqualStrings("old", (try follower.next(testing.io)).value.kind);

    // Rotation of the kind that leaves the old file intact: the name moves,
    // and a new file takes it.
    try tmp.dir.rename("log.jsonl", tmp.dir, "log.1", testing.io);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"new\"}\n" });

    // A system that called these two the same file would leave the follower
    // with nothing to notice, and a follower with nothing to notice waits.
    // Checking it here makes that a failure rather than a wait.
    const replaced = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer replaced.close(testing.io);
    try testing.expect((try replaced.stat(testing.io)).inode != (try file.stat(testing.io)).inode);

    const line = try follower.next(testing.io);
    try testing.expectEqualStrings("new", line.value.kind);
    // A different file is a different file: the numbering starts again.
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 0), line.offset);
    try testing.expectEqual(@as(u64, 1), follower.rotations);
}

/// The second half of a rotation, landed inside a follower's own waits: the
/// path is renamed away by the test before the follower waits, and the file
/// that replaces it is written during the wait numbered `create_at`. Every
/// wait in between finds the path naming nothing, which is what a rotation
/// looks like from outside between its rename and its create — a window a
/// writer may hold open for as long as it likes.
const Gap = struct {
    var dir: std.Io.Dir = undefined;
    var waits: usize = 0;
    var create_at: usize = 0;
    var absent_looks: usize = 0;

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        _ = userdata;
        _ = timeout;
        waits += 1;
        if (waits == create_at) {
            dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"new\"}\n" }) catch
                @panic("could not write the replacement file");
        }
    }

    /// A `PathOpener` that counts the times it found nothing at the path.
    fn open(io: std.Io, context: *anyopaque) Opener.OpenError!std.Io.File {
        const path: *PathOpener = @ptrCast(@alignCast(context)); // safe: `opener` below is the only maker of this interface, with a *PathOpener as its context
        return path.opener().open(io) catch |err| {
            if (err == error.FileNotFound) absent_looks += 1;
            return err;
        };
    }

    fn close(io: std.Io, context: *anyopaque, file: std.Io.File) void {
        const path: *PathOpener = @ptrCast(@alignCast(context)); // safe: as in `open`
        path.opener().close(io, file);
    }

    fn opener(path: *PathOpener) Opener {
        return .{ .context = path, .openFn = open, .closeFn = close };
    }
};

test "a path that names nothing between a rotation's rename and its create is waited out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"old\"}\n" });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    // The waits are the test's: each one is a step of the writer's, run on
    // this thread, so the interleaving is the same on every run.
    Gap.dir = tmp.dir;
    Gap.waits = 0;
    Gap.absent_looks = 0;
    // A follower looks at the path once its file has stood still for two
    // waits; by the sixth it has looked at least twice and found nothing.
    Gap.create_at = 6;
    var vtable = testing.io.vtable.*;
    vtable.sleep = Gap.sleep;
    const io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = Gap.opener(&path),
    });
    defer follower.deinit(io);

    try testing.expectEqualStrings("old", (try follower.next(io)).value.kind);
    try tmp.dir.rename("log.jsonl", tmp.dir, "log.1", testing.io);

    const line = try follower.next(io);
    try testing.expectEqualStrings("new", line.value.kind);
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 1), follower.rotations);
    try testing.expect(Gap.absent_looks >= 2);
}

test "an opener that fails for any other reason ends the follow" {
    var fixture = try Fixture.init("{\"kind\":\"only\"}\n", 64);
    defer fixture.deinit();
    const Refusing = struct {
        fn open(io: std.Io, context: *anyopaque) Opener.OpenError!std.Io.File {
            _ = context;
            _ = io;
            return error.OpenFailed;
        }
        fn close(io: std.Io, context: *anyopaque, file: std.Io.File) void {
            _ = context;
            _ = io;
            _ = file;
        }
    };
    var context: u8 = 0;
    var follower: Follower(Event) = .init(testing.allocator, &fixture.reader, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = .{ .context = &context, .openFn = Refusing.open, .closeFn = Refusing.close },
    });
    defer follower.deinit(testing.io);
    try testing.expectEqualStrings("only", (try follower.next(testing.io)).value.kind);
    try testing.expectError(error.ReopenFailed, follower.next(testing.io));
}

test "the old file is read to its end before the new one is started" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.jsonl",
        .data = "{\"kind\":\"a\",\"at\":1}\n{\"kind\":\"a\",\"at\":2}\n{\"kind\":\"a\",\"at\":3}\n",
    });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [16]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit(testing.io);

    // The rotation happens before a single line has been read, which is the
    // case the ordering rule is about: the old file is behind, and nothing
    // on it may be lost for that.
    try tmp.dir.rename("log.jsonl", tmp.dir, "log.1", testing.io);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.jsonl",
        .data = "{\"kind\":\"b\",\"at\":1}\n{\"kind\":\"b\",\"at\":2}\n",
    });
    const replaced = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer replaced.close(testing.io);
    try testing.expect((try replaced.stat(testing.io)).inode != (try file.stat(testing.io)).inode);

    for ([_]struct { []const u8, u64, u64 }{
        .{ "a", 1, 1 },
        .{ "a", 2, 2 },
        .{ "a", 3, 3 },
        .{ "b", 1, 1 },
        .{ "b", 2, 2 },
    }) |want| {
        const line = try follower.next(testing.io);
        try testing.expectEqualStrings(want[0], line.value.kind);
        try testing.expectEqual(want[1], line.value.at);
        try testing.expectEqual(want[2], line.number);
    }
    try testing.expectEqual(@as(u64, 1), follower.rotations);
}

test "a truncation is begun again rather than reported when there is an opener" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"before\"}\n" });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit(testing.io);

    try testing.expectEqualStrings("before", (try follower.next(testing.io)).value.kind);

    // Rotation of the kind that empties the file in place. Without an opener
    // this is `error.Truncated`; with one it is a file to begin again on.
    const writer = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.setLength(testing.io, 0);
    try writer.writePositionalAll(testing.io, "{\"kind\":\"after\"}\n", 0);

    const line = try follower.next(testing.io);
    try testing.expectEqualStrings("after", line.value.kind);
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 1), follower.rotations);
}

test "two writers on two tasks share nothing" {
    const each = 2000;
    const Task = struct {
        fn run(io: std.Io, mark: []const u8, out: *std.Io.Writer.Allocating) !u64 {
            _ = io;
            var log: strand.Writer(Event) = .init(&out.writer, .{});
            for (0..each) |i| try log.write(.{ .kind = mark, .at = i });
            return log.count;
        }
    };

    var left: std.Io.Writer.Allocating = .init(testing.allocator);
    defer left.deinit();
    var right: std.Io.Writer.Allocating = .init(testing.allocator);
    defer right.deinit();

    var a = testing.io.concurrent(Task.run, .{ testing.io, "left", &left }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    var b = testing.io.concurrent(Task.run, .{ testing.io, "right", &right }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            _ = try a.await(testing.io);
            return error.SkipZigTest;
        },
    };
    try testing.expectEqual(@as(u64, each), try a.await(testing.io));
    try testing.expectEqual(@as(u64, each), try b.await(testing.io));

    for ([_]struct { []const u8, []const u8 }{
        .{ left.written(), "left" },
        .{ right.written(), "right" },
    }) |pair| {
        var source: std.Io.Reader = .fixed(pair[0]);
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        var seen: u64 = 0;
        while (try reader.next()) |line| : (seen += 1) {
            try testing.expectEqual(seen, line.value.at);
            try testing.expectEqualStrings(pair[1], line.value.kind);
        }
        try testing.expectEqual(@as(u64, each), seen);
    }
}

test "a checkpoint with the old identity shape is refused" {
    const Checkpoint = Follower(struct {}).Checkpoint;
    for ([_][]const u8{
        "{\"file\":{\"inode\":7},\"offset\":12}",
        "{\"file\":{\"inode\":7,\"volume\":9,\"fingerprint\":null},\"offset\":12}",
        "{\"file\":{\"inode\":7,\"volume\":9,\"fingerprint\":123},\"offset\":12}",
    }) |old| {
        try testing.expectError(error.MissingField, strand.parseLine(Checkpoint, testing.allocator, old, .{}));
    }
}

test "a taken identity keeps every bit of the file id" {
    if (comptime @hasField(Identity.Taken, "id")) {
        const a: Identity.Taken = .{ .id = .{ .volume = 3, .file = 7 } };
        const b: Identity.Taken = .{ .id = .{ .volume = 3, .file = (@as(u128, 1) << 96) | 7 } };
        try testing.expect(!a.eql(b));
        try testing.expect(!b.eql(a));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try strand.writeLine(&out.writer, b);
        const read = try strand.parseLine(Identity.Taken, testing.allocator, std.mem.trimEnd(u8, out.written(), "\n"), .{});
        try testing.expectEqual(b.id.file, read.id.file);
        try testing.expect(b.eql(read));
    } else {
        try testing.expect(false);
    }
}

test "the identity policy names the volume-qualified file id" {
    const options: Follower(struct {}).Options = .{};
    const policy = options.identity;
    try testing.expectEqualStrings("file_id", @tagName(policy));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try strand.writeLine(&out.writer, policy);
    try testing.expectEqualStrings("{\"file_id\":{}}\n", out.written());
    const read = try strand.parseLine(Identity, testing.allocator, std.mem.trimEnd(u8, out.written(), "\n"), .{});
    try testing.expectEqual(policy, read);
}

test "the old inode identity policy is refused" {
    try testing.expectError(error.UnknownField, strand.parseLine(Identity, testing.allocator, "{\"inode\":{}}", .{}));
}
