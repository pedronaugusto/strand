//! JSON strings at the byte level: where a run of plain text ends, whether it
//! is UTF-8, and what an escape means. The decoder and the encoder share these
//! and nothing else does.
const std = @import("std");
const work = @import("work.zig");

pub const Special = struct { at: usize, non_ascii: bool };

/// Finds JSON's three interesting classes inside a raw string run: a quote, a
/// backslash and a control byte. ASCII text is cleared a vector at a time, and
/// whether a high bit was seen before the hit is reported so that UTF-8 is
/// validated once for the whole run, and only when it has to be.
pub fn special(bytes: []const u8) Special {
    var i: usize = 0;
    var non_ascii = false;
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |width| {
            const V = @Vector(width, u8);
            const quote: V = @splat('"');
            const slash: V = @splat('\\');
            const control: V = @splat(0x20);
            const high: V = @splat(0x80);
            while (i + width <= bytes.len) : (i += width) {
                const v: V = bytes[i..][0..width].*;
                const hits = (v == quote) | (v == slash) | (v < control);
                if (@reduce(.Or, hits)) {
                    const at = std.simd.firstTrue(hits).?;
                    // High bits after the hit belong to another token.
                    const before = std.simd.iota(u8, width) < @as(V, @splat(@intCast(at)));
                    non_ascii = non_ascii or @reduce(.Or, ((v & high) == high) & before);
                    return .{ .at = i + at, .non_ascii = non_ascii };
                }
                non_ascii = non_ascii or @reduce(.Or, (v & high) == high);
            }
        }
    }
    while (i < bytes.len) : (i += 1) {
        work.scalarString(1);
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return .{ .at = i, .non_ascii = non_ascii };
        non_ascii = non_ascii or c >= 0x80;
    }
    return .{ .at = bytes.len, .non_ascii = non_ascii };
}

/// What an escape after a backslash stands for, and how many bytes of input
/// it took, the backslash not counted. A `\u` escape is a Unicode scalar: a
/// surrogate half on its own is not one.
pub const Escape = struct { len: usize, scalar: u21 };

pub fn escape(bytes: []const u8) error{SyntaxError}!Escape {
    if (bytes.len == 0) return error.SyntaxError;
    const simple: ?u8 = switch (bytes[0]) {
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => null,
        else => return error.SyntaxError,
    };
    if (simple) |c| return .{ .len = 1, .scalar = c };
    const first = try hexQuad(bytes[1..]);
    if (std.unicode.utf16IsLowSurrogate(first)) return error.SyntaxError;
    if (!std.unicode.utf16IsHighSurrogate(first)) return .{ .len = 5, .scalar = first };
    if (bytes.len < 7 or bytes[5] != '\\' or bytes[6] != 'u') return error.SyntaxError;
    const second = try hexQuad(bytes[7..]);
    if (!std.unicode.utf16IsLowSurrogate(second)) return error.SyntaxError;
    const pair = [2]u16{ first, second };
    return .{ .len = 11, .scalar = std.unicode.utf16DecodeSurrogatePair(&pair) catch return error.SyntaxError };
}

fn hexQuad(bytes: []const u8) error{SyntaxError}!u16 {
    if (bytes.len < 4) return error.SyntaxError;
    var out: u16 = 0;
    for (bytes[0..4]) |c| {
        const nibble: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.SyntaxError,
        };
        out = (out << 4) | nibble;
    }
    return out;
}

/// Where the string whose body begins at `bytes[0]` ends: the index of its
/// closing quote, and whether there is an escape before it. Every run is
/// checked to be UTF-8 and every escape to be one.
pub const End = struct { at: usize, escaped: bool };

pub fn end(bytes: []const u8) error{SyntaxError}!End {
    var at: usize = 0;
    var escaped = false;
    while (true) {
        const found = special(bytes[at..]);
        const stop = at + found.at;
        if (found.non_ascii and !std.unicode.utf8ValidateSlice(bytes[at..stop])) return error.SyntaxError;
        if (stop == bytes.len or bytes[stop] < 0x20) return error.SyntaxError;
        if (bytes[stop] == '"') return .{ .at = stop, .escaped = escaped };
        escaped = true;
        at = stop + 1 + (try escape(bytes[stop + 1 ..])).len;
    }
}

/// Writes the body of a string `end` has checked, escapes replaced by what
/// they stand for, into `out`, which is at least as long as `body`: no escape
/// is shorter than what it stands for. Returns the length written.
pub fn unescape(body: []const u8, out: []u8) usize {
    var from: usize = 0;
    var to: usize = 0;
    while (std.mem.findScalarPos(u8, body, from, '\\')) |slash| {
        @memcpy(out[to..][0 .. slash - from], body[from..slash]);
        to += slash - from;
        // unreachable: `end` checked every escape in this body.
        const e = escape(body[slash + 1 ..]) catch unreachable;
        var encoded: [4]u8 = undefined;
        // unreachable: a scalar `escape` decoded is at most U+10FFFF and no surrogate.
        const n = std.unicode.utf8Encode(e.scalar, &encoded) catch unreachable;
        @memcpy(out[to..][0..n], encoded[0..n]);
        to += n;
        from = slash + 1 + e.len;
    }
    @memcpy(out[to..][0 .. body.len - from], body[from..]);
    return to + body.len - from;
}

test unescape {
    const body = "a\\n\\u00e9\\ud83d\\ude00\\/z";
    const e = try end(body ++ "\"");
    try std.testing.expect(e.escaped);
    var out: [body.len]u8 = undefined;
    try std.testing.expectEqualStrings("a\n\u{e9}\u{1f600}/z", out[0..unescape(body, &out)]);
    try std.testing.expectError(error.SyntaxError, end("\\ud83d\""));
    try std.testing.expectError(error.SyntaxError, end("\\x\""));
    try std.testing.expectError(error.SyntaxError, end("\xff\""));
    try std.testing.expectError(error.SyntaxError, end("abc"));
}
