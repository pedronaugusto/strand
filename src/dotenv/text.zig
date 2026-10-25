//! .env text as python-dotenv reads it (its `parser.py`, 1.2), a binding at
//! a time, and what a key or a value must be to read back as written. White
//! space is Python's `str.isspace`, as its expressions' `\s` is, the one
//! configparser's INI is read by.
const std = @import("std");
const xenoglyph = @import("xenoglyph");
const ini_text = @import("../ini/text.zig");

/// How a value was written, which says what its escapes are.
pub const Quoting = enum { none, single, double };
/// A value as written: its quotes taken off, its escapes not yet read.
pub const Value = struct { body: []const u8, quoting: Quoting };
/// A key and its value, `null` for a key with no `=`; `at` is where it starts.
pub const Binding = struct { key: []const u8, value: ?Value, at: usize };

/// What a step read: a binding, or nothing (white space, a comment, the end),
/// and where the next step starts.
pub const Step = struct { binding: ?Binding, next: usize };

/// The binding from `from` on, as python-dotenv's `parse_binding` reads one:
/// white space and line ends skipped; `export` and white space; a key, in
/// single quotes or up to `=`, `#` or white space; white space; `=`, white
/// space and a value, or no value; a comment after white space; the line's
/// end. A comment line is nothing. What python-dotenv skips as an error is
/// a syntax error.
pub fn next(input: []const u8, from: usize) error{SyntaxError}!Step {
    var at = skipSpace(input, from, true);
    if (at == input.len) return .{ .binding = null, .next = at };
    const start = at;
    at = exportEnd(input, at);
    var key: ?[]const u8 = null;
    if (at < input.len and input[at] == '#') {
        // A comment: no key, and so no `=`.
    } else if (at < input.len and input[at] == '\'') {
        const close = std.mem.findScalarPos(u8, input, at + 1, '\'') orelse return error.SyntaxError;
        if (close == at + 1) return error.SyntaxError;
        key = input[at + 1 .. close];
        at = close + 1;
    } else {
        const end = keyEnd(input, at);
        if (end == at) return error.SyntaxError;
        key = input[at..end];
        at = end;
    }
    at = skipSpace(input, at, false);
    var value: ?Value = null;
    if (key != null and at < input.len and input[at] == '=') {
        const sign = at;
        at = skipSpace(input, at + 1, false);
        // `KEY= # note` is empty, its comment after white space; `KEY=#v` is `#v`.
        if (at > sign + 1 and at < input.len and input[at] == '#') {
            value = .{ .body = "", .quoting = .none };
        } else {
            const v = try valueAt(input, at);
            value = v.value;
            at = v.next;
        }
    }
    const comment = skipSpace(input, at, false);
    if (comment < input.len and input[comment] == '#') at = lineEnd(input, comment);
    at = skipSpace(input, at, false);
    if (at < input.len) switch (input[at]) {
        '\r' => at += if (at + 1 < input.len and input[at + 1] == '\n') 2 else 1,
        '\n' => at += 1,
        else => return error.SyntaxError,
    };
    const k = key orelse return .{ .binding = null, .next = at };
    return .{ .binding = .{ .key = k, .value = value, .at = start }, .next = at };
}

/// The value at `at` and where it ends: in single or double quotes, across
/// lines, a backslash taking the character after it with it; or the rest of
/// the line, cut where a `#` follows white space, white space after it trimmed.
fn valueAt(input: []const u8, at: usize) error{SyntaxError}!struct { value: Value, next: usize } {
    if (at == input.len or input[at] == '\n' or input[at] == '\r') return .{ .value = .{ .body = "", .quoting = .none }, .next = at };
    const quote = input[at];
    if (quote == '\'' or quote == '"') {
        var i = at + 1;
        while (i < input.len) {
            if (input[i] == '\\') {
                if (i + 1 == input.len) return error.SyntaxError;
                i += 1 + sequence(input[i + 1 ..]);
            } else if (input[i] == quote) {
                return .{ .value = .{ .body = input[at + 1 .. i], .quoting = if (quote == '\'') .single else .double }, .next = i + 1 };
            } else i += 1;
        }
        return error.SyntaxError;
    }
    const end = std.mem.findAnyPos(u8, input, at, "\r\n") orelse input.len;
    var part = input[at..end];
    if (commentStart(part)) |hash| part = part[0..hash];
    return .{ .value = .{ .body = trimEnd(part), .quoting = .none }, .next = end };
}

/// Where the first `#` after white space is in an unquoted value, which is
/// where python-dotenv's `\s+#.*` cuts it.
fn commentStart(part: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, part, from, '#')) |i| : (from = i + 1) {
        if (i > 0 and spaceBefore(part, i)) return i;
    }
    return null;
}

/// How long the character `bytes` begin with is, a byte for a broken one.
fn sequence(bytes: []const u8) usize {
    return xenoglyph.utf8.decode(bytes).len;
}
/// The white space character at `bytes[at]`, or null.
fn spaceAt(bytes: []const u8, at: usize) ?usize {
    const d = xenoglyph.utf8.decode(bytes[at..]);
    return if (ini_text.whitespace(d.code_point)) d.len else null;
}
fn spaceBefore(s: []const u8, end: usize) bool {
    var start = end - 1;
    while (start > 0 and s[start] & 0xc0 == 0x80) start -= 1;
    return ini_text.whitespace(xenoglyph.utf8.decode(s[start..end]).code_point);
}
/// Past the white space from `at`, and line ends with it where `lines`.
fn skipSpace(input: []const u8, from: usize, lines: bool) usize {
    var at = from;
    while (at < input.len) {
        if (!lines and (input[at] == '\r' or input[at] == '\n')) break;
        at += spaceAt(input, at) orelse break;
    }
    return at;
}
fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and spaceBefore(s, end)) {
        end -= 1;
        while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    }
    return s[0..end];
}
/// Where the line from `at` ends, before its line end.
fn lineEnd(input: []const u8, at: usize) usize {
    return std.mem.findAnyPos(u8, input, at, "\r\n") orelse input.len;
}
/// Past `export` and the white space after it, where there is some.
fn exportEnd(input: []const u8, at: usize) usize {
    if (!std.mem.startsWith(u8, input[at..], "export")) return at;
    const after = skipSpace(input, at + "export".len, false);
    return if (after > at + "export".len) after else at;
}
/// Where an unquoted key ends: at `=`, `#` or white space.
fn keyEnd(input: []const u8, from: usize) usize {
    var at = from;
    while (at < input.len and input[at] != '=' and input[at] != '#') {
        if (spaceAt(input, at) != null) break;
        at += sequence(input[at..]);
    }
    return at;
}

/// The escape a backslash and the byte after it are in a value so quoted,
/// or null where they stand for themselves: in single quotes `\\` and `\'`,
/// in double quotes those, `\"` and `\a \b \f \n \r \t \v`.
fn escaped(quoting: Quoting, b: u8) ?u8 {
    if (quoting == .none) return null;
    return switch (b) {
        '\\' => '\\',
        '\'' => '\'',
        else => if (quoting != .double) null else switch (b) {
            '"' => '"',
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            else => null,
        },
    };
}
/// Whether reading `v` rewrites it: an escape in quotes, or a carriage
/// return in them, which reads as a line feed, as Python's text files read
/// a line end, which python-dotenv reads a file through.
pub fn rewritten(v: Value) bool {
    if (v.quoting == .none) return false;
    if (std.mem.findScalar(u8, v.body, '\r') != null) return true;
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, v.body, from, '\\')) |i| : (from = i + 2) {
        if (escaped(v.quoting, v.body[i + 1]) != null) return true;
    }
    return false;
}
/// `v`'s text into `out`, at least `v.body.len` long, its escapes read and
/// its line ends line feeds. Returns the length written.
pub fn unescape(v: Value, out: []u8) usize {
    var to: usize = 0;
    var i: usize = 0;
    while (i < v.body.len) {
        const b = v.body[i];
        if (b == '\r') {
            out[to] = '\n';
            to += 1;
            i += if (i + 1 < v.body.len and v.body[i + 1] == '\n') 2 else 1;
            continue;
        }
        if (b == '\\' and i + 1 < v.body.len) if (escaped(v.quoting, v.body[i + 1])) |e| {
            out[to] = e;
            to += 1;
            i += 2;
            continue;
        };
        out[to] = b;
        to += 1;
        i += 1;
    }
    return to;
}

/// A quoted key into `out`, at least as long, its line ends line feeds as a
/// value's are; a key has no escapes. Returns the length written.
pub fn lineFeeds(key: []const u8, out: []u8) usize {
    var to: usize = 0;
    var i: usize = 0;
    while (i < key.len) : (to += 1) {
        out[to] = if (key[i] == '\r') '\n' else key[i];
        i += if (key[i] == '\r' and i + 1 < key.len and key[i + 1] == '\n') 2 else 1;
    }
    return to;
}

/// How `key` is written to read back as itself, or null where it cannot
/// be: unquoted where it has no `=`, `#` or white space and begins with no
/// `'` or U+FEFF (which first in a file is a byte-order mark); else in
/// single quotes, where it has no `'` and no carriage return, which would
/// read as a line feed.
pub fn keyQuoting(key: []const u8) ?Quoting {
    if (key.len == 0 or std.mem.findScalar(u8, key, '\r') != null) return null;
    if (key[0] != '\'' and !std.mem.startsWith(u8, key, "\u{feff}") and keyEnd(key, 0) == key.len) return .none;
    if (std.mem.findScalar(u8, key, '\'') == null) return .single;
    return null;
}
/// How `value` is written to read back as itself: unquoted where it is
/// empty, or on one line with no quote first, no white space at either end
/// and no `#` after white space; in single quotes where it is one line with
/// no `'` or `\`; else in double quotes, escaped.
pub fn quotingOf(value: []const u8) Quoting {
    if (value.len == 0) return .none;
    const one_line = std.mem.findAny(u8, value, "\r\n") == null;
    const plain = one_line and value[0] != '\'' and value[0] != '"' and spaceAt(value, 0) == null and
        !spaceBefore(value, value.len) and commentStart(value) == null;
    if (plain) return .none;
    if (one_line and std.mem.findAny(u8, value, "'\\") == null) return .single;
    return .double;
}
/// The escape a byte is written as in double quotes, or null for itself.
pub fn doubleEscape(b: u8) ?[]const u8 {
    return switch (b) {
        '\\' => "\\\\",
        '"' => "\\\"",
        '\n' => "\\n",
        '\r' => "\\r",
        else => null,
    };
}

test next {
    const input = "\xef\xbb\xbf# c\n export A = 1 # note\n'b k'=\"x\\ny\"#c\nC\nD=\nE= # e\nF=#f\nG='a\nb'\r\nH=v w  ";
    var at: usize = 3;
    var seen: std.ArrayList(Binding) = .empty;
    defer seen.deinit(std.testing.allocator);
    while (at < input.len) {
        const step = try next(input, at);
        if (step.binding) |b| try seen.append(std.testing.allocator, b);
        at = step.next;
    }
    const expected = [_]struct { []const u8, ?[]const u8, Quoting }{
        .{ "A", "1", .none }, .{ "b k", "x\\ny", .double }, .{ "C", null, .none },     .{ "D", "", .none },
        .{ "E", "", .none },  .{ "F", "#f", .none },        .{ "G", "a\nb", .single }, .{ "H", "v w", .none },
    };
    try std.testing.expectEqual(expected.len, seen.items.len);
    for (expected, seen.items) |e, b| {
        try std.testing.expectEqualStrings(e[0], b.key);
        if (e[1]) |v| {
            try std.testing.expectEqualStrings(v, b.value.?.body);
            try std.testing.expectEqual(e[2], b.value.?.quoting);
        } else try std.testing.expect(b.value == null);
    }
    for ([_][]const u8{ "=v", "A=\"open", "A=\"v\" w", "'k", "''=v", "export =1", "A B=1" }) |bad| {
        try std.testing.expectError(error.SyntaxError, next(bad, 0));
    }
}

test "escapes as each quote reads them" {
    var out: [32]u8 = undefined;
    const double: Value = .{ .body = "a\\n\\t\\\\\\\"\\'\\d", .quoting = .double };
    try std.testing.expect(rewritten(double));
    try std.testing.expectEqualStrings("a\n\t\\\"'\\d", out[0..unescape(double, &out)]);
    const single: Value = .{ .body = "a\\n\\\\\\'", .quoting = .single };
    try std.testing.expectEqualStrings("a\\n\\'", out[0..unescape(single, &out)]);
    try std.testing.expect(!rewritten(.{ .body = "a\\n", .quoting = .single }));
}

test quotingOf {
    try std.testing.expectEqual(Quoting.none, quotingOf("plain value"));
    try std.testing.expectEqual(Quoting.none, quotingOf("#hash"));
    try std.testing.expectEqual(Quoting.single, quotingOf(" lead"));
    try std.testing.expectEqual(Quoting.single, quotingOf("a #b"));
    try std.testing.expectEqual(Quoting.single, quotingOf("\"q"));
    try std.testing.expectEqual(Quoting.double, quotingOf("it's "));
    try std.testing.expectEqual(Quoting.double, quotingOf("two\nlines"));
    try std.testing.expectEqual(Quoting.none, keyQuoting("A.b-c").?);
    try std.testing.expectEqual(Quoting.single, keyQuoting("a b").?);
    try std.testing.expectEqual(Quoting.single, keyQuoting("\u{feff}a").?);
    try std.testing.expect(keyQuoting("'a") == null);
    try std.testing.expect(keyQuoting("") == null);
}
