//! The parts of a line that are the same whichever direction it is read in.
//!
//! `Reader` goes forwards over a stream and `Tail` goes backwards over a
//! file, and the two loops are genuinely different; what is not different is
//! what a line is. The terminator, the mark, the blank line, what to say
//! about a line that failed, and what it takes to keep a value past the line
//! it came from are all the same fact told twice, so they are here and told
//! once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const strand = @import("strand.zig");
const ParseLineError = strand.ParseLineError;

/// The UTF-8 byte-order mark. Not part of the first line of a stream, and
/// never written by this package.
pub const bom = "\xEF\xBB\xBF";

/// A line without the `\r` of a `\r\n` terminator.
pub fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// True for a line with nothing on it but spaces and tabs.
pub fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

/// A copy of the value on `line` that borrows nothing from it: every string
/// is copied onto `allocator`. See `Reader.keep`, whose contract this is.
pub fn keep(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: anytype,
) ParseLineError!T {
    return strand.parseLine(T, allocator, line, .{
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
    var where: strand.Diagnostics = .{};
    _ = strand.parseLine(T, allocator, line, .{
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
