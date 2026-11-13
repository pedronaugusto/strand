//! The text formats' grammars, each exactly its RFC's: `uuid` (RFC 9562
//! §4's 8-4-4-4-12 hexadecimal form), `uri-template` (RFC 6570 §2's
//! syntax, levels 1 to 4), `json-pointer` (RFC 6901 §3) and
//! `relative-json-pointer` (draft-handrews-relative-json-pointer-01).
//! Where the JSON-Schema-Test-Suite reads a grammar otherwise, the code says.
const std = @import("std");

pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => if (c != '-') return false,
        else => if (!std.ascii.isHex(c)) return false,
    };
    return true;
}

/// RFC 6901's JSON Pointer: empty, or `/` and a token, again; a `~` only
/// before `0` or `1`.
pub fn isJsonPointer(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] != '/') return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) if (s[i] == '~') {
        if (i + 1 >= s.len or (s[i + 1] != '0' and s[i + 1] != '1')) return false;
    };
    return true;
}

/// A non-negative integer with no leading zero, then `#` or a JSON
/// Pointer; the integer may be followed by an index manipulation (`+n`,
/// `-n`) in the later revisions the suite reads.
pub fn isRelativeJsonPointer(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or (i > 1 and s[0] == '0')) return false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        const start = i + 1;
        var j = start;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j == start or (j - start > 1 and s[start] == '0')) return false;
        i = j;
    }
    const rest = s[i..];
    return std.mem.eql(u8, rest, "#") or isJsonPointer(rest);
}

/// RFC 6570's URI-Template: literals (any but CTL, space, `"`, `%`
/// unescaped, `<`, `>`, `\`, `^`, `` ` ``, `{`, `|`, `}`) and expressions
/// `{` an operator, varspecs joined by `,` `}`; a varspec a varname
/// (`varchar`s and `.` between them) with a prefix (`:` 1 to 4 digits, not
/// beginning with 0, under 10000) or an explode (`*`).
pub fn isUriTemplate(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '{') {
            const end = std.mem.findScalarPos(u8, s, i + 1, '}') orelse return false;
            if (!expression(s[i + 1 .. end])) return false;
            i = end + 1;
        } else if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 3;
        } else {
            // RFC 6570's literals leave out `'` too; the JSON-Schema-Test-Suite
            // reads it as a literal, and so does strand.
            if (c <= 0x20 or c == 0x7F or std.mem.findScalar(u8, "\"<>\\^`|}", c) != null) return false;
            i += 1;
        }
    }
    return true;
}

fn expression(e: []const u8) bool {
    if (e.len == 0) return false;
    var body = e;
    if (std.mem.findScalar(u8, "+#./;?&=,!@|", e[0]) != null) {
        // `=,!@|` are reserved for future extensions.
        if (std.mem.findScalar(u8, "=,!@|", e[0]) != null) return false;
        body = e[1..];
    }
    var specs = std.mem.splitScalar(u8, body, ',');
    while (specs.next()) |spec| if (!varspec(spec)) return false;
    return true;
}

fn varspec(spec: []const u8) bool {
    var name = spec;
    if (std.mem.endsWith(u8, spec, "*")) {
        name = spec[0 .. spec.len - 1];
    } else if (std.mem.findScalar(u8, spec, ':')) |colon| {
        const digits = spec[colon + 1 ..];
        if (digits.len == 0 or digits.len > 4 or digits[0] == '0') return false;
        for (digits) |d| if (!std.ascii.isDigit(d)) return false;
        name = spec[0..colon];
    }
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c == '%') {
            if (i + 2 >= name.len or !std.ascii.isHex(name[i + 1]) or !std.ascii.isHex(name[i + 2])) return false;
            i += 3;
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            i += 1;
        } else if (c == '.') {
            if (i + 1 < name.len and name[i + 1] == '.') return false;
            i += 1;
        } else return false;
    }
    return true;
}

const testing = std.testing;

test "the text formats' grammars" {
    try testing.expect(isUuid("2EB8AA08-AA98-11EA-B4AA-73B441D16380"));
    try testing.expect(!isUuid("2eb8aa08-aa98-11ea-b4aa-73b441d1638"));
    try testing.expect(!isUuid("2eb8aa08aa9811eab4aa73b441d16380"));
    for ([_][]const u8{ "", "/", "/a~0b/c~1d/0" }) |p| try testing.expect(isJsonPointer(p));
    for ([_][]const u8{ "a", "/~", "/~2" }) |p| try testing.expect(!isJsonPointer(p));
    for ([_][]const u8{ "0", "1#", "0/a", "2/0/b", "1+1/a", "0-1#" }) |p| try testing.expect(isRelativeJsonPointer(p));
    for ([_][]const u8{ "", "/a", "01", "-1", "0##", "a" }) |p| try testing.expect(!isRelativeJsonPointer(p));
    for ([_][]const u8{ "http://example.com/dictionary/{term:1}/{term}", "{+path}/here", "{/list*}", "x{?a,b,c}", "%20" }) |t| try testing.expect(isUriTemplate(t));
    for ([_][]const u8{ "{", "{}", "{term:0}", "{=x}", "a b", "{a..b}", "%2" }) |t| try testing.expect(!isUriTemplate(t));
}
