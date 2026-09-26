//! `Writer`: values as JSON Lines on a `*std.Io.Writer`, counted, drained and
//! synced as often as it is told to.

const std = @import("std");
const assert = std.debug.assert;
const encode = @import("encode.zig");

const line_mod = @import("line.zig");
const Format = line_mod.Format;
const separator = line_mod.separator;

const syncFile = @import("sync.zig").syncFile;

/// Writes values as JSON Lines to a `*std.Io.Writer`, and counts them.
pub fn Writer(comptime T: type) type {
    return struct {
        /// The destination. Not owned: this writer never closes it, and
        /// drains it only when `Options.flush` or `Options.sync` says to.
        output: *std.Io.Writer,
        /// The file under `output`, when the writer was made with `initFile`.
        /// `null` otherwise, and a `sync` policy needs it: there is no way to
        /// ask a `*std.Io.Writer` to put its bytes on a disk, because not
        /// every one of them has a disk.
        file: ?*std.Io.File.Writer = null,
        /// Read-only after `init`.
        options: Options,
        /// Records written so far.
        count: u64 = 0,
        /// Set once a sync has failed, after which this writer refuses every
        /// record: see `Options.sync`. A failed sync is not a thing to try
        /// again — the kernel may have dropped the error with the data, so a
        /// second call can come back clean over a log that lost a record —
        /// and it is not a thing to write past either, since what follows
        /// would be a log claiming a durability it does not have. Deal with
        /// the file, then build a writer over it.
        sync_failed: bool = false,

        const Self = @This();

        /// Encoding policy, fixed at `init`.
        pub const Options = struct {
            /// When false, an optional field that is `null` is left out of
            /// the line rather than written as `null` — which is what a
            /// reader that defaults its missing fields wants, and what keeps
            /// a log small.
            emit_null_optional_fields: bool = false,
            /// When true, non-ASCII characters are written as `\uXXXX`
            /// escapes, so every line is pure ASCII.
            escape_unicode: bool = false,
            /// See `Format`. `.pretty` writes a record over several lines,
            /// which only a reader in `.pretty` mode reads back.
            format: Format = .minified,
            /// When true, every record is written with a `separator` byte in
            /// front of it, which only a reader in the matching mode reads
            /// back. One byte per record, and what it buys is on
            /// `Reader.Options.record_separator`.
            record_separator: bool = false,
            /// The longest record this writer will emit, in bytes, not
            /// counting the terminator; `null` for no bound, which is the
            /// default. A longer one is `error.LineTooLong` and **none of it
            /// is written**, so the log is left where the record before it
            /// left it.
            ///
            /// A writer with no bound can write a log a reader will not read
            /// back: `Reader.Options.max_line_bytes` is a megabyte by
            /// default, and a record over it is discarded whole at the far
            /// end, where nothing knows what was meant. Set this to the
            /// bound the readers use and the mistake is an error at the
            /// place it is made.
            ///
            /// It costs a second pass: the record is encoded once into a
            /// writer that counts and keeps nothing, to find out how long it
            /// is before any of it is written. That is why there is no bound
            /// unless one is asked for.
            max_line_bytes: ?usize = null,
            /// When the destination is asked to drain what it is holding.
            ///
            /// The default is never, because this writer does not own the
            /// stream and a flush is a decision about durability that belongs
            /// to whoever does. A log that another process tails, or that has
            /// to survive a crash between two records, is the case where the
            /// decision is "after every one", and saying so here is shorter
            /// than wrapping every `write`. `.per_records` is the one for a
            /// stream that is neither: one drain per `n` records, however
            /// they arrive.
            flush: Flush = .never,
            /// When the file is asked to put what it has been given onto the
            /// disk under it.
            ///
            /// A flush moves a record out of this program's buffer and into
            /// the operating system's. That is enough to survive the process
            /// dying — another process reading the file sees the record — and
            /// it is not enough to survive the machine losing power, because
            /// the operating system is free to hold those bytes in memory for
            /// as long as it likes. A sync is the call that says otherwise.
            ///
            /// What each level buys and costs:
            ///
            /// | | Survives the process | Survives the machine | Costs |
            /// |---|---|---|---|
            /// | `.never` | only what the caller drains | no | nothing |
            /// | `.per_record` | yes | yes, to the last record | one sync per record, which is a disk write and a wait: on a spinning disk single-digit milliseconds, on an SSD tens to hundreds of microseconds, and on either it is the slowest thing a log does |
            /// | `.per_batch` | yes | yes, to the last batch | one sync per `writeAll`, so a batch of a thousand records pays once and risks losing the batch |
            /// | `.per_records` | yes | yes, to the last `n` | one sync per `n` records, whether they came one at a time or in batches: the cost divided by `n`, against losing up to `n` |
            ///
            /// A sync drains first, whatever `flush` says: bytes still in
            /// this program's buffer have not reached the file at all, so
            /// there would be nothing on it to sync.
            ///
            /// What the call is, platform by platform:
            ///
            /// | | |
            /// |---|---|
            /// | Linux | `fdatasync`, by syscall: the record and the length that finds it, without the timestamp writeback `fsync` adds, which is a second metadata write per record for a time no reader of this log consults. A file that declines the call gets `fsync` |
            /// | macOS | `fcntl(F_FULLFSYNC)`, because `fsync` there hands the bytes to the drive without making it write them down. A filesystem with no such call gets `fsync`, which is then the strongest thing on it |
            /// | Windows | the system's own flush of the file's buffers |
            ///
            /// A sync that fails is `error.SyncFailed`, and that writer
            /// refuses every record after it. A failed sync is not a thing to
            /// try again — the kernel may drop the error along with the data,
            /// so a second call can come back clean over a log that lost a
            /// record — and it is not a thing to write past either. Deal with
            /// the file, then build a writer over it.
            ///
            /// There is no setting that drains on a timer. A writer is only
            /// ever called when there is a record, so a timer would need a
            /// task of its own, and this package does not own one — a caller
            /// that has a task has `flush` and `sync` to call from it.
            ///
            /// Only a writer made with `initFile` has a file to sync. `init`
            /// refuses any other setting than `.never`, and a writer built by
            /// hand without a file reports `error.SyncFailed` rather than
            /// pretending.
            ///
            /// What this does not cover is the directory entry: a file that
            /// is synced but whose directory is not may not be there under
            /// its name after a crash. Creating and syncing the directory is
            /// the caller's, as opening the file is.
            sync: Sync = .never,
        };

        /// How often the destination is asked to drain. See `Options.flush`.
        pub const Flush = union(enum) {
            /// Nothing is flushed. The caller drains its own writer.
            never,
            /// `write` flushes the destination after each record.
            per_record,
            /// `writeAll` flushes once, after the last record of the batch.
            /// A plain `write` flushes nothing.
            per_batch,
            /// Every `n`th record, counted across `write` and `writeAll`
            /// alike. This is the one a stream of records can use: it costs
            /// one drain per `n` rather than one per record, and it bounds
            /// what a crash loses at `n` records rather than at whatever the
            /// caller happened to batch. `n` must not be 0.
            per_records: u64,
        };

        /// How often the file is asked to sync. See `Options.sync`.
        pub const Sync = union(enum) {
            /// Nothing is synced. A crash of the machine may lose records a
            /// reader of the file had already seen.
            never,
            /// `write` syncs the file after each record, having drained it.
            per_record,
            /// `writeAll` syncs once, after the last record of the batch,
            /// having drained it. A plain `write` syncs nothing.
            per_batch,
            /// Every `n`th record, having drained it: one sync for the `n`
            /// records that arrived since the last one, which is the trade a
            /// log that is written to continuously has to make. The slowest
            /// thing a log does, divided by `n`, against losing up to `n`
            /// records. `n` must not be 0.
            per_records: u64,
        };

        /// Whether `policy` falls due on the record just written.
        fn due(self: *const Self, policy: anytype) bool {
            return switch (policy) {
                .never, .per_batch => false,
                .per_record => true,
                .per_records => |n| self.count % n == 0,
            };
        }

        /// Whether `policy` falls due at the end of a batch.
        fn dueForBatch(policy: anytype) bool {
            return switch (policy) {
                .per_batch => true,
                // A count is counted across a batch too, so the records in
                // one have already drained it every `n`; draining again at
                // the end would be a second policy, not this one.
                .never, .per_record, .per_records => false,
            };
        }

        /// A count of zero would fall due on every record and on none,
        /// depending on how the remainder is read; it is a mistake rather
        /// than a setting.
        fn checkPolicies(options: Options) void {
            switch (options.flush) {
                .per_records => |n| assert(n > 0),
                else => {},
            }
            switch (options.sync) {
                .per_records => |n| assert(n > 0),
                else => {},
            }
        }

        /// What `write` can report. `WriteFailed` is the destination refusing
        /// the bytes, `SyncFailed` is the file refusing to put them on the
        /// disk — ask the destination or the file for diagnostics — and
        /// `LineTooLong` is this writer's own bound, if it was given one.
        pub const Error = std.Io.Writer.Error || error{ SyncFailed, LineTooLong };

        /// A writer over `output`. Writes nothing.
        ///
        /// A writer made this way has no file, so `options.sync` must be
        /// `.never`; `initFile` is the constructor that can sync.
        pub fn init(output: *std.Io.Writer, options: Options) Self {
            assert(options.sync == .never);
            checkPolicies(options);
            return .{ .output = output, .options = options };
        }

        /// A writer over a file, which is what a `sync` policy needs. Writes
        /// nothing.
        ///
        /// The file is still not owned: this writer never closes it, and
        /// drains it only when `Options.flush` or `Options.sync` says to.
        pub fn initFile(dest: *std.Io.File.Writer, options: Options) Self {
            checkPolicies(options);
            return .{ .output = &dest.interface, .file = dest, .options = options };
        }

        /// Writes `value` as one record: its JSON, then `\n`.
        ///
        /// In `.minified` the record is exactly one line, whatever `value`
        /// holds, because `std.json` escapes the line terminators that could
        /// appear inside a string — there is no value this writer has to
        /// refuse, and `write escapes every terminator` in the test suite is
        /// the proof. In `.pretty` the record spans lines by design.
        ///
        /// Nothing is flushed or synced unless `Options.flush` or
        /// `Options.sync` says so; otherwise draining is the caller's to do,
        /// on the writer it owns.
        pub fn write(self: *Self, value: T) Error!void {
            if (self.sync_failed) return error.SyncFailed;
            if (self.options.max_line_bytes) |max| try self.checkLength(value, max);
            try self.writeRecord(value);
            self.count += 1;
            if (self.due(self.options.sync)) return self.drainAndSync();
            if (self.due(self.options.flush)) try self.flushOutput();
        }

        /// Writes every value in `values`, in order.
        ///
        /// The same bytes as a `write` per value: this exists so that a
        /// caller holding a batch hands it over once instead of writing a
        /// loop, and so that a buffered `output` sees the whole batch before
        /// it decides to drain. Under `flush = .per_batch` the batch is what
        /// a flush follows. On failure the values before the one that failed
        /// have been written and `count` says how many.
        pub fn writeAll(self: *Self, values: []const T) Error!void {
            for (values) |value| try self.write(value);
            if (dueForBatch(self.options.sync)) return self.drainAndSync();
            if (dueForBatch(self.options.flush)) try self.flushOutput();
        }

        /// How `std.json` is asked to lay a value out.
        fn encoding(self: *const Self) std.json.Stringify.Options {
            return .{
                .whitespace = switch (self.options.format) {
                    .minified => .minified,
                    .pretty => .indent_2,
                },
                .emit_null_optional_fields = self.options.emit_null_optional_fields,
                .escape_unicode = self.options.escape_unicode,
            };
        }

        /// The direct encoder is the minified ordinary-type path. Pretty
        /// output and custom `jsonStringify` methods keep std's stateful
        /// stringifier, which defines those extension contracts.
        fn encodeValue(self: *const Self, value: T, output: *std.Io.Writer) std.Io.Writer.Error!void {
            if (comptime encode.supports(T)) {
                if (self.options.format == .minified) return encode.value(value, self.encoding(), output);
            }
            return std.json.Stringify.value(value, self.encoding(), output);
        }

        /// Encode a common record wholly inside the destination's unused
        /// buffer, then publish its length in one step. If the record does
        /// not fit, the ordinary writer path drains and carries on.
        fn writeRecord(self: *const Self, value: T) std.Io.Writer.Error!void {
            if (comptime encode.supports(T)) {
                if (self.options.format == .minified and self.output.end < self.output.buffer.len) {
                    var fixed: std.Io.Writer = .fixed(self.output.buffer[self.output.end..]);
                    if (self.options.record_separator) fixed.writeByte(separator) catch
                        return self.writeRecordSlow(value);
                    const encoded = encode.valueBuffer(value, self.encoding(), fixed.buffer[fixed.end..]) catch
                        return self.writeRecordSlow(value);
                    fixed.end += encoded;
                    fixed.writeByte('\n') catch return self.writeRecordSlow(value);
                    self.output.end += fixed.end;
                    return;
                }
            }
            return self.writeRecordSlow(value);
        }

        fn writeRecordSlow(self: *const Self, value: T) std.Io.Writer.Error!void {
            if (self.options.record_separator) try self.output.writeByte(separator);
            try self.encodeValue(value, self.output);
            try self.output.writeByte('\n');
        }

        /// Refuses a record longer than the bound before a byte of it is
        /// written. Measured by encoding it into a writer that counts and
        /// keeps nothing, which is the second pass `Options.max_line_bytes`
        /// costs — and why there is no bound unless one is asked for.
        fn checkLength(self: *Self, value: T, max: usize) Error!void {
            var counter: std.Io.Writer.Discarding = .init(&.{});
            self.encodeValue(value, &counter.writer) catch
                return error.WriteFailed;
            const written = counter.fullCount() + @intFromBool(self.options.record_separator);
            if (written > max) return error.LineTooLong;
        }

        /// Drains the destination now, whatever `Options.flush` says.
        ///
        /// The policy covers the ordinary case — after every record, after
        /// every batch, never — and this is the one-off: a barrier at a
        /// checkpoint, or at the end of a run. A writer on `.never` that had
        /// to reach past itself to the stream it does not own, to do that,
        /// was the reason `Options.flush` exists at all, and this is the same
        /// reason one level further in.
        pub fn flush(self: *Self) Error!void {
            if (self.sync_failed) return error.SyncFailed;
            try self.flushOutput();
        }

        /// Drains the destination and puts what the file then holds onto the
        /// disk under it, whatever `Options.sync` says.
        ///
        /// The same one-off as `flush`, one level down, and it needs a file
        /// for the same reason `Options.sync` does: `error.SyncFailed` when
        /// this writer has none, and the writer takes no more records after
        /// a sync that failed.
        pub fn sync(self: *Self) Error!void {
            if (self.sync_failed) return error.SyncFailed;
            return self.drainAndSync();
        }

        /// Drains the destination and then asks the file to put what it now
        /// holds onto the disk. The order is the whole of it: a sync of a
        /// file that has not been given the bytes syncs nothing.
        fn drainAndSync(self: *Self) Error!void {
            try self.flushOutput();
            const dest = self.file orelse return self.syncFault();
            _ = syncFile(dest.file, dest.io) catch return self.syncFault();
        }

        /// `initFile` knows the concrete writer behind `output`. Calling its
        /// drain directly avoids two indirect calls on a per-record flush;
        /// writers supplied through `init` retain their own flush semantics.
        fn flushOutput(self: *Self) std.Io.Writer.Error!void {
            if (self.file != null) {
                while (self.output.end != 0)
                    _ = try std.Io.File.Writer.drain(self.output, &.{""}, 1);
                return;
            }
            return self.output.flush();
        }

        /// Records that this writer's log is not what it was asked to be, and
        /// says so. Every later call says so too; see `sync_failed`.
        fn syncFault(self: *Self) error{SyncFailed} {
            self.sync_failed = true;
            return error.SyncFailed;
        }
    };
}

/// Writes one value as one JSON Lines line, for a caller with nothing to
/// count. Same encoding as `Writer` with default options.
pub fn writeLine(output: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var w: Writer(@TypeOf(value)) = .init(output, .{});
    w.write(value) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        // The default sync policy is `.never`, so nothing here ever asks a
        // file for anything and this writer has no file to ask; the default
        // bound is no bound.
        error.SyncFailed, error.LineTooLong => unreachable,
    };
}

test writeLine {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeLine(&out.writer, .{ .kind = "open", .at = 17, .note = @as(?[]const u8, null) });
    try std.testing.expectEqualStrings("{\"kind\":\"open\",\"at\":17}\n", out.written());
}
