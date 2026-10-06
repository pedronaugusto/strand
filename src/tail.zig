//! Reading a JSON Lines file backwards: the last line first, and only the
//! bytes that takes.
//!
//! A log answers most questions from its end — what happened last, what the
//! last hundred events were, when the process stopped — and a file that has
//! grown for a week should not have to be read from the start to answer them.
//! `Tail` walks a seekable file from its end towards its beginning, reading
//! one block at a time and stopping as soon as the caller does.
//!
//! It is the same line layer as `Reader`, with the same borrow rule and the
//! same treatment of `\r\n`, blank lines, control bytes and byte-order marks.
//! What it cannot do is count: a backwards read never learns how many lines
//! came before the ones it read, so `Line.number` counts back from the end,
//! 1 being the last line of the file.
//!
//! The other thing it does not do is `.pretty`. `Tail.Options` is where the
//! setting would be, and it carries the reason it is not there.
const codec_module = @import("codec.zig");
const control_module = @import("control.zig");
const owned_module = @import("owned.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const strand = struct {
    pub const Line = line_mod.Line;
    pub const RawLine = line_mod.RawLine;
    pub const separator = line_mod.separator;
    pub const DuplicateFields = codec_module.parser.DuplicateFields;
    pub const parseLine = codec_module.parser.parseLine;
    pub const indexOfControl = control_module.indexOfControl;
};
const line_mod = @import("line.zig");
const Fault = line_mod.Fault;
const Line = strand.Line;

/// The policy types of every `Tail`, whatever its record type: shared,
/// so that options and errors mean the same thing across instantiations.
const shared = struct {
    /// Reading and parsing policy, fixed at `init`.
    ///
    /// The same policy as `Reader.Options`, minus the two settings a
    /// backwards read cannot honour.
    ///
    /// **`require_terminator`** is absent because a file being appended
    /// to is `Follower`'s job, not this one's.
    ///
    /// **`format`** is absent because joining lines needs an answer to
    /// "is this the whole of a value, or only part of one", and there is
    /// one answer only going forwards. `Reader` in `.pretty` mode joins
    /// on `error.UnexpectedEndOfInput`, which `std.json` gives when a
    /// value is cut off at the end: a definite signal, and the only
    /// failure that means "the rest is on the next line". Backwards there
    /// is no mirror of it. `std.json` has no notion of a valid *tail* of
    /// a value, so a lone `}` is a syntax error exactly as `not json` is,
    /// and a backwards join would have to treat every failure as "not the
    /// beginning yet" and keep prepending lines.
    ///
    /// That is sound on a file this package wrote — no line-aligned
    /// proper suffix of an indented record is itself a complete value,
    /// because such a suffix starts inside a container and so carries
    /// unmatched closing brackets — and it is unbounded on anything else.
    /// One damaged line would prepend until `max_line_bytes`: with the
    /// default megabyte over thirty-byte lines, tens of thousands of
    /// parse attempts over ever longer slices, ending in one malformed
    /// record that has swallowed every good record inside it. Forwards, a
    /// syntax error costs exactly one line. `Tail` exists to be cheap and
    /// to survive a log damaged at its end, and a `.pretty` mode would
    /// give up both.
    ///
    /// The cheap way out would be counting brackets backwards instead of
    /// parsing, and it needs to know whether a `"` opens a string or
    /// closes one — a fact about everything to the left of it. Which is
    /// to say: finding where a multi-line record begins means parsing
    /// forwards.
    pub const Options = struct {
        /// See `ParseOptions.ignore_unknown_fields`.
        ignore_unknown_fields: bool = true,
        /// See `ParseOptions.duplicate_fields`.
        duplicate_fields: strand.DuplicateFields = .@"error",
        /// See `ParseOptions.max_depth`.
        max_depth: usize = codec_module.parser.default_max_depth,
        /// The longest line accepted, in bytes. A longer one is
        /// `error.LineTooLong`, and is discarded whole: `prev` continues
        /// with the line before it. The terminator and a leading
        /// byte-order mark are excluded. In separator mode only the JSON
        /// payload counts: the separator and discarded torn prefix do not.
        max_line_bytes: usize = 1 << 20,
        /// When true, a line that is empty or all spaces and tabs is
        /// passed over. Its number is still counted.
        skip_blank: bool = true,
        /// See `Reader.Options.reject_control_bytes`.
        reject_control_bytes: bool = true,
        /// See `Reader.Options.record_separator`. A backwards read
        /// treats a line the same way a forwards one does: the record is
        /// what follows the first separator on it, and a line with none
        /// is `error.MissingSeparator`. The discarded prefix can be any
        /// length without growing the retained payload buffer.
        record_separator: bool = false,
        /// When true, a UTF-8 byte-order mark at the very start of the
        /// file is not part of the first line — which a backwards read
        /// only ever meets last.
        skip_bom: bool = true,
        /// See `Reader.Options.on_malformed`.
        on_malformed: enum { fail, skip } = .fail,
        /// See `LineReader.Options.crlf`.
        crlf: bool = true,
        /// Where the file ends for this reader: its length when `null`.
        /// A log that reserves space ahead of its records — zeros a
        /// writer has not filled yet — reads back from where its
        /// records end. Past the file's length is `error.Truncated`.
        end: ?u64 = null,
        /// How many bytes one read asks the file for. The buffer holds
        /// one of these plus the line being assembled, so this trades a
        /// syscall per block against the memory a `Tail` costs while it
        /// is open. Zero means the smallest supported block, one byte.
        block_bytes: usize = 64 * 1024,
    };

    /// What `init` can report: the file could not be measured. A stream
    /// with no size — a pipe, a socket — is `error.Streaming`, which is
    /// this package saying "there is no end to start from".
    pub const InitError = std.Io.File.Reader.SizeError;

    /// What `prev` can report.
    ///
    /// The first three are about a line, and none of them loses the
    /// reader its place: the offending line has been passed over whole
    /// and `prev` can be called again for the one before it. The rest are
    /// about the file or the allocator.
    ///
    /// | Error | Meaning |
    /// |---|---|
    /// | `MalformedLine` | This line is not a `T`; see `fault.err`. |
    /// | `ControlByte` | This line holds a raw control byte; see `fault.offset`. |
    /// | `MissingSeparator` | This line has no record on it; see `Options.record_separator`. |
    /// | `LineTooLong` | This line ran past `max_line_bytes`. |
    /// | `ReadFailed` | The file refused a read; ask `source` for diagnostics. |
    /// | `SeekFailed` | The file refused a seek; ask `source.seek_err`. |
    /// | `Truncated` | The file is shorter than when `init` measured it. |
    /// | `OutOfMemory` | The allocator failed. |
    pub const NextError = error{
        MalformedLine,
        ControlByte,
        MissingSeparator,
        LineTooLong,
        ReadFailed,
        SeekFailed,
        Truncated,
        OutOfMemory,
    };
};

/// A stream of `T` read from the end of a seekable file towards its start.
///
/// The reverse of `Reader`, and its mirror image in every way that matters:
/// buffers holding one block and the current line, one arena holding what
/// parsing it allocated, all recycled by `prev`, and a value that must be
/// copied out (`keep`) to outlive the line it came from.
///
/// The buffers hold one block plus the line being assembled, so the cost of a
/// backwards read is the cost of the lines it actually returns — a `last(10)`
/// over a gigabyte reads one block.
pub fn Tail(comptime T: type) type {
    return struct {
        /// The file. Not owned: this reader never closes it. It seeks it, and
        /// leaves it wherever the last block read left it, so a caller that
        /// also reads the file forwards must seek it back itself.
        source: *std.Io.File.Reader,
        /// Read-only after `init`.
        options: Options,
        /// How many lines `prev` has returned or refused, blank and skipped
        /// lines included. Also the number of the line `prev` last returned,
        /// counting back from the end of the file: 1 is the last line.
        number: u64 = 0,
        /// The byte offset in the file of the first byte of the line `prev`
        /// last returned.
        offset: u64 = 0,
        /// How many records `prev` passed over under
        /// `on_malformed = .skip`. See `LineReader.skipped`.
        skipped: u64 = 0,
        /// What this reader would not hand over, and why, in the same
        /// backwards numbering. See `Fault`.
        fault: Fault = .{},

        /// Internal. The allocator behind `buf` and `arena`.
        allocator: Allocator,
        /// Internal. File bytes `[lo, lo + buf.items.len)`. The lines not yet
        /// returned end at `lo + end`; what is past `end` has been handed out
        /// already and is what the next `prev` overwrites.
        buf: std.ArrayList(u8) = .empty,
        /// Internal. The bounded suffix of a separated physical line. The
        /// block buffer is reused while its torn prefix is scanned and dropped.
        record: std.ArrayList(u8) = .empty,
        /// Internal. See `buf`.
        lo: u64 = 0,
        /// Internal. See `buf`.
        end: usize = 0,
        /// Internal. Set when the line beginning at offset 0 has been
        /// returned: there is nothing before it.
        exhausted: bool = false,
        /// Internal. Set once the file's own last byte has been looked at,
        /// which is where a final newline is dropped.
        trimmed: bool = false,
        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub const Options = shared.Options;

        pub const InitError = shared.InitError;

        pub const NextError = shared.NextError;

        /// A backwards reader over `source`, positioned at its end.
        ///
        /// Measures the file once, from the file handle's current length, and
        /// works within that size for the rest of its life: a file that grows
        /// afterwards is not read, and a file that shrinks is
        /// `error.Truncated`. That is the contract that makes a backwards
        /// read meaningful at all — it is a view of the file as it was when
        /// the tail opened.
        pub fn init(allocator: Allocator, source: *std.Io.File.Reader, options: Options) InitError!Self {
            var normalized = options;
            if (normalized.block_bytes == 0) normalized.block_bytes = 1;
            if (source.size_err) |err| return err;
            const length = try source.file.length(source.io);
            source.size = length;
            const size = normalized.end orelse length;
            return .{
                .source = source,
                .options = normalized,
                .allocator = allocator,
                .arena = .init(allocator),
                .lo = size,
                .end = 0,
                // A file ending in a newline does not end in an empty line:
                // that byte is the terminator of the last line, not a line of
                // its own. An empty file has no lines at all.
                .exhausted = size == 0,
            };
        }

        /// Releases the block buffer and the arena. Every `Line` this reader
        /// returned, and every string borrowed from one, dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
            self.record.deinit(self.allocator);
            self.arena.deinit();
            self.* = undefined;
        }

        /// The line before the last one returned, or `null` once the line at
        /// offset 0 has been given out.
        ///
        /// Ownership: exactly `Reader.next`'s. The returned `Line` borrows the
        /// reader's block buffer and its arena, and the next call to `prev`
        /// takes both back. `keep` is how a value outlives its line.
        pub fn prev(self: *Self) NextError!?Line(T) {
            while (true) {
                const raw = (try self.prevRaw()) orelse return null;
                _ = self.arena.reset(.retain_capacity);
                const value = strand.parseLine(T, self.arena.allocator(), raw.line, .{
                    .ignore_unknown_fields = self.options.ignore_unknown_fields,
                    .duplicate_fields = self.options.duplicate_fields,
                    .max_depth = self.options.max_depth,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |parse_err| {
                        self.fault.parse(raw.number, parse_err, line_mod.whereItFailed(
                            T,
                            self.arena.allocator(),
                            raw.line,
                            self.options,
                        ));
                        switch (self.options.on_malformed) {
                            .fail => return error.MalformedLine,
                            .skip => {
                                self.skipped += 1;
                                continue;
                            },
                        }
                    },
                };
                return .{ .value = value, .line = raw.line, .number = raw.number, .offset = raw.offset };
            }
        }

        /// The line before the last one returned, as its bytes: framed,
        /// held to the bound and checked for damage as `prev` does, and not
        /// parsed. `LineReader.next` read backwards, for a caller with its
        /// own reading of a line — a log whose record is more than a value.
        ///
        /// Ownership: the bytes borrow the reader's block buffer, and the
        /// next `prev` or `prevRaw` takes them back.
        pub fn prevRaw(self: *Self) NextError!?strand.RawLine {
            assert(self.end <= self.buf.items.len);
            defer assert(self.end <= self.buf.items.len);
            while (true) {
                var raw = if (self.options.record_separator)
                    (self.prevSeparated() catch |err| switch (err) {
                        error.MissingSeparator => switch (self.options.on_malformed) {
                            .fail => return err,
                            .skip => {
                                self.skipped += 1;
                                continue;
                            },
                        },
                        else => return err,
                    }) orelse return null
                else
                    (try self.prevPhysical()) orelse return null;
                const number = self.number;

                // The terminator is not part of the line, and neither is a
                // mark at the very start of the file.
                if (self.options.crlf) raw = line_mod.trimCr(raw);
                if (!self.options.record_separator and self.options.skip_bom and self.offset == 0 and
                    std.mem.startsWith(u8, raw, line_mod.bom))
                {
                    raw = raw[line_mod.bom.len..];
                    // The mark is not part of the line, so it is not where
                    // the line begins either.
                    self.offset = line_mod.bom.len;
                }

                if (!self.options.record_separator and self.options.skip_blank and line_mod.isBlank(raw)) continue;
                if (self.options.reject_control_bytes) {
                    if (strand.indexOfControl(raw)) |at| {
                        self.fault.control(number, at);
                        switch (self.options.on_malformed) {
                            .fail => return error.ControlByte,
                            .skip => {
                                self.skipped += 1;
                                continue;
                            },
                        }
                    }
                }
                return .{ .line = raw, .number = number, .offset = self.offset };
            }
        }

        /// A copy of `line.value` that outlives the reader, allocated on
        /// `allocator`. See `Reader.keep`, whose contract this is.
        pub fn keep(self: *Self, allocator: Allocator, line: Line(T)) Allocator.Error!T {
            _ = self;
            return owned_module.copyOwned(allocator, line.value);
        }

        /// The last `n` values of the file, in file order, allocated on
        /// `allocator`.
        ///
        /// Ownership: everything the result points at is on `allocator`, and
        /// none of it borrows the reader. Each line is parsed normally and
        /// copied through `copyOwned`, under the same data contract as `keep`.
        /// With an arena, drop it whole; otherwise `freeOwned` each value and
        /// free the returned slice. A failure releases the partial batch.
        /// Fewer than `n` values means the file ran out; under
        /// `on_malformed = .skip` a skipped line is not one of the `n`.
        ///
        /// This is the whole reason to read a file backwards, so it is worth
        /// saying what it costs: one block read per block the last `n` lines
        /// span, and nothing at all for the rest of the file.
        pub fn last(self: *Self, allocator: Allocator, n: usize) NextError![]T {
            var out: std.ArrayList(T) = .empty;
            errdefer {
                for (out.items) |value| owned_module.freeOwned(allocator, value);
                out.deinit(allocator);
            }
            try out.ensureTotalCapacity(allocator, @min(n, 1024));
            while (out.items.len < n) {
                const line = (try self.prev()) orelse break;
                try out.ensureUnusedCapacity(allocator, 1);
                out.appendAssumeCapacity(try self.keep(allocator, line));
            }
            std.mem.reverse(T, out.items);
            return out.toOwnedSlice(allocator);
        }

        /// Frames a separated line while scanning back to its beginning.
        /// Keep only its bounded rightmost bytes, but look for the first
        /// separator across the whole physical line. An earlier separator
        /// can turn a short candidate into an overlong payload; a torn
        /// prefix with no separator cannot.
        fn prevSeparated(self: *Self) NextError!?[]const u8 {
            while (!self.exhausted) {
                self.record.clearRetainingCapacity();
                var suffix_bytes: u64 = 0;
                var payload_bytes: ?u64 = null;
                var separator_offset: u64 = 0;
                var blank = true;
                var marked_bytes: u2 = 0;
                var trailing_cr = false;
                // Every separator starts a record, so each one before the
                // last on the line starts a torn record, and so does anything
                // but whitespace in front of the first.
                var torn: u64 = 0;
                var prefix_torn = false;
                while (true) {
                    if (self.end == 0 and self.lo > 0) try self.fillBefore();
                    const newline = lastNewline(self.buf.items[0..self.end]);
                    const start = if (newline) |at| at + 1 else 0;
                    const chunk = self.buf.items[start..self.end];
                    const chunk_offset = self.lo + start;
                    if (suffix_bytes == 0 and chunk.len != 0)
                        trailing_cr = self.options.crlf and chunk[chunk.len - 1] == '\r';

                    if (payload_bytes == null) {
                        if (std.mem.lastIndexOfScalar(u8, chunk, strand.separator)) |at| {
                            payload_bytes = suffix_bytes + chunk.len - at - 1 - @intFromBool(trailing_cr);
                            separator_offset = chunk_offset + at;
                            torn += std.mem.countScalar(u8, chunk[0..at], strand.separator);
                            const first = std.mem.indexOfScalar(u8, chunk, strand.separator).?;
                            prefix_torn = hasContent(chunk[0..first]);
                        }
                    } else if (std.mem.indexOfScalar(u8, chunk, strand.separator)) |first| {
                        torn += std.mem.countScalar(u8, chunk, strand.separator);
                        prefix_torn = hasContent(chunk[0..first]);
                    } else prefix_torn = prefix_torn or hasContent(chunk);
                    if (blank) for (chunk, 0..) |byte, at| {
                        const position = chunk_offset + at;
                        if (byte == ' ' or byte == '\t') continue;
                        if (suffix_bytes == 0 and at + 1 == chunk.len and trailing_cr) continue;
                        if (self.options.skip_bom and position < line_mod.bom.len and
                            byte == line_mod.bom[@intCast(position)])
                        {
                            marked_bytes += 1;
                            continue;
                        }
                        blank = false;
                        break;
                    };

                    // At most the bound plus the possible CR is retained.
                    // Once that suffix is full, all earlier bytes are only
                    // scanned; they cannot be part of an accepted payload.
                    const room = (self.options.max_line_bytes +| 1) - self.record.items.len;
                    const take = @min(room, chunk.len);
                    if (take != 0) {
                        const kept = self.record.items.len;
                        const capacity = @min(self.options.max_line_bytes +| 1, @max(kept + take, self.record.capacity *| 2));
                        try self.record.ensureTotalCapacityPrecise(self.allocator, capacity);
                        self.record.items.len = kept + take;
                        std.mem.copyBackwards(u8, self.record.items[take..], self.record.items[0..kept]);
                        @memcpy(self.record.items[0..take], chunk[chunk.len - take ..]);
                    }
                    suffix_bytes += chunk.len;
                    self.end = if (newline) |at| at else 0;
                    if (newline != null or self.lo == 0) {
                        self.exhausted = newline == null;
                        self.number += 1;
                        self.offset = if (payload_bytes != null) separator_offset else chunk_offset;
                        break;
                    }
                }
                const length = payload_bytes orelse {
                    if (marked_bytes != 0 and marked_bytes != line_mod.bom.len) blank = false;
                    if (blank and self.options.skip_blank) continue;
                    self.fault.framing(self.number);
                    return error.MissingSeparator;
                };
                torn += @intFromBool(prefix_torn);
                if (torn != 0) {
                    self.skipped += torn;
                    self.fault.framing(self.number);
                }
                if (length > self.options.max_line_bytes) {
                    self.fault.framing(self.number);
                    return error.LineTooLong;
                }
                const physical: usize = @intCast(length + @intFromBool(trailing_cr));
                return self.record.items[self.record.items.len - physical ..];
            }
            return null;
        }

        /// The bytes of the line before the last one returned, terminator
        /// excluded, or `null` at the start of the file. Counts the line.
        fn prevPhysical(self: *Self) NextError!?[]const u8 {
            if (self.exhausted) return null;
            var over = false;
            while (true) {
                if (lastNewline(self.buf.items[0..self.end])) |i| {
                    const line = self.buf.items[i + 1 .. self.end];
                    self.offset = self.lo + i + 1;
                    // The newline at `i` terminates the line before this one.
                    self.end = i;
                    self.number += 1;
                    return self.emit(line, over);
                }
                if (self.lo == 0) {
                    const line = self.buf.items[0..self.end];
                    self.offset = 0;
                    self.end = 0;
                    self.exhausted = true;
                    self.number += 1;
                    return self.emit(line, over);
                }
                if (!over and self.end > self.options.max_line_bytes +| line_mod.bom.len +| 1) {
                    // Longer than the bound allows to be held: drop what has
                    // been read of it and keep scanning back for where it
                    // began, so that the line before it is still reachable.
                    over = true;
                }
                if (over) {
                    self.end = 0;
                    self.buf.clearRetainingCapacity();
                }
                try self.fillBefore();
            }
        }

        /// Hands over a line, or refuses it for its length. `over` is set when
        /// the line was already too long to hold, in which case its bytes
        /// have been dropped and only its extent is known.
        fn emit(self: *Self, line: []const u8, over: bool) NextError!?[]const u8 {
            if (!over) {
                var record = if (self.options.crlf) line_mod.trimCr(line) else line;
                if (self.options.skip_bom and self.offset == 0 and
                    std.mem.startsWith(u8, record, line_mod.bom))
                {
                    record = record[line_mod.bom.len..];
                }
                if (record.len <= self.options.max_line_bytes) return line;
            }
            self.fault.framing(self.number);
            return error.LineTooLong;
        }

        /// Prepends the block of file bytes that ends where the buffer begins.
        fn fillBefore(self: *Self) NextError!void {
            assert(self.lo > 0);
            assert(self.end <= self.buf.items.len);
            const old_lo = self.lo;
            const take: usize = @intCast(@min(self.options.block_bytes, self.lo));
            const kept = self.end;

            self.buf.items.len = kept;
            if (self.options.record_separator) {
                try self.buf.ensureTotalCapacityPrecise(self.allocator, kept + take);
            } else {
                try self.buf.ensureTotalCapacity(self.allocator, kept + take);
            }
            self.buf.items.len = kept + take;
            // The two regions overlap, and the destination is the later one.
            std.mem.copyBackwards(u8, self.buf.items[take..], self.buf.items[0..kept]);

            self.source.seekTo(self.lo - take) catch return error.SeekFailed;
            self.source.interface.readSliceAll(self.buf.items[0..take]) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                // The file was this long when `init` measured it.
                error.EndOfStream => return error.Truncated,
            };
            self.lo -= take;
            self.end = kept + take;
            assert(self.lo < old_lo);
            assert(self.lo + take == old_lo);
            assert(self.end == self.buf.items.len);

            if (!self.trimmed) {
                self.trimmed = true;
                // A file ending in a newline ends with a terminator, not with
                // an empty line, so that byte is not part of any line.
                if (self.end > 0 and self.buf.items[self.end - 1] == '\n') {
                    self.end -= 1;
                    self.buf.items.len -= 1;
                }
            }
        }
    };
}

/// The offset of the last `\n` in `bytes`, or `null`.
///
/// Every line a backwards read returns is found by this, and the block it is
/// looking in is as large as the caller made `block_bytes`, so it reads a
/// register's worth of bytes at a time from the end rather than one. Nothing
/// in `std` vectorises a scan that runs backwards; the forwards one is
/// `std.mem.findScalarPos`, and this is its mirror.
fn lastNewline(bytes: []const u8) ?usize {
    var i = bytes.len;
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            const block_type = @Vector(block_len, u8);
            const wanted: block_type = @splat('\n');
            while (i >= block_len) : (i -= block_len) {
                const block: block_type = bytes[i - block_len ..][0..block_len].*;
                const matches = block == wanted;
                // The last line of a block is the first thing a backwards
                // read wants, so the usual case is one block and one answer.
                if (@reduce(.Or, matches)) {
                    return i - block_len + std.simd.lastTrue(matches).?;
                }
            }
        }
    }
    return std.mem.findScalarLast(u8, bytes[0..i], '\n');
}

test lastNewline {
    // The same answer as the loop it replaces, for a terminator at every
    // offset of every length up to four vectors, and for a buffer with none.
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    var buf: [4 * 64 + 3]u8 = undefined;
    const longest = @min(4 * block_len + 3, buf.len);

    for (0..longest) |len| {
        const bytes = buf[0..len];
        @memset(bytes, 'x');
        try testing.expectEqual(std.mem.findScalarLast(u8, bytes, '\n'), lastNewline(bytes));
        for (0..len) |at| {
            @memset(bytes, 'x');
            bytes[at] = '\n';
            try testing.expectEqual(@as(?usize, at), lastNewline(bytes));
            // And with a second one before it, the later of the two.
            if (at > 0) {
                bytes[at - 1] = '\n';
                try testing.expectEqual(@as(?usize, at), lastNewline(bytes));
            }
        }
    }
}

//=========================================================================
// Tests. A file has to exist for any of this, so each one writes its bytes
// into a temporary directory and reads them back.
//=========================================================================

/// Whether `bytes`, passed over in front of a line's first separator, hold
/// anything but whitespace: the tail of a record that was torn.
fn hasContent(bytes: []const u8) bool {
    for (bytes) |byte| switch (byte) {
        ' ', '\t', '\r' => {},
        else => return true,
    };
    return false;
}
