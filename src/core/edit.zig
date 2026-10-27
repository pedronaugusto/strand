//! What every format's editor shares: a document held as its text, changed
//! by splices that the format's own reader locates and its own writer
//! spells, and the paths that address a value, as JSON Pointer (RFC 6901)
//! spells them for every data model JSON's covers. Nothing here knows a
//! format: an editor finds the bytes a change replaces, and the text keeps
//! every other byte as it was.
const std = @import("std");
const aegis = @import("aegis");
const ctx = @import("context.zig");

/// What an edit can fail with, beside its format's reading and writing.
pub const PathError = error{
    /// The pointer is not one: not empty and not starting with `/`, or a `~`
    /// not followed by `0` or `1`.
    InvalidPointer,
    /// No value is where the pointer points, or its parent is not there to
    /// take one, or a token names no member or no element of what it is in.
    PathNotFound,
};
pub const Error = PathError || ctx.DecodeError || ctx.EncodeError || std.Io.Writer.Error;

/// A JSON Pointer's reference tokens, unescaped as they are read.
pub const Pointer = struct {
    rest: []const u8,

    /// `text`, checked: empty (the whole document) or tokens each after a `/`.
    pub fn parse(text: []const u8) PathError!Pointer {
        if (text.len != 0 and text[0] != '/') return error.InvalidPointer;
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, text, i, '~')) |k| {
            if (k + 1 >= text.len or (text[k + 1] != '0' and text[k + 1] != '1')) return error.InvalidPointer;
            i = k + 2;
        }
        return .{ .rest = text };
    }
    /// Whether no token is left.
    pub fn done(self: Pointer) bool {
        return self.rest.len == 0;
    }
    /// The next token as written (escapes in it), and the pointer after it.
    pub fn next(self: *Pointer) ?Token {
        if (self.rest.len == 0) return null;
        const end = std.mem.findScalarPos(u8, self.rest, 1, '/') orelse self.rest.len;
        const token = self.rest[1..end];
        self.rest = self.rest[end..];
        return .{ .written = token };
    }
    /// The pointer without its last token, and that token.
    pub fn split(self: Pointer) ?struct { parent: Pointer, last: Token } {
        if (self.rest.len == 0) return null;
        const slash = std.mem.findScalarLast(u8, self.rest, '/').?;
        return .{ .parent = .{ .rest = self.rest[0..slash] }, .last = .{ .written = self.rest[slash + 1 ..] } };
    }
};
/// One reference token, as written in the pointer.
pub const Token = struct {
    written: []const u8,

    /// Whether the token, unescaped, is `name`.
    pub fn is(self: Token, name: []const u8) bool {
        if (std.mem.findScalar(u8, self.written, '~') == null) return std.mem.eql(u8, self.written, name);
        var i: usize = 0;
        var k: usize = 0;
        while (i < self.written.len) : (k += 1) {
            if (k >= name.len) return false;
            var b = self.written[i];
            i += 1;
            if (b == '~') {
                b = if (self.written[i] == '0') '~' else '/';
                i += 1;
            }
            if (b != name[k]) return false;
        }
        return k == name.len;
    }
    /// The token unescaped into `buffer`, which is as long as it is written.
    pub fn unescape(self: Token, buffer: []u8) []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.written.len) : (n += 1) {
            var b = self.written[i];
            i += 1;
            if (b == '~') {
                b = if (self.written[i] == '0') '~' else '/';
                i += 1;
            }
            buffer[n] = b;
        }
        return buffer[0..n];
    }
    /// The token as an array index: decimal digits with no zero before
    /// others, or null (`-`, the end of an array, among the rest).
    pub fn index(self: Token) ?usize {
        const t = self.written;
        if (t.len == 0 or (t[0] == '0' and t.len > 1)) return null;
        for (t) |b| if (!std.ascii.isDigit(b)) return null;
        return std.fmt.parseInt(usize, t, 10) catch null;
    }
    /// Whether the token is `-`, the place past an array's last element.
    pub fn isEnd(self: Token) bool {
        return std.mem.eql(u8, self.written, "-");
    }
};

/// A change to the text: the bytes from `start` to `end` replaced by
/// `replacement`.
pub const Splice = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

/// The text `splices` make of `text`, on `a`: each names bytes of `text`,
/// none overlapping another, and is made in one pass in the order they lie.
pub fn applied(a: std.mem.Allocator, text: []const u8, splices: []const Splice) error{OutOfMemory}![]u8 {
    const sorted = try a.dupe(Splice, splices);
    defer a.free(sorted);
    std.mem.sort(Splice, sorted, {}, struct {
        fn lessThan(_: void, x: Splice, y: Splice) bool {
            return x.start < y.start;
        }
    }.lessThan);
    // The contract is checked before anything is counted: each splice lies in
    // the text, after the one before it.
    var length = text.len;
    var last: usize = 0;
    for (sorted) |s| {
        aegis.assert.invariant(last <= s.start and s.start <= s.end and s.end <= text.len, "each splice lies in the text, none overlapping another");
        length = length - (s.end - s.start) + s.replacement.len; // aegis: no-danger: the splice, checked on the line before, lies in the text
        last = s.end;
    }
    const out = try a.alloc(u8, length);
    var from: usize = 0;
    var to: usize = 0;
    // `out` is as long as the checked splices make the text, and `to` counts
    // what has been written of it.
    for (sorted) |s| {
        @memcpy(out[to..][0 .. s.start - from], text[from..s.start]); // aegis: no-danger: from <= s.start <= text.len, checked above; out holds what the splices make
        to += s.start - from; // aegis: no-danger: from <= s.start, checked above
        @memcpy(out[to..][0..s.replacement.len], s.replacement); // aegis: no-danger: out holds each replacement, counted in its length above
        to += s.replacement.len;
        from = s.end;
    }
    @memcpy(out[to..], text[from..]); // aegis: no-danger: from is the last splice's end, at most text.len, checked above
    return out;
}

/// A document's text and what reading it found (`Read`, which holds the
/// text), on an arena of their own: the read that checked an edit, kept to
/// find the next edit's place.
pub fn Held(comptime Read: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        read: Read,
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// A document's text, which every edit changes and nothing else holds.
pub const Text = struct {
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Text {
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(gpa, text);
        return .{ .bytes = bytes };
    }
    pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }
    /// The text `splice` makes, on `gpa`, the caller's: the bytes it names
    /// replaced (its replacement may be a part of the text itself).
    pub fn spliced(self: *const Text, gpa: std.mem.Allocator, splice: Splice) error{OutOfMemory}![]u8 {
        const text = self.bytes.items;
        aegis.assert.invariant(splice.start <= splice.end and splice.end <= text.len, "splice.start <= splice.end and splice.end <= text.len");
        return std.mem.concat(gpa, u8, &.{ text[0..splice.start], splice.replacement, text[splice.end..] });
    }
    /// The text made `next`, which an edit checked.
    pub fn replace(self: *Text, gpa: std.mem.Allocator, next: []const u8) error{OutOfMemory}!void {
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(gpa, next);
    }
};

/// Where the line holding `at` starts.
pub fn lineStart(text: []const u8, at: usize) usize {
    return if (std.mem.findScalarLast(u8, text[0..at], '\n')) |k| k + 1 else 0; // aegis: no-danger: `at` is a position in `text` the caller's read found
}
/// Where the line holding `at` ends: past its line feed, or the text's end.
pub fn lineEnd(text: []const u8, at: usize) usize {
    return if (std.mem.findScalarPos(u8, text, at, '\n')) |k| k + 1 else text.len;
}
/// Whether only spaces and tabs stand between `from` and `to`.
pub fn blankBetween(text: []const u8, from: usize, to: usize) bool {
    for (text[from..to]) |b| if (b != ' ' and b != '\t') return false; // aegis: no-danger: positions in `text` the caller's read found, `from` the start of the line `to` is on
    return true;
}
/// The spaces and tabs that start the line holding `at`.
pub fn indentation(text: []const u8, at: usize) []const u8 {
    const start = lineStart(text, at);
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return text[start..i];
}
/// `text` with `indent` after each of its line feeds but a last one.
pub fn indented(gpa: std.mem.Allocator, text: []const u8, indent: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text, 0..) |b, i| {
        try out.append(gpa, b);
        if (b == '\n' and i + 1 < text.len) try out.appendSlice(gpa, indent);
    }
    return out.toOwnedSlice(gpa);
}

test "pointers and their tokens" {
    var p = try Pointer.parse("/a~1b/m~0n/0/-");
    try std.testing.expect(p.next().?.is("a/b"));
    try std.testing.expect(p.next().?.is("m~n"));
    try std.testing.expectEqual(@as(?usize, 0), p.next().?.index());
    try std.testing.expect(p.next().?.isEnd());
    try std.testing.expect(p.done());
    try std.testing.expectError(error.InvalidPointer, Pointer.parse("a"));
    try std.testing.expectError(error.InvalidPointer, Pointer.parse("/a~2"));
    const s = (try Pointer.parse("/x/y")).split().?;
    try std.testing.expectEqualStrings("/x", s.parent.rest);
    try std.testing.expect(s.last.is("y"));
    try std.testing.expectEqual(@as(?usize, null), (Token{ .written = "01" }).index());
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a/~", (Token{ .written = "a~1~0" }).unescape(&buffer));
}
