//! The bytes of application/x-www-form-urlencoded (WHATWG URL, section 5):
//! percent-encoding, `+` for a space, and the bracketed paths of the names.
const std = @import("std");

/// Whether a byte is written as itself: an ASCII letter or digit, or one of
/// `*-._`. Every other byte is percent-encoded, and a space is `+`.
pub fn plain(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '*' or byte == '-' or byte == '.' or byte == '_';
}

/// The bytes `encode` writes for `bytes`.
pub fn encodedLength(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |byte| n += if (plain(byte) or byte == ' ') 1 else 3;
    return n;
}

/// `bytes` encoded into `out`, which holds `encodedLength(bytes)`.
pub fn encode(bytes: []const u8, out: []u8) void {
    const hex = "0123456789ABCDEF";
    var at: usize = 0;
    for (bytes) |byte| {
        if (plain(byte)) {
            out[at] = byte;
            at += 1;
        } else if (byte == ' ') {
            out[at] = '+';
            at += 1;
        } else {
            out[at..][0..3].* = .{ '%', hex[byte >> 4], hex[byte & 0xf] };
            at += 3;
        }
    }
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// What decoding `raw` gives: whether it changes anything, and how many
/// bytes it gives. A `%` that two hexadecimal digits do not follow is not
/// form encoding: `error.SyntaxError`, where the WHATWG parser keeps it as it
/// is, since a form an encoder wrote never holds one.
pub fn decodedLength(raw: []const u8) error{SyntaxError}!struct { len: usize, changes: bool } {
    var n: usize = 0;
    var changes = false;
    var at: usize = 0;
    while (at < raw.len) : (n += 1) switch (raw[at]) {
        '%' => {
            if (at + 2 >= raw.len) return error.SyntaxError;
            if (hexValue(raw[at + 1]) == null or hexValue(raw[at + 2]) == null) return error.SyntaxError;
            changes = true;
            at += 3;
        },
        '+' => {
            changes = true;
            at += 1;
        },
        else => at += 1,
    };
    return .{ .len = n, .changes = changes };
}

/// `raw` decoded into `out`, which holds `decodedLength(raw).len`; `raw` is
/// one `decodedLength` accepts.
pub fn decode(raw: []const u8, out: []u8) void {
    var n: usize = 0;
    var at: usize = 0;
    while (at < raw.len) : (n += 1) switch (raw[at]) {
        '%' => {
            out[n] = (hexValue(raw[at + 1]).? << 4) | hexValue(raw[at + 2]).?;
            at += 3;
        },
        '+' => {
            out[n] = ' ';
            at += 1;
        },
        else => |byte| {
            out[n] = byte;
            at += 1;
        },
    };
}

/// A name's path: its first segment, then one for each `[...]` after it, an
/// empty one (`[]`) adding to a sequence. `a[b][]` is `a`, `b` and the empty
/// segment. The first segment is not empty and holds no bracket; a bracketed
/// one holds none either; nothing follows the last `]`.
pub fn validName(name: []const u8) bool {
    const first = std.mem.findScalar(u8, name, '[') orelse name.len;
    if (first == 0 or std.mem.findScalar(u8, name[0..first], ']') != null) return false;
    var at = first;
    while (at < name.len) {
        if (name[at] != '[') return false;
        const close = std.mem.findScalarPos(u8, name, at + 1, ']') orelse return false;
        if (std.mem.findScalar(u8, name[at + 1 .. close], '[') != null) return false;
        at = close + 1;
    }
    return true;
}

/// How many segments a valid name has.
pub fn segments(name: []const u8) usize {
    return 1 + std.mem.countScalar(u8, name, '[');
}

/// The bytes of a valid name that hold its first `n` segments (`n` at least
/// one), the brackets included: `a[b]` of `a[b][c]` for two.
pub fn prefixLength(name: []const u8, n: usize) usize {
    var at = std.mem.findScalar(u8, name, '[') orelse name.len;
    var left = n - 1;
    while (left > 0) : (left -= 1) at = std.mem.findScalarPos(u8, name, at, ']').? + 1;
    return at;
}

/// Segment `n` (from zero) of a valid name.
pub fn segment(name: []const u8, n: usize) []const u8 {
    if (n == 0) return name[0 .. std.mem.findScalar(u8, name, '[') orelse name.len];
    const start = prefixLength(name, n);
    const close = std.mem.findScalarPos(u8, name, start, ']').?;
    return name[start + 1 .. close];
}

test "percent-encoding both ways" {
    var out: [64]u8 = undefined;
    const raw = "a+b%2Bc%5B%5d%E2%82%AC";
    const d = try decodedLength(raw);
    try std.testing.expect(d.changes);
    decode(raw, out[0..d.len]);
    try std.testing.expectEqualStrings("a b+c[]\u{20ac}", out[0..d.len]);
    const plain_text = "x y+z~";
    const n = encodedLength(plain_text);
    encode(plain_text, out[0..n]);
    try std.testing.expectEqualStrings("x+y%2Bz%7E", out[0..n]);
    try std.testing.expectError(error.SyntaxError, decodedLength("100%"));
    try std.testing.expectError(error.SyntaxError, decodedLength("%4"));
    try std.testing.expectError(error.SyntaxError, decodedLength("%zz"));
}

test "bracketed names" {
    try std.testing.expect(validName("a"));
    try std.testing.expect(validName("a[b][]"));
    try std.testing.expect(!validName("[a]"));
    try std.testing.expect(!validName("a[b"));
    try std.testing.expect(!validName("a]b"));
    try std.testing.expect(!validName("a[b]c"));
    try std.testing.expect(!validName("a[[b]]"));
    try std.testing.expectEqual(3, segments("a[b][]"));
    try std.testing.expectEqualStrings("a[b]", "a[b][]"[0..prefixLength("a[b][]", 2)]);
    try std.testing.expectEqualStrings("b", segment("a[b][]", 1));
    try std.testing.expectEqualStrings("", segment("a[b][]", 2));
    try std.testing.expectEqualStrings("a", segment("a[b][]", 0));
}
