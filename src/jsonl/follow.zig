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
const line_module = @import("line.zig");
const reader_module = @import("reader.zig");
const core = @import("../core.zig");

const std = @import("std");
const FileId = @import("airlock").FileId;
const Allocator = std.mem.Allocator;

const strand = struct {
    pub const Line = line_module.Line;
    pub const Reader = reader_module.Reader;
};
const Line = strand.Line;

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
/// `Follower` was built on stays the caller's, and a rotation moves the
/// caller's `File.Reader` off it; see `Follower.source`.
pub const Opener = struct {
    /// Whatever the implementation needs. Not touched here.
    context: *anyopaque,
    /// The file the path names now, open for reading.
    openFn: *const fn (io: std.Io, context: *anyopaque) OpenError!std.Io.File,
    /// Called on a file `openFn` returned and the follower is done with.
    closeFn: *const fn (io: std.Io, context: *anyopaque, file: std.Io.File) void,

    /// What an opener may report. `FileNotFound` is the path naming no file
    /// right now, which is a moment in every rotation — between the rename
    /// that takes the old file away and the create that puts a new one
    /// there — and a follower waits it out on the file it holds.
    /// `OpenFailed` is every other reason, and ends the follow: the reasons
    /// a file will not open are the caller's to know and to report, the way
    /// `error.ReadFailed` leaves diagnostics to the stream.
    pub const OpenError = error{ FileNotFound, OpenFailed } || std.Io.Cancelable;

    pub fn open(self: Opener, io: std.Io) OpenError!std.Io.File {
        return self.openFn(io, self.context);
    }

    pub fn close(self: Opener, io: std.Io, file: std.Io.File) void {
        self.closeFn(io, self.context, file);
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

    fn openPath(io: std.Io, context: *anyopaque) Opener.OpenError!std.Io.File {
        const self: *PathOpener = @ptrCast(@alignCast(context)); // safe: `opener` is the only maker of this interface, with a *PathOpener as its context
        return self.dir.openFile(io, self.sub_path, .{}) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.FileNotFound => error.FileNotFound,
            else => error.OpenFailed,
        };
    }

    fn closePath(io: std.Io, context: *anyopaque, file: std.Io.File) void {
        _ = context;
        file.close(io);
    }
};

/// What makes two handles the same file.
///
/// A rotation is noticed by asking "is what the path holds now the file I was
/// reading?", and there are two ways to answer it.
///
/// The native policy is `.file_id`, including in serialized settings. The
/// old `inode` policy tag is refused; there is no conversion or fallback.
/// Start a new follower at the beginning or seek to the chosen position.
pub const Identity = union(enum) {
    /// The number the system gives a file: the inode on a POSIX system, the
    /// full 128-bit file id on Windows, together with the volume it is on,
    /// since two volumes number their files independently. Nothing read,
    /// and exactly right while the numbers are not reused — which is the
    /// catch. A filesystem
    /// is free to give a new file the number of one just deleted, and then a
    /// log that was rotated away reads as the log that replaced it; going
    /// the other way, a filesystem that renumbers a file it did not replace
    /// reads as a rotation that never happened. Both are silent.
    file_id,
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
        /// Zero disables the content comparison and falls back to `.file_id`.
        length: usize = 1024,
    },

    /// What one file is, under one identity.
    ///
    /// Taken while the file is the file you mean and compared later, which
    /// is the whole point: a fingerprint read afresh from both sides of a
    /// rotation that rewrote a file in place would find the two the same.
    pub const Taken = struct {
        /// What the system calls the file, including its volume and every
        /// bit of its file id. Required in a serialized checkpoint; the old
        /// inode/volume shape is refused with `error.MissingField`.
        id: FileId,
        /// The hash of the window, or `null` under `.file_id` and for a file
        /// that is not yet as long as the window.
        fingerprint: ?u64 = null,

        /// Whether these are the same file. Two fingerprints settle it; with
        /// fewer than two, the number and the volume do.
        pub fn eql(a: Identity.Taken, b: Identity.Taken) bool {
            if (a.fingerprint) |mine| {
                if (b.fingerprint) |yours| return mine == yours;
            }
            return a.id.eql(b.id);
        }
    };

    /// What `take` can report: the file's attributes refused, or, for a
    /// fingerprint, its first bytes.
    pub const TakeError = FileId.Error || std.Io.File.ReadPositionalError;

    /// What `file` is, now. The handle must be open for reading: asking a
    /// file's attributes is read access, and so is reading its first bytes.
    pub fn take(self: Identity, io: std.Io, file: std.Io.File) Identity.TakeError!Identity.Taken {
        const id = try FileId.of(io, file);
        switch (self) {
            .file_id => return .{ .id = id },
            .fingerprint => |window| return .{
                .id = id,
                .fingerprint = try fingerprintOf(io, file, window.offset, window.length),
            },
        }
    }
};

/// The hash of `length` bytes of `file` at `offset`, or `null` when the file
/// does not reach that far yet. Read positionally, so nothing that is reading
/// the file moves.
fn fingerprintOf(io: std.Io, file: std.Io.File, offset: u64, length: usize) std.Io.File.ReadPositionalError!?u64 {
    if (length == 0) return null;
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

/// The policy types of every `Follower`, whatever its record type: shared,
/// so that options and errors mean the same thing across instantiations.
const shared = struct {
    /// Following policy, fixed at `init`.
    pub const Options = struct {
        /// Passed to the `Reader` underneath, except for
        /// `require_terminator`, which a follower always sets: a final
        /// line with no newline on it is a line the writer has not
        /// finished, and this is the whole difference between following a
        /// file and reading one.
        reader: strand.Reader(void).Options = .{},
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
        ///
        /// A path that names nothing (`error.FileNotFound` from the
        /// opener) is a rotation half done: the follower stays on the
        /// file it holds and looks again after its next wait, for as
        /// long as the path stays empty. Only `error.OpenFailed` ends
        /// `next`, as `error.ReopenFailed`.
        reopen: ?Opener = null,
        /// What makes the file the path holds now the file this follower
        /// is reading. Only looked at when `reopen` is set, since it is
        /// the answer to a question only a reopen asks.
        identity: Identity = .file_id,
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
    /// failing with `error.OpenFailed`, or the system refusing to say which file a handle is;
    /// ask your own opener for diagnostics.
    pub const NextError = strand.Reader(void).NextError || error{
        SeekFailed,
        Truncated,
        ReopenFailed,
    } || std.Io.Cancelable;

    /// Where a follower stands, and enough to build another one there.
    ///
    /// The thing that crashes is the follower, and the point of
    /// `Line.offset` is to be able to start again where the last one
    /// stopped. This keeps the file identity, the offset, the line count
    /// and how many files the follower has been through to get here.
    ///
    /// It is an ordinary struct of integers, so a caller keeping one
    /// between runs can write it with this package and read it back with
    /// it — a registry of checkpoints is a JSON Lines file like any
    /// other. A checkpoint in the old inode/volume shape is refused by
    /// `json.parse` with `error.UnknownField`. Start a new follower from
    /// the beginning, or seek to a position the caller chooses.
    pub const Checkpoint = struct {
        /// What the file being read is, under `Options.identity`. A
        /// checkpoint taken under one identity and resumed under another
        /// means nothing; keep the setting with it.
        file: Identity.Taken,
        /// The byte offset in that file at which the next line begins.
        /// Everything before it has been read.
        offset: u64 = 0,
        /// How many lines have come off this file.
        number: u64 = 0,
        /// What `rotations` stood at.
        rotations: u64 = 0,
    };

    /// What `checkpoint` can report: the file's identity could not be taken.
    pub const CheckpointError = error{ReopenFailed} || std.Io.Cancelable;

    /// What `resumeFrom` can report: the file's identity could not be taken,
    /// or the handle could not be put at the checkpoint.
    pub const ResumeError = error{ SeekFailed, ReopenFailed } || std.Io.Cancelable;

    /// What `truncated` can report: the file's length could not be read.
    pub const TruncatedError = error{ ReadFailed, SeekFailed } || std.Io.Cancelable;

    /// What `restart` can report: the handle could not be put back at 0.
    pub const RestartError = error{SeekFailed} || std.Io.Cancelable;
};

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
        /// The caller's `File.Reader`, which this follower reads through.
        /// The handle this follower was built on is not owned and is never
        /// closed. With `Options.reopen`, a rotation rewrites the struct this
        /// points at into a reader over a handle the follower opened for
        /// itself, keeping its buffer; that handle is closed by `deinit`. So a
        /// caller with an opener keeps its own copy of the original `File` to
        /// close, and does not use the `File.Reader` after `deinit`.
        source: *std.Io.File.Reader,
        /// The line layer. Public so that `reader.lines.number` and
        /// `reader.lines.fault` are readable, and read-only otherwise.
        reader: strand.Reader(T),
        /// Read-only after `init`.
        options: Options,
        /// How many times this follower has begun again on a file: once per
        /// replacement it followed across, once per truncation it restarted
        /// on. The count a log's line numbers have to be read against, since
        /// they start at 1 again after each.
        rotations: u64 = 0,

        /// Private: The handle this follower opened for itself, which is the
        /// only one it may close. `null` while it is still reading the one it
        /// was given.
        opened: ?std.Io.File = null,
        /// Private: What the file this follower is reading was, when it
        /// started reading it. Taken at the first read rather than at `init`,
        /// which cannot fail, and taken again for every file adopted since.
        held: ?Identity.Taken = null,
        /// Private: What the file measured the last time this follower
        /// waited. A file that has not grown between two waits has stopped,
        /// and that is when the path is worth looking at again.
        size_seen: ?u64 = null,

        const Self = @This();

        pub const Options = shared.Options;

        pub const Wait = shared.Wait;

        pub const NextError = shared.NextError;

        pub const Checkpoint = shared.Checkpoint;
        pub const CheckpointError = shared.CheckpointError;
        pub const ResumeError = shared.ResumeError;
        pub const TruncatedError = shared.TruncatedError;
        pub const RestartError = shared.RestartError;

        /// Where this follower stands right now.
        ///
        /// Take it after `next` has returned a line and before the next call:
        /// that is when the file position is a line boundary, which is what
        /// makes the offset in it one a reader can be started at.
        pub fn checkpoint(self: *Self, io: std.Io) CheckpointError!Checkpoint {
            return .{
                .file = self.heldIdentity(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.ReopenFailed,
                },
                .offset = self.source.logicalPos(),
                .number = self.reader.lines.number,
                .rotations = self.rotations,
            };
        }

        /// A copy of `line.value` that outlives the follower, owned on
        /// `gpa`. See `Reader.keep`, whose contract this is.
        pub fn keep(self: *Self, gpa: Allocator, line: Line(T)) core.DecodeError!core.Parsed(T) {
            return self.reader.keep(gpa, line);
        }

        /// A follower that carries on from `point`.
        ///
        /// `source` is the file the path holds now, which is not necessarily
        /// the file the checkpoint was taken on: a log can rotate while
        /// nothing is following it. The two cases are told apart the way a
        /// running follower tells them apart, by `Options.identity`, and the
        /// answer is on the follower rather than in a flag — `rotations` is
        /// the checkpoint's own when the file is the file it named, and one
        /// more when it is not.
        ///
        /// Same file: the read carries on at the recorded offset with the
        /// recorded numbering, so a line's number and offset mean across the
        /// crash what they meant before it. Different file: it is read from
        /// the start and numbered from 1, because none of it has been read.
        ///
        /// This one seeks `source`, which `init` does not: a follower resumed
        /// at an offset it was not positioned at would read from the wrong
        /// place, and there is no answer it could give instead.
        pub fn resumeFrom(
            gpa: Allocator,
            io: std.Io,
            source: *std.Io.File.Reader,
            point: Checkpoint,
            options: Options,
        ) ResumeError!Self {
            const now = options.identity.take(io, source.file) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.ReopenFailed,
            };
            const same = now.eql(point.file);
            source.seekTo(if (same) point.offset else 0) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.SeekFailed,
            };

            var self = Self.init(gpa, source, options);
            self.held = now;
            self.rotations = point.rotations + @intFromBool(!same);
            if (same) self.reader.lines.reset(.{ .offset = point.offset, .lines_before = point.number });
            return self;
        }

        /// A follower over `source`, starting wherever `source` is positioned.
        ///
        /// Start it at 0 to read a log from the beginning and then keep up
        /// with it; seek `source` to its end first to read only what arrives
        /// from now on, which is what `tail -f` does by default.
        ///
        /// `source` must outlive the follower, and with `Options.reopen` it
        /// is rewritten on a rotation; see `source`.
        pub fn init(
            gpa: Allocator,
            source: *std.Io.File.Reader,
            options: Options,
        ) Self {
            var reader_options = options.reader;
            reader_options.require_terminator = true;
            return .{
                .source = source,
                // The reader places its lines from where it started; a
                // follower starts somewhere in a file, so resuming it there
                // is what makes `Line.offset` an offset in that file rather
                // than in what has been read from it.
                .reader = .resumeAt(gpa, &source.interface, .{
                    .offset = source.logicalPos(),
                }, reader_options),
                .options = options,
            };
        }

        /// Releases the reader's buffers, and closes the handle this follower
        /// opened for itself if it opened one. The handle it was given is the
        /// caller's and is left alone. Every `Line` this follower returned
        /// dangles afterwards.
        pub fn deinit(self: *Self, io: std.Io) void {
            std.debug.assert(self.opened == null or self.options.reopen != null);
            if (self.opened) |file| {
                if (self.options.reopen) |opener| opener.close(io, file);
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
        pub fn next(self: *Self, io: std.Io) NextError!Line(T) {
            try io.checkCancel();
            // What the file is has to be taken before it is read, not when
            // the question is asked: a file rewritten where it stands would
            // otherwise be measured after the rewrite and match itself.
            if (self.held == null and self.options.reopen != null) {
                _ = self.heldIdentity(io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.ReopenFailed,
                };
            }
            while (true) {
                if (self.reader.next()) |maybe_line| {
                    if (maybe_line) |line| return line;
                } else |err| switch (err) {
                    error.ReadFailed => return self.readFault(),
                    else => |other| return other,
                }

                // `Reader.next` can pass over complete blank or skipped
                // records before finding an unfinished one. Rewind only the
                // current record, preserving that completed progress. A
                // record rewound to the top of the file is where a
                // byte-order mark may still arrive, and `reset` looks for
                // one again there.
                const unfinished = self.reader.lines.recordStart();
                self.source.seekTo(unfinished.offset) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.SeekFailed,
                };
                self.reader.lines.reset(unfinished);
                try self.waitForGrowth(io, unfinished.offset);
            }
        }

        /// Whether the file has become shorter than what has been read from
        /// it, which is what a truncating rotation looks like through an open
        /// handle.
        ///
        /// A rename-and-recreate rotation does not shorten the old file:
        /// its handle stays readable and simply stops growing. With
        /// `Options.reopen`, `next` finishes that file and uses the opener
        /// to follow the replacement. Without it, the caller reopens the
        /// path and builds a new follower over the new handle.
        pub fn truncated(self: *Self, io: std.Io) TruncatedError!bool {
            const size = self.currentSize(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.ReadFailed,
            };
            return size < self.source.logicalPos();
        }

        /// Begins again at the start of the file the handle now refers to,
        /// with the line numbering reset.
        ///
        /// This is what to do about a `error.Truncated` or a `truncated` of
        /// true: the file was emptied and is being written again from the
        /// top, so what is on it now has never been read.
        pub fn restart(self: *Self) RestartError!void {
            self.source.seekTo(0) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.SeekFailed,
            };
            self.source.size = null;
            self.atStart();
        }

        /// Waits for the file to grow, or for the wait itself to time out,
        /// whichever comes first — and decides what a file that did not grow
        /// means.
        fn waitForGrowth(self: *Self, io: std.Io, position: u64) NextError!void {
            switch (self.options.wait) {
                .poll => |duration| try io.sleep(duration, .awake),
                .wake => |wake| {
                    wake.event.waitTimeout(io, .{ .duration = .{
                        .raw = wake.timeout,
                        .clock = .awake,
                    } }) catch |err| switch (err) {
                        error.Timeout => {},
                        error.Canceled => return error.Canceled,
                    };
                    wake.event.reset();
                },
            }

            const size = self.currentSize(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.ReadFailed,
            };
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
            if (size < position or stalled) try self.rotate(io, opener, size < position);
        }

        /// Looks at what the path holds now, and moves to it if it is not
        /// what this follower is reading.
        ///
        /// `emptied` says the file the follower holds has become shorter than
        /// what has been read from it, which is a reason to begin again on it
        /// even when the path still names it.
        fn rotate(self: *Self, io: std.Io, opener: Opener, emptied: bool) NextError!void {
            const fresh = opener.open(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // Renamed away and not yet created again. The file held is
                // the only one there is, so it is the one to read on — from
                // the top, if it was emptied as well.
                error.FileNotFound => {
                    if (emptied) {
                        try self.restart();
                        self.rotations += 1;
                    }
                    return;
                },
                error.OpenFailed => return error.ReopenFailed,
            };
            var adopted = false;
            defer if (!adopted) opener.close(io, fresh);

            const held = self.heldIdentity(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.ReopenFailed,
            };
            const there = self.options.identity.take(io, fresh) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return error.ReopenFailed,
            };
            if (!held.eql(there)) {
                // The old file has been read to its end — that is what
                // brought us here — so the new one starts from its own.
                adopted = true;
                if (self.opened) |old| opener.close(io, old);
                self.opened = fresh;
                self.source.* = fresh.reader(io, self.source.interface.buffer);
                self.atStart();
                self.held = there;
                self.rotations += 1;
                return;
            }
            if (emptied) {
                try self.restart();
                self.held = there;
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
        fn heldIdentity(self: *Self, io: std.Io) Identity.TakeError!Identity.Taken {
            if (self.held) |taken| {
                if (taken.fingerprint != null or self.options.identity == .file_id) return taken;
            }
            const taken = try self.options.identity.take(io, self.source.file);
            self.held = taken;
            return taken;
        }

        /// Puts the line layer back to where it stands at the top of a file.
        fn atStart(self: *Self) void {
            std.debug.assert(self.source.logicalPos() == 0);
            self.reader.lines.reset(.{});
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
        fn currentSize(self: *Self, io: std.Io) std.Io.File.LengthError!u64 {
            const size = try self.source.file.length(io);
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

test "a rotated follower checkpoints the identity it adopted before reading" {
    const Event = struct { kind: []const u8 };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"old\"}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.jsonl", .data = "{\"kind\":\"new\"}\n" });
    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [8]u8 = undefined;
    var source = file.reader(testing.io, &buffer);
    var path: PathOpener = .{ .dir = tmp.dir, .sub_path = "new.jsonl" };
    const identity: Identity = .{ .fingerprint = .{ .length = 14 } };
    var follower = Follower(Event).init(testing.allocator, &source, .{
        .reopen = path.opener(),
        .identity = identity,
    });
    defer follower.deinit(testing.io);
    // Exercise the two operations inside one next call after its wait,
    // without a second next entry capturing the identity again.
    try follower.rotate(testing.io, path.opener(), false);
    const adopted = try identity.take(testing.io, source.file);
    try testing.expectEqualStrings("new", (try follower.reader.next()).?.value.kind);
    // An in-place rewrite after that read cannot change what the follower
    // says it has already consumed, even when the native id stays the same.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.jsonl", .data = "{\"kind\":\"now\"}\n" });
    const rewritten = try identity.take(testing.io, source.file);
    try testing.expect(!adopted.eql(rewritten));
    const point = try follower.checkpoint(testing.io);
    try testing.expect(adopted.eql(point.file));
    try testing.expectEqual(@as(u64, 1), point.rotations);
}
