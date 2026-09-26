//! What a line is, whichever direction it is read in.
//!
//! `Reader` goes forwards over a stream and `Tail` goes backwards over a
//! file, and the two loops are genuinely different; what is not different is
//! what a line is. The terminator, the mark, the blank line, what to say
//! about a line that failed, and what it takes to keep a value past the line
//! it came from are all the same fact told twice, so they are here and told
//! once. So are the shapes every reader hands back — `Line` and `RawLine` —
//! the two things a reader and a writer agree on beyond the schema — `Format`
//! and `separator` — and `lines`, which walks the lines of a buffer already
//! in memory.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parse_line = @import("parse_line.zig");
const ParseLineError = parse_line.ParseLineError;

/// The UTF-8 byte-order mark. Not part of the first line of a stream, and
/// never written by this package.
pub const bom = "\xEF\xBB\xBF";

/// A line without the `\r` of a `\r\n` terminator.
pub fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// True for a line with nothing on it but spaces and tabs.
///
/// Written out rather than handed to `std.mem.indexOfNone`, whose set of
/// bytes is a slice read at run time: every line a reader frames goes
/// through this, and all but the blank ones leave it on the first byte.
pub fn isBlank(line: []const u8) bool {
    for (line) |byte| {
        if (byte != ' ' and byte != '\t') return false;
    }
    return true;
}

/// A copy of the value on `line` that borrows nothing from it: every string
/// is copied onto `allocator`. See `Reader.keep`, whose contract this is.
pub fn keep(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: anytype,
) ParseLineError!T {
    return parse_line.parseLine(T, allocator, line, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .duplicate_fields = options.duplicate_fields,
        .copy_strings = true,
    });
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
    var where: parse_line.Diagnostics = .{};
    _ = parse_line.parseLine(T, allocator, line, .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .duplicate_fields = options.duplicate_fields,
        .copy_strings = false,
        .diagnostics = &where,
    }) catch return where.offset;
    return null;
}

/// What a reader says about the last line it would not hand over.
///
/// One fact about one line, so one struct: which line, what was wrong with
/// it, and where in it. Every reader here carries one and fills it in the
/// same way, whichever way it is reading.
pub const Fault = struct {
    /// The number of the line, in that reader's own numbering; 0 when there
    /// has not been one.
    line: u64 = 0,
    /// What `std.json` made of the line. `null` when the line never reached
    /// `std.json` — it was too long, it carried a raw control byte, or it
    /// carried no record at all.
    err: ?ParseLineError = null,
    /// The 0-based offset within the line: the control byte itself, or the
    /// byte `std.json` gave up at — which is not always the byte that is
    /// wrong, but is never before it. `null` when there is no place to name.
    offset: ?usize = null,

    /// A raw control byte at `at`.
    pub fn control(self: *Fault, number: u64, at: usize) void {
        self.* = .{ .line = number, .err = null, .offset = at };
    }

    /// `std.json` refused the line, having got as far as `at`.
    pub fn parse(self: *Fault, number: u64, err: ParseLineError, at: ?usize) void {
        self.* = .{ .line = number, .err = err, .offset = at };
    }

    /// The line never reached `std.json`: it ran past the bound, or it had
    /// no record on it.
    pub fn framing(self: *Fault, number: u64) void {
        self.* = .{ .line = number, .err = null, .offset = null };
    }
};

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
        /// seek needs: it is what turns a line number into a place. Where a
        /// record is separated, this is the separator, since that is where
        /// the record begins; `line` is what follows it.
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

/// The byte that marks the start of a record in a separated stream: ASCII
/// RS, 0x1E, which is what RFC 7464 puts in front of one.
///
/// It is the only byte that cannot appear unescaped inside a JSON value, so
/// it is the only unambiguous "a record starts here" there is. JSON Lines on
/// its own has no such marker: a torn line is detectable only as one that
/// does not parse, and a reader cannot tell the difference between damage
/// and a record it does not understand. See `Reader.Options.record_separator`.
pub const separator: u8 = 0x1E;

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
