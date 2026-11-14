//! The network formats' grammars, each exactly its RFC's and no reading
//! beyond it: `hostname` (RFC 1123 §2.1 over RFC 952), `ipv4` (RFC 2673
//! §3.2's dotted-quad, no leading zeros), `ipv6` (RFC 4291 §2.2, no zone),
//! and `email` (RFC 5321 §4.1.2's Mailbox: a dot-string or quoted local part,
//! a domain or an address literal), with `idn-email` (RFC 6531) taking UTF-8
//! in the local part and an IDNA2008 name as its domain.
const std = @import("std");
const xenoglyph = @import("xenoglyph");

/// RFC 1123's host name: labels of letters, digits and hyphens, 1 to 63
/// bytes each, neither beginning nor ending with a hyphen, the name at most
/// 253 bytes. A label beginning `xn--` must be a valid A-label (IDNA2008).
pub fn isHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    var labels = std.mem.splitScalar(u8, s, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        // `--` in the third and fourth places is reserved for A-labels.
        if (label.len >= 4 and label[2] == '-' and label[3] == '-') {
            if (!std.ascii.eqlIgnoreCase(label[0..2], "xn")) return false;
            const failures = xenoglyph.idna.check2008(label) catch return false;
            if (failures.any()) return false;
        }
    }
    return true;
}

/// An internationalized host name: IDNA2008's validity as written, every
/// label an A-label or a U-label, and the ASCII length rules.
pub fn isIdnHostname(s: []const u8) bool {
    if (s.len == 0) return false;
    // IDNA2008 splits at U+002E alone; the ideographic and other full
    // stops (U+3002, U+FF0E, U+FF61) are separators too in IDNA's
    // processing, and a name using them is read with them as dots.
    var buffer: [1024]u8 = undefined;
    if (s.len > buffer.len) return false;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
        if (i + len > s.len) return false;
        const cp: u21 = switch (len) {
            1 => s[i],
            2 => std.unicode.utf8Decode2(s[i..][0..2].*) catch return false,
            3 => std.unicode.utf8Decode3(s[i..][0..3].*) catch return false,
            4 => std.unicode.utf8Decode4(s[i..][0..4].*) catch return false,
            else => return false,
        };
        if (cp == 0x3002 or cp == 0xFF0E or cp == 0xFF61) {
            buffer[n] = '.';
            n += 1;
        } else {
            @memcpy(buffer[n..][0..len], s[i..][0..len]);
            n += len;
        }
        i += len;
    }
    const name = buffer[0..n];
    if (name[name.len - 1] == '.') return false;
    const failures = xenoglyph.idna.check2008(name) catch return false;
    if (failures.any()) return false;
    // An ASCII label still follows the host name rules.
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        const ascii = for (label) |c| {
            if (c >= 0x80) break false;
        } else true;
        if (ascii and !isHostname(label)) return false;
    }
    return true;
}

/// RFC 2673's dotted-quad: four decimal octets, each 0 to 255 with no
/// leading zero.
pub fn isIpv4(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count == 4) return false;
        if (part.len == 0 or part.len > 3) return false;
        if (part.len > 1 and part[0] == '0') return false;
        var v: u16 = 0;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
            v = v * 10 + (c - '0');
        }
        if (v > 255) return false;
    }
    return count == 4;
}

/// RFC 4291 §2.2's text forms: eight groups of one to four hexadecimal
/// digits, one `::` standing for one or more groups of zeros, and the last
/// two groups optionally a dotted-quad. No zone, no prefix length.
pub fn isIpv6(s: []const u8) bool {
    if (s.len < 2) return false;
    var groups: usize = 0;
    var elided = false;
    var i: usize = 0;
    if (std.mem.startsWith(u8, s, "::")) {
        elided = true;
        i = 2;
        if (i == s.len) return true;
    } else if (s[0] == ':') return false;
    while (i < s.len) {
        // A dotted-quad, the address's last part, holds no more colons.
        const rest = s[i..];
        if (std.mem.findScalar(u8, rest, ':') == null and std.mem.findScalar(u8, rest, '.') != null) {
            if (!isIpv4(rest)) return false;
            groups += 2;
            break;
        }
        var digits: usize = 0;
        while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) digits += 1;
        if (digits == 0 or digits > 4) return false;
        groups += 1;
        if (i == s.len) break;
        if (s[i] != ':') return false;
        i += 1;
        if (i < s.len and s[i] == ':') {
            if (elided) return false;
            elided = true;
            i += 1;
            if (i == s.len) break;
        } else if (i == s.len) return false;
    }
    return if (elided) groups < 8 else groups == 8;
}

/// RFC 5321 §4.1.2's Mailbox; with `international`, RFC 6531's: UTF-8 in
/// the local part and an internationalized domain.
pub fn isEmail(s: []const u8, international: bool) bool {
    const at = std.mem.findScalarLast(u8, s, '@') orelse return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (!isLocalPart(local, international)) return false;
    if (domain.len >= 2 and domain[0] == '[' and domain[domain.len - 1] == ']') {
        const literal = domain[1 .. domain.len - 1];
        if (std.ascii.startsWithIgnoreCase(literal, "IPv6:")) return isIpv6(literal[5..]);
        return isIpv4(literal);
    }
    return if (international) isIdnHostname(domain) else isHostname(domain);
}

/// `Dot-string` (atoms of atext joined by single dots) or `Quoted-string`.
fn isLocalPart(s: []const u8, international: bool) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (s[0] == '"') {
        if (s.len < 2 or s[s.len - 1] != '"') return false;
        var i: usize = 1;
        while (i < s.len - 1) : (i += 1) {
            const c = s[i];
            if (c == '\\') {
                // quoted-pairSMTP: a backslash and a printable ASCII.
                i += 1;
                if (i >= s.len - 1 or s[i] < 32 or s[i] > 126) return false;
            } else if (c == '"' or (c < 32 or c == 127) or (c >= 0x80 and !international)) return false;
        }
        return true;
    }
    if (s[0] == '.' or s[s.len - 1] == '.' or std.mem.find(u8, s, "..") != null) return false;
    for (s) |c| {
        if (c >= 0x80) {
            if (!international) return false;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!#$%&'*+-/=?^_`{|}~.", c) == null) return false;
    }
    return true;
}

const testing = std.testing;

test "the network formats' grammars" {
    for ([_][]const u8{ "example.com", "a", "a-b.c1", "xn--bcher-kva.example" }) |h| try testing.expect(isHostname(h));
    for ([_][]const u8{ "", "-a", "a-", "a..b", "a_b", "ab--c", "xn--x.example" }) |h| try testing.expect(!isHostname(h));
    for ([_][]const u8{ "0.0.0.0", "255.255.255.255", "192.168.0.1" }) |a| try testing.expect(isIpv4(a));
    for ([_][]const u8{ "256.0.0.0", "01.2.3.4", "1.2.3", "1.2.3.4.5", "1.2.3.a", "" }) |a| try testing.expect(!isIpv4(a));
    for ([_][]const u8{ "::", "::1", "1::", "1:2:3:4:5:6:7:8", "fe80::1:2", "::ffff:192.168.0.1", "1:2:3:4:5:6:1.2.3.4" }) |a| try testing.expect(isIpv6(a));
    for ([_][]const u8{ ":", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::", "1:", ":1", "::1.2.3", "1:2:3:4:5:6:7:1.2.3.4", "fe80::1%eth0" }) |a| try testing.expect(!isIpv6(a));
    for ([_][]const u8{ "joe@example.com", "\"joe bloggs\"@example.com", "a.b+c@[127.0.0.1]", "x@[IPv6:::1]" }) |m| try testing.expect(isEmail(m, false));
    for ([_][]const u8{ "joe", ".a@b.com", "a..b@c.com", "a.@b.com", "a@-b.com", "a@[300.0.0.1]" }) |m| try testing.expect(!isEmail(m, false));
    try testing.expect(isEmail("실례@실례.테스트", true));
    try testing.expect(!isEmail("실례@example.com", false));
    try testing.expect(isIdnHostname("실례.테스트"));
    try testing.expect(!isIdnHostname("〮실례.테스트"));
}
