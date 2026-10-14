//! TOML's strings and keys as text: the four kinds of string read off the
//! input (where each ends, what it holds, whether its bytes can be lent as
//! they are), and a key or a string spelled for writing.
const std = @import("std");

pub const Error = error{SyntaxError};

/// The string kinds, by their opening delimiter.
pub const Kind = enum { basic, multiline_basic, literal, multiline_literal };

/// A string read: the content's bytes as written (between the delimiters, a
/// multiline string's first newline left off), where the string ends in the
/// input, and whether its value is those bytes or needs `decode`.
pub const Scanned = struct {
    content: []const u8,
    end: usize,
    /// The value is `content`, byte for byte.
    plain: bool,
    /// How long the value is, when it is not plain.
    len: usize,
};

/// The kind of string at `input[at]`, which is a quote or an apostrophe.
pub fn kindAt(input: []const u8, at: usize) Kind {
    const triple = at + 3 <= input.len and input[at + 1] == input[at] and input[at + 2] == input[at];
    return if (input[at] == '"')
        (if (triple) .multiline_basic else .basic)
    else if (triple) .multiline_literal else .literal;
}

/// Whether TOML lets `byte` stand for itself in a string or a comment: a
/// tab, printable ASCII or the bytes of a non-ASCII character; no other
/// control character, and not DEL.
pub inline fn ordinary(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

/// The string at `input[at]`, of `kind`. `version_1_1` allows `\e` and
/// `\xHH`, and refuses a carriage return that ends no line in a multiline
/// string, which TOML 1.0 lets stand.
pub fn scan(input: []const u8, at: usize, kind: Kind, version_1_1: bool) Error!Scanned {
    return switch (kind) {
        .literal => {
            var i = at + 1;
            while (i < input.len) : (i += 1) {
                const byte = input[i];
                if (byte == '\'') return .{ .content = input[at + 1 .. i], .end = i + 1, .plain = true, .len = i - at - 1 };
                if (!ordinary(byte)) return error.SyntaxError;
            }
            return error.SyntaxError;
        },
        .basic => {
            var i = at + 1;
            var len: usize = 0;
            var plain = true;
            while (i < input.len) {
                const byte = input[i];
                if (byte == '"') return .{ .content = input[at + 1 .. i], .end = i + 1, .plain = plain, .len = len };
                if (byte == '\\') {
                    plain = false;
                    const e = try escape(input, i, version_1_1);
                    len += e.len;
                    i = e.end;
                    continue;
                }
                if (!ordinary(byte)) return error.SyntaxError;
                len += 1;
                i += 1;
            }
            return error.SyntaxError;
        },
        .multiline_literal, .multiline_basic => {
            const quote = input[at];
            var start = at + 3;
            // A newline right after the delimiter is no part of the string.
            if (start < input.len and input[start] == '\n') start += 1 else if (start + 1 < input.len and input[start] == '\r' and input[start + 1] == '\n') start += 2;
            var i = start;
            var len: usize = 0;
            var plain = true;
            while (i < input.len) {
                const byte = input[i];
                if (byte == quote) {
                    var run: usize = 1;
                    while (i + run < input.len and input[i + run] == quote) run += 1;
                    if (run >= 3) {
                        // Up to two quotes before the delimiter are content.
                        if (run > 5) return error.SyntaxError;
                        return .{ .content = input[start .. i + run - 3], .end = i + run, .plain = plain, .len = len + run - 3 };
                    }
                    len += run;
                    i += run;
                    continue;
                }
                if (quote == '"' and byte == '\\') {
                    plain = false;
                    if (try lineEnding(input, i)) |end| {
                        i = end;
                        continue;
                    }
                    const e = try escape(input, i, version_1_1);
                    len += e.len;
                    i = e.end;
                    continue;
                }
                if (byte == '\r') {
                    if (i + 1 < input.len and input[i + 1] == '\n') {
                        len += 2;
                        i += 2;
                        continue;
                    }
                    if (version_1_1) return error.SyntaxError;
                    len += 1;
                    i += 1;
                    continue;
                }
                if (byte != '\n' and !ordinary(byte)) return error.SyntaxError;
                len += 1;
                i += 1;
            }
            return error.SyntaxError;
        },
    };
}

/// After a line-ending backslash at `input[at]`: where the next character
/// that is no whitespace or newline is. `null` when the backslash ends no
/// line (whitespace, then something other than a newline).
fn lineEnding(input: []const u8, at: usize) Error!?usize {
    var i = at + 1;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
    if (i < input.len and input[i] == '\n') {
        i += 1;
    } else if (i + 1 < input.len and input[i] == '\r' and input[i + 1] == '\n') {
        i += 2;
    } else return null;
    while (i < input.len) {
        if (input[i] == ' ' or input[i] == '\t' or input[i] == '\n') {
            i += 1;
        } else if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') {
            i += 2;
        } else break;
    }
    return i;
}

const Escape = struct { end: usize, len: usize, scalar: u21 };
/// The escape at `input[at]` (a backslash): where it ends, and the character
/// it stands for and that character's UTF-8 length.
fn escape(input: []const u8, at: usize, version_1_1: bool) Error!Escape {
    if (at + 1 >= input.len) return error.SyntaxError;
    const simple: ?u21 = switch (input[at + 1]) {
        'b' => 0x08,
        't' => '\t',
        'n' => '\n',
        'f' => 0x0c,
        'r' => '\r',
        '"' => '"',
        '\\' => '\\',
        'e' => if (version_1_1) 0x1b else return error.SyntaxError,
        else => null,
    };
    if (simple) |scalar| return .{ .end = at + 2, .len = 1, .scalar = scalar };
    const digits: usize = switch (input[at + 1]) {
        'x' => if (version_1_1) 2 else return error.SyntaxError,
        'u' => 4,
        'U' => 8,
        else => return error.SyntaxError,
    };
    if (at + 2 + digits > input.len) return error.SyntaxError;
    var value: u32 = 0;
    for (input[at + 2 ..][0..digits]) |byte| value = value * 16 + (std.fmt.charToDigit(byte, 16) catch return error.SyntaxError);
    if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.SyntaxError;
    const scalar: u21 = @intCast(value); // safe: checked against U+10FFFF above.
    return .{ .end = at + 2 + digits, .len = std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable, .scalar = scalar }; // unreachable: a scalar value has a length.
}

/// A scanned string's value into `out`, which is `Scanned.len` long.
pub fn decode(scanned: Scanned, kind: Kind, out: []u8) void {
    const content = scanned.content;
    var n: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];
        if (byte == '\\' and (kind == .basic or kind == .multiline_basic)) {
            if (kind == .multiline_basic) if (lineEnding(content, i) catch unreachable) |end| { // unreachable: scanned already.
                i = end;
                continue;
            };
            const e = escape(content, i, true) catch unreachable; // unreachable: scanned already, in its version.
            n += std.unicode.utf8Encode(e.scalar, out[n..]) catch unreachable; // unreachable: a scalar value, and its length was counted.
            i = e.end;
            continue;
        }
        out[n] = byte;
        n += 1;
        i += 1;
    }
    std.debug.assert(n == out.len);
}

/// Whether `key` can be written bare: one or more of `A-Za-z0-9_-`.
pub fn bare(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    return true;
}

/// `value` as a basic string: quoted, with a quote, a backslash and every
/// control character escaped (`\uXXXX` where no short escape exists, which
/// TOML 1.0 reads too).
pub fn quoted(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!usize {
    var written: usize = 2;
    try writer.writeByte('"');
    var start: usize = 0;
    for (value, 0..) |byte, i| {
        const short: ?u8 = switch (byte) {
            '"' => '"',
            '\\' => '\\',
            0x08 => 'b',
            '\t' => 't',
            '\n' => 'n',
            0x0c => 'f',
            '\r' => 'r',
            else => null,
        };
        if (short == null and ordinary(byte)) continue;
        try writer.writeAll(value[start..i]);
        written += i - start;
        if (short) |s| {
            try writer.writeAll(&.{ '\\', s });
            written += 2;
        } else {
            try writer.print("\\u{X:0>4}", .{byte});
            written += 6;
        }
        start = i + 1;
    }
    try writer.writeAll(value[start..]);
    written += value.len - start;
    try writer.writeByte('"');
    return written;
}

test "each kind of string, its end and its value" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\"plain\" tail", "plain" },
        .{ "\"tab\\tquote\\\"\\u00e9\\U0001F600\"", "tab\tquote\"\u{e9}\u{1F600}" },
        .{ "'C:\\Users\\nodejs'", "C:\\Users\\nodejs" },
        .{ "\"\"\"\nRoses\nViolets\"\"\"", "Roses\nViolets" },
        .{ "\"\"\"The quick \\\n\n   brown\"\"\"", "The quick brown" },
        .{ "\"\"\"two quotes: \"\"\"\"\"", "two quotes: \"\"" },
        .{ "'''\nfirst newline trimmed\n'''", "first newline trimmed\n" },
        .{ "'''That,' she said'''", "That,' she said" },
        .{ "\"\\e[ \\x61\"", "\x1b[ a" },
    };
    for (cases) |case| {
        const kind = kindAt(case[0], 0);
        const scanned = try scan(case[0], 0, kind, true);
        var buffer: [64]u8 = undefined;
        const value = if (scanned.plain) scanned.content else blk: {
            decode(scanned, kind, buffer[0..scanned.len]);
            break :blk buffer[0..scanned.len];
        };
        try std.testing.expectEqualStrings(case[1], value);
    }
    for ([_][]const u8{ "\"open", "\"bad \\q\"", "\"\\uD800\"", "\"\\U00110000\"", "'a\x00'", "\"\"\"six\"\"\"\"\"\"", "\"\x7f\"" }) |input|
        try std.testing.expectError(error.SyntaxError, scan(input, 0, kindAt(input, 0), true));
    // TOML 1.0 has neither \e nor \x, and lets a lone carriage return stand.
    try std.testing.expectError(error.SyntaxError, scan("\"\\e\"", 0, .basic, false));
    try std.testing.expectError(error.SyntaxError, scan("\"\"\"a\rb\"\"\"", 0, .multiline_basic, true));
    _ = try scan("\"\"\"a\rb\"\"\"", 0, .multiline_basic, false);
}

test "a string written is read back as itself" {
    var buffer: [128]u8 = undefined;
    for ([_][]const u8{ "", "plain", "quote \" and \\ back", "\x00\x1f\x7f\ttab", "é \u{1F600}" }) |value| {
        var writer: std.Io.Writer = .fixed(&buffer);
        const n = try quoted(&writer, value);
        const spelled = writer.buffered();
        try std.testing.expectEqual(spelled.len, n);
        const scanned = try scan(spelled, 0, .basic, false);
        var out: [128]u8 = undefined;
        decode(scanned, .basic, out[0..scanned.len]);
        try std.testing.expectEqualStrings(value, out[0..scanned.len]);
    }
}
