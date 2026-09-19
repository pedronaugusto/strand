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
//!
//! The third hard part is rotation, and it is the one that needs something
//! from outside: a log that is renamed away and recreated leaves the follower
//! holding a handle to a file nobody writes to any more. `Options.reopen`
//! takes an `Opener` — one call that returns the file a path names right now —
//! and the follower uses it only when the file it holds has stopped growing,
//! so the old file is read to its end before the new one is started.

const std = @import("std");
const Allocator = std.mem.Allocator;

const strand = @import("strand.zig");
const Line = strand.Line;
const ParseLineError = strand.ParseLineError;

/// How a follower gets the file a path names right now.
///
/// This package does not open files, so following a path across a rotation
/// takes one call the caller supplies. It is an interface rather than a path
/// because the two callers are not alike: a program follows a real path, and
/// a test hands over files it has staged, so that a rotation happens when the
/// test says it does and not when the filesystem gets around to it.
///
/// `open` returns a file the follower reads from the beginning, and it must be
/// open for reading: the follower reads the lines on it and asks the system
/// which file it is, and asking for a file's attributes is read access —
/// Windows refuses it on a handle opened only for writing. `close` is called on
/// every file this interface opened, and on none that it did not: the handle a
/// `Follower` was built on stays the caller's.
pub const Opener = struct {
    /// Whatever the implementation needs. Not touched here.
    context: *anyopaque,
    /// The file the path names now, open for reading.
    openFn: *const fn (context: *anyopaque, io: std.Io) OpenError!std.Io.File,
    /// Called on a file `openFn` returned and the follower is done with.
    closeFn: *const fn (context: *anyopaque, io: std.Io, file: std.Io.File) void,

    /// What an opener may report. One member, on purpose: the reasons a file
    /// will not open are the caller's to know and to report, the way
    /// `error.ReadFailed` leaves diagnostics to the stream.
    pub const OpenError = error{OpenFailed};

    pub fn open(self: Opener, io: std.Io) OpenError!std.Io.File {
        return self.openFn(self.context, io);
    }

    pub fn close(self: Opener, io: std.Io, file: std.Io.File) void {
        self.closeFn(self.context, io, file);
    }
};

/// An `Opener` over a directory and a path in it, which is what a program
/// following a real log wants.
///
/// The struct must outlive the `Follower`, since the follower holds a pointer
/// to it, and so must `sub_path`.
pub const PathOpener = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,

    /// The interface over this path. The directory is opened once, here, and
    /// the path is resolved against it on every call, so a rotation that
    /// replaces the file is seen and one that replaces the directory is not.
    pub fn opener(self: *PathOpener) Opener {
        return .{ .context = self, .openFn = openPath, .closeFn = closePath };
    }

    fn openPath(context: *anyopaque, io: std.Io) Opener.OpenError!std.Io.File {
        const self: *PathOpener = @ptrCast(@alignCast(context));
        return self.dir.openFile(io, self.sub_path, .{}) catch error.OpenFailed;
    }

    fn closePath(context: *anyopaque, io: std.Io, file: std.Io.File) void {
        _ = context;
        file.close(io);
    }
};

/// What makes two handles the same file.
///
/// A rotation is noticed by asking "is what the path holds now the file I was
/// reading?", and there are two ways to answer it.
pub const Identity = union(enum) {
    /// The number the system gives a file: the inode on a POSIX system, the
    /// file index on Windows. One call, nothing read, and exactly right
    /// while the numbers are not reused — which is the catch. A filesystem
    /// is free to give a new file the number of one just deleted, and then a
    /// log that was rotated away reads as the log that replaced it; going
    /// the other way, a filesystem that renumbers a file it did not replace
    /// reads as a rotation that never happened. Both are silent.
    inode,
    /// The first bytes of the file, hashed. A log's opening lines are
    /// written once and not written again, so they name the file in a way
    /// the filesystem cannot take back — which is what makes this the answer
    /// for a log on a filesystem whose numbers move, and the answer for a
    /// rotation that copies the log away and writes the same file again
    /// from the top, which no number can see at all.
    ///
    /// A file with fewer bytes than the window needs cannot be told apart by
    /// its content yet, so it is compared by number until it is long enough.
    /// Two files whose first bytes are identical — two logs opened in the
    /// same second with the same header — are one file as far as this is
    /// concerned: make the window long enough to reach something that
    /// differs.
    fingerprint: struct {
        /// Where the window starts.
        offset: u64 = 0,
        /// How many bytes of it are hashed.
        length: usize = 1024,
    },

    /// What one file is, under one identity.
    ///
    /// Taken while the file is the file you mean and compared later, which
    /// is the whole point: a fingerprint read afresh from both sides of a
    /// rotation that rewrote a file in place would find the two the same.
    pub const Taken = struct {
        /// What the system calls the file.
        inode: std.Io.File.INode,
        /// The hash of the window, or `null` under `.inode` and for a file
        /// that is not yet as long as the window.
        fingerprint: ?u64 = null,

        /// Whether these are the same file. Two fingerprints settle it; with
        /// fewer than two, the number does.
        pub fn eql(a: Taken, b: Taken) bool {
            if (a.fingerprint) |mine| {
                if (b.fingerprint) |yours| return mine == yours;
            }
            return a.inode == b.inode;
        }
    };

    /// What `file` is, now. The handle must be open for reading: asking a
    /// file's attributes is read access, and so is reading its first bytes.
    pub fn take(self: Identity, io: std.Io, file: std.Io.File) !Taken {
        const inode = (try file.stat(io)).inode;
        switch (self) {
            .inode => return .{ .inode = inode },
            .fingerprint => |window| return .{
                .inode = inode,
                .fingerprint = try fingerprintOf(io, file, window.offset, window.length),
            },
        }
    }
};

/// The hash of `length` bytes of `file` at `offset`, or `null` when the file
/// does not reach that far yet. Read positionally, so nothing that is reading
/// the file moves.
fn fingerprintOf(io: std.Io, file: std.Io.File, offset: u64, length: usize) !?u64 {
    var hash: std.hash.Wyhash = .init(0);
    var buffer: [512]u8 = undefined;
    var taken: usize = 0;
    while (taken < length) {
        const want = @min(buffer.len, length - taken);
        const got = try file.readPositionalAll(io, buffer[0..want], offset + taken);
        if (got < want) return null;
        hash.update(buffer[0..got]);
        taken += got;
    }
    return hash.final();
}

/// A stream of `T` over a file that is still being appended to.
///
/// Wraps a `Reader` and the file handle under it, because following a file
/// takes both: the reader to make lines out of bytes, and the handle to ask
/// whether there are more bytes yet and to rewind when a line turned out to
/// be half-written.
///
/// What it follows is the open handle, unless it was given an `Opener`, in
/// which case it follows the path: see `Options.reopen` for the semantics,
/// and `truncated` and `restart` for what a rotation looks like without one.
pub fn Follower(comptime T: type) type {
    return struct {
        /// Where the waiting happens, and where cancellation comes from.
        io: std.Io,
        /// The file being read. The handle this follower was built on is not
        /// owned and is never closed; a handle the follower opened for itself
        /// across a rotation is, and this points at whichever it is reading.
        source: *std.Io.File.Reader,
        /// The line layer. Public so that `number`, `last_error_line` and
        /// `last_error` are readable, and read-only otherwise.
        reader: strand.Reader(T),
        /// Read-only after `init`.
        options: Options,
        /// How many times this follower has begun again on a file: once per
        /// replacement it followed across, once per truncation it restarted
        /// on. The count a log's line numbers have to be read against, since
        /// they start at 1 again after each.
        rotations: u64 = 0,

        /// Internal. The handle this follower opened for itself, which is the
        /// only one it may close. `null` while it is still reading the one it
        /// was given.
        opened: ?std.Io.File = null,
        /// Internal. What the file this follower is reading was, when it
        /// started reading it. Taken at the first read rather than at `init`,
        /// which cannot fail, and taken again for every file adopted since.
        held: ?Identity.Taken = null,
        /// Internal. What the file measured the last time this follower
        /// waited. A file that has not grown between two waits has stopped,
        /// and that is when the path is worth looking at again.
        size_seen: ?u64 = null,

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
            /// How to get the file the path names now, or `null` to follow
            /// the open handle and nothing else — which is the default, and
            /// what every earlier version did.
            ///
            /// With one set, a follower that finds its file has stopped
            /// growing asks the opener what the path holds. If that is a
            /// different file, the follower moves to it and reads it from
            /// the start; if it is the same file made shorter, the follower
            /// begins again at the top of it. `error.Truncated` is therefore
            /// never returned when this is set: a truncation is something to
            /// act on rather than something to report.
            ///
            /// The order is the part worth stating: **the old file is read to
            /// its end first, and only then is the new one started.** A
            /// rename leaves the old handle readable, so a rotation that
            /// happens while the follower is behind loses nothing — the
            /// follower finishes the old file, then moves. The one thing it
            /// does not carry over is a final line the old file never
            /// finished, which was never a line.
            reopen: ?Opener = null,
            /// What makes the file the path holds now the file this follower
            /// is reading. Only looked at when `reopen` is set, since it is
            /// the answer to a question only a reopen asks.
            identity: Identity = .inode,
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
        /// rotation seen from the inside: see `restart`. It is not reported
        /// at all when `Options.reopen` is set, because then a truncation is
        /// acted on rather than reported. `ReopenFailed` is that opener
        /// declining, or the system refusing to say which file a handle is;
        /// ask your own opener for diagnostics.
        pub const NextError = strand.Reader(T).NextError || error{
            SeekFailed,
            Truncated,
            ReopenFailed,
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
            return .{
                .io = io,
                .source = source,
                // The reader places its lines from where it started; a
                // follower starts somewhere in a file, so resuming it there
                // is what makes `Line.offset` an offset in that file rather
                // than in what has been read from it.
                .reader = .resumeAt(allocator, &source.interface, reader_options, .{
                    .offset = source.logicalPos(),
                }),
                .options = options,
            };
        }

        /// Releases the reader's buffers, and closes the handle this follower
        /// opened for itself if it opened one. The handle it was given is the
        /// caller's and is left alone. Every `Line` this follower returned
        /// dangles afterwards.
        pub fn deinit(self: *Self) void {
            if (self.opened) |file| {
                if (self.options.reopen) |opener| opener.close(self.io, file);
            }
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
            // What the file is has to be taken before it is read, not when
            // the question is asked: a file rewritten where it stands would
            // otherwise be measured after the rewrite and match itself.
            if (self.held == null and self.options.reopen != null) {
                _ = self.heldIdentity() catch return error.ReopenFailed;
            }
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
            self.atStart();
        }

        /// Waits for the file to grow, or for the wait itself to time out,
        /// whichever comes first — and decides what a file that did not grow
        /// means.
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

            const size = self.currentSize() catch return error.ReadFailed;
            // Two waits with the same size is a file that has stopped. One
            // wait is not enough to say so, and the length alone is not
            // either: a file whose last line the writer never finished has
            // bytes past `position` for ever.
            const stalled = if (self.size_seen) |seen| seen == size else false;
            self.size_seen = size;

            const opener = self.options.reopen orelse {
                // A file that is now shorter than where the reader stands has
                // been truncated under it, and reading on would splice two
                // different files together.
                if (size < position) return error.Truncated;
                return;
            };
            // With somewhere to reopen from, a truncation is not news to
            // report but a rotation to follow, and it is worth looking at at
            // once rather than after a second wait.
            if (size < position or stalled) try self.rotate(opener, size < position);
        }

        /// Looks at what the path holds now, and moves to it if it is not
        /// what this follower is reading.
        ///
        /// `emptied` says the file the follower holds has become shorter than
        /// what has been read from it, which is a reason to begin again on it
        /// even when the path still names it.
        fn rotate(self: *Self, opener: Opener, emptied: bool) NextError!void {
            const fresh = opener.open(self.io) catch return error.ReopenFailed;
            var adopted = false;
            defer if (!adopted) opener.close(self.io, fresh);

            const held = self.heldIdentity() catch return error.ReopenFailed;
            const there = self.options.identity.take(self.io, fresh) catch return error.ReopenFailed;
            if (!held.eql(there)) {
                // The old file has been read to its end — that is what
                // brought us here — so the new one starts from its own.
                adopted = true;
                if (self.opened) |old| opener.close(self.io, old);
                self.opened = fresh;
                self.source.* = fresh.reader(self.io, self.source.interface.buffer);
                self.atStart();
                self.rotations += 1;
                return;
            }
            if (emptied) {
                try self.restart();
                self.rotations += 1;
            }
        }

        /// What the file being read was when this follower took it up.
        ///
        /// Taken once and kept, because that is what a later comparison has
        /// to be against: a file rewritten where it stands is a different
        /// file, and reading its first bytes again would only find what it
        /// says about itself now. A file still too short to fingerprint is
        /// asked again, since its first bytes have not all been written yet.
        fn heldIdentity(self: *Self) !Identity.Taken {
            if (self.held) |taken| {
                if (taken.fingerprint != null or self.options.identity == .inode) return taken;
            }
            const taken = try self.options.identity.take(self.io, self.source.file);
            self.held = taken;
            return taken;
        }

        /// Puts the line layer back to where it stands at the top of a file.
        fn atStart(self: *Self) void {
            self.reader.number = 0;
            self.reader.consumed = 0;
            self.reader.offset = 0;
            self.reader.bom_checked = false;
            self.size_seen = null;
            self.held = null;
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

const fixtures = @import("fixtures.zig");
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
    var follower: Follower(Event) = .init(testing.allocator, io, source, .{
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
        _ = consumer.cancel(testing.io) catch {};
        return err;
    };
    try consumer.await(testing.io);
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

    var follower: Follower(Event) = .init(testing.allocator, testing.io, &fixture.reader, .{});
    defer follower.deinit();

    try testing.expectEqualStrings("whole", (try follower.next()).value.kind);

    // The rest of line two arrives, and only then is it a line.
    try fixture.write_file.writeStreamingAll(testing.io, "f\"}\n");
    const second = try follower.next();
    try testing.expectEqualStrings("half", second.value.kind);
    try testing.expectEqual(@as(u64, 2), second.number);
}

test "a wake is a way to wait that is not a sleep" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"first\"}\n");

    var event: std.Io.Event = .unset;
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &fixture.reader, .{
        .wait = .{ .wake = .{ .event = &event, .timeout = .fromMilliseconds(50) } },
    });
    defer follower.deinit();

    try testing.expectEqualStrings("first", (try follower.next()).value.kind);
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"second\"}\n");
    event.set(testing.io);
    try testing.expectEqualStrings("second", (try follower.next()).value.kind);
}

test "a truncated file is reported rather than spliced onto the old one" {
    var fixture = try Fixture.init("", 512);
    defer fixture.deinit();
    try fixture.write_file.writeStreamingAll(testing.io, "{\"kind\":\"before\"}\n");

    var follower: Follower(Event) = .init(testing.allocator, testing.io, &fixture.reader, .{
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

    fn open(context: *anyopaque, io: std.Io) Opener.OpenError!std.Io.File {
        _ = io;
        const self: *Staged = @ptrCast(@alignCast(context));
        self.opens += 1;
        return self.files[self.now];
    }

    /// The staged handles belong to the test, so this counts and does not
    /// close. A real opener closes; see `PathOpener`.
    fn close(context: *anyopaque, io: std.Io, file: std.Io.File) void {
        _ = io;
        _ = file;
        const self: *Staged = @ptrCast(@alignCast(context));
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
        var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
            .wait = .{ .poll = .fromMicroseconds(100) },
            .reopen = staged.opener(),
        });
        defer follower.deinit();

        try testing.expectEqualStrings("one", (try follower.next()).value.kind);
        try testing.expectEqual(@as(u64, 0), follower.rotations);

        // What the path holds, changed by the test rather than by the
        // filesystem, is the whole of a rotation as the follower sees it.
        staged.now = 1;
        const line = try follower.next();
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

    const header = "{\"kind\":\"open\",\"at\":1}\n" ** 60;
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
    try testing.expect((try Identity.take(.inode, testing.io, one))
        .eql(try Identity.take(.inode, testing.io, one)));
    try testing.expect((try by_content.take(testing.io, one)).eql(try by_content.take(testing.io, one)));

    // Two files with the same bytes on them are two files by number and one
    // file by content, which is the trade between the two answers.
    try testing.expect(!(try Identity.take(.inode, testing.io, one))
        .eql(try Identity.take(.inode, testing.io, copy)));
    try testing.expect((try by_content.take(testing.io, one)).eql(try by_content.take(testing.io, copy)));

    // A file with too few bytes to fingerprint is compared by number.
    const shortly = try by_content.take(testing.io, short);
    try testing.expectEqual(@as(?u64, null), shortly.fingerprint);
    try testing.expect(!shortly.eql(try by_content.take(testing.io, one)));
    try testing.expect(shortly.eql(try by_content.take(testing.io, short)));

    // And the case no number can see: the same file, rewritten where it
    // stands with something else of the same length. Taken before and after,
    // the number says it is the file it was and the content says it is not.
    const before = try by_content.take(testing.io, one);
    const writer = try tmp.dir.openFile(testing.io, "one", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.writePositionalAll(testing.io, "{\"kind\":\"else\",\"at\":9}\n" ** 60, 0);
    const after = try by_content.take(testing.io, one);
    try testing.expectEqual(before.inode, after.inode);
    try testing.expect(!before.eql(after));
}

test "a rotation that keeps the file's number is followed by its content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Long enough to fingerprint, and the same length before and after, so
    // that nothing but the bytes themselves can tell the two apart: not the
    // number the system gives it, and not its length either.
    const before = "{\"kind\":\"old\",\"at\":1}\n" ** 60;
    const after = "{\"kind\":\"new\",\"at\":2}\n" ** 60;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = before });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [256]u8 = undefined;
    var source = file.reader(testing.io, &buffer);

    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
        .identity = .{ .fingerprint = .{} },
    });
    defer follower.deinit();

    for (0..60) |_| try testing.expectEqualStrings("old", (try follower.next()).value.kind);

    // The log is rotated by being rewritten where it stands, which is what
    // a copy-and-truncate rotation looks like from here.
    const writer = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.writePositionalAll(testing.io, after, 0);

    const line = try follower.next();
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
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit();

    try testing.expectEqualStrings("old", (try follower.next()).value.kind);

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

    const line = try follower.next();
    try testing.expectEqualStrings("new", line.value.kind);
    // A different file is a different file: the numbering starts again.
    try testing.expectEqual(@as(u64, 1), line.number);
    try testing.expectEqual(@as(u64, 0), line.offset);
    try testing.expectEqual(@as(u64, 1), follower.rotations);
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
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit();

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
        const line = try follower.next();
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
    var follower: Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .wait = .{ .poll = .fromMicroseconds(100) },
        .reopen = path.opener(),
    });
    defer follower.deinit();

    try testing.expectEqualStrings("before", (try follower.next()).value.kind);

    // Rotation of the kind that empties the file in place. Without an opener
    // this is `error.Truncated`; with one it is a file to begin again on.
    const writer = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.setLength(testing.io, 0);
    try writer.writePositionalAll(testing.io, "{\"kind\":\"after\"}\n", 0);

    const line = try follower.next();
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
