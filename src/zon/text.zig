//! The lexical rules of ZON, as the Zig tokenizer has them: where whitespace,
//! comments, names, numbers, strings and characters end, and the bytes none of
//! them may hold. Nothing here allocates; every scan is linear in what it reads.
const std = @import("std");
const literal = std.zig.string_literal;

pub fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}

/// A byte a comment, string or character may not contain, newline apart.
fn forbidden(b: u8) bool {
    return b < 0x20 or b == 0x7f;
}

/// One run of whitespace, or one comment, from `at`; `at` if neither. A comment
/// with a byte the tokenizer refuses, or a doc comment, is not trivia: the `/`
/// is left for the grammar to refuse.
pub fn trivia(input: []const u8, at: usize) usize {
    if (at >= input.len) return at;
    const b = input[at];
    if (isSpace(b)) {
        var i = at + 1;
        while (i < input.len and isSpace(input[i])) i += 1;
        return i;
    }
    if (b != '/' or at + 1 >= input.len or input[at + 1] != '/') return at;
    // `///` and `//!` document something; ZON has nothing to document.
    if (at + 2 < input.len and (input[at + 2] == '!' or (input[at + 2] == '/' and !(at + 3 < input.len and input[at + 3] == '/')))) return at;
    var i = at + 2;
    while (i < input.len and input[i] != '\n') : (i += 1) {
        if (forbidden(input[i]) and !(input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n')) return at;
    }
    return i;
}

pub fn skipTrivia(input: []const u8, at: usize) usize {
    var i = at;
    while (true) {
        const next = trivia(input, i);
        if (next == i) return i;
        i = next;
    }
}

pub fn identifierStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

pub fn identifierEnd(input: []const u8, at: usize) usize {
    var i = at;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) i += 1;
    return i;
}

/// The end of a number literal, which is validated by the number reader: every
/// byte a literal can hold, and a sign only where an exponent can take one.
pub fn numberEnd(input: []const u8, at: usize) usize {
    var i = at;
    while (i < input.len) : (i += 1) switch (input[i]) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_', '.' => {},
        '+', '-' => switch (input[i - 1]) {
            'e', 'E', 'p', 'P' => {},
            else => break,
        },
        else => break,
    };
    return i;
}

const lanes = 16;
/// The first byte of `bytes` that ends a literal's plain run: the quote, an
/// escape, or a byte it may not hold.
fn special(bytes: []const u8, quote: u8) usize {
    var i: usize = 0;
    const lane_vector = @Vector(lanes, u8);
    while (i + lanes <= bytes.len) : (i += lanes) {
        const chunk: lane_vector = bytes[i..][0..lanes].*;
        const hit = (chunk < @as(lane_vector, @splat(0x20))) | (chunk == @as(lane_vector, @splat(0x7f))) | (chunk == @as(lane_vector, @splat(quote))) | (chunk == @as(lane_vector, @splat('\\')));
        if (@reduce(.Or, hit)) break;
    }
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == quote or b == '\\' or forbidden(b)) return i;
    }
    return i;
}

/// The index of the quote that closes a literal whose body begins at `from`.
pub fn literalEnd(input: []const u8, from: usize, quote: u8) error{SyntaxError}!usize {
    var i = from;
    while (true) {
        i += special(input[i..], quote);
        if (i >= input.len) return error.SyntaxError;
        const b = input[i];
        if (b == quote) return i;
        if (b != '\\') return error.SyntaxError;
        // The byte after a backslash is the escape's own; its meaning is read later.
        i += 1;
        if (i >= input.len or forbidden(input[i])) return error.SyntaxError;
        i += 1;
    }
}

pub fn stringEnd(input: []const u8, from: usize) error{SyntaxError}!usize {
    return literalEnd(input, from, '"');
}

/// The bytes a string literal means, `token` being the literal with its quotes.
pub fn unescapedLength(token: []const u8) error{SyntaxError}!usize {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    switch (literal.parseWrite(&discarding.writer, token) catch return error.SyntaxError) {
        .success => return @intCast(discarding.fullCount()), // safe: at most the literal's own length.
        .failure => return error.SyntaxError,
    }
}

pub fn unescape(token: []const u8, out: []u8) void {
    var writer: std.Io.Writer = .fixed(out);
    // The length was measured by the same reader a moment ago.
    const result = literal.parseWrite(&writer, token) catch unreachable; // unreachable: a fixed writer sized by the measuring pass cannot fill.
    std.debug.assert(result == .success);
    std.debug.assert(writer.end == out.len);
}

pub const Character = struct { value: u21, end: usize };

/// The character literal at `at`, an opening quote.
pub fn character(input: []const u8, at: usize) error{SyntaxError}!Character {
    const end = try literalEnd(input, at + 1, '\'');
    // std indexes the whole UTF-8 sequence a lead byte announces, and does
    // not look that the literal holds it: `'\xe2'` is out of bounds there.
    const inner = input[at + 1 .. end];
    if (inner.len != 0 and inner[0] != '\\') {
        const length = std.unicode.utf8ByteSequenceLength(inner[0]) catch return error.SyntaxError;
        if (inner.len < length) return error.SyntaxError;
    }
    return switch (literal.parseCharLiteral(input[at .. end + 1])) {
        .success => |value| .{ .value = value, .end = end + 1 },
        .failure => error.SyntaxError,
    };
}

pub const Line = struct {
    /// What follows the two backslashes, without its line ending.
    content: []const u8,
    /// Where the content ends, which is where the literal ends if this is its last line.
    content_end: usize,
    /// The start of the next line.
    next: usize,
};

/// The multiline string line at `at`, which begins `\\`.
pub fn multilineLine(input: []const u8, at: usize) ?Line {
    if (at + 1 >= input.len or input[at] != '\\' or input[at + 1] != '\\') return null;
    var i = at + 2;
    while (i < input.len and input[i] != '\n') : (i += 1) {
        const b = input[i];
        if (b == '\r' and i + 1 < input.len and input[i + 1] == '\n') break;
        if (forbidden(b)) return null;
    }
    const content_end = i;
    var next = i;
    if (next < input.len and input[next] == '\r') next += 1;
    if (next < input.len) next += 1;
    return .{ .content = input[at + 2 .. content_end], .content_end = content_end, .next = next };
}
