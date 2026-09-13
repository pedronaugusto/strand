//! `tail -f` semantics: read a file to its end, wait for it to grow, carry on.
//!
//! A log is read while it is still being written, and the two hard parts of
//! that are not parsing. The first is the half-written line: a reader that
//! reaches the end of a file mid-record must not hand that record over, and
//! must not lose the bytes either. The second is waiting: a follower that
//! spins burns a core, and a follower that blocks forever cannot be stopped.
//!
//! `Follower` answers both with things `std` already has. It reads with
//! `Reader.Options.require_terminator`, so a line the writer has not finished
//! is not a line; it rewinds the file to where that line began; and it waits
//! on the `std.Io` it was given — a sleep, or an event the caller sets from a
//! filesystem watch — so that cancelling the task cancels the wait, and
//! `error.Canceled` comes back out of `next`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const strand = @import("strand.zig");
const Line = strand.Line;
const ParseLineError = strand.ParseLineError;

/// A stream of `T` over a file that is still being appended to.
///
/// Wraps a `Reader` and the file handle under it, because following a file
/// takes both: the reader to make lines out of bytes, and the handle to ask
/// whether there are more bytes yet and to rewind when a line turned out to
/// be half-written.
///
/// What it follows is the open handle, not the path. See `truncated` and
/// `restart` for what that means when the file is rotated.
pub fn Follower(comptime T: type) type {
    return struct {
        /// Where the waiting happens, and where cancellation comes from.
        io: std.Io,
        /// The file. Not owned: this follower never closes it. It seeks it
        /// back over every line the writer had not finished.
        source: *std.Io.File.Reader,
        /// The line layer. Public so that `number`, `last_error_line` and
        /// `last_error` are readable, and read-only otherwise.
        reader: strand.Reader(T),
        /// Read-only after `init`.
        options: Options,

        const Self = @This();

        /// Following policy, fixed at `init`.
        pub const Options = struct {
            /// Passed to the `Reader` underneath, except for
            /// `require_terminator`, which a follower always sets: a final
            /// line with no newline on it is a line the writer has not
            /// finished, and this is the whole difference between following a
            /// file and reading one.
            reader: strand.Reader(T).Options = .{},
            /// How to wait when the file has nothing more on it yet.
            wait: Wait = .{ .poll = .fromMilliseconds(20) },
        };

        /// How a follower waits for the file to grow.
        pub const Wait = union(enum) {
            /// Sleep for this long and look again. What `tail -f` itself
            /// does, and what works on every platform without help.
            poll: std.Io.Duration,
            /// Wait until `event` is set — by a filesystem watch, or by the
            /// writer when it is in the same program — or until `timeout`
            /// passes, whichever is first. The event is reset before each
            /// read, so a set that lands while the follower is reading is not
            /// lost; the timeout is there so that a set that is lost anyway
            /// costs one late line rather than a hung task.
            wake: struct {
                event: *std.Io.Event,
                timeout: std.Io.Duration = .fromSeconds(1),
            },
        };

        /// What `next` can report.
        ///
        /// Everything `Reader.next` can report, and three more. `Canceled` is
        /// the `std.Io` saying stop, and it is the ordinary way a follower
        /// ends. `SeekFailed` means the file refused the rewind over a
        /// half-written line; ask `source.seek_err`. `Truncated` means the
        /// file got shorter than what has already been read from it, which is
        /// rotation seen from the inside: see `restart`.
        pub const NextError = strand.Reader(T).NextError || error{
            SeekFailed,
            Truncated,
        } || std.Io.Cancelable;

        /// A follower over `source`, starting wherever `source` is positioned.
        ///
        /// Start it at 0 to read a log from the beginning and then keep up
        /// with it; seek `source` to its end first to read only what arrives
        /// from now on, which is what `tail -f` does by default.
        pub fn init(
            allocator: Allocator,
            io: std.Io,
            source: *std.Io.File.Reader,
            options: Options,
        ) Self {
            var reader_options = options.reader;
            reader_options.require_terminator = true;
            var self: Self = .{
                .io = io,
                .source = source,
                .reader = .init(allocator, &source.interface, reader_options),
                .options = options,
            };
            // The reader counts from where it started; a follower starts
            // somewhere in a file, so seeding it is what makes `Line.offset`
            // an offset in that file rather than in what was read from it.
            self.reader.consumed = source.logicalPos();
            return self;
        }

        /// Releases the reader's buffers. Every `Line` this follower returned
        /// dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.reader.deinit();
            self.* = undefined;
        }

        /// The next line, waiting as long as it takes.
        ///
        /// There is no `null`: a file being appended to has no end, so a
        /// follower stops when the `std.Io` cancels it — `error.Canceled` —
        /// or when the caller stops asking. That is the contract that makes
        /// cancellation the only way out, and it is why `next` is a
        /// cancellation point even on a file that is growing fast enough that
        /// it never waits.
        ///
        /// Ownership: exactly `Reader.next`'s. The returned `Line` borrows the
        /// reader's line buffer and arena, and the next call takes both back.
        pub fn next(self: *Self) NextError!Line(T) {
            while (true) {
                // Where the line about to be read begins, and what it will be
                // numbered — so that a line the writer has not finished can
                // be un-read, bytes and number alike.
                const position = self.source.logicalPos();
                const number = self.reader.number;

                if (self.reader.next()) |maybe_line| {
                    if (maybe_line) |line| return line;
                } else |err| switch (err) {
                    error.ReadFailed => return self.readFault(),
                    else => |other| return other,
                }

                self.source.seekTo(position) catch return error.SeekFailed;
                self.reader.number = number;
                self.reader.consumed = position;
                try self.waitForGrowth(position);
            }
        }

        /// Whether the file has become shorter than what has been read from
        /// it, which is what a truncating rotation looks like through an open
        /// handle.
        ///
        /// A rename-and-recreate rotation looks like nothing at all: the
        /// handle still refers to the old file, which simply stops growing,
        /// and following the path across that is the caller's to do — reopen
        /// the path, and make a new `Follower` over the new handle. This
        /// package does not open files, so it cannot do it for you.
        pub fn truncated(self: *Self) error{ ReadFailed, SeekFailed }!bool {
            const size = self.currentSize() catch return error.ReadFailed;
            return size < self.source.logicalPos();
        }

        /// Begins again at the start of the file the handle now refers to,
        /// with the line numbering reset.
        ///
        /// This is what to do about a `error.Truncated` or a `truncated` of
        /// true: the file was emptied and is being written again from the
        /// top, so what is on it now has never been read.
        pub fn restart(self: *Self) error{SeekFailed}!void {
            self.source.seekTo(0) catch return error.SeekFailed;
            self.source.size = null;
            self.reader.number = 0;
            self.reader.consumed = 0;
            self.reader.offset = 0;
            self.reader.bom_checked = false;
        }

        /// Waits for the file to be longer than `position`, or for the wait
        /// itself to time out, whichever comes first.
        fn waitForGrowth(self: *Self, position: u64) NextError!void {
            switch (self.options.wait) {
                .poll => |duration| try self.io.sleep(duration, .awake),
                .wake => |wake| {
                    wake.event.waitTimeout(self.io, .{ .duration = .{
                        .raw = wake.timeout,
                        .clock = .awake,
                    } }) catch |err| switch (err) {
                        error.Timeout => {},
                        error.Canceled => return error.Canceled,
                    };
                    wake.event.reset();
                },
            }
            // A file that is now shorter than where the reader stands has
            // been truncated under it, and reading on would splice two
            // different files together.
            const size = self.currentSize() catch return error.ReadFailed;
            if (size < position) return error.Truncated;
        }

        /// What a failed read really was.
        ///
        /// A cancellation that lands inside a read reaches the `Io.Reader`
        /// interface as `error.ReadFailed`, because that interface has one
        /// failure and no room for another; the real error is on the file
        /// reader. Unwrapping it here is what makes `error.Canceled` the one
        /// way a follower ends, however the cancellation happened to arrive.
        fn readFault(self: *Self) NextError {
            const err = self.source.err orelse return error.ReadFailed;
            return switch (err) {
                error.Canceled => error.Canceled,
                else => error.ReadFailed,
            };
        }

        /// The length of the file right now, rather than the length it had
        /// when it was last looked at. A follower must ask again every time:
        /// the whole point is that the answer changes.
        fn currentSize(self: *Self) std.Io.File.LengthError!u64 {
            const size = try self.source.file.length(self.io);
            self.source.size = size;
            return size;
        }
    };
}

//=========================================================================
// Tests. These are the concurrency proof: a writer task and a reader task
// over one file, and a follower that a cancellation stops.
//=========================================================================

const testing = std.testing;

const Event = struct {
    kind: []const u8,
    at: u64 = 0,
};

/// A file in a temporary directory, open for writing and for reading.
const Fixture = struct {
    tmp: testing.TmpDir,
    read_file: std.Io.File,
    write_file: std.Io.File,
    read_buffer: []u8,
    write_buffer: []u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const write_file = try tmp.dir.createFile(testing.io, "log.jsonl", .{});
        errdefer write_file.close(testing.io);
        const read_file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
        errdefer read_file.close(testing.io);
        return .{
            .tmp = tmp,
            .read_file = read_file,
            .write_file = write_file,
            .read_buffer = try testing.allocator.alloc(u8, 512),
            .write_buffer = try testing.allocator.alloc(u8, 512),
        };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.read_buffer);
        testing.allocator.free(self.write_buffer);
        self.read_file.close(testing.io);
        self.write_file.close(testing.io);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

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

test "a producer task and a follower task over one growing file" {
    const count = 500;
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var producer = testing.io.concurrent(produce, .{
        testing.io,
        fixture.write_file,
        fixture.write_buffer,
        @as(u64, count),
    }) catch |err| switch (err) {
        // A single-threaded `Io` cannot run a producer and a consumer at
        // once, and this test is about what happens when it can.
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };

    var source = fixture.read_file.reader(testing.io, fixture.read_buffer);
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit();

    var seen: u64 = 0;
    while (seen < count) : (seen += 1) {
        const line = try follower.next();
        try testing.expectEqual(seen, line.value.at);
        try testing.expectEqualStrings("tick", line.value.kind);
        try testing.expectEqual(seen + 1, line.number);
    }
    try producer.await(testing.io);
}

/// Follows `source` until it is cancelled, which is the only way it ends.
fn followUntilCanceled(io: std.Io, source: *std.Io.File.Reader) Follower(Event).NextError!void {
    var follower: Follower(Event) = .init(testing.allocator, io, source, .{
        .wait = .{ .poll = .fromMilliseconds(1) },
    });
    defer follower.deinit();
    while (true) _ = try follower.next();
}

test "a follower waiting on a file that never grows is stopped by cancellation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"only\"}\n");

    var source = fixture.read_file.reader(testing.io, fixture.read_buffer);
    var task = testing.io.concurrent(followUntilCanceled, .{ testing.io, &source }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    // The task reads the one line there is and then waits; cancelling it is
    // what gets it out of that wait.
    try testing.expectError(error.Canceled, task.cancel(testing.io));
}

test "a half-written line is not a line until it is finished" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"whole\"}\n{\"kind\":\"hal");

    var source = fixture.read_file.reader(testing.io, fixture.read_buffer);
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{});
    defer follower.deinit();

    try testing.expectEqualStrings("whole", (try follower.next()).value.kind);

    // The rest of line two arrives, and only then is it a line.
    try fixture.write_file.writeStreamingAll(testing.io, "f\"}\n");
    const second = try follower.next();
    try testing.expectEqualStrings("half", second.value.kind);
    try testing.expectEqual(@as(u64, 2), second.number);
}

test "a wake is a way to wait that is not a sleep" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"first\"}\n");

    var event: std.Io.Event = .unset;
    var source = fixture.read_file.reader(testing.io, fixture.read_buffer);
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .wake = .{ .event = &event, .timeout = .fromMilliseconds(50) } },
    });
    defer follower.deinit();

    try testing.expectEqualStrings("first", (try follower.next()).value.kind);
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"second\"}\n");
    event.set(testing.io);
    try testing.expectEqualStrings("second", (try follower.next()).value.kind);
}

test "a truncated file is reported rather than spliced onto the old one" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"before\"}\n");

    var source = fixture.read_file.reader(testing.io, fixture.read_buffer);
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
    });
    defer follower.deinit();

    try testing.expectEqualStrings("before", (try follower.next()).value.kind);
    try testing.expect(!try follower.truncated());

    // Rotation, of the kind that empties the file in place.
    try fixture.write_file.setLength(testing.io, 0);
    try testing.expect(try follower.truncated());
    try testing.expectError(error.Truncated, follower.next());

    // Starting again is what there is to do about it.
    try fixture.write_file.writePositionalAll(testing.io, "{\"kind\":\"after\"}\n", 0);
    try follower.restart();
    const after = try follower.next();
    try testing.expectEqualStrings("after", after.value.kind);
    try testing.expectEqual(@as(u64, 1), after.number);
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
            _ = a.await(testing.io) catch {};
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
