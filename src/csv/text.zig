//! The bytes of CSV (RFC 4180): a record's fields, quoted or not, and the
//! dialect that names its delimiter and quote.
const std = @import("std");

/// How a CSV document is spelled. RFC 4180's is the default: a comma, a
/// double quote, a header record, CRLF after each record written. Either CRLF
/// or LF ends a record read.
pub const Dialect = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    /// Whether the first record names the columns. A row read into a struct
    /// takes its fields by those names; without them a row is read into a
    /// tuple or an array, by position.
    header: bool = true,
    /// What ends a record written.
    line_ending: LineEnding = .crlf,

    pub const LineEnding = enum { crlf, lf };

    /// A dialect a document can be read in: the delimiter and the quote are
    /// two different bytes, and neither ends a line.
    pub fn valid(d: Dialect) bool {
        return d.delimiter != d.quote and d.delimiter != '\r' and d.delimiter != '\n' and d.quote != '\r' and d.quote != '\n';
    }

    pub fn ending(d: Dialect) []const u8 {
        return if (d.line_ending == .crlf) "\r\n" else "\n";
    }
};

/// One field of a record, as it is written.
pub const Field = struct {
    /// The field's bytes: unquoted, the field itself; quoted, what is between
    /// the quotes, doubled quotes still doubled.
    bytes: []const u8,
    quoted: bool,
    /// Whether a quoted field holds a doubled quote, so reading it changes
    /// its bytes.
    escaped: bool,
    /// Where the field ends: at a delimiter, at the record's end, or at the
    /// input's end.
    end: usize,
    /// What follows it.
    after: After,

    pub const After = enum { delimiter, record_end, input_end };
};

/// The field that starts at `at`, which a record or a delimiter just began.
/// A quote inside an unquoted field, a carriage return that no line feed
/// follows outside quotes, anything but a delimiter or the record's end after
/// a closing quote, and a quote never closed are `error.SyntaxError`.
pub fn field(bytes: []const u8, at: usize, d: Dialect) error{SyntaxError}!Field {
    if (at < bytes.len and bytes[at] == d.quote) {
        var escaped = false;
        var i = at + 1;
        while (true) {
            const q = std.mem.findScalarPos(u8, bytes, i, d.quote) orelse return error.SyntaxError;
            if (q + 1 < bytes.len and bytes[q + 1] == d.quote) {
                escaped = true;
                i = q + 2;
                continue;
            }
            const end = q + 1;
            const after: Field.After = if (end < bytes.len and bytes[end] == d.delimiter) .delimiter else (try boundary(bytes, end)) orelse return error.SyntaxError;
            return .{ .bytes = bytes[at + 1 .. q], .quoted = true, .escaped = escaped, .end = end, .after = after };
        }
    }
    var i = at;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == d.delimiter) return .{ .bytes = bytes[at..i], .quoted = false, .escaped = false, .end = i, .after = .delimiter };
        if (b == '\n' or b == '\r') {
            _ = (try boundary(bytes, i)) orelse return error.SyntaxError;
            return .{ .bytes = bytes[at..i], .quoted = false, .escaped = false, .end = i, .after = .record_end };
        }
        if (b == d.quote) return error.SyntaxError;
    }
    return .{ .bytes = bytes[at..], .quoted = false, .escaped = false, .end = bytes.len, .after = .input_end };
}

/// What is at `at` after a field: a delimiter, a record's end (`\r\n` or
/// `\n`), the input's end, or (null) anything else. A `\r` alone is an error.
fn boundary(bytes: []const u8, at: usize) error{SyntaxError}!?Field.After {
    if (at == bytes.len) return .input_end;
    return switch (bytes[at]) {
        '\n' => .record_end,
        '\r' => if (at + 1 < bytes.len and bytes[at + 1] == '\n') .record_end else error.SyntaxError,
        else => null,
    };
}

/// Where the record after a field that ended it begins: past its `\r\n` or `\n`.
pub fn pastEnd(bytes: []const u8, end: usize) usize {
    if (end >= bytes.len) return bytes.len;
    return end + @as(usize, if (bytes[end] == '\r') 2 else 1);
}

/// Where the next record begins from `at`, past any blank lines.
pub fn skipBlank(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len) {
        if (bytes[at] == '\n') {
            at += 1;
        } else if (bytes[at] == '\r' and at + 1 < bytes.len and bytes[at + 1] == '\n') {
            at += 2;
        } else break;
    }
    return at;
}

/// A quoted field's bytes with its doubled quotes made single, into `out`,
/// which holds `unescapedLength`.
pub fn unescape(inner: []const u8, quote: u8, out: []u8) void {
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (n += 1) {
        out[n] = inner[i];
        i += if (inner[i] == quote) 2 else 1;
    }
}
pub fn unescapedLength(inner: []const u8, quote: u8) usize {
    return inner.len - std.mem.countScalar(u8, inner, quote) / 2;
}

/// Whether a value must be quoted to be read back as itself: it holds the
/// delimiter, the quote or a line break. (An empty one is the writer's call:
/// unquoted it is a null where one is taken.)
pub fn needsQuotes(value: []const u8, d: Dialect) bool {
    for (value) |b| if (b == d.delimiter or b == d.quote or b == '\n' or b == '\r') return true;
    return false;
}

/// Whether `record` leaves a quoted field open: an odd number of quotes, so
/// the line break after it is inside the field.
pub fn open(record: []const u8, quote: u8) bool {
    return std.mem.countScalar(u8, record, quote) % 2 == 1;
}

test "fields as RFC 4180 writes them" {
    const d: Dialect = .{};
    const row = "a,\"b,\"\"c\"\"\",,\"\"\r\nnext";
    var f = try field(row, 0, d);
    try std.testing.expectEqualStrings("a", f.bytes);
    f = try field(row, f.end + 1, d);
    try std.testing.expect(f.quoted and f.escaped);
    try std.testing.expectEqualStrings("b,\"\"c\"\"", f.bytes);
    var out: [16]u8 = undefined;
    unescape(f.bytes, '"', out[0..unescapedLength(f.bytes, '"')]);
    try std.testing.expectEqualStrings("b,\"c\"", out[0..unescapedLength(f.bytes, '"')]);
    f = try field(row, f.end + 1, d);
    try std.testing.expectEqualStrings("", f.bytes);
    try std.testing.expect(!f.quoted);
    f = try field(row, f.end + 1, d);
    try std.testing.expect(f.quoted);
    try std.testing.expectEqual(Field.After.record_end, f.after);
    try std.testing.expectEqualStrings("next", row[pastEnd(row, f.end)..]);
    try std.testing.expectError(error.SyntaxError, field("a\"b", 0, d));
    try std.testing.expectError(error.SyntaxError, field("\"a\"b", 0, d));
    try std.testing.expectError(error.SyntaxError, field("\"a", 0, d));
    try std.testing.expectError(error.SyntaxError, field("a\rb", 0, d));
}
