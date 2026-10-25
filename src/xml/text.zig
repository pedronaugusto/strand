//! XML's characters and names (XML 1.0, fifth edition), the white space
//! between its tokens, the escapes its writer needs, and the lexical forms of
//! XML Schema's numbers and booleans, which is what an element's text is read
//! as when a type asks for one.
const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json/number.zig");

/// `Char`: tab, line feed, carriage return, and the scalars from U+0020 but
/// the surrogates (which UTF-8 cannot hold), U+FFFE and U+FFFF.
pub fn isChar(c: u21) bool {
    return switch (c) {
        0x9, 0xA, 0xD => true,
        0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
}
/// `S`: the four white space characters.
pub inline fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r';
}
/// `NameStartChar`.
pub fn isNameStart(c: u21) bool {
    return switch (c) {
        ':', 'A'...'Z', '_', 'a'...'z' => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF, 0x370...0x37D, 0x37F...0x1FFF, 0x200C...0x200D => true,
        0x2070...0x218F, 0x2C00...0x2FEF, 0x3001...0xD7FF, 0xF900...0xFDCF, 0xFDF0...0xFFFD, 0x10000...0xEFFFF => true,
        else => false,
    };
}
/// `NameChar`.
pub fn isName(c: u21) bool {
    return isNameStart(c) or switch (c) {
        '-', '.', '0'...'9', 0xB7, 0x300...0x36F, 0x203F...0x2040 => true,
        else => false,
    };
}

/// The scalar at `at` and its length, or null where the bytes are no UTF-8.
pub inline fn decode(bytes: []const u8, at: usize) ?struct { c: u21, len: u3 } {
    const b = bytes[at];
    if (b < 0x80) return .{ .c = b, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (at + len > bytes.len) return null;
    const c = switch (len) {
        2 => std.unicode.utf8Decode2(bytes[at..][0..2].*),
        3 => std.unicode.utf8Decode3(bytes[at..][0..3].*),
        4 => std.unicode.utf8Decode4(bytes[at..][0..4].*),
        else => return null,
    } catch return null;
    return .{ .c = c, .len = len };
}

/// What each ASCII byte may be in a name: bit 0 its start, bit 1 after it.
const ascii_names: [128]u2 = blk: {
    var table: [128]u2 = @splat(0);
    for (0..128) |b| {
        const start: u2 = @intFromBool(isNameStart(@intCast(b)));
        const rest: u2 = @intFromBool(isName(@intCast(b)));
        table[b] = start | rest << 1;
    }
    break :blk table;
};

/// The length of the `Name` at the start of `bytes` (0 where none starts),
/// or null where the bytes there are no UTF-8.
pub fn nameLength(bytes: []const u8) ?usize {
    var at: usize = 0;
    while (at < bytes.len) {
        const b = bytes[at];
        // ASCII names are the common case: a table, no decode.
        if (b < 0x80) {
            const bit: u2 = if (at == 0) 1 else 2;
            if (ascii_names[b] & bit == 0) return at;
            at += 1;
            continue;
        }
        const d = decode(bytes, at) orelse return null;
        const ok = if (at == 0) isNameStart(d.c) else isName(d.c);
        if (!ok) return at;
        at += d.len;
    }
    return at;
}
/// Whether all of `bytes` is one `Name`.
pub fn isWholeName(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const n = nameLength(bytes) orelse return false;
    return n == bytes.len;
}
/// Whether all of `bytes` is one `Nmtoken`: name characters, any first.
pub fn isNmtoken(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var at: usize = 0;
    while (at < bytes.len) {
        const d = decode(bytes, at) orelse return false;
        if (!isName(d.c)) return false;
        at += d.len;
    }
    return true;
}
/// Whether `name` is a namespace-well-formed QName: no colon, or one colon
/// with a name on each side.
pub fn isQName(name: []const u8) bool {
    const colon = std.mem.findScalar(u8, name, ':') orelse return true;
    if (colon == 0 or colon == name.len - 1) return false;
    if (std.mem.findScalarPos(u8, name, colon + 1, ':') != null) return false;
    return isNameStart((decode(name, colon + 1) orelse return false).c);
}
/// A QName's prefix, empty where it has none.
pub fn prefix(name: []const u8) []const u8 {
    const colon = std.mem.findScalar(u8, name, ':') orelse return "";
    return name[0..colon];
}

/// Whether `bytes` is all white space.
pub fn allSpace(bytes: []const u8) bool {
    for (bytes) |b| if (!isSpace(b)) return false;
    return true;
}
/// `bytes` with the white space at either end taken off, as XML Schema's
/// `collapse` facet reads a number or a boolean.
pub fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\n\r");
}

/// Where in `bytes` the first character is that XML cannot hold, or null.
/// UTF-8 is the caller's to have checked.
pub fn forbidden(bytes: []const u8) ?usize {
    var at: usize = 0;
    while (at < bytes.len) {
        const b = bytes[at];
        if (b < 0x80) {
            if (b < 0x20 and b != '\t' and b != '\n' and b != '\r') return at;
            at += 1;
            continue;
        }
        const d = decode(bytes, at) orelse return at;
        if (!isChar(d.c)) return at;
        at += d.len;
    }
    return null;
}

/// XML Schema's `boolean`: `true`, `false`, `1` or `0`.
pub fn boolean(bytes: []const u8) ?bool {
    const t = trim(bytes);
    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) return true;
    if (std.mem.eql(u8, t, "false") or std.mem.eql(u8, t, "0")) return false;
    return null;
}

/// A number's lexical form, XML Schema's `integer` or `double`, as the JSON
/// number of the same value: a `+` taken off, leading zeros dropped, a bare
/// `.5` given its `0` and a `5.` its fraction's absence. Written into `out`;
/// null where it is no number of XML Schema's (`INF` and `NaN` are the
/// caller's).
pub fn jsonNumber(lexical: []const u8, out: []u8) ?[]const u8 {
    var s = lexical;
    var n: usize = 0;
    if (s.len != 0 and (s[0] == '+' or s[0] == '-')) {
        if (s[0] == '-') {
            out[n] = '-';
            n += 1;
        }
        s = s[1..];
    }
    const exponent_at = std.mem.findAny(u8, s, "eE") orelse s.len;
    const mantissa = s[0..exponent_at];
    const dot = std.mem.findScalar(u8, mantissa, '.');
    var whole = mantissa[0 .. dot orelse mantissa.len];
    const fraction = if (dot) |d| mantissa[d + 1 ..] else "";
    if (whole.len == 0 and fraction.len == 0) return null;
    for (whole) |b| if (!std.ascii.isDigit(b)) return null;
    for (fraction) |b| if (!std.ascii.isDigit(b)) return null;
    while (whole.len > 1 and whole[0] == '0') whole = whole[1..];
    if (whole.len == 0) whole = "0";
    if (n + whole.len + 1 + fraction.len + s.len - exponent_at > out.len) return null;
    @memcpy(out[n..][0..whole.len], whole);
    n += whole.len;
    if (fraction.len != 0) {
        out[n] = '.';
        n += 1;
        @memcpy(out[n..][0..fraction.len], fraction);
        n += fraction.len;
    }
    if (exponent_at != s.len) {
        var e = s[exponent_at + 1 ..];
        out[n] = 'e';
        n += 1;
        if (e.len != 0 and (e[0] == '+' or e[0] == '-')) {
            if (e[0] == '-') {
                out[n] = '-';
                n += 1;
            }
            e = e[1..];
        }
        if (e.len == 0) return null;
        for (e) |b| if (!std.ascii.isDigit(b)) return null;
        @memcpy(out[n..][0..e.len], e);
        n += e.len;
    }
    return out[0..n];
}

/// An element's text as a `T`: XML Schema's `integer`, white space at its
/// ends allowed, converted by JSON's exact kernels.
pub fn parseInteger(comptime T: type, spelling: []const u8, c: *core.Context) core.DecodeError!T {
    const t = trim(spelling);
    if (t.len != 0 and json.valid(t)) return json.integer(T, t, c);
    const out = try c.alloc(u8, t.len + 2);
    const normal = jsonNumber(t, out) orelse return error.UnexpectedType;
    return json.integer(T, normal, c);
}
/// An element's text as a `T`: XML Schema's `double` (`INF`, `-INF` and
/// `NaN` among it), rounded once from its decimal digits.
pub fn parseFloat(comptime T: type, spelling: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    const t = trim(spelling);
    try c.chargeWork(t.len);
    if (std.mem.eql(u8, t, "INF") or std.mem.eql(u8, t, "+INF")) return std.math.inf(T);
    if (std.mem.eql(u8, t, "-INF")) return -std.math.inf(T);
    if (std.mem.eql(u8, t, "NaN")) return std.math.nan(T);
    if (t.len != 0 and json.valid(t)) return json.floating(T, t, exact, c);
    const out = try c.alloc(u8, t.len + 2);
    const normal = jsonNumber(t, out) orelse return error.UnexpectedType;
    return json.floating(T, normal, exact, c);
}
/// Whether an element's text is a number of XML Schema's.
pub fn isNumber(spelling: []const u8) bool {
    const t = trim(spelling);
    if (std.mem.eql(u8, t, "INF") or std.mem.eql(u8, t, "+INF") or std.mem.eql(u8, t, "-INF") or std.mem.eql(u8, t, "NaN")) return true;
    var buffer: [64]u8 = undefined;
    if (t.len + 2 > buffer.len) return json.valid(t);
    return jsonNumber(t, &buffer) != null;
}

/// What `text` is written as in character data or, with `attribute`, in a
/// quoted attribute value: each character that needs one as its escape.
pub fn escape(writer: *std.Io.Writer, text: []const u8, attribute: bool) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |b, i| {
        const replacement: []const u8 = switch (b) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '\r' => "&#13;",
            '"' => if (attribute) "&quot;" else continue,
            '\t' => if (attribute) "&#9;" else continue,
            '\n' => if (attribute) "&#10;" else continue,
            else => continue,
        };
        try writer.writeAll(text[start..i]);
        try writer.writeAll(replacement);
        start = i + 1;
    }
    try writer.writeAll(text[start..]);
}
/// How many bytes `escape` writes for `text`.
pub fn escapedLength(text: []const u8, attribute: bool) usize {
    var n = text.len;
    for (text) |b| n += switch (b) {
        '&' => 4,
        '<', '>' => 3,
        '\r' => 4,
        '"' => if (attribute) 5 else 0,
        '\t' => if (attribute) 3 else 0,
        '\n' => if (attribute) 4 else 0,
        else => 0,
    };
    return n;
}

test "names, characters and numbers" {
    try std.testing.expect(isWholeName("soap:Envelope"));
    try std.testing.expect(isWholeName("élan"));
    try std.testing.expect(!isWholeName("1a"));
    try std.testing.expect(!isWholeName("a b"));
    try std.testing.expect(isQName("a:b") and !isQName("a:b:c") and !isQName(":a") and !isQName("a:1"));
    try std.testing.expectEqual(@as(?usize, 1), forbidden("a\x01"));
    try std.testing.expectEqual(@as(?usize, null), forbidden("a\tb\u{10000}"));
    try std.testing.expectEqual(@as(?usize, 0), forbidden("\u{FFFE}"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("5", jsonNumber("+005", &buffer).?);
    try std.testing.expectEqualStrings("0.5", jsonNumber(".5", &buffer).?);
    try std.testing.expectEqualStrings("-5", jsonNumber("-5.", &buffer).?);
    try std.testing.expectEqualStrings("1.0e-3", jsonNumber("1.0E-3", &buffer).?);
    try std.testing.expectEqual(null, jsonNumber(".", &buffer));
    try std.testing.expectEqual(null, jsonNumber("1e", &buffer));
    var c: core.Context = .init(std.testing.allocator, .{}, .borrowed);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    c.storage = arena.allocator();
    try std.testing.expectEqual(@as(i32, 7), try parseInteger(i32, " +007 ", &c));
    try std.testing.expectEqual(@as(f64, 0.25), try parseFloat(f64, ".25", false, &c));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-INF", false, &c)));
    try std.testing.expectError(error.UnexpectedType, parseInteger(i32, "x", &c));
    try std.testing.expectEqual(@as(?bool, true), boolean(" 1 "));
}
