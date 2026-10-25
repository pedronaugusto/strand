//! JSON5's tokens at the byte level, where they are not JSON's: its white
//! space and comments, identifier names as keys, strings in either quote
//! with ECMAScript's escapes, and numbers in hexadecimal, with a sign of
//! either kind, a bare point, `Infinity` and `NaN`. The decoder's JSON5
//! dialect reads with these; JSON's own tokens never reach them.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const core = @import("../core.zig");
const strings = @import("text.zig");
const numbers = @import("number.zig");

pub const Unicode = strings.Unicode;

/// Past the white space and comments from `from`. JSON5's white space is
/// JSON's, the vertical tab, the form feed, U+00A0, U+FEFF, U+2028, U+2029
/// and the other space separators (Zs); a `//` comment ends at any line
/// terminator, U+2028 and U+2029 among them. A `/* */` comment that does
/// not end stops it at its `/`, where the next token is then a syntax error.
pub fn space(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len) switch (bytes[at]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => at += 1,
        '/' => {
            if (at + 1 == bytes.len) return at;
            switch (bytes[at + 1]) {
                '/' => at = lineEnd(bytes, at + 2),
                '*' => at = (std.mem.findPos(u8, bytes, at + 2, "*/") orelse return at) + 2,
                else => return at,
            }
        },
        0xc2, 0xe1, 0xe2, 0xe3, 0xef => {
            const n = wideSpace(bytes[at..]);
            if (n == 0) return at;
            at += n;
        },
        else => return at,
    };
    return at;
}

/// Where the line terminator from `from` on is, which is then passed as
/// white space, or the end.
fn lineEnd(bytes: []const u8, from: usize) usize {
    var at = from;
    while (std.mem.findAnyPos(u8, bytes, at, "\n\r\xe2")) |i| {
        if (bytes[i] != 0xe2 or separator(bytes[i..])) return i;
        at = i + 1;
    }
    return bytes.len;
}

/// Whether `bytes` begin with U+2028 or U+2029, the line and paragraph
/// separators ECMAScript ends a line at.
fn separator(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xe2 and bytes[1] == 0x80 and (bytes[2] == 0xa8 or bytes[2] == 0xa9);
}

/// The length of the white space beyond ASCII that `bytes` begin with, or 0.
/// The space separators have been these since Unicode 6.3 took U+180E out.
fn wideSpace(bytes: []const u8) usize {
    if (bytes.len >= 2 and bytes[0] == 0xc2 and bytes[1] == 0xa0) return 2;
    if (bytes.len < 3 or bytes[0] & 0xf0 != 0xe0 or bytes[1] & 0xc0 != 0x80 or bytes[2] & 0xc0 != 0x80) return 0;
    const scalar = (@as(u21, bytes[0] & 0x0f) << 12) | (@as(u21, bytes[1] & 0x3f) << 6) | (bytes[2] & 0x3f);
    return switch (scalar) {
        0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => 3,
        else => 0,
    };
}

/// An identifier name read as a key: where it ends, and whether a `\u`
/// escape is in it, so that its text is to be unescaped.
pub const Name = struct { end: usize, escaped: bool };

/// The identifier name that begins at `bytes[from]`, ECMAScript 5.1's
/// IdentifierName: a letter (Lu, Ll, Lt, Lm, Lo, Nl), `$`, `_`, or a `\u`
/// escape of one, then any of those, combining marks (Mn, Mc), digits (Nd),
/// connector punctuation (Pc), U+200C and U+200D, by the categories of the
/// Unicode xenoglyph carries. A key that begins with none of them is a
/// syntax error, as a byte that is not UTF-8 in one is.
pub fn identifier(bytes: []const u8, from: usize) error{SyntaxError}!Name {
    var at = from;
    var escaped = false;
    while (at < bytes.len) {
        const first = at == from;
        const b = bytes[at];
        if (b == '\\') {
            if (at + 1 == bytes.len or bytes[at + 1] != 'u') return error.SyntaxError;
            if (!identifierChar(try strings.hexQuad(bytes[at + 2 ..]), first)) return error.SyntaxError;
            escaped = true;
            at += 6;
        } else if (b < 0x80) {
            if (!identifierChar(b, first)) break;
            at += 1;
        } else {
            const n = strings.sequence(bytes[at..]);
            if (n == 0) return error.SyntaxError;
            if (!identifierChar(xenoglyph.utf8.decode(bytes[at..]).code_point, first)) break;
            at += n;
        }
    }
    if (at == from) return error.SyntaxError;
    return .{ .end = at, .escaped = escaped };
}

/// Whether `scalar` may be in an identifier name: first in it, or after.
fn identifierChar(scalar: u21, first: bool) bool {
    if (scalar < 0x80) return switch (scalar) {
        'a'...'z', 'A'...'Z', '$', '_' => true,
        '0'...'9' => !first,
        else => false,
    };
    if (scalar == 0x200c or scalar == 0x200d) return !first;
    return switch (xenoglyph.generalCategory(scalar)) {
        .uppercase_letter, .lowercase_letter, .titlecase_letter, .modifier_letter, .other_letter, .letter_number => true,
        .nonspacing_mark, .spacing_mark, .decimal_number, .connector_punctuation => !first,
        else => false,
    };
}

/// What an escape after a backslash stands for, and how many bytes of input
/// it took, the backslash not counted: JSON's escapes, `\v`, `\0` before no
/// digit, `\xHH`, and any other character as itself but a digit; a line
/// terminator after the backslash continues the string on the next line and
/// stands for nothing (`scalar` null). A `\u` escape is read as JSON reads
/// one, a surrogate half on its own refused or U+FFFD.
pub const Escape = struct { len: usize, scalar: ?u21 };

pub fn escape(bytes: []const u8, unicode: Unicode) error{SyntaxError}!Escape {
    if (bytes.len == 0) return error.SyntaxError;
    const scalar: u21 = switch (bytes[0]) {
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0b,
        '0' => if (bytes.len > 1 and std.ascii.isDigit(bytes[1])) return error.SyntaxError else 0,
        '1'...'9' => return error.SyntaxError,
        'x' => return .{ .len = 3, .scalar = try hexPair(bytes[1..]) },
        'u' => {
            const e = try strings.escape(bytes, unicode);
            return .{ .len = e.len, .scalar = e.scalar };
        },
        '\n' => return .{ .len = 1, .scalar = null },
        '\r' => return .{ .len = if (bytes.len > 1 and bytes[1] == '\n') 2 else 1, .scalar = null },
        0x80...0xff => {
            if (separator(bytes)) return .{ .len = 3, .scalar = null };
            const n = strings.sequence(bytes);
            if (n == 0) return if (unicode == .replace) .{ .len = 1, .scalar = 0xfffd } else error.SyntaxError;
            return .{ .len = n, .scalar = xenoglyph.utf8.decode(bytes).code_point };
        },
        else => |b| b,
    };
    return .{ .len = 1, .scalar = scalar };
}

fn hexPair(bytes: []const u8) error{SyntaxError}!u21 {
    if (bytes.len < 2) return error.SyntaxError;
    const high = std.fmt.charToDigit(bytes[0], 16) catch return error.SyntaxError;
    const low = std.fmt.charToDigit(bytes[1], 16) catch return error.SyntaxError;
    return @as(u21, high) << 4 | low;
}

/// Where the string in `quote` whose body begins at `bytes[0]` ends: the index
/// of its closing quote, and whether its body is to be rewritten, as JSON's
/// `strings.end` says. Any character but a line feed or a carriage return
/// may stand in it as itself, a control character and the other quote too.
pub fn end(bytes: []const u8, quote: u8, unicode: Unicode) error{SyntaxError}!strings.End {
    var at: usize = 0;
    var escaped = false;
    while (true) {
        // A run stops at a byte a UTF-8 sequence never holds, so each is
        // checked whole: in double quotes at JSON's stops, a quote, a
        // backslash and a control byte, found a vector at a time.
        var stop: usize = undefined;
        var non_ascii = true;
        if (quote == '"') {
            const found = strings.special(bytes[at..]);
            stop = at + found.at;
            non_ascii = found.non_ascii;
        } else stop = std.mem.findAnyPos(u8, bytes, at, "'\\\n\r") orelse bytes.len;
        if (non_ascii and !std.unicode.utf8ValidateSlice(bytes[at..stop])) {
            if (unicode == .refuse) return error.SyntaxError;
            escaped = true;
        }
        if (stop == bytes.len) return error.SyntaxError;
        switch (bytes[stop]) {
            '\\' => {
                escaped = true;
                at = stop + 1 + (try escape(bytes[stop + 1 ..], unicode)).len;
            },
            '\n', '\r' => return error.SyntaxError,
            else => |b| {
                if (b == quote) return .{ .at = stop, .escaped = escaped };
                at = stop + 1;
            },
        }
    }
}

/// Writes a body `end` or `identifier` has checked, escapes replaced by what
/// they stand for, into `out`, which is at least `unescapedLength` long:
/// under `.refuse` `body`'s length is enough, no escape being shorter than
/// what it stands for. Returns the length written.
pub fn unescape(body: []const u8, out: []u8, unicode: Unicode) usize {
    var from: usize = 0;
    var to: usize = 0;
    while (std.mem.findScalarPos(u8, body, from, '\\')) |slash| {
        to += strings.copyRun(body[from..slash], out[to..], unicode);
        // unreachable: `end` checked every escape in this body.
        const e = escape(body[slash + 1 ..], unicode) catch unreachable;
        if (e.scalar) |scalar| {
            var encoded: [4]u8 = undefined;
            // unreachable: a scalar `escape` decoded is at most U+10FFFF and no surrogate.
            const n = std.unicode.utf8Encode(scalar, &encoded) catch unreachable;
            @memcpy(out[to..][0..n], encoded[0..n]);
            to += n;
        }
        from = slash + 1 + e.len;
    }
    return to + strings.copyRun(body[from..], out[to..], unicode);
}

/// How long a body `end` or `identifier` has checked is once unescaped.
pub fn unescapedLength(body: []const u8, unicode: Unicode) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, body, from, '\\')) |slash| {
        // unreachable: `end` checked every escape in this body.
        const e = escape(body[slash + 1 ..], unicode) catch unreachable;
        n += strings.runLength(body[from..slash], unicode);
        // unreachable: an escape decodes to a Unicode scalar, never a surrogate half.
        if (e.scalar) |scalar| n += std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable;
        from = slash + 1 + e.len;
    }
    return n + strings.runLength(body[from..], unicode);
}

/// The text a checked body spells, a byte at a time, with nothing unescaped
/// anywhere but the escape being read.
const Unescaped = struct {
    rest: []const u8,
    unicode: Unicode,
    pending: [4]u8 = undefined,
    len: usize = 0,
    at: usize = 0,

    fn next(self: *Unescaped) ?u8 {
        while (self.at == self.len) {
            if (self.rest.len == 0) return null;
            self.at = 0;
            if (self.rest[0] == '\\') {
                // unreachable: `end` checked every escape in this body.
                const e = escape(self.rest[1..], self.unicode) catch unreachable;
                self.rest = self.rest[1 + e.len ..];
                // unreachable: an escape decodes to a Unicode scalar, never a surrogate half.
                self.len = if (e.scalar) |scalar| std.unicode.utf8Encode(scalar, &self.pending) catch unreachable else 0;
                continue;
            }
            // A sequence goes by whole under `.replace`, as `copyRun` copies it.
            const n = if (self.unicode == .replace and self.rest[0] >= 0x80) strings.sequence(self.rest) else 1;
            const bytes = if (n == 0) "\u{fffd}" else self.rest[0..n];
            @memcpy(self.pending[0..bytes.len], bytes);
            self.len = bytes.len;
            self.rest = self.rest[@max(n, 1)..];
        }
        self.at += 1;
        return self.pending[self.at - 1];
    }
};

/// Whether two checked bodies spell the same text, however each is escaped.
pub fn sameText(a: []const u8, b: []const u8, unicode: Unicode) bool {
    var left: Unescaped = .{ .rest = a, .unicode = unicode };
    var right: Unescaped = .{ .rest = b, .unicode = unicode };
    while (true) {
        const x = left.next();
        if (x != right.next()) return false;
        if (x == null) return true;
    }
}

/// Where the number that starts at `start` ends; its grammar is checked: a
/// sign of either kind or none, then `Infinity`, `NaN`, `0x` and hexadecimal
/// digits, or JSON's decimal with digits on at least one side of its point.
pub fn numberEnd(bytes: []const u8, start: usize) error{SyntaxError}!usize {
    var at = start;
    if (at < bytes.len and (bytes[at] == '-' or bytes[at] == '+')) at += 1;
    if (at == bytes.len) return error.SyntaxError;
    var integral = true;
    switch (bytes[at]) {
        'I' => return word(bytes, at, "Infinity"),
        'N' => return word(bytes, at, "NaN"),
        '0' => {
            at += 1;
            if (at < bytes.len and (bytes[at] == 'x' or bytes[at] == 'X')) {
                const digits = at + 1;
                at = digits;
                while (at < bytes.len and std.ascii.isHex(bytes[at])) at += 1;
                if (at == digits) return error.SyntaxError;
                return at;
            }
        },
        '1'...'9' => at = digitsEnd(bytes, at + 1),
        '.' => integral = false,
        else => return error.SyntaxError,
    }
    if (at < bytes.len and bytes[at] == '.') {
        const digits = at + 1;
        at = digitsEnd(bytes, digits);
        if (!integral and at == digits) return error.SyntaxError;
    }
    if (at < bytes.len and (bytes[at] == 'e' or bytes[at] == 'E')) {
        at += 1;
        if (at < bytes.len and (bytes[at] == '+' or bytes[at] == '-')) at += 1;
        const digits = at;
        at = digitsEnd(bytes, digits);
        if (at == digits) return error.SyntaxError;
    }
    return at;
}

fn word(bytes: []const u8, at: usize, comptime spelling: []const u8) error{SyntaxError}!usize {
    if (!std.mem.startsWith(u8, bytes[at..], spelling)) return error.SyntaxError;
    return at + spelling.len;
}

fn digitsEnd(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
    return at;
}

/// Whether `bytes` are one JSON5 number and nothing else.
pub fn validNumber(bytes: []const u8) bool {
    const stop = numberEnd(bytes, 0) catch return false;
    return stop == bytes.len;
}

/// A number `numberEnd` has checked, as a `T`, as JSON's `number.integer`
/// reads one: with a sign of either kind, and in hexadecimal digits, which
/// are an integer's spelling under `Integers.digits` too. `Infinity` is out
/// of every integer's range, and `NaN` is no integer.
pub fn integer(comptime T: type, text: []const u8, c: *core.Context) core.DecodeError!T {
    const negative = text[0] == '-';
    const unsigned = text[@intFromBool(negative or text[0] == '+')..];
    switch (unsigned[0]) {
        'I' => {
            try c.chargeWork(text.len);
            return error.NumberOutOfRange;
        },
        'N' => {
            try c.chargeWork(text.len);
            return error.UnexpectedType;
        },
        else => {},
    }
    if (unsigned.len > 1 and (unsigned[1] == 'x' or unsigned[1] == 'X')) return hexadecimal(T, negative, unsigned[2..], c);
    return numbers.integer(T, if (text[0] == '+') text[1..] else text, c);
}

/// Hexadecimal digits, after a minus where `negative`, as a `T`.
fn hexadecimal(comptime T: type, negative: bool, digits: []const u8, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(digits.len);
    const bits = @typeInfo(T).int.bits;
    // Wide enough for the magnitude of any `T`, the signed minimum's included.
    const Magnitude = @Int(.unsigned, @max(bits, 1));
    var magnitude: Magnitude = 0;
    for (digits) |digit| {
        // unreachable: `numberEnd` checked these are hexadecimal digits.
        const nibble = std.fmt.charToDigit(digit, 16) catch unreachable;
        magnitude = (aegis.int.Checked(Magnitude).init(magnitude).mul(16) catch return error.NumberOutOfRange).raw();
        magnitude = (aegis.int.Checked(Magnitude).init(magnitude).add(nibble) catch return error.NumberOutOfRange).raw();
    }
    if (@typeInfo(T).int.signedness == .unsigned) {
        if (negative and c.acceptance.integers == .digits) return error.UnexpectedType;
        if (negative and magnitude != 0) return error.NumberOutOfRange;
        return std.math.cast(T, magnitude) orelse error.NumberOutOfRange;
    }
    if (!negative) return std.math.cast(T, magnitude) orelse error.NumberOutOfRange;
    const minimum: Magnitude = @as(Magnitude, 1) << (bits - 1);
    if (magnitude > minimum) return error.NumberOutOfRange;
    if (magnitude == minimum) return std.math.minInt(T);
    return -@as(T, @intCast(magnitude)); // safe: below the magnitude of the signed minimum.
}

/// A number `numberEnd` has checked, as a float: JSON's decimals, with a sign
/// of either kind and a bare point; hexadecimal digits, to the nearest `T`;
/// and `Infinity`, `-Infinity` and `NaN`. A number beyond `T`'s range is out
/// of it, as in JSON, and not infinite. Where `exact` asks, the value must
/// be exactly the number written.
pub fn floating(comptime T: type, text: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    const negative = text[0] == '-';
    const unsigned = text[@intFromBool(negative or text[0] == '+')..];
    switch (unsigned[0]) {
        'I' => {
            try c.chargeWork(text.len);
            return if (negative) -std.math.inf(T) else std.math.inf(T);
        },
        'N' => {
            try c.chargeWork(text.len);
            return std.math.nan(T);
        },
        else => {},
    }
    if (unsigned.len > 1 and (unsigned[1] == 'x' or unsigned[1] == 'X')) {
        try c.chargeWork(text.len);
        const value = std.fmt.parseFloat(T, unsigned) catch return error.NumberOutOfRange;
        if (!std.math.isFinite(value)) return error.NumberOutOfRange;
        if (exact and !hexadecimalExact(T, unsigned[2..])) return error.InexactNumber;
        return if (negative) -value else value;
    }
    return numbers.floating(T, if (text[0] == '+') text[1..] else text, exact, c);
}

/// Whether the integer hexadecimal `digits` spell, within `T`'s range, has
/// no more significant bits than a `T` keeps.
fn hexadecimalExact(comptime T: type, digits: []const u8) bool {
    const first = std.mem.findNone(u8, digits, "0") orelse return true;
    const last = std.mem.findLastNone(u8, digits, "0").?;
    // unreachable: `numberEnd` checked these are hexadecimal digits.
    const lead: u8 = std.fmt.charToDigit(digits[first], 16) catch unreachable;
    // unreachable: as the one before.
    const tail: u8 = std.fmt.charToDigit(digits[last], 16) catch unreachable;
    const width = (last - first) * 4 + (8 - @clz(lead)) - @ctz(tail);
    return width <= std.math.floatFractionalBits(T) + 1;
}

test space {
    try std.testing.expectEqual(@as(usize, 8), space(" \t\x0b\x0c\r\n\xc2\xa0", 0));
    try std.testing.expectEqual(@as(usize, 11), space("// c\r\xe2\x80\xa8\xef\xbb\xbf1", 0));
    try std.testing.expectEqual(@as(usize, 7), space("// c\xe2\x80\xa91", 0));
    try std.testing.expectEqual(@as(usize, 0), space("/* open", 0));
    try std.testing.expectEqual(@as(usize, 1), space(" /x", 0));
    // U+180E, a space separator before Unicode 6.3, is not one now.
    try std.testing.expectEqual(@as(usize, 0), space("\xe1\xa0\x8e", 0));
}

test "the white space beyond ASCII is the space separators and four more" {
    var scalar: u21 = 0x80;
    while (scalar < 0x10000) : (scalar += 1) {
        if (scalar >= 0xd800 and scalar <= 0xdfff) continue;
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(scalar, &encoded) catch unreachable; // unreachable: no surrogate, within range.
        const expected = xenoglyph.generalCategory(scalar) == .space_separator or switch (scalar) {
            0xfeff, 0x2028, 0x2029 => true,
            else => false,
        };
        try std.testing.expectEqual(expected, wideSpace(encoded[0..n]) == n);
    }
}

test identifier {
    try std.testing.expectEqual(Name{ .end = 6, .escaped = false }, try identifier("$a_1é:", 0));
    try std.testing.expectEqual(Name{ .end = 7, .escaped = true }, try identifier("\\u0061b:", 0));
    try std.testing.expectError(error.SyntaxError, identifier("1a", 0));
    try std.testing.expectError(error.SyntaxError, identifier("\\u0031", 0));
    try std.testing.expectError(error.SyntaxError, identifier("\\ud835\\udc00", 0));
    try std.testing.expectError(error.SyntaxError, identifier("a\xff", 0));
    try std.testing.expectEqual(Name{ .end = 1, .escaped = false }, try identifier("a-b", 0));
    // A combining mark and U+200D may follow a letter, not begin a name.
    try std.testing.expectEqual(Name{ .end = 6, .escaped = false }, try identifier("a\xcc\x81\xe2\x80\x8d", 0));
    try std.testing.expectError(error.SyntaxError, identifier("\xcc\x81", 0));
}

test "a string's escapes" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "a\\'\\\"\\\\\\/", "a'\"\\/" },
        .{ "\\v\\0\\x41\\xe9\\q", "\x0b\x00A\u{e9}q" },
        .{ "line\\\none\\\r\ntwo\\\rthree\\\xe2\x80\xa8four", "lineonetwothreefour" },
        .{ "\\ud83d\\ude00\\\xc3\xa9", "\u{1f600}\u{e9}" },
        .{ "tab\there\"", "tab\there\"" },
    };
    inline for (cases) |case| {
        const e = try end(case[0] ++ "'", '\'', .refuse);
        try std.testing.expectEqual(case[0].len, e.at);
        var out: [64]u8 = undefined;
        try std.testing.expectEqual(case[1].len, unescapedLength(case[0], .refuse));
        try std.testing.expectEqualStrings(case[1], out[0..unescape(case[0], &out, .refuse)]);
        try std.testing.expect(sameText(case[0], case[1], .refuse) == (std.mem.findScalar(u8, case[1], '\\') == null));
    }
    for ([_][]const u8{ "\\01'", "\\1'", "\\x4'", "a\nb'", "a\rb'", "\\ud800'", "\xff'", "open" }) |body| {
        try std.testing.expectError(error.SyntaxError, end(body, '\'', .refuse));
    }
    try std.testing.expect(sameText("\\u0061\\\nb", "a\\x62", .refuse));
}

test numberEnd {
    for ([_][]const u8{ "0", "-0", "+1", ".5", "5.", "-.5e-3", "5.e3", "0x1F", "-0XaB", "Infinity", "-Infinity", "+NaN", "1e+9" }) |text| {
        try std.testing.expect(validNumber(text));
    }
    for ([_][]const u8{ "", "+", ".", "-.", "0x", "1e", ".e1", "Inf", "nan", "+-1", "01", "0x1.5", "1.5.5" }) |text| {
        try std.testing.expect(!validNumber(text));
    }
}

test "numbers as integers and floats" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c = core.Context.init(arena.allocator(), .{}, .borrowed);
    try std.testing.expectEqual(@as(u8, 255), try integer(u8, "0xFF", &c));
    try std.testing.expectEqual(@as(i8, -128), try integer(i8, "-0x80", &c));
    try std.testing.expectEqual(@as(u8, 0), try integer(u8, "-0x0", &c));
    try std.testing.expectEqual(@as(i32, 5), try integer(i32, "+5", &c));
    try std.testing.expectEqual(@as(i32, 50), try integer(i32, "5.e1", &c));
    try std.testing.expectError(error.NumberOutOfRange, integer(u8, "0x100", &c));
    try std.testing.expectError(error.NumberOutOfRange, integer(i8, "-0x81", &c));
    try std.testing.expectError(error.NumberOutOfRange, integer(i64, "Infinity", &c));
    try std.testing.expectError(error.UnexpectedType, integer(i64, "NaN", &c));
    try std.testing.expectEqual(@as(f64, 0.5), try floating(f64, "+.5", true, &c));
    try std.testing.expectEqual(@as(f64, 31), try floating(f64, "0x1f", true, &c));
    try std.testing.expectEqual(-std.math.inf(f64), try floating(f64, "-Infinity", true, &c));
    try std.testing.expect(std.math.isNan(try floating(f64, "NaN", true, &c)));
    try std.testing.expectEqual(@as(f64, 0x20000000000000), try floating(f64, "0x20000000000001", false, &c));
    try std.testing.expectError(error.InexactNumber, floating(f64, "0x20000000000001", true, &c));
    try std.testing.expectEqual(@as(f64, 0x20000000000000), try floating(f64, "0x020000000000000", true, &c));
    try std.testing.expectError(error.NumberOutOfRange, floating(f32, "1e39", false, &c));
}
