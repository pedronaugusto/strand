//! TOML's four kinds of date and time, as RFC 3339 spells them with TOML's
//! liberties: a space or a `t` for the `T`, a `z` for the `Z`, seconds left
//! off (TOML 1.1). Read into their parts, checked (a day the month has, an
//! hour of the day, an offset within a day), and written back in one spelling.
const std = @import("std");

/// Which of the four a spelling is; the tag a TOML date or time travels under.
pub const Kind = enum(u64) { offset_date_time, local_date_time, local_date, local_time };

/// Every part a spelling may hold; those its kind has no place for are zero.
pub const Parts = struct {
    kind: Kind,
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,
    /// Minutes east of UTC, for an offset date-time.
    offset_minutes: i16 = 0,
};

/// What the front of `bytes` is when it is a date or a time: its parts and
/// its length. `null` when it starts as neither (no `DDDD-` and no `DD:`),
/// `error.SyntaxError` when it starts as one and is not one. A value of TOML
/// ends at its length; what follows is the caller's to judge.
pub fn lex(bytes: []const u8, seconds_optional: bool) error{SyntaxError}!?struct { parts: Parts, len: usize } {
    if (startsDate(bytes)) {
        var parts: Parts = .{ .kind = .local_date };
        try date(bytes, &parts);
        var at: usize = 10;
        // A time follows a `T` or `t`, or a space with a time after it.
        const delimiter = at < bytes.len and (bytes[at] == 'T' or bytes[at] == 't' or (bytes[at] == ' ' and startsTime(bytes[at + 1 ..])));
        if (!delimiter) return .{ .parts = parts, .len = at };
        at += 1;
        at += try time(bytes[at..], &parts, seconds_optional);
        parts.kind = .local_date_time;
        if (at < bytes.len and (bytes[at] == 'Z' or bytes[at] == 'z')) {
            parts.kind = .offset_date_time;
            return .{ .parts = parts, .len = at + 1 };
        }
        if (at < bytes.len and (bytes[at] == '+' or bytes[at] == '-')) {
            const hours = two(bytes, at + 1) orelse return error.SyntaxError;
            if (at + 3 >= bytes.len or bytes[at + 3] != ':') return error.SyntaxError;
            const minutes = two(bytes, at + 4) orelse return error.SyntaxError;
            if (hours > 23 or minutes > 59) return error.SyntaxError;
            const offset: i16 = @intCast(@as(u16, hours) * 60 + minutes); // safe: at most 23 * 60 + 59.
            parts.offset_minutes = if (bytes[at] == '-') -offset else offset;
            parts.kind = .offset_date_time;
            return .{ .parts = parts, .len = at + 6 };
        }
        return .{ .parts = parts, .len = at };
    }
    if (startsTime(bytes)) {
        var parts: Parts = .{ .kind = .local_time };
        const len = try time(bytes, &parts, seconds_optional);
        return .{ .parts = parts, .len = len };
    }
    return null;
}

/// `text` whole, as one date or time.
pub fn parse(text: []const u8) ?Parts {
    const lexed = (lex(text, true) catch return null) orelse return null;
    if (lexed.len != text.len) return null;
    return lexed.parts;
}

fn startsDate(bytes: []const u8) bool {
    return bytes.len >= 5 and std.ascii.isDigit(bytes[0]) and std.ascii.isDigit(bytes[1]) and std.ascii.isDigit(bytes[2]) and std.ascii.isDigit(bytes[3]) and bytes[4] == '-';
}
fn startsTime(bytes: []const u8) bool {
    return bytes.len >= 3 and std.ascii.isDigit(bytes[0]) and std.ascii.isDigit(bytes[1]) and bytes[2] == ':';
}
fn two(bytes: []const u8, at: usize) ?u8 {
    if (at + 2 > bytes.len or !std.ascii.isDigit(bytes[at]) or !std.ascii.isDigit(bytes[at + 1])) return null;
    return (bytes[at] - '0') * 10 + (bytes[at + 1] - '0');
}

fn date(bytes: []const u8, parts: *Parts) error{SyntaxError}!void {
    const century = two(bytes, 0) orelse return error.SyntaxError;
    const years = two(bytes, 2) orelse return error.SyntaxError;
    if (bytes.len < 10 or bytes[4] != '-' or bytes[7] != '-') return error.SyntaxError;
    const month = two(bytes, 5) orelse return error.SyntaxError;
    const day = two(bytes, 8) orelse return error.SyntaxError;
    const year = @as(u16, century) * 100 + years;
    if (month < 1 or month > 12 or day < 1 or day > daysIn(year, month)) return error.SyntaxError;
    parts.year = year;
    parts.month = month;
    parts.day = day;
}

/// The days of `month` in `year`, leap years by the Gregorian rule.
pub fn daysIn(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// A partial time at the front of `bytes`, and its length. A fraction past
/// nanoseconds is read and dropped, as TOML says: truncated, not rounded.
fn time(bytes: []const u8, parts: *Parts, seconds_optional: bool) error{SyntaxError}!usize {
    const hour = two(bytes, 0) orelse return error.SyntaxError;
    if (bytes.len < 3 or bytes[2] != ':') return error.SyntaxError;
    const minute = two(bytes, 3) orelse return error.SyntaxError;
    if (hour > 23 or minute > 59) return error.SyntaxError;
    parts.hour = hour;
    parts.minute = minute;
    if (bytes.len <= 5 or bytes[5] != ':') {
        if (!seconds_optional) return error.SyntaxError;
        return 5;
    }
    const second = two(bytes, 6) orelse return error.SyntaxError;
    if (second > 60) return error.SyntaxError;
    parts.second = second;
    var at: usize = 8;
    if (at < bytes.len and bytes[at] == '.') {
        at += 1;
        const start = at;
        var nanosecond: u32 = 0;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) : (at += 1) {
            if (at - start < 9) nanosecond = nanosecond * 10 + (bytes[at] - '0');
        }
        if (at == start) return error.SyntaxError;
        var digits = at - start;
        while (digits < 9) : (digits += 1) nanosecond *= 10;
        parts.nanosecond = nanosecond;
    }
    return at;
}

/// Whether the parts are a date and time of their kind: what a writer checks
/// before it spells one it did not read.
pub fn valid(parts: Parts) bool {
    const has_date = parts.kind != .local_time;
    const has_time = parts.kind != .local_date;
    if (has_date and (parts.year > 9999 or parts.month < 1 or parts.month > 12 or parts.day < 1 or parts.day > daysIn(parts.year, parts.month))) return false;
    if (has_time and (parts.hour > 23 or parts.minute > 59 or parts.second > 60 or parts.nanosecond > 999_999_999)) return false;
    if (parts.kind == .offset_date_time and @abs(parts.offset_minutes) > 23 * 60 + 59) return false;
    return true;
}

/// The longest spelling `format` writes.
pub const max_len = "9999-12-31T23:59:60.999999999+23:59".len;

/// The parts spelled as RFC 3339 spells them, seconds always written, a
/// fraction with its trailing zeros left off, a zero offset as `Z`: TOML 1.0
/// reads it, and so does every RFC 3339 reader. The parts must be `valid`.
pub fn format(parts: Parts, buffer: *[max_len]u8) []const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    if (parts.kind != .local_time) out.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ parts.year, parts.month, parts.day }) catch unreachable; // unreachable: max_len holds the longest spelling of valid parts.
    if (parts.kind == .local_date) return out.buffered();
    if (parts.kind != .local_time) out.writeByte('T') catch unreachable; // unreachable: within max_len.
    out.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ parts.hour, parts.minute, parts.second }) catch unreachable; // unreachable: within max_len.
    if (parts.nanosecond != 0) {
        var digits: [9]u8 = undefined;
        _ = std.mem.print(&digits, "{d:0>9}", .{parts.nanosecond}) catch unreachable; // unreachable: below 10^9, nine digits.
        var len: usize = 9;
        while (digits[len - 1] == '0') len -= 1;
        out.writeByte('.') catch unreachable; // unreachable: within max_len.
        out.writeAll(digits[0..len]) catch unreachable; // unreachable: within max_len.
    }
    if (parts.kind == .offset_date_time) {
        if (parts.offset_minutes == 0) {
            out.writeByte('Z') catch unreachable; // unreachable: within max_len.
        } else {
            const magnitude = @abs(parts.offset_minutes);
            out.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (parts.offset_minutes < 0) '-' else '+'), magnitude / 60, magnitude % 60 }) catch unreachable; // unreachable: within max_len.
        }
    }
    return out.buffered();
}

test "each kind read, and what is none" {
    const odt = parse("1979-05-27T07:32:00.999999-07:00").?;
    try std.testing.expectEqual(Kind.offset_date_time, odt.kind);
    try std.testing.expectEqual(@as(u32, 999_999_000), odt.nanosecond);
    try std.testing.expectEqual(@as(i16, -7 * 60), odt.offset_minutes);
    try std.testing.expectEqual(Kind.local_date_time, parse("1979-05-27 07:32").?.kind);
    try std.testing.expectEqual(Kind.local_date, parse("2000-02-29").?.kind);
    try std.testing.expectEqual(Kind.local_time, parse("00:32:00.5").?.kind);
    try std.testing.expectEqual(@as(u32, 123_456_789), parse("00:00:00.1234567891").?.nanosecond);
    try std.testing.expectEqual(null, parse("2001-02-29"));
    try std.testing.expectEqual(null, parse("2006-01-01T00:00:61Z"));
    try std.testing.expectEqual(null, parse("1987-07-05T17:45:00+24:00"));
    try std.testing.expectEqual(null, parse("2006-01-30T"));
    try std.testing.expectEqual(null, parse("10000-01-01"));
    try std.testing.expectError(error.SyntaxError, lex("07:32", false));
}

test "a spelling written is read back as the same parts" {
    var buffer: [max_len]u8 = undefined;
    for ([_][]const u8{ "1979-05-27T07:32:00Z", "1979-05-27T00:32:00.5-07:00", "0001-01-01T00:00:00", "9999-12-31", "23:59:60.000000001", "12:00:00+05:45" }) |text| {
        const parts = parse(text) orelse {
            // A local time takes no offset: what follows it is no part of it.
            try std.testing.expectEqualStrings("12:00:00+05:45", text);
            continue;
        };
        try std.testing.expect(valid(parts));
        try std.testing.expectEqualStrings(text, format(parts, &buffer));
        try std.testing.expectEqual(parts, parse(format(parts, &buffer)).?);
    }
}
