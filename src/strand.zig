//! Typed JSON Lines: one JSON value per line, read and written on top of
//! `std.json`.
//!
//! The format is the one append-only logs and line protocols already use — a
//! complete JSON value, then `\n`, and nothing else on the line. That makes a
//! file greppable, tailable and appendable, and it makes a stream framable
//! without a length prefix. `std.json` parses and emits the values; this
//! package is the line layer over it:
//!
//! * `Reader` turns a `*std.Io.Reader` into a stream of typed values, one per
//!   line, each carrying its 1-based line number, its raw bytes and the byte
//!   offset it began at — and `Reader.resumeAt` starts again from one of
//!   those offsets with the numbering intact.
//! * A malformed line is an error naming the line, not an abort, and can be
//!   skipped instead (`Options.on_malformed`).
//! * Strings borrow from the line's bytes when they need no unescaping, so
//!   the common case copies nothing. `Reader.keep` is how a value outlives
//!   the line it came from.
//! * `kindOf` and `tagOf` answer "what kind of line is this" from the first
//!   key alone, without parsing the value.
//! * `Writer` emits one value per line — minified, or indented for a human —
//!   and counts them, draining the destination and syncing the file under it
//!   as often as it is told to.
//! * `Tail` reads a seekable file backwards, last line first, without
//!   reading what comes before.
//! * `Follower` reads to the end and keeps reading, the way `tail -f` does,
//!   waiting on an `std.Io` and stopping when that `std.Io` cancels it — and,
//!   given an `Opener`, following the path across a rotation rather than the
//!   handle into a file nobody writes to any more.
//! * `Versioned` puts a schema version on a record and migrates an older one
//!   forward.
//!
//! What this package does NOT do: it does not parse JSON (`std.json` does),
//! does not buffer or own a stream, does not open a file except through an
//! `Opener` a caller hands it, does not lock or compress one, does not index
//! a log or seek to line *n*, does not
//! validate a line it is not asked to parse, and has no opinion about what a
//! line means. There is no global state and no dependency beyond `std`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Tail = @import("tail.zig").Tail;
pub const Follower = @import("follow.zig").Follower;
pub const Opener = @import("follow.zig").Opener;
pub const PathOpener = @import("follow.zig").PathOpener;
pub const Versioned = @import("versioned.zig").Versioned;
pub const payloadOf = @import("versioned.zig").payloadOf;

test {
    _ = @import("tests.zig");
    _ = @import("fuzz.zig");
    _ = @import("tail.zig");
    _ = @import("follow.zig");
    _ = @import("versioned.zig");
}

/// How a line's bytes are turned into a `T`.
///
/// The defaults are the ones a log or a protocol wants: a reader that is
/// older than the writer ignores fields it does not know, and a field the
/// writer omitted takes the Zig default declared on the struct. A field with
/// no default that is absent from the line is `error.MissingField`.
pub const ParseOptions = struct {
    /// When true, a key with no matching field is skipped. When false, it is
    /// `error.UnknownField`.
    ignore_unknown_fields: bool = true,
    /// When false, a string field that needs no unescaping points into the
    /// line's own bytes and nothing is allocated for it. When true, every
    /// string is copied out of the line, so the value borrows nothing from
    /// it.
    copy_strings: bool = false,
    /// What a line that names the same field twice does. `std.json`'s
    /// default, kept here, is to refuse it; the other two are what a log
    /// written by a language whose own encoder allows duplicates needs, since
    /// those encoders resolve a repeat by keeping one of the two.
    duplicate_fields: DuplicateFields = .@"error",
};

/// What a repeated key in one line means. The names are `std.json`'s.
pub const DuplicateFields = enum {
    /// `error.DuplicateField`, which through a `Reader` is
    /// `error.MalformedLine`.
    @"error",
    /// The first value wins and the rest are skipped.
    use_first,
    /// The last value wins, which is what most JSON encoders do.
    use_last,
};

/// Everything `std.json` can report about a line whose bytes are already in
/// memory. `error.OutOfMemory` is the allocator's; every other member means
/// the line did not describe a `T`.
pub const ParseLineError = std.json.ParseError(std.json.Scanner);

/// Parses one line's bytes as a `T`.
///
/// `line` is one JSON value with no line terminator; a trailing `\n` is
/// `error.SyntaxError`, because a JSON Lines line does not contain one.
///
/// Ownership: allocations are made on `allocator` and are not individually
/// tracked, so `allocator` should be an arena you can drop as a whole (this
/// is `std.json.parseFromSliceLeaky`'s contract). With the default
/// `copy_strings = false`, string fields that need no unescaping point into
/// `line` and are valid exactly as long as it is; with `copy_strings = true`
/// the returned value borrows nothing from `line`.
pub fn parseLine(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: ParseOptions,
) ParseLineError!T {
    return std.json.parseFromSliceLeaky(T, allocator, line, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .allocate = if (options.copy_strings) .alloc_always else .alloc_if_needed,
        .duplicate_field_behavior = switch (options.duplicate_fields) {
            .@"error" => .@"error",
            .use_first => .use_first,
            .use_last => .use_last,
        },
    });
}

test parseLine {
    const Event = struct {
        kind: []const u8,
        at: u64,
        note: ?[]const u8 = null,
        level: enum { info, warn } = .info,
    };

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"kind\":\"open\",\"at\":17,\"extra\":[1,2,3]}";
    const event = try parseLine(Event, arena.allocator(), line, .{});

    try std.testing.expectEqualStrings("open", event.kind);
    try std.testing.expectEqual(@as(u64, 17), event.at);
    // Absent fields take their declared defaults, and `extra` is ignored.
    try std.testing.expectEqual(@as(?[]const u8, null), event.note);
    try std.testing.expectEqual(.info, event.level);
    // "open" needed no unescaping, so it is a view into `line`.
    try std.testing.expect(event.kind.ptr == line.ptr + std.mem.indexOf(u8, line, "open").?);
}

/// One line of input: the value it parsed to, the bytes it parsed from, and
/// where it was.
///
/// Ownership is documented per field, and both borrowed fields are tied to
/// the reader that produced them; see `Reader.next`.
pub fn Line(comptime T: type) type {
    return struct {
        /// The parsed value. String fields either point into `line` or into
        /// the reader's per-line arena; either way they die when `line` does.
        value: T,
        /// The line's bytes, without the `\n` or `\r\n` that ended it, and
        /// without a leading byte-order mark. Owned by the reader, valid
        /// until the next call to `next` or `deinit`. In `.pretty` mode this
        /// is the whole record, newlines and all.
        line: []const u8,
        /// 1-based line number. `Reader` counts forwards from the start of
        /// the stream, blank and skipped lines included, so the number is the
        /// one a text editor shows; `Tail` counts backwards from the end of
        /// the file, because a backwards read never learns how many lines
        /// came before. In `.pretty` mode it is the number of the record's
        /// first line.
        number: u64,
        /// The byte offset of the record's first byte. `Tail` measures it
        /// from the start of the file; `Reader` measures it from wherever the
        /// reader started, which is the same thing for a reader started at
        /// the beginning, and which `Follower` seeds from the file position
        /// so that it is a file offset there too. A byte-order mark and the
        /// terminators of earlier lines are counted, so this is the offset a
        /// seek needs: it is what turns a line number into a place.
        offset: u64 = 0,
    };
}

/// How a value is laid out on the wire — the one thing a reader and a writer
/// have to agree about beyond the schema.
pub const Format = enum {
    /// One value per line, no whitespace between tokens. The usual thing: a
    /// line is a record, and a record is a line.
    minified,
    /// A value indented over several lines, for a human to read. The framing
    /// still holds — `std.json` escapes every line terminator that could
    /// appear inside a string, so a record ends at the first `\n` that is not
    /// part of one — but putting the record back together means joining lines
    /// until they parse, which only a reader in `.pretty` mode does.
    pretty,
};

/// A stream of `T`, one per line, over a `*std.Io.Reader`.
///
/// The reader owns two buffers and reuses both: the bytes of the current line,
/// and an arena holding whatever parsing that line had to allocate. Both are
/// recycled at the start of every `next`, which is what keeps memory bounded
/// over a stream of any length, and which is why a value must be copied out
/// (`keep`) to outlive the line it came from.
///
/// Threads: a `Reader` has no global state and no lock. Two readers on two
/// streams are independent and may run on two threads at once — that is what
/// `Follower`'s tests do — but one `Reader` is not shared between threads.
pub fn Reader(comptime T: type) type {
    return struct {
        /// The byte source. Not owned: this reader never closes or flushes it,
        /// and leaves it positioned just past the last line returned.
        input: *std.Io.Reader,
        /// Read-only after `init`.
        options: Options,
        /// The number of the line `next` last returned, which is also the
        /// count of physical lines consumed so far — blank, malformed and
        /// over-long lines included.
        number: u64 = 0,
        /// The byte offset of the record `next` last returned or refused,
        /// measured from where this reader started. See `Line.offset`.
        offset: u64 = 0,
        /// How many records `next` passed over under
        /// `on_malformed = .skip` — the count a stream that tolerates damage
        /// is judged by, since under `.skip` nothing else says a line was
        /// lost. Blank lines are not damage and are not counted.
        skipped: u64 = 0,
        /// The line number of the most recent `error.MalformedLine`,
        /// `error.LineTooLong`, `error.ControlByte`, or line skipped under
        /// `.skip`; 0 if there has been none.
        last_error_line: u64 = 0,
        /// What `std.json` said about the line at `last_error_line`. `null`
        /// for `error.LineTooLong` and `error.ControlByte`, neither of which
        /// reached `std.json`.
        last_error: ?ParseLineError = null,
        /// The 0-based offset within the line of the byte that tripped
        /// `error.ControlByte`. `null` for every other failure: `std.json`
        /// reports no offset, and this reader does not invent one.
        last_error_offset: ?usize = null,

        /// Internal. The current record's bytes; `Line.line` is a view of it.
        line_buf: std.Io.Writer.Allocating,
        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,
        /// Internal. Where in `line_buf` the current record starts. Always 0
        /// today; the field is what `joinPhysical` measures the record
        /// against, rather than the buffer.
        record_start: usize = 0,
        /// Internal. Whether the stream has been looked at for a byte-order
        /// mark, which happens once and before anything else is read.
        bom_checked: bool = false,
        /// Internal. Bytes taken from `input` so far, terminators and a
        /// byte-order mark included. `Line.offset` is a snapshot of this.
        consumed: u64 = 0,
        /// Internal. What `consumed` was when the current record began.
        record_offset: u64 = 0,

        const Self = @This();

        /// Reading and parsing policy, fixed at `init`.
        pub const Options = struct {
            /// See `ParseOptions.ignore_unknown_fields`.
            ignore_unknown_fields: bool = true,
            /// See `ParseOptions.duplicate_fields`.
            duplicate_fields: DuplicateFields = .@"error",
            /// The longest record accepted, in bytes, not counting the
            /// terminator; in `.pretty` mode this bounds the joined record
            /// rather than one physical line. A longer one is
            /// `error.LineTooLong`; the rest of it is discarded, so `next`
            /// can be called again to continue with the line after it. This
            /// bound is the reader's memory bound, and it is independent of
            /// the size of `input`'s buffer.
            max_line_bytes: usize = 1 << 20,
            /// When true, a line that is empty or all spaces and tabs is
            /// consumed and not returned. Its number is still counted.
            skip_blank: bool = true,
            /// See `Format`. A `.pretty` reader also reads minified lines,
            /// since a minified record simply parses on its first line; the
            /// cost of the tolerance is that a truncated line joins with the
            /// one after it instead of failing on the spot.
            format: Format = .minified,
            /// When true, a C0 control byte other than tab — a NUL above all,
            /// which is what a torn write or a half-written block leaves
            /// behind — is `error.ControlByte` naming the line and the offset,
            /// rather than whatever `std.json` would have made of it.
            ///
            /// JSON forbids these bytes raw in a string and has no use for
            /// them between tokens, so this refuses nothing that was valid;
            /// it costs one scan of the line and buys an error that says what
            /// actually happened.
            reject_control_bytes: bool = true,
            /// When true, a final line the stream has not terminated with a
            /// `\n` is not a line: `next` returns `null`, `number` does not
            /// advance, and the bytes are dropped. This is what a reader of a
            /// file still being appended to wants, because the last line of
            /// such a file is usually half-written; see `Follower`, which
            /// rewinds and reads it again once the writer has finished it.
            ///
            /// When false — the default, and what a finished file wants — a
            /// final line with no terminator is a line like any other.
            require_terminator: bool = false,
            /// When true, a UTF-8 byte-order mark at the very start of the
            /// stream is not part of the first line. Editors and Windows
            /// tooling put one there; `std.json` has no idea what it is.
            skip_bom: bool = true,
            /// What a line that is not a `T` does.
            on_malformed: enum {
                /// `next` returns `error.MalformedLine` or
                /// `error.ControlByte`.
                fail,
                /// `next` moves on to the following line.
                skip,
            } = .fail,
        };

        /// What `next` can report.
        ///
        /// The parse errors of `std.json` collapse into `MalformedLine`,
        /// which says "this line, the one at `last_error_line`, is not a
        /// `T`"; `last_error` holds which parse error it was. `ControlByte`
        /// is the same claim about a line `std.json` was not shown, made
        /// before parsing because a control byte in a line means the line is
        /// damaged rather than merely wrong. The other three are not about
        /// the content of a line: `OutOfMemory` is the allocator's,
        /// `ReadFailed` is the stream's (ask it for diagnostics), and
        /// `LineTooLong` is this reader's own bound.
        pub const NextError = error{
            MalformedLine,
            ControlByte,
            LineTooLong,
            ReadFailed,
            OutOfMemory,
        };

        /// Where a resumed reader begins: the place it is reading from, and
        /// how much of the file is behind it. See `resumeAt`.
        pub const Start = struct {
            /// The byte offset `input` is positioned at. Every offset this
            /// reader reports is measured from here, so an offset taken out
            /// of an index reads back as the same offset.
            offset: u64 = 0,
            /// How many lines came before that offset. The first line this
            /// reader returns is numbered `lines_before + 1`, so a line
            /// number taken out of an index reads back as the same line
            /// number.
            lines_before: u64 = 0,
        };

        /// A reader over `input`, with `allocator` backing the line buffer and
        /// the per-line arena. Does not read from `input`.
        pub fn init(allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
            return .resumeAt(allocator, input, options, .{});
        }

        /// A reader over an `input` already positioned part-way into a file,
        /// numbering and placing its lines as if it had read the rest.
        ///
        /// This is the other half of `Line.offset`. An index is a list of
        /// offsets and the line numbers they belong to; `init` would read
        /// back from such an offset as line 1 at offset 0, which makes the
        /// index a place and not a line number. `resumeAt` is told both, so
        /// the line it returns first carries the number and the offset the
        /// index recorded, and every line after it carries the next ones.
        ///
        /// `input` must already be positioned at `start.offset` — this reader
        /// does not seek, because it does not own the stream. A byte-order
        /// mark is looked for only at offset 0, since that is the only place
        /// one can be.
        ///
        /// `start.lines_before` is not checked against anything: a reader
        /// cannot know what it did not read. An offset that is not where a
        /// line begins reads as a line beginning there, which is the same
        /// answer a caller would get by seeking a file and reading it.
        pub fn resumeAt(
            allocator: Allocator,
            input: *std.Io.Reader,
            options: Options,
            start: Start,
        ) Self {
            return .{
                .input = input,
                .options = options,
                .number = start.lines_before,
                .offset = start.offset,
                .line_buf = .init(allocator),
                .arena = .init(allocator),
                .consumed = start.offset,
                .record_offset = start.offset,
                // A mark belongs to the very start of a file, so a reader
                // that begins anywhere else must not eat three bytes of a
                // line looking for one.
                .bom_checked = start.offset != 0,
            };
        }

        /// Releases the line buffer and the arena. Every `Line` this reader
        /// returned, and every string borrowed from one, dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.line_buf.deinit();
            self.arena.deinit();
            self.* = undefined;
        }

        /// The next line, or `null` at end of stream.
        ///
        /// Ownership: the returned `Line` borrows from the reader. Its `line`
        /// field is the reader's line buffer, and the value's strings point
        /// either into that buffer (when they needed no unescaping) or into
        /// the reader's arena (when they did). The next call to `next`
        /// overwrites the buffer and resets the arena, so everything the
        /// previous `Line` pointed at is gone by the time the next one is
        /// returned. To keep a value past that point, call `keep`.
        ///
        /// `error.MalformedLine`, `error.ControlByte` and
        /// `error.LineTooLong` do not desynchronize the stream: the offending
        /// line has been consumed in full, and calling `next` again continues
        /// with the one after it. `error.ReadFailed` and `error.OutOfMemory`
        /// can arrive in the middle of a line, and leave the stream wherever
        /// they found it.
        pub fn next(self: *Self) NextError!?Line(T) {
            record: while (true) {
                self.line_buf.writer.end = 0;
                self.record_start = 0;

                var record = (try self.readPhysical()) orelse return null;
                const number = self.number;
                if (self.options.skip_blank and isBlank(record)) continue :record;
                const offset = self.record_offset;
                self.offset = offset;
                if (try self.checkControl(record, 0, number)) {
                    self.skipped += 1;
                    continue :record;
                }

                while (true) {
                    _ = self.arena.reset(.retain_capacity);
                    if (parseLine(T, self.arena.allocator(), record, .{
                        .ignore_unknown_fields = self.options.ignore_unknown_fields,
                        .duplicate_fields = self.options.duplicate_fields,
                        .copy_strings = false,
                    })) |value| {
                        return .{ .value = value, .line = record, .number = number, .offset = offset };
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.UnexpectedEndOfInput => if (self.options.format == .pretty) {
                            // A prefix of a value: the rest of it is on the
                            // lines that follow, unless there are none.
                            if (try self.joinPhysical(number)) |joined| {
                                record = joined;
                                continue;
                            }
                            self.fault(number, error.UnexpectedEndOfInput);
                            switch (self.options.on_malformed) {
                                .fail => return error.MalformedLine,
                                .skip => {
                                    self.skipped += 1;
                                    continue :record;
                                },
                            }
                        } else {
                            self.fault(number, error.UnexpectedEndOfInput);
                            switch (self.options.on_malformed) {
                                .fail => return error.MalformedLine,
                                .skip => {
                                    self.skipped += 1;
                                    continue :record;
                                },
                            }
                        },
                        else => |parse_err| {
                            self.fault(number, parse_err);
                            switch (self.options.on_malformed) {
                                .fail => return error.MalformedLine,
                                .skip => {
                                    self.skipped += 1;
                                    continue :record;
                                },
                            }
                        },
                    }
                }
            }
        }

        /// A copy of `line.value` that outlives the reader, allocated on
        /// `allocator`.
        ///
        /// Ownership: the result borrows nothing — not from the reader's line
        /// buffer, not from its arena — so it stays valid across any number of
        /// further `next` calls and past `deinit`. Allocations are not
        /// individually tracked, so `allocator` should be an arena the caller
        /// frees as a whole.
        ///
        /// This re-parses `line.line` with every string copied rather than
        /// handing over pages: a value from `next` points partly into the
        /// reader's line buffer, which the reader must keep reusing, so there
        /// is nothing whole to hand over. In practice the only error is
        /// `error.OutOfMemory`, since these bytes have already parsed once —
        /// but a `T` with a custom `jsonParse` method is free to disagree, so
        /// the full set is reported rather than asserted away.
        pub fn keep(self: *Self, allocator: Allocator, line: Line(T)) ParseLineError!T {
            return parseLine(T, allocator, line.line, .{
                .ignore_unknown_fields = self.options.ignore_unknown_fields,
                .duplicate_fields = self.options.duplicate_fields,
                .copy_strings = true,
            });
        }

        /// Records a parse failure against `number`, whatever is done about it.
        fn fault(self: *Self, number: u64, err: ParseLineError) void {
            self.last_error_line = number;
            self.last_error = err;
            self.last_error_offset = null;
        }

        /// Looks for a control byte in `record[from..]`. Returns true when the
        /// caller should skip this record; returns `error.ControlByte` when it
        /// should fail.
        fn checkControl(self: *Self, record: []const u8, from: usize, number: u64) NextError!bool {
            if (!self.options.reject_control_bytes) return false;
            const offset = indexOfControl(record[from..]) orelse return false;
            self.last_error_line = number;
            self.last_error = null;
            self.last_error_offset = from + offset;
            return switch (self.options.on_malformed) {
                .fail => error.ControlByte,
                .skip => true,
            };
        }

        /// Appends the next physical line to the current record, separated by
        /// the `\n` that ended the previous one. `null` when the stream ended
        /// first, in which case the record is left exactly as it was.
        fn joinPhysical(self: *Self, number: u64) NextError!?[]const u8 {
            const before = self.line_buf.writer.end;
            // The separator counts against the bound like any other byte.
            if (self.options.max_line_bytes -| (before - self.record_start) == 0) {
                // It is the record that is too long, and the record began at
                // `number`, whatever line the reader has reached since.
                self.last_error_line = number;
                self.last_error = null;
                self.last_error_offset = null;
                self.offset = self.record_offset;
                self.consumed += try self.discardLine();
                return error.LineTooLong;
            }
            self.line_buf.writer.writeByte('\n') catch return error.OutOfMemory;
            const joined = (try self.readPhysical()) orelse {
                self.line_buf.writer.end = before;
                return null;
            };
            if (try self.checkControl(joined, before + 1 - self.record_start, number)) return null;
            return joined;
        }

        /// Reads one physical line, appending its bytes to the line buffer
        /// without its terminator, and returns the record so far. `null` at
        /// end of stream, and at an unterminated final line under
        /// `require_terminator`. Counts the line.
        fn readPhysical(self: *Self) NextError!?[]const u8 {
            if (!self.bom_checked) {
                self.bom_checked = true;
                if (self.options.skip_bom) try self.skipBom();
            }

            const before = self.line_buf.writer.end;
            // The first physical line of a record is where the record begins,
            // and where it begins is what `Line.offset` reports.
            if (before == self.record_start) self.record_offset = self.consumed;
            const max = self.options.max_line_bytes;
            // One past the bound, so that a record of exactly `max` bytes is
            // accepted and the first byte over it is what trips the limit.
            // Saturating, because `Limit` reads a saturated `usize` as
            // unlimited, which is what a bound of `maxInt(usize)` means.
            const room = max -| (before - self.record_start);
            const n = self.input.streamDelimiterLimit(
                &self.line_buf.writer,
                '\n',
                .limited(room +| 1),
            ) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                // The only writer is `line_buf`, which fails only to allocate.
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => {
                    self.number += 1;
                    self.last_error_line = self.number;
                    self.last_error = null;
                    self.last_error_offset = null;
                    self.offset = self.record_offset;
                    self.consumed += self.line_buf.writer.end - before;
                    self.consumed += try self.discardLine();
                    return error.LineTooLong;
                },
            };
            assert(n <= room);
            self.consumed += n;

            // `streamDelimiterLimit` stops before the delimiter, so what is
            // next is either it or the end of the stream — unless the stream
            // is a file that grew in between, in which case what is next is
            // the rest of this very line. The byte is looked at rather than
            // taken, so that the third case consumes nothing and reads as
            // what it is: a line that is not finished yet.
            const terminated = if (self.input.peekByte()) |byte| byte == '\n' else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };
            if (terminated) {
                self.input.toss(1);
                self.consumed += 1;
            }
            if (!terminated) {
                // Nothing at all is the end of the stream; a final line with
                // no newline is a line unless the caller said otherwise.
                if (n == 0 or self.options.require_terminator) {
                    self.line_buf.writer.end = before;
                    return null;
                }
            }

            self.number += 1;
            // Tolerate CRLF: the `\r` belongs to the terminator, not the JSON.
            if (self.line_buf.writer.end > before and
                self.line_buf.writer.buffer[self.line_buf.writer.end - 1] == '\r')
            {
                self.line_buf.writer.end -= 1;
            }
            return self.line_buf.written()[self.record_start..];
        }

        /// Consumes a UTF-8 byte-order mark if the stream opens with one.
        /// Called once, before anything else is read.
        ///
        /// A stream whose own buffer cannot hold three bytes cannot be asked
        /// to peek at three, and cannot be carrying a mark worth finding, so
        /// it is left alone.
        fn skipBom(self: *Self) NextError!void {
            const bom = "\xEF\xBB\xBF";
            if (self.input.buffer.len < bom.len) return;
            const head = self.input.peek(bom.len) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            if (std.mem.eql(u8, head, bom)) {
                self.input.toss(bom.len);
                self.consumed += bom.len;
            }
        }

        /// Discards the remainder of an over-long line, terminator included,
        /// and says how many bytes that was. An over-long line with no
        /// terminator ends the stream, so what it discarded is not counted:
        /// there is no offset after it to be wrong.
        fn discardLine(self: *Self) error{ReadFailed}!u64 {
            return self.input.discardDelimiterInclusive('\n') catch |err| switch (err) {
                // The over-long line was the last one, with no terminator.
                error.EndOfStream => 0,
                error.ReadFailed => error.ReadFailed,
            };
        }
    };
}

/// True for a line with nothing on it but spaces and tabs.
fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

/// The offset of the first byte in `bytes` that must not appear raw in a JSON
/// Lines line, or `null`.
///
/// Those are the C0 controls other than tab: JSON forbids them inside a
/// string without an escape and has no use for them between tokens, so one
/// arriving raw means the bytes are damaged rather than merely wrong. `\r`
/// and `\n` reach this test only when they are not the terminator, which is
/// exactly when they are damage too. DEL and the C1 range are left alone:
/// they are ordinary characters inside a JSON string.
pub fn indexOfControl(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, i| {
        if (byte < 0x20 and byte != '\t') return i;
    }
    return null;
}

test indexOfControl {
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("{\"a\":\"b\"}"));
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("{\"a\":\t1}"));
    try std.testing.expectEqual(@as(?usize, 5), indexOfControl("{\"a\":\x00}"));
    try std.testing.expectEqual(@as(?usize, 0), indexOfControl("\r"));
    // DEL is an ordinary character as far as JSON is concerned.
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("\x7f"));
}

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
            /// When the destination is asked to drain what it is holding.
            ///
            /// The default is never, because this writer does not own the
            /// stream and a flush is a decision about durability that belongs
            /// to whoever does. A log that another process tails, or that has
            /// to survive a crash between two records, is the case where the
            /// decision is "after every one", and saying so here is shorter
            /// than wrapping every `write`.
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
            /// | `.per_record` | yes | yes, to the last record | one `fsync` per record, which is a disk write and a wait: on a spinning disk single-digit milliseconds, on an SSD tens to hundreds of microseconds, and on either it is the slowest thing a log does |
            /// | `.per_batch` | yes | yes, to the last batch | one `fsync` per `writeAll`, so a batch of a thousand records pays once and risks losing the batch |
            ///
            /// A sync drains first, whatever `flush` says: bytes still in
            /// this program's buffer have not reached the file at all, so
            /// there would be nothing on it to sync.
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
        pub const Flush = enum {
            /// Nothing is flushed. The caller drains its own writer.
            never,
            /// `write` flushes the destination after each record.
            per_record,
            /// `writeAll` flushes once, after the last record of the batch.
            /// A plain `write` flushes nothing.
            per_batch,
        };

        /// How often the file is asked to sync. See `Options.sync`.
        pub const Sync = enum {
            /// Nothing is synced. A crash of the machine may lose records a
            /// reader of the file had already seen.
            never,
            /// `write` syncs the file after each record, having drained it.
            per_record,
            /// `writeAll` syncs once, after the last record of the batch,
            /// having drained it. A plain `write` syncs nothing.
            per_batch,
        };

        /// What `write` can report. `WriteFailed` is the destination refusing
        /// the bytes and `SyncFailed` is the file refusing to put them on the
        /// disk; ask the destination or the file for diagnostics.
        pub const Error = std.Io.Writer.Error || error{SyncFailed};

        /// A writer over `output`. Writes nothing.
        ///
        /// A writer made this way has no file, so `options.sync` must be
        /// `.never`; `initFile` is the constructor that can sync.
        pub fn init(output: *std.Io.Writer, options: Options) Self {
            assert(options.sync == .never);
            return .{ .output = output, .options = options };
        }

        /// A writer over a file, which is what a `sync` policy needs. Writes
        /// nothing.
        ///
        /// The file is still not owned: this writer never closes it, and
        /// drains it only when `Options.flush` or `Options.sync` says to.
        pub fn initFile(dest: *std.Io.File.Writer, options: Options) Self {
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
            try std.json.Stringify.value(value, .{
                .whitespace = switch (self.options.format) {
                    .minified => .minified,
                    .pretty => .indent_2,
                },
                .emit_null_optional_fields = self.options.emit_null_optional_fields,
                .escape_unicode = self.options.escape_unicode,
            }, self.output);
            try self.output.writeByte('\n');
            self.count += 1;
            if (self.options.sync == .per_record) return self.drainAndSync();
            if (self.options.flush == .per_record) try self.output.flush();
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
            if (self.options.sync == .per_batch) return self.drainAndSync();
            if (self.options.flush == .per_batch) try self.output.flush();
        }

        /// Drains the destination and then asks the file to put what it now
        /// holds onto the disk. The order is the whole of it: a sync of a
        /// file that has not been given the bytes syncs nothing.
        fn drainAndSync(self: *Self) Error!void {
            try self.output.flush();
            const dest = self.file orelse return error.SyncFailed;
            dest.file.sync(dest.io) catch return error.SyncFailed;
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
        // file for anything and this writer has no file to ask.
        error.SyncFailed => unreachable,
    };
}

test writeLine {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeLine(&out.writer, .{ .kind = "open", .at = 17, .note = @as(?[]const u8, null) });
    try std.testing.expectEqualStrings("{\"kind\":\"open\",\"at\":17}\n", out.written());
}

/// The first key of the object on `line`, or `null` when there is not one to
/// read cheaply.
///
/// This is the "what kind of line is this" question, answered without parsing
/// the value: a dispatcher can compare the result against the kinds it knows
/// and only then parse into the matching type. It scans the first few bytes
/// and allocates nothing.
///
/// Ownership: the result points into `line`.
///
/// `null` means: not an object, an object with no keys, or a first key
/// containing a `\` escape, which this function does not decode (`parseLine`
/// decodes it correctly; this is a peek, not a parser). The rest of the line
/// is not looked at, so a `kindOf` that answers is not a claim that the line
/// is valid JSON.
pub fn kindOf(line: []const u8) ?[]const u8 {
    var i = skipSpace(line, 0);
    if (i == line.len or line[i] != '{') return null;
    i = skipSpace(line, i + 1);
    if (i == line.len or line[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '\\' => return null,
        '"' => {
            const key = line[start..i];
            // A string this early can only be a key, and a key is followed by
            // a colon; anything else means the line is not shaped as assumed.
            const after = skipSpace(line, i + 1);
            if (after == line.len or line[after] != ':') return null;
            return key;
        },
        else => {},
    };
    return null;
}

/// The index of the first byte at or after `i` that is not JSON whitespace.
fn skipSpace(bytes: []const u8, i: usize) usize {
    var j = i;
    while (j < bytes.len) : (j += 1) switch (bytes[j]) {
        ' ', '\t', '\r', '\n' => {},
        else => return j,
    };
    return j;
}

test kindOf {
    try std.testing.expectEqualStrings("kind", kindOf("{\"kind\":\"open\",\"at\":17}").?);
    try std.testing.expectEqualStrings("at", kindOf("  { \"at\" : 17 }").?);
    try std.testing.expectEqual(@as(?[]const u8, null), kindOf("[1,2,3]"));
    try std.testing.expectEqual(@as(?[]const u8, null), kindOf("{}"));
}

/// The arm of the tagged union `U` that `line` names, or `null`.
///
/// `std.json` encodes a tagged union as a one-key object whose key is the
/// active arm — `{"open":{...}}` — so the first key is the tag, and reading
/// it is enough to route a line without parsing its payload.
///
/// `null` means the line is not shaped that way, its key is escaped (see
/// `kindOf`), or the key does not name an arm of `U`. The last of those is
/// how a line from a newer writer arrives; see "Arms added over time" in
/// README.md for the `unknown` arm that gives it somewhere to land.
pub fn tagOf(comptime U: type, line: []const u8) ?std.meta.Tag(U) {
    comptime {
        const info = @typeInfo(U);
        if (info != .@"union" or info.@"union".tag_type == null) {
            @compileError("strand.tagOf expects a tagged union, got " ++ @typeName(U));
        }
    }
    const key = kindOf(line) orelse return null;
    return std.meta.stringToEnum(std.meta.Tag(U), key);
}

test tagOf {
    const Message = union(enum) {
        open: struct { path: []const u8 },
        close: struct { code: u8 },
    };

    try std.testing.expectEqual(.open, tagOf(Message, "{\"open\":{\"path\":\"/tmp\"}}").?);
    try std.testing.expectEqual(.close, tagOf(Message, "{\"close\":{\"code\":0}}").?);
    try std.testing.expectEqual(@as(?std.meta.Tag(Message), null), tagOf(Message, "{\"other\":1}"));
}

/// One line of a buffer, as `lines` yields it: `Line` without the value,
/// and named the same way.
pub const RawLine = struct {
    /// The line's bytes, without the `\n` or `\r\n` that ended it. Points
    /// into the buffer given to `lines` and is valid as long as it is.
    line: []const u8,
    /// 1-based line number.
    number: u64,
};

/// Walks the lines of a buffer that is already in memory, numbering them.
///
/// For a buffer, where `Reader` is for a stream: nothing is allocated and
/// every line is a view into `bytes`. A final line with no terminator is
/// still a line; a buffer ending in a terminator does not yield an empty line
/// after it. A UTF-8 byte-order mark at the start of the buffer is not part
/// of the first line. Blank lines are yielded — `lines` splits, it does not
/// filter.
pub fn lines(bytes: []const u8) LineIterator {
    const bom = "\xEF\xBB\xBF";
    return .{ .rest = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes };
}

/// The iterator `lines` returns.
pub const LineIterator = struct {
    /// The bytes not yet yielded.
    rest: []const u8,
    /// The number of the line last yielded.
    number: u64 = 0,

    /// The next line, or `null` when the buffer is spent.
    pub fn next(it: *LineIterator) ?RawLine {
        if (it.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
        var line = it.rest[0..end];
        it.rest = it.rest[@min(end + 1, it.rest.len)..];
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        it.number += 1;
        return .{ .line = line, .number = it.number };
    }
};

test lines {
    var it = lines("{\"a\":1}\r\n\n{\"a\":2}");
    try std.testing.expectEqualStrings("{\"a\":1}", it.next().?.line);
    try std.testing.expectEqualStrings("", it.next().?.line);

    const last = it.next().?;
    try std.testing.expectEqualStrings("{\"a\":2}", last.line);
    try std.testing.expectEqual(@as(u64, 3), last.number);
    try std.testing.expectEqual(@as(?RawLine, null), it.next());
}
