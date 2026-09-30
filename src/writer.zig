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
        /// The file under `output`, when made with `initFile` or
        /// `initFileBounded`.
        /// `null` otherwise, and a `sync` policy needs it: there is no way to
        /// ask a `*std.Io.Writer` to put its bytes on a disk, because not
        /// every one of them has a disk.
        file: ?*std.Io.File.Writer = null,
        /// Read-only after `init`.
        options: Options,
        /// Owned record storage for a bounded writer; null for streaming.
        scratch: ?RecordScratch = null,
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
            /// Only `initFile` and `initFileBounded` have a file to sync.
            /// `init` and `initBounded` require `.never`, and a writer built by
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
        /// `OutOfMemory` is bounded record storage refusing to grow.
        pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error || error{ SyncFailed, LineTooLong };

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

        /// A bounded writer over `output`. Encodes each record once into
        /// storage owned by this writer, then emits those same bytes if the
        /// JSON payload fits `max_line_bytes`. The separator and terminator
        /// do not count. An oversized record or failed encoding writes
        /// nothing to the destination and does not advance `count`.
        ///
        /// Scratch grows as needed and is reused until `deinit`. The caller
        /// keeps `allocator` alive until then. Construction allocates nothing.
        /// Like `init`, this requires `options.sync = .never`.
        pub fn initBounded(allocator: std.mem.Allocator, output: *std.Io.Writer, max_line_bytes: usize, options: Options) Self {
            var self = init(output, options);
            self.scratch = .init(allocator, max_line_bytes);
            return self;
        }

        /// A bounded writer over a file, with the same record storage and
        /// lifetime as `initBounded`, and the sync policies of `initFile`.
        pub fn initFileBounded(allocator: std.mem.Allocator, dest: *std.Io.File.Writer, max_line_bytes: usize, options: Options) Self {
            var self = initFile(dest, options);
            self.scratch = .init(allocator, max_line_bytes);
            return self;
        }

        /// Releases owned record storage. Does not drain, sync or close the
        /// destination. Streaming writers have no storage to release.
        /// A bounded writer must be released once; copying it shares ownership.
        pub fn deinit(self: *Self) void {
            if (self.scratch) |*scratch| scratch.deinit();
            self.* = undefined;
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
            if (self.scratch) |*scratch| {
                scratch.reset();
                self.encodeValue(value, &scratch.writer) catch |err|
                    return if (scratch.allocation_failed) error.OutOfMemory else err;
                const bytes = scratch.writer.buffered();
                if (bytes.len > scratch.max_line_bytes) return error.LineTooLong;
                if (self.options.record_separator) try self.output.writeByte(separator);
                try self.output.writeAll(bytes);
                try self.output.writeByte('\n');
            } else {
                try self.writeRecord(value);
            }
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
            _ = syncFile(dest.file, dest.io, .data) catch return self.syncFault();
        }

        /// The file constructors know the concrete writer behind `output`.
        /// Calling its drain directly avoids two indirect calls on a
        /// per-record flush; stream constructors retain the supplied writer's
        /// own flush semantics.
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

// One owner of the encoded payload and its allocation diagnostics. Writer's
// buffer and end are the storage and length; no second list keeps them in sync.
const RecordScratch = struct {
    allocator: std.mem.Allocator,
    max_line_bytes: usize,
    writer: std.Io.Writer,
    allocation_failed: bool = false,

    fn init(allocator: std.mem.Allocator, max_line_bytes: usize) RecordScratch {
        return .{
            .allocator = allocator,
            .max_line_bytes = max_line_bytes,
            .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush, .rebase = rebase } },
        };
    }

    fn deinit(self: *RecordScratch) void {
        self.allocator.free(self.writer.buffer);
        self.* = undefined;
    }

    fn reset(self: *RecordScratch) void {
        self.writer.end = 0;
        self.allocation_failed = false;
    }

    fn grow(self: *RecordScratch, additional: usize) std.Io.Writer.Error!void {
        var storage: std.ArrayList(u8) = .{
            .items = self.writer.buffered(),
            .capacity = self.writer.buffer.len,
        };
        storage.ensureUnusedCapacity(self.allocator, additional) catch {
            self.allocation_failed = true;
            return error.WriteFailed;
        };
        self.writer.buffer = storage.allocatedSlice();
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *RecordScratch = @fieldParentPtr("writer", writer);
        const start = writer.end;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.grow(bytes.len);
            @memcpy(writer.buffer[writer.end..][0..bytes.len], bytes);
            writer.end += bytes.len;
        }
        const pattern = data[data.len - 1];
        const total = std.math.mul(usize, pattern.len, splat) catch {
            self.allocation_failed = true;
            return error.WriteFailed;
        };
        try self.grow(total);
        for (0..splat) |_| {
            @memcpy(writer.buffer[writer.end..][0..pattern.len], pattern);
            writer.end += pattern.len;
        }
        return writer.end - start;
    }

    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

    fn rebase(writer: *std.Io.Writer, _: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *RecordScratch = @fieldParentPtr("writer", writer);
        try self.grow(capacity);
    }
};

/// How `writeValue` spells a value. The same two settings as
/// `Writer.Options`, and the same defaults.
pub const ValueOptions = struct {
    /// When false, an optional field that is `null` is left out rather than
    /// written as `null`. `std.json`'s own default is true: a caller whose
    /// bytes must be the ones `std.json.Stringify.value(v, .{}, w)` writes
    /// says so here.
    emit_null_optional_fields: bool = false,
    /// When true, non-ASCII characters are written as `\uXXXX` escapes.
    escape_unicode: bool = false,
};

/// Writes one value's JSON, minified, with no terminator: the bytes a line
/// holds, for a caller that frames the line itself — an envelope around the
/// value, a checksum after it, a length in front of it.
///
/// The encoding is `Writer`'s, which is `std.json`'s byte for byte under the
/// same options. A value that fits in the unused part of `output`'s buffer
/// is encoded there directly, and one that does not goes through `output`'s
/// interface, which drains or grows it as `output` does.
pub fn writeValue(output: *std.Io.Writer, value: anytype, options: ValueOptions) std.Io.Writer.Error!void {
    const encoding: std.json.Stringify.Options = .{
        .emit_null_optional_fields = options.emit_null_optional_fields,
        .escape_unicode = options.escape_unicode,
    };
    if (comptime encode.supports(@TypeOf(value))) {
        if (output.end < output.buffer.len) {
            if (encode.valueBuffer(value, encoding, output.buffer[output.end..])) |written| {
                output.end += written;
                return;
            } else |_| {}
        }
        return encode.value(value, encoding, output);
    }
    return std.json.Stringify.value(value, encoding, output);
}

test writeValue {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // A record framed by its caller: the value, then what the caller adds.
    try out.writer.writeAll("{\"seq\":1,\"ev\":");
    try writeValue(&out.writer, .{ .kind = "open", .note = @as(?[]const u8, null) }, .{ .emit_null_optional_fields = true });
    try out.writer.writeAll("}");
    try std.testing.expectEqualStrings("{\"seq\":1,\"ev\":{\"kind\":\"open\",\"note\":null}}", out.written());
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
        error.SyncFailed, error.LineTooLong, error.OutOfMemory => unreachable,
    };
}

test writeLine {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeLine(&out.writer, .{ .kind = "open", .at = 17, .note = @as(?[]const u8, null) });
    try std.testing.expectEqualStrings("{\"kind\":\"open\",\"at\":17}\n", out.written());
}
