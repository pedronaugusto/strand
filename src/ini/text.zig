//! INI's text: the dialect a document is read and written in, its lines, and
//! what a key, a value or a section name must be to read back as written.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

/// How a document is spelled. The defaults are Python's configparser's, the
/// most specified INI: `#` and `;` comment lines, no comment after a value,
/// `=` and `:` between a key and its value, a value continued on the lines
/// indented under it, keys lowercased.
pub const Dialect = struct {
    /// What begins a comment line, after its leading white space.
    comment_prefixes: []const []const u8 = &.{ "#", ";" },
    /// What begins a comment after white space on a line (or at its start):
    /// none, as configparser, so `a = b ; c` is `b ; c`.
    inline_comment_prefixes: []const []const u8 = &.{},
    /// The bytes that end a key: its value follows the first of them.
    delimiters: []const u8 = "=:",
    /// A line indented deeper than its key's continues the key's value,
    /// joined to it by a line feed, blank lines within kept (configparser).
    /// Off, every line stands alone (rust-ini, Go's ini).
    continuation: bool = true,
    /// Keys lowercased by Unicode's full lowercase mapping, as configparser's
    /// `optionxform` does; off, keys are as written. Section names are kept.
    lowercase_keys: bool = true,
    /// A line with no delimiter is a key with no value, a null
    /// (configparser's `allow_no_value`); off, it is refused.
    keys_without_values: bool = false,

    /// A dialect a document can be read in: some delimiter, each an ASCII
    /// byte that is not white space or `[`, and every comment prefix some
    /// bytes with no line break.
    pub fn valid(d: Dialect) bool {
        if (d.delimiters.len == 0) return false;
        for (d.delimiters) |b| if (b >= 0x80 or whitespace(b) or b == '[') return false;
        for (d.comment_prefixes) |p| if (!prefix(p)) return false;
        for (d.inline_comment_prefixes) |p| if (!prefix(p)) return false;
        return true;
    }
    fn prefix(p: []const u8) bool {
        return p.len != 0 and std.mem.findAny(u8, p, "\r\n") == null;
    }
};

/// White space as Python's `str.isspace` and its expressions' `\s` read it,
/// by which configparser trims a line and measures its indentation: the
/// ASCII controls `\t` to `\r` and `\x1c` to `\x1f`, the space, and
/// Unicode's other spaces and separators.
pub fn whitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x1c...0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
/// Whether the character that ends `s[0..end]` is white space.
fn spaceBefore(s: []const u8, end: usize) bool {
    var start = end - 1;
    while (start > 0 and s[start] & 0xc0 == 0x80) start -= 1;
    return whitespace(xenoglyph.utf8.decode(s[start..end]).code_point);
}
/// `s` without the white space at its ends.
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const d = xenoglyph.utf8.decode(s[start..]);
        if (!whitespace(d.code_point)) break;
        start += d.len;
    }
    var end = s.len;
    while (end > start and spaceBefore(s, end)) {
        end -= 1;
        while (end > start and s[end] & 0xc0 == 0x80) end -= 1;
    }
    return s[start..end];
}

/// A line of `input` from `at`, without its line feed, and where the next
/// starts (past the input's end after the last).
pub fn line(input: []const u8, at: usize) struct { bytes: []const u8, next: usize } {
    const end = std.mem.findScalarPos(u8, input, at, '\n') orelse input.len;
    return .{ .bytes = input[at..end], .next = end + 1 };
}
/// How far the line's first character that is no white space stands in,
/// in characters, as configparser measures it.
pub fn indentation(bytes: []const u8) usize {
    var at: usize = 0;
    var n: usize = 0;
    while (at < bytes.len) : (n += 1) {
        const d = xenoglyph.utf8.decode(bytes[at..]);
        if (!whitespace(d.code_point)) return n;
        at += d.len;
    }
    return n;
}

/// A line's content, as configparser reads one: a comment taken off
/// (`commented`) and white space trimmed. A comment line's content is empty.
pub fn content(bytes: []const u8, d: Dialect) struct { text: []const u8, commented: bool } {
    const trimmed = trim(bytes);
    for (d.comment_prefixes) |p| if (std.mem.startsWith(u8, trimmed, p)) return .{ .text = "", .commented = true };
    if (inlineComment(bytes, d)) |start| return .{ .text = trim(bytes[0..start]), .commented = true };
    return .{ .text = trimmed, .commented = false };
}
/// Where the first inline comment starts: a prefix at the line's start or
/// after white space.
fn inlineComment(bytes: []const u8, d: Dialect) ?usize {
    var first: ?usize = null;
    for (d.inline_comment_prefixes) |p| {
        var from: usize = 0;
        while (std.mem.findPos(u8, bytes, from, p)) |i| : (from = i + 1) {
            if (i == 0 or spaceBefore(bytes, i)) {
                if (first == null or i < first.?) first = i;
                break;
            }
        }
    }
    return first;
}

/// A section header's name: what stands between a line's `[` and its last
/// `]`, at least a byte, as configparser's `\[(?P<header>.+)\]` matches.
/// What follows the last `]` is not read.
pub fn sectionName(text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '[') return null;
    const close = std.mem.findScalarLast(u8, text, ']') orelse return null;
    if (close < 2) return null;
    return text[1..close];
}

/// Whether lowercasing `key` may change it: an ASCII capital or a byte past ASCII.
pub fn needsLower(key: []const u8) bool {
    for (key) |b| if (b >= 0x80 or (b >= 'A' and b <= 'Z')) return true;
    return false;
}
/// `key` lowercased by Unicode's full mapping, as Python's `str.lower`.
pub fn lower(key: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try xenoglyph.case.write(.lower, key, w, .{});
}

/// Whether `key = value` reads back as that key: some bytes, none of them a
/// delimiter or a line feed, no white space at either end, no comment's
/// start, not a section header (`[` first and a `]` after it on the line),
/// and as the dialect folds it.
pub fn writableKey(key: []const u8, value: []const u8, d: Dialect) bool {
    if (key.len == 0 or !std.mem.eql(u8, trim(key), key)) return false;
    if (key[0] == '[') {
        const first_line = value[0 .. std.mem.findScalar(u8, value, '\n') orelse value.len];
        if (std.mem.findScalar(u8, key, ']') != null or std.mem.findScalar(u8, first_line, ']') != null) return false;
    }
    if (std.mem.findScalar(u8, key, '\n') != null or std.mem.findAny(u8, key, d.delimiters) != null) return false;
    if (!plainText(key, d)) return false;
    return !d.lowercase_keys or !needsLower(key) or isLower(key);
}
/// Whether `key`, valid UTF-8, is its own lowercase.
fn isLower(key: []const u8) bool {
    var it: xenoglyph.case.Iterator(.lower) = .init(key, .{});
    var at: usize = 0;
    while (it.next()) |cp| {
        if (at >= key.len) return false;
        const decoded = xenoglyph.utf8.decode(key[at..]);
        if (decoded.code_point != cp) return false;
        at += decoded.len;
    }
    return at == key.len;
}
/// Whether a section named `name` reads back as itself from `[name]`: some
/// bytes, no line feed, no comment's start after white space in it.
pub fn writableSection(name: []const u8, d: Dialect) bool {
    return name.len != 0 and std.mem.findScalar(u8, name, '\n') == null and afterSpace(name, d) == null;
}
/// Where an inline comment starts after white space in `s`, past its first byte.
fn afterSpace(s: []const u8, d: Dialect) ?usize {
    for (d.inline_comment_prefixes) |p| {
        var from: usize = 1;
        while (std.mem.findPos(u8, s, from, p)) |i| : (from = i + 1) if (spaceBefore(s, i)) return i;
    }
    return null;
}
/// Whether a value written after `key =` reads back as itself: each line
/// trimmed already, no line after the first a comment, no inline comment, a
/// last line that is not blank, and more than one line only where the
/// dialect continues values.
pub fn writableValue(value: []const u8, d: Dialect) bool {
    var lines = std.mem.splitScalar(u8, value, '\n');
    var count: usize = 0;
    var last: []const u8 = "";
    while (lines.next()) |l| : (count += 1) {
        if (!std.mem.eql(u8, trim(l), l)) return false;
        // The first line follows its delimiter with no space where it begins
        // with a comment's prefix (`k =;v`); the others follow a tab.
        if ((if (count == 0) afterSpace(l, d) else inlineComment(l, d)) != null) return false;
        if (count > 0) for (d.comment_prefixes) |p| if (std.mem.startsWith(u8, l, p)) return false;
        last = l;
    }
    if (count > 1 and (!d.continuation or last.len == 0)) return false;
    return true;
}
/// Whether a value's first line can follow its delimiter after a space: it
/// does not begin with an inline comment's prefix.
pub fn spaced(value: []const u8, d: Dialect) bool {
    for (d.inline_comment_prefixes) |p| if (std.mem.startsWith(u8, value, p)) return false;
    return value.len != 0;
}
/// No comment's start in `s`, where a line read would find one.
fn plainText(s: []const u8, d: Dialect) bool {
    for (d.comment_prefixes) |p| if (std.mem.startsWith(u8, s, p)) return false;
    return inlineComment(s, d) == null;
}

/// configparser's `getboolean`: `1`, `yes`, `true`, `on` and `0`, `no`,
/// `false`, `off`, in any case.
pub fn boolean(s: []const u8) ?bool {
    for ([_][]const u8{ "1", "yes", "true", "on" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    for ([_][]const u8{ "0", "no", "false", "off" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return false;
    return null;
}

test "a line's content, comments and section names as configparser reads them" {
    const d: Dialect = .{};
    try std.testing.expectEqualStrings("a = b ; c", content("  a = b ; c  ", d).text);
    try std.testing.expect(content("  ; note", d).commented);
    const inline_d: Dialect = .{ .inline_comment_prefixes = &.{";"} };
    try std.testing.expectEqualStrings("a = b", content("a = b ; c", inline_d).text);
    try std.testing.expectEqualStrings("a = b;c", content("a = b;c", inline_d).text);
    try std.testing.expectEqualStrings("a]b", sectionName("[a]b]").?);
    try std.testing.expectEqualStrings("a", sectionName("[a] tail").?);
    try std.testing.expect(sectionName("[]") == null);
    try std.testing.expectEqual(true, boolean("YES").?);
    try std.testing.expectEqual(false, boolean("Off").?);
    try std.testing.expect(boolean("2") == null);
}
