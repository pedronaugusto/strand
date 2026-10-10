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
    // What is left, shorter than a vector: a word at a time, the last word
    // overlapping the one before it, and bytes one by one only under eight.
    if (bytes.len - i >= 8) {
        while (i + 8 <= bytes.len) : (i += 8) {
            const word = load(bytes[i..]);
            const hits = specialBytes(word);
            if (hits != 0) {
                const at: usize = @ctz(hits) / 8;
                return .{ .at = i + at, .non_ascii = non_ascii or (word & high_bits & below(at)) != 0 };
            }
            non_ascii = non_ascii or word & high_bits != 0;
        }
        if (i < bytes.len) {
            const from = bytes.len - 8;
            const seen: usize = i - from;
            const word = load(bytes[from..]);
            const hits = specialBytes(word) & ~below(seen);
            if (hits != 0) {
                const at: usize = @ctz(hits) / 8;
                return .{ .at = from + at, .non_ascii = non_ascii or (word & high_bits & below(at) & ~below(seen)) != 0 };
            }
            non_ascii = non_ascii or (word & high_bits & ~below(seen)) != 0;
        }
        return .{ .at = bytes.len, .non_ascii = non_ascii };
    }
    const rest = bytes.len - i;
    if (rest == 0) return .{ .at = bytes.len, .non_ascii = non_ascii };
    work.scalarString(rest);
    // Under eight bytes: copied into a word padded with plain ones.
    var padded: [8]u8 = @splat('a');
    copy(&padded, bytes[i..]);
    const word = load(&padded);
    const hits = specialBytes(word);
    if (hits != 0) {
        const at: usize = @ctz(hits) / 8;
        return .{ .at = i + at, .non_ascii = non_ascii or (word & high_bits & below(at)) != 0 };
    }
    return .{ .at = bytes.len, .non_ascii = non_ascii or (word & high_bits) != 0 };
}

const ones: u64 = 0x0101010101010101;
const high_bits: u64 = ones * 0x80;
inline fn load(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}
/// The high bit of every byte of `word` that is a quote, a backslash or a
/// control byte, exact up to the first such byte, which is all a caller reads.
inline fn specialBytes(word: u64) u64 {
    const quote = word ^ (ones * '"');
    const slash = word ^ (ones * '\\');
    return ((quote -% ones) & ~quote | (slash -% ones) & ~slash | (word -% ones * 0x20) & ~word) & high_bits;
}
/// A mask of the bytes of a word below byte `n`.
inline fn below(n: usize) u64 {
    return if (n >= 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n * 8)) - 1;
}

/// Copies a few bytes, as a piece of output usually is, without a call: two
/// overlapping loads and stores cover any length up to sixteen.
pub inline fn copy(to: [*]u8, from: []const u8) void {
    const n = from.len;
    if (n >= 16) return @memcpy(to[0..n], from);
    if (n >= 8) {
        const head = std.mem.readInt(u64, from[0..8], .little);
        const tail = std.mem.readInt(u64, from[n - 8 ..][0..8], .little);
        std.mem.writeInt(u64, to[0..8], head, .little);
        std.mem.writeInt(u64, to[n - 8 ..][0..8], tail, .little);
    } else if (n >= 4) {
        const head = std.mem.readInt(u32, from[0..4], .little);
        const tail = std.mem.readInt(u32, from[n - 4 ..][0..4], .little);
        std.mem.writeInt(u32, to[0..4], head, .little);
        std.mem.writeInt(u32, to[n - 4 ..][0..4], tail, .little);
    } else if (n > 0) {
        to[0] = from[0];
        to[n / 2] = from[n / 2];
        to[n - 1] = from[n - 1];
    }
}

/// Writes `value` in decimal at the end of `buffer`, two digits at a time,
/// and returns the digits.
pub fn decimal(buffer: []u8, value: anytype) []const u8 {
    const T = @TypeOf(value);
    const negative = @typeInfo(T).int.signedness == .signed and value < 0;
    var magnitude = @abs(value);
    var at = buffer.len;
    while (magnitude >= 100) {
        const pair: usize = @intCast(magnitude % 100); // safe: below one hundred.
        magnitude /= 100;
        at -= 2;
        buffer[at..][0..2].* = digit_pairs[pair * 2 ..][0..2].*;
    }
    if (magnitude >= 10) {
        const pair: usize = @intCast(magnitude); // safe: below one hundred.
        at -= 2;
        buffer[at..][0..2].* = digit_pairs[pair * 2 ..][0..2].*;
    } else {
        at -= 1;
        buffer[at] = '0' + @as(u8, @intCast(magnitude)); // safe: a single digit.
    }
    if (negative) {
        at -= 1;
        buffer[at] = '-';
    }
    return buffer[at..];
}
const digit_pairs = blk: {
    var pairs: [200]u8 = undefined;
    for (0..100) |n| {
        pairs[n * 2] = '0' + n / 10;
        pairs[n * 2 + 1] = '0' + n % 10;
    }
    break :blk pairs;
};

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

test special {
    const cases = [_]struct { []const u8, usize, bool }{
        .{ "", 0, false },
        .{ "abc", 3, false },
        .{ "abcdefgh", 8, false },
        .{ "abcdefg\"", 7, false },
        .{ "abcdefghijk\\", 11, false },
        .{ "abc\xc3\xa9defghij\"", 12, true },
        .{ "abcdefghij\x01k", 10, false },
        .{ "abcdefghijklmnopqrstuvw\n", 23, false },
        .{ "\xc3\xa9", 2, true },
        .{ "abcdefgh\"\xc3\xa9", 8, false },
    };
    for (cases) |case| {
        const found = special(case[0]);
        try std.testing.expectEqual(case[1], found.at);
        try std.testing.expectEqual(case[2], found.non_ascii);
    }
    for (0..40) |n| {
        var bytes: [40]u8 = @splat('a');
        bytes[n] = '"';
        try std.testing.expectEqual(n, special(bytes[0 .. n + 1]).at);
        try std.testing.expectEqual(n + 1, special(bytes[0..n]).at + 1);
    }
}

test decimal {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0", decimal(&buffer, @as(u8, 0)));
    try std.testing.expectEqualStrings("18446744073709551615", decimal(&buffer, @as(u64, std.math.maxInt(u64))));
    try std.testing.expectEqualStrings("-128", decimal(&buffer, @as(i8, -128)));
    try std.testing.expectEqualStrings("-9223372036854775808", decimal(&buffer, @as(i64, std.math.minInt(i64))));
    try std.testing.expectEqualStrings("105", decimal(&buffer, @as(u16, 105)));
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
