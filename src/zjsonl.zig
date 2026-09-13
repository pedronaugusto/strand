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
//!   line, each carrying its 1-based line number and its raw bytes.
//! * A malformed line is an error naming the line, not an abort, and can be
//!   skipped instead (`Options.on_malformed`).
//! * Strings borrow from the line's bytes when they need no unescaping, so
//!   the common case copies nothing. `Reader.keep` is how a value outlives
//!   the line it came from.
//! * `kindOf` and `tagOf` answer "what kind of line is this" from the first
//!   key alone, without parsing the value.
//! * `Writer` emits one minified value per line and counts them.
//!
//! What this package does NOT do: it does not parse JSON (`std.json` does),
//! does not buffer or own the underlying stream, does not rotate, lock,
//! compress or seek files, does not index a log or read it backwards, does
//! not validate a line it is not asked to parse, and has no opinion about
//! what a line means. There is no global state and no dependency beyond
//! `std`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

test {
    _ = @import("tests.zig");
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
    try std.testing.expect(event.kind.ptr == line.ptr + 9);
}

/// One line of input: the value it parsed to, the bytes it parsed from, and
/// where it was.
///
/// Ownership is documented per field, and both borrowed fields are tied to
/// the `Reader` that produced them; see `Reader.next`.
pub fn Line(comptime T: type) type {
    return struct {
        /// The parsed value. String fields either point into `line` or into
        /// the reader's per-line arena; either way they die when `line` does.
        value: T,
        /// The line's bytes, without the `\n` or `\r\n` that ended it. Owned
        /// by the reader, valid until the next call to `next` or `deinit`.
        line: []const u8,
        /// 1-based physical line number, counting blank and skipped lines.
        number: u64,
    };
}

/// A stream of `T`, one per line, over a `*std.Io.Reader`.
///
/// The reader owns two buffers and reuses both: the bytes of the current line,
/// and an arena holding whatever parsing that line had to allocate. Both are
/// recycled at the start of every `next`, which is what keeps memory bounded
/// over a stream of any length, and which is why a value must be copied out
/// (`keep`) to outlive the line it came from.
pub fn Reader(comptime T: type) type {
    return struct {
        /// The byte source. Not owned: this reader never closes or flushes it,
        /// and leaves it positioned just past the last line returned.
        input: *std.Io.Reader,
        /// Read-only after `init`.
        options: Options,
        /// Number of physical lines consumed so far, blank and malformed
        /// lines included. The number of the line `next` last returned.
        number: u64 = 0,
        /// The line number of the most recent `error.MalformedLine`,
        /// `error.LineTooLong`, or line skipped under `.skip`; 0 if there has
        /// been none.
        last_error_line: u64 = 0,
        /// What `std.json` said about the line at `last_error_line`. `null`
        /// for `error.LineTooLong`, which never reached `std.json`.
        last_error: ?ParseLineError = null,

        line_buf: std.Io.Writer.Allocating,
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        /// Reading and parsing policy, fixed at `init`.
        pub const Options = struct {
            /// See `ParseOptions.ignore_unknown_fields`.
            ignore_unknown_fields: bool = true,
            /// The longest line accepted, in bytes, not counting the
            /// terminator. A longer line is `error.LineTooLong`; the rest of
            /// it is discarded, so `next` can be called again to continue
            /// with the line after it. This bound is the reader's memory
            /// bound, and it is independent of the size of `input`'s buffer.
            max_line_bytes: usize = 1 << 20,
            /// When true, a line that is empty or all spaces and tabs is
            /// consumed and not returned. Its number is still counted.
            skip_blank: bool = true,
            /// What a line that is not a `T` does.
            on_malformed: enum {
                /// `next` returns `error.MalformedLine`.
                fail,
                /// `next` moves on to the following line.
                skip,
            } = .fail,
        };

        /// What `next` can report.
        ///
        /// The parse errors of `std.json` collapse into `MalformedLine`,
        /// which says "this line, the one at `last_error_line`, is not a
        /// `T`"; `last_error` holds which parse error it was. The other three
        /// are not about the content of a line: `OutOfMemory` is the
        /// allocator's, `ReadFailed` is the stream's (ask it for diagnostics),
        /// and `LineTooLong` is this reader's own bound.
        pub const NextError = error{
            MalformedLine,
            LineTooLong,
            ReadFailed,
            OutOfMemory,
        };

        /// A reader over `input`, with `allocator` backing the line buffer and
        /// the per-line arena. Does not read from `input`.
        pub fn init(allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
            return .{
                .input = input,
                .options = options,
                .line_buf = .init(allocator),
                .arena = .init(allocator),
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
        /// A returned error does not desynchronize the stream: the offending
        /// line has been consumed in full, and calling `next` again continues
        /// with the one after it.
        pub fn next(self: *Self) NextError!?Line(T) {
            while (true) {
                const raw = (try self.readLine()) orelse return null;
                if (self.options.skip_blank and isBlank(raw)) continue;

                _ = self.arena.reset(.retain_capacity);
                const value = parseLine(T, self.arena.allocator(), raw, .{
                    .ignore_unknown_fields = self.options.ignore_unknown_fields,
                    .copy_strings = false,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |parse_err| {
                        self.last_error_line = self.number;
                        self.last_error = parse_err;
                        switch (self.options.on_malformed) {
                            .fail => return error.MalformedLine,
                            .skip => continue,
                        }
                    },
                };
                return .{ .value = value, .line = raw, .number = self.number };
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
        pub fn keep(self: *Self, line: Line(T), allocator: Allocator) ParseLineError!T {
            return parseLine(T, allocator, line.line, .{
                .ignore_unknown_fields = self.options.ignore_unknown_fields,
                .copy_strings = true,
            });
        }

        /// Reads one physical line into the line buffer and returns it without
        /// its terminator, or `null` at end of stream. Counts the line.
        fn readLine(self: *Self) NextError!?[]const u8 {
            self.line_buf.clearRetainingCapacity();
            const max = self.options.max_line_bytes;
            // One past the bound, so that a line of exactly `max` bytes is
            // accepted and the first byte over it is what trips the limit.
            // Saturating, because `Limit` reads a saturated `usize` as
            // unlimited, which is what a bound of `maxInt(usize)` means.
            const n = self.input.streamDelimiterLimit(
                &self.line_buf.writer,
                '\n',
                .limited(max +| 1),
            ) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                // The only writer is `line_buf`, which fails only to allocate.
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => {
                    self.number += 1;
                    self.last_error_line = self.number;
                    self.last_error = null;
                    self.discardLine() catch |e| switch (e) {
                        error.ReadFailed => return error.ReadFailed,
                    };
                    return error.LineTooLong;
                },
            };
            assert(n <= max);

            // `streamDelimiterLimit` stops before the delimiter, so what is
            // next is either it or the end of the stream.
            const terminated = if (self.input.takeByte()) |_| true else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };
            // A final line with no newline is still a line; nothing at all is
            // the end of the stream.
            if (n == 0 and !terminated) return null;

            self.number += 1;
            const raw = self.line_buf.written();
            // Tolerate CRLF: the `\r` belongs to the terminator, not the JSON.
            return if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        }

        /// Discards the remainder of an over-long line, terminator included.
        fn discardLine(self: *Self) error{ReadFailed}!void {
            _ = self.input.discardDelimiterInclusive('\n') catch |err| switch (err) {
                // The over-long line was the last one, with no terminator.
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
        }
    };
}

/// True for a line with nothing on it but spaces and tabs.
fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

/// Writes values as JSON Lines to a `*std.Io.Writer`, and counts them.
pub fn Writer(comptime T: type) type {
    return struct {
        /// The destination. Not owned: this writer never flushes or closes it.
        output: *std.Io.Writer,
        /// Read-only after `init`.
        options: Options,
        /// Lines written so far.
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
        };

        /// What `write` can report: the destination refused the bytes. Ask it
        /// for diagnostics.
        pub const Error = std.Io.Writer.Error;

        /// A writer over `output`. Writes nothing.
        pub fn init(output: *std.Io.Writer, options: Options) Self {
            return .{ .output = output, .options = options };
        }

        /// Writes `value` as one line: minified JSON, then `\n`.
        ///
        /// The output is always exactly one line, whatever `value` holds:
        /// JSON escapes the line terminators that could appear inside a
        /// string. Nothing is flushed; that is the caller's to do, on the
        /// writer it owns.
        pub fn write(self: *Self, value: T) Error!void {
            try std.json.Stringify.value(value, .{
                .whitespace = .minified,
                .emit_null_optional_fields = self.options.emit_null_optional_fields,
                .escape_unicode = self.options.escape_unicode,
            }, self.output);
            try self.output.writeByte('\n');
            self.count += 1;
        }
    };
}

/// Writes one value as one JSON Lines line, for a caller with nothing to
/// count. Same encoding as `Writer` with default options.
pub fn writeLine(output: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var w: Writer(@TypeOf(value)) = .init(output, .{});
    return w.write(value);
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
/// `kindOf`), or the key does not name an arm of `U`.
pub fn tagOf(comptime U: type, line: []const u8) ?std.meta.Tag(U) {
    comptime {
        const info = @typeInfo(U);
        if (info != .@"union" or info.@"union".tag_type == null) {
            @compileError("zjsonl.tagOf expects a tagged union, got " ++ @typeName(U));
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

/// One line of a buffer, as `lines` yields it.
pub const RawLine = struct {
    /// The line's bytes, without the `\n` or `\r\n` that ended it. Points
    /// into the buffer given to `lines`.
    bytes: []const u8,
    /// 1-based line number.
    number: u64,
};

/// Walks the lines of a buffer that is already in memory, numbering them.
///
/// For a buffer, where `Reader` is for a stream: nothing is allocated and
/// every line is a view into `bytes`. A final line with no terminator is
/// still a line; a buffer ending in a terminator does not yield an empty line
/// after it. Blank lines are yielded — `lines` splits, it does not filter.
pub fn lines(bytes: []const u8) LineIterator {
    return .{ .rest = bytes };
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
        return .{ .bytes = line, .number = it.number };
    }
};

test lines {
    var it = lines("{\"a\":1}\r\n\n{\"a\":2}");
    try std.testing.expectEqualStrings("{\"a\":1}", it.next().?.bytes);
    try std.testing.expectEqualStrings("", it.next().?.bytes);

    const last = it.next().?;
    try std.testing.expectEqualStrings("{\"a\":2}", last.bytes);
    try std.testing.expectEqual(@as(u64, 3), last.number);
    try std.testing.expectEqual(@as(?RawLine, null), it.next());
}
