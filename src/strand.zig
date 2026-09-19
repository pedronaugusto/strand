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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Tail = @import("tail.zig").Tail;
pub const Follower = @import("follow.zig").Follower;
pub const Opener = @import("follow.zig").Opener;
pub const PathOpener = @import("follow.zig").PathOpener;
pub const Identity = @import("follow.zig").Identity;
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
    /// Where to put what `std.json` can say about where it got to. Filled in
    /// whether the parse succeeded or not; see `Diagnostics`.
    ///
    /// Asking costs the scan a little bookkeeping per line, which is why the
    /// readers ask only about a line that has already failed.
    diagnostics: ?*Diagnostics = null,
};

/// How far into a line `std.json` got.
///
/// On a line that did not parse, this is where it gave up — which is not
/// always the byte that is wrong, but is always at or after it, and is what
/// turns "line 402 is malformed" into something a person can look at.
pub const Diagnostics = struct {
    /// The 0-based byte offset in the line. `line.len` means the parse ran
    /// off the end, which is what a truncated line does.
    offset: usize = 0,
    /// The 1-based line within what was parsed, which is 1 for every
    /// minified line and counts within the record in `.pretty` mode.
    line: u64 = 1,
    /// The 1-based column within that line.
    column: u64 = 1,
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
    var scanner: std.json.Scanner = .initCompleteInput(allocator, line);
    defer scanner.deinit();

    var where: std.json.Diagnostics = .{};
    if (options.diagnostics != null) scanner.enableDiagnostics(&where);

    const parsed = std.json.parseFromTokenSourceLeaky(T, allocator, &scanner, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .allocate = if (options.copy_strings) .alloc_always else .alloc_if_needed,
        .duplicate_field_behavior = switch (options.duplicate_fields) {
            .@"error" => .@"error",
            .use_first => .use_first,
            .use_last => .use_last,
        },
    });
    // Read out before the scanner goes: what the diagnostics point at is the
    // scanner's own cursor.
    if (options.diagnostics) |out| out.* = .{
        .offset = @min(@as(usize, @intCast(where.getByteOffset())), line.len),
        .line = where.getLine(),
        .column = where.getColumn(),
    };
    return parsed;
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
        /// without a leading byte-order mark. Not owned by the caller and
        /// valid until the next call to `next` or `deinit`: it is a slice of
        /// the stream's own buffer when the whole line was already sitting in
        /// it, and of the reader's line buffer when it was not. In `.pretty`
        /// mode it is the whole record, newlines and all.
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
        /// The 0-based offset within the line at which the last failure was:
        /// the control byte itself for `error.ControlByte`, and the byte
        /// `std.json` gave up at for `error.MalformedLine` — which is not
        /// always the byte that is wrong, but is never before it. The line's
        /// own length means the parse ran off the end, which is what a
        /// truncated line does. `null` for `error.LineTooLong`, which never
        /// reached `std.json`, and for a line the reader has not failed on.
        last_error_offset: ?usize = null,

        /// Internal. The current record's bytes; `Line.line` is a view of it.
        line_buf: std.Io.Writer.Allocating,
        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,
        /// Internal. Set while the current record is a slice of `input`'s own
        /// buffer rather than a copy in `line_buf`. It says what a record
        /// about to be joined to has to do first, and it is the whole of the
        /// bookkeeping the zero-copy frame costs.
        borrowed: bool = false,
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
        /// Ownership: the returned `Line` borrows. Its `line` field is a
        /// slice of `input`'s own buffer when the whole line was already
        /// there and of the reader's line buffer when it was not, and the
        /// value's strings point either into that same line (when they needed
        /// no unescaping) or into the reader's arena (when they did). The
        /// next call to `next` reads the stream, overwrites the line buffer
        /// and resets the arena, so everything the previous `Line` pointed at
        /// is gone by the time the next one is returned. To keep a value past
        /// that point, call `keep`.
        ///
        /// `error.MalformedLine`, `error.ControlByte` and
        /// `error.LineTooLong` do not desynchronize the stream: the offending
        /// line has been consumed in full, and calling `next` again continues
        /// with the one after it. `error.ReadFailed` and `error.OutOfMemory`
        /// can arrive in the middle of a line, and leave the stream wherever
        /// they found it.
        pub fn next(self: *Self) NextError!?Line(T) {
            while (true) {
                const raw = (try self.nextRaw()) orelse return null;
                if (try self.parse(raw)) |line| return line;
                // The record was passed over under `.skip`; the next one.
            }
        }

        /// The next line's bytes, its number and its place, without parsing
        /// them into a `T`.
        ///
        /// This is `next` with the parse left out, and it is what routing a
        /// stream is built from: `kindOf` or `tagOf` on `raw.line` says what
        /// kind of line it is, and only the ones worth having need to become
        /// values. A line that is not parsed costs no arena and no allocator
        /// at all. `parse` is how one of them becomes a `Line(T)` afterwards.
        ///
        /// Everything about a line other than its type is decided here:
        /// blank lines are passed over, the number and the offset are the
        /// ones `next` would report, a line past `max_line_bytes` is
        /// `error.LineTooLong`, and a raw control byte is `error.ControlByte`
        /// or a skip, as `on_malformed` says.
        ///
        /// Ownership: `raw.line` borrows exactly as `Line.line` does, and is
        /// gone at the next call to `next`, `nextRaw` or `deinit`.
        ///
        /// In `.pretty` mode a record is known to be finished only when it
        /// parses, so what this hands back there is one physical line and not
        /// a record. Routing a `.pretty` stream means parsing it.
        pub fn nextRaw(self: *Self) NextError!?RawLine {
            while (true) {
                self.line_buf.writer.end = 0;

                const record = (try self.readPhysical()) orelse return null;
                const number = self.number;
                if (self.options.skip_blank and isBlank(record)) continue;
                self.offset = self.record_offset;
                if (try self.checkControl(record, 0, number)) {
                    self.skipped += 1;
                    continue;
                }
                return .{ .line = record, .number = number, .offset = self.record_offset };
            }
        }

        /// The value on a line `nextRaw` handed back, on this reader's own
        /// arena. `null` when the line is not a `T` and `on_malformed` is
        /// `.skip`, which is the one thing `next` does with it that a caller
        /// routing lines itself would otherwise have to write out.
        ///
        /// Ownership: exactly `next`'s — the value borrows the line, the line
        /// borrows the stream, and the next read takes both back.
        ///
        /// `raw` must be the line the reader last handed back. In `.pretty`
        /// mode a record that is only a prefix of a value is joined to the
        /// lines after it here, which means reading them.
        pub fn parse(self: *Self, raw: RawLine) NextError!?Line(T) {
            var record = raw.line;
            while (true) {
                _ = self.arena.reset(.retain_capacity);
                if (parseLine(T, self.arena.allocator(), record, .{
                    .ignore_unknown_fields = self.options.ignore_unknown_fields,
                    .duplicate_fields = self.options.duplicate_fields,
                    .copy_strings = false,
                })) |value| {
                    return .{
                        .value = value,
                        .line = record,
                        .number = raw.number,
                        .offset = raw.offset,
                    };
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.UnexpectedEndOfInput => if (self.options.format == .pretty) {
                        // A prefix of a value: the rest of it is on the lines
                        // that follow, unless there are none.
                        switch (try self.joinPhysical(raw.number, record)) {
                            .grown => |joined| {
                                record = joined;
                                continue;
                            },
                            // The record is damaged rather than unfinished,
                            // and `checkControl` has already said where:
                            // saying anything else here would replace the
                            // true diagnosis with a guess.
                            .damaged => {
                                self.skipped += 1;
                                return null;
                            },
                            .ended => return self.malformed(raw.number, record, error.UnexpectedEndOfInput),
                        }
                    } else {
                        return self.malformed(raw.number, record, error.UnexpectedEndOfInput);
                    },
                    else => |parse_err| return self.malformed(raw.number, record, parse_err),
                }
            }
        }

        /// Records a parse failure against `number` and does what
        /// `on_malformed` says about it: `null` is a record passed over.
        fn malformed(self: *Self, number: u64, record: []const u8, err: ParseLineError) NextError!?Line(T) {
            self.fault(number, err);
            self.last_error_offset = whereItFailed(T, self.arena.allocator(), record, self.options);
            switch (self.options.on_malformed) {
                .fail => return error.MalformedLine,
                .skip => {
                    self.skipped += 1;
                    return null;
                },
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

        /// Records a parse failure against `number`, whatever is done about
        /// it. The offset is the caller's to fill in, since only a line that
        /// reached `std.json` has one.
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

        /// What a join did. Three outcomes rather than two, because a record
        /// that did not grow can have failed to for either of two reasons,
        /// and the caller has a different thing to say about each.
        pub const Joined = union(enum) {
            /// The next line is part of this record: these are its bytes now.
            grown: []const u8,
            /// The stream ended first, and the record is exactly as it was —
            /// which for a `.pretty` reader means a record that never
            /// finished.
            ended,
            /// The line joined on holds a raw control byte and the reader was
            /// told to skip such a record. `last_error_line` and
            /// `last_error_offset` name it already.
            damaged,
        };

        /// Appends the next physical line to the current record, separated by
        /// the `\n` that ended the previous one.
        fn joinPhysical(self: *Self, number: u64, record: []const u8) NextError!Joined {
            if (self.borrowed) {
                // The record so far is a slice of the input reader's buffer,
                // and reading the line after it is what takes that buffer
                // back: a record that is about to grow has to own its bytes.
                self.line_buf.writer.end = 0;
                self.line_buf.writer.writeAll(record) catch return error.OutOfMemory;
                self.borrowed = false;
            }
            const before = self.line_buf.writer.end;
            // The separator counts against the bound like any other byte.
            if (self.options.max_line_bytes -| before == 0) {
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
                return .ended;
            };
            if (try self.checkControl(joined, before + 1, number)) return .damaged;
            return .{ .grown = joined };
        }

        /// Reads one physical line and returns the record so far: a slice of
        /// `input`'s own buffer when the whole line was already sitting in
        /// it, and the line buffer's contents when it was not. `null` at end
        /// of stream, and at an unterminated final line under
        /// `require_terminator`. Counts the line.
        fn readPhysical(self: *Self) NextError!?[]const u8 {
            if (!self.bom_checked) {
                self.bom_checked = true;
                if (self.options.skip_bom) try self.skipBom();
            }

            const before = self.line_buf.writer.end;
            // The first physical line of a record is where the record begins,
            // and where it begins is what `Line.offset` reports.
            if (before == 0) self.record_offset = self.consumed;
            const max = self.options.max_line_bytes;
            // One past the bound, so that a record of exactly `max` bytes is
            // accepted and the first byte over it is what trips the limit.
            // Saturating, because `Limit` reads a saturated `usize` as
            // unlimited, which is what a bound of `maxInt(usize)` means.
            const room = max -| before;

            // A whole line already in `input`'s buffer is handed back as a
            // slice of it. The bytes have been read once and are not read
            // again, and nothing below this is done at all: framing a line
            // this way costs one scan for the terminator and no copy. What
            // follows is for the line that straddles a refill, which is the
            // only one whose bytes are not all in one place.
            if (before == 0) {
                if (self.frameBuffered()) |frame| return self.takeFrame(frame, room);
            }
            self.borrowed = false;

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
            return self.line_buf.written();
        }

        /// The whole of the next line, terminator included, when `input` is
        /// already holding it; `null` when it is not, which is a line that
        /// straddles a refill or a reader with nothing in hand yet.
        ///
        /// Nothing is read here: what is looked at is what an earlier read
        /// left behind, so a reader whose buffer holds many lines gives all
        /// of them up one after another without touching the stream.
        fn frameBuffered(self: *Self) ?[]const u8 {
            const contents = self.input.buffered();
            const end = std.mem.findScalar(u8, contents, '\n') orelse return null;
            return contents[0 .. end + 1];
        }

        /// Takes a framed line off `input` without copying it. `room` is what
        /// is left of the bound; a line past it is discarded here in full,
        /// since it is already known where it ends.
        fn takeFrame(self: *Self, frame: []const u8, room: usize) NextError!?[]const u8 {
            const line = frame[0 .. frame.len - 1];
            self.number += 1;
            self.input.toss(frame.len);
            self.consumed += frame.len;
            if (line.len > room) {
                self.last_error_line = self.number;
                self.last_error = null;
                self.last_error_offset = null;
                self.offset = self.record_offset;
                return error.LineTooLong;
            }
            self.borrowed = true;
            // Tolerate CRLF: the `\r` belongs to the terminator, not the JSON.
            return trimCr(line);
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

/// Where `std.json` gave up on a line that has already failed to parse.
///
/// The line is parsed a second time with the scanner's diagnostics on, which
/// is what makes the first parse — the one every good line goes through —
/// cost nothing for this. The answer is an offset in `line`; `null` when the
/// second parse disagrees with the first and succeeds, which only a `T` with
/// a `jsonParse` of its own can arrange.
pub fn whereItFailed(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: anytype,
) ?usize {
    var where: Diagnostics = .{};
    _ = parseLine(T, allocator, line, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .duplicate_fields = options.duplicate_fields,
        .copy_strings = false,
        .diagnostics = &where,
    }) catch return where.offset;
    return null;
}

/// A line without the `\r` of a `\r\n` terminator.
fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
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
///
/// Every line a reader returns is scanned by this, so it reads a register's
/// worth of bytes at a time rather than one: a byte is control when it is
/// below 0x20 and is not a tab, and both halves of that predicate answer a
/// whole vector at once. `scalarControl` is the same predicate written out,
/// and the tail of a line shorter than a vector goes through it.
pub fn indexOfControl(bytes: []const u8) ?usize {
    var i: usize = 0;
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            const Block = @Vector(block_len, u8);
            const highest: Block = @splat(0x20);
            const tab: Block = @splat('\t');
            const group = 4 * block_len;
            // Four blocks are folded into one answer before anything leaves
            // the vector registers, because asking a vector "did any lane
            // match" is the expensive instruction here and the compares are
            // not. A line that has no control byte in it — which is every
            // line of an undamaged log — pays one of those per group.
            while (i + group <= bytes.len) : (i += group) {
                var any = @as(@Vector(block_len, bool), @splat(false));
                inline for (0..4) |k| {
                    const block: Block = bytes[i + k * block_len ..][0..block_len].*;
                    any = any | ((block < highest) & (block != tab));
                }
                // One of these four blocks holds it; which byte it is, is
                // worth finding the slow way, since it ends the scan.
                if (@reduce(.Or, any)) return i + scalarControl(bytes[i..][0..group]).?;
            }
            // What is left of the line is folded the same way, in one go: the
            // last block is read overlapping the one before it rather than a
            // byte at a time, so a line of any length at all costs at most
            // one more of those instructions.
            if (i < bytes.len and bytes.len >= block_len) {
                const rest = i;
                var any = @as(@Vector(block_len, bool), @splat(false));
                while (i + block_len <= bytes.len) : (i += block_len) {
                    const block: Block = bytes[i..][0..block_len].*;
                    any = any | ((block < highest) & (block != tab));
                }
                if (i < bytes.len) {
                    const block: Block = bytes[bytes.len - block_len ..][0..block_len].*;
                    any = any | ((block < highest) & (block != tab));
                }
                if (!@reduce(.Or, any)) return null;
                // The overlap may reach back over bytes already cleared, so
                // what it found is at `rest` or after it, or was never here.
                return if (scalarControl(bytes[rest..])) |at| rest + at else null;
            }
        }
    }
    return if (scalarControl(bytes[i..])) |at| i + at else null;
}

/// `indexOfControl`'s predicate, one byte at a time: the tail of a line, and
/// the whole of one where there are no vectors to use.
fn scalarControl(bytes: []const u8) ?usize {
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

test "indexOfControl reads a line by the vector the way it reads it by the byte" {
    // Every length up to four vectors, with every awkward byte at every
    // offset of every one of them: the unrolled pair, the single block and
    // the tail all have to answer what the loop they replace answers.
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    var buf: [4 * 64 + 3]u8 = undefined;
    const longest = @min(4 * block_len + 3, buf.len);

    for (0..longest) |len| {
        const bytes = buf[0..len];
        for ([_]u8{ 0x00, 0x01, 0x1f, '\n', '\r', '\t', ' ', 'x', 0x7f, 0xff }) |byte| {
            for (0..len) |at| {
                @memset(bytes, 'x');
                bytes[at] = byte;
                try std.testing.expectEqual(scalarControl(bytes), indexOfControl(bytes));
            }
        }
        // A line that is nothing but tabs is the case the second half of the
        // predicate is there for.
        @memset(bytes, '\t');
        try std.testing.expectEqual(scalarControl(bytes), indexOfControl(bytes));
    }
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
            /// | Linux | `fsync`, which the filesystems in ordinary use turn into a write the drive has acknowledged |
            /// | macOS | `fcntl(F_FULLFSYNC)`, because `fsync` there hands the bytes to the drive without making it write them down. A filesystem with no such call gets `fsync`, which is then the strongest thing on it |
            /// | Windows | the system's own flush of the file's buffers |
            ///
            /// There is no `fdatasync` here, on any platform. It skips the
            /// timestamp writeback and is the cheaper call for a log, and
            /// `std.Io.File` does not expose one; this package asks for what
            /// it is given to ask for.
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
            try std.json.Stringify.value(value, self.encoding(), self.output);
            try self.output.writeByte('\n');
            self.count += 1;
            if (self.due(self.options.sync)) return self.drainAndSync();
            if (self.due(self.options.flush)) try self.output.flush();
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
            if (dueForBatch(self.options.flush)) try self.output.flush();
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

        /// Refuses a record longer than the bound before a byte of it is
        /// written. Measured by encoding it into a writer that counts and
        /// keeps nothing, which is the second pass `Options.max_line_bytes`
        /// costs — and why there is no bound unless one is asked for.
        fn checkLength(self: *Self, value: T, max: usize) Error!void {
            var counter: std.Io.Writer.Discarding = .init(&.{});
            std.json.Stringify.value(value, self.encoding(), &counter.writer) catch
                return error.WriteFailed;
            if (counter.fullCount() > max) return error.LineTooLong;
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
            try self.output.flush();
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
            try self.output.flush();
            const dest = self.file orelse return self.syncFault();
            _ = syncFile(dest.file, dest.io) catch return self.syncFault();
        }

        /// Records that this writer's log is not what it was asked to be, and
        /// says so. Every later call says so too; see `sync_failed`.
        fn syncFault(self: *Self) error{SyncFailed} {
            self.sync_failed = true;
            return error.SyncFailed;
        }
    };
}

/// Which call put the file's bytes on the disk under it. See `syncFile`.
const SyncKind = enum {
    /// The platform's strongest: the drive was told to write its own cache
    /// out, not merely told about the bytes.
    full,
    /// The ordinary one, which is all the platform or the filesystem has.
    plain,
};

/// Puts what a file has been given onto the disk under it, as completely as
/// the platform allows, and says which call did it.
///
/// `std.Io.File.sync` is `fsync` where there is one. On Darwin that is not
/// the end of the story: `fsync` there hands the bytes to the drive and does
/// not make the drive write them down, so a machine that loses power can lose
/// a record an `fsync` returned success for. `fcntl(F_FULLFSYNC)` is the call
/// that waits for the media, and it is what a sync asks for there.
///
/// A filesystem that has no such call — a network mount, an image — refuses
/// it, and then `fsync` is the strongest thing there is on that filesystem
/// and is what it gets. Any other failure is reported rather than retried: a
/// failed sync can clear the error the kernel was holding, so asking a second
/// time is how the loss gets lost rather than how it gets fixed.
fn syncFile(file: std.Io.File, io: std.Io) !SyncKind {
    if (comptime builtin.os.tag.isDarwin()) {
        while (true) {
            switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
                .SUCCESS => return .full,
                .INTR => continue,
                // This filesystem cannot be asked. Everything else is the
                // file saying the bytes are not down.
                .OPNOTSUPP, .INVAL, .NOTTY, .PERM => break,
                else => return error.SyncFailed,
            }
        }
    }
    try file.sync(io);
    return .plain;
}

test syncFile {
    var fixture = try @import("fixtures.zig").Fixture.init("{\"kind\":\"one\"}\n", 64);
    defer fixture.deinit();

    // The platform's strongest flush is the one a sync makes, and on the one
    // platform where that is not what `std` calls a sync, this is the test
    // that it is asked for.
    const kind = try syncFile(fixture.write_file, std.testing.io);
    const expected: SyncKind = if (builtin.os.tag.isDarwin()) .full else .plain;
    try std.testing.expectEqual(expected, kind);
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

/// One line with nothing read out of it: `Line` without the value, and named
/// the same way. `lines` yields these, and `Reader.nextRaw` hands them back.
pub const RawLine = struct {
    /// The line's bytes, without the `\n` or `\r\n` that ended it, and
    /// without a leading byte-order mark. From `lines` it points into the
    /// buffer and is valid as long as that is; from `Reader.nextRaw` it
    /// borrows the way `Line.line` does.
    line: []const u8,
    /// 1-based line number.
    number: u64,
    /// The byte offset the line began at, counted the way `Line.offset` is:
    /// from the start of the buffer, or from wherever the reader started.
    offset: u64 = 0,
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
    const marked = std.mem.startsWith(u8, bytes, bom);
    return .{
        .rest = if (marked) bytes[bom.len..] else bytes,
        // A mark is not part of the first line, so it is not where that line
        // begins either — the same answer `Tail` gives.
        .offset = if (marked) bom.len else 0,
    };
}

/// The iterator `lines` returns.
pub const LineIterator = struct {
    /// The bytes not yet yielded.
    rest: []const u8,
    /// The number of the line last yielded.
    number: u64 = 0,
    /// The offset of the next line's first byte in the buffer.
    offset: u64 = 0,

    /// The next line, or `null` when the buffer is spent.
    pub fn next(it: *LineIterator) ?RawLine {
        if (it.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
        const line = trimCr(it.rest[0..end]);
        const offset = it.offset;
        const taken = @min(end + 1, it.rest.len);
        it.rest = it.rest[taken..];
        it.offset += taken;
        it.number += 1;
        return .{ .line = line, .number = it.number, .offset = offset };
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
