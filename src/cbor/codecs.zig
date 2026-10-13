//! The tags a type asks for by name: a value of `T` under a tag of its own,
//! integers wider than 64 bits (tags 2 and 3), and the two date forms (tags 0
//! and 1). A tag nobody asked for is refused where a typed value is read.
const std = @import("std");

/// A `T` under tag `number`, which must be there when it is read.
pub fn Tagged(comptime T: type, comptime number: u64) type {
    return struct {
        value: T,
        const Self = @This();
        pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Self {
            if (try access.tag() != number) return error.UnexpectedType;
            return .{ .value = try access.read(T) };
        }
        pub fn strandSerialize(self: Self, access: anytype) @TypeOf(access.*).Error!void {
            try access.tag(number);
            try access.write(self.value);
        }
    };
}

/// An integer of any width (tags 2 and 3, RFC 8949 3.4.3): its magnitude as
/// big-endian bytes, and for a negative one `-1 - magnitude`. Its bytes are
/// the shortest that hold it, as preferred serialization writes them; reading
/// takes leading zeros too.
pub const Bignum = struct {
    negative: bool,
    magnitude: []const u8,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Bignum {
        const number = try access.tag();
        if (number != 2 and number != 3) return error.UnexpectedType;
        return .{ .negative = number == 3, .magnitude = try access.bytes(.prefer) };
    }
    pub fn strandSerialize(self: Bignum, access: anytype) @TypeOf(access.*).Error!void {
        var magnitude = self.magnitude;
        while (magnitude.len > 0 and magnitude[0] == 0) magnitude = magnitude[1..];
        try access.tag(if (self.negative) 3 else 2);
        try access.bytes(magnitude);
    }
};

/// A date and time as RFC 3339 text (tag 0), checked for its form: a date,
/// `T`, a time with optional fraction, and `Z` or an offset.
pub const DateTime = struct {
    text: []const u8,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!DateTime {
        if (try access.tag() != 0) return error.UnexpectedType;
        const text = try access.read([]const u8);
        if (!valid(text)) return error.UnsupportedValue;
        return .{ .text = text };
    }
    pub fn strandSerialize(self: DateTime, access: anytype) @TypeOf(access.*).Error!void {
        if (!valid(self.text)) return error.UnsupportedValue;
        try access.tag(0);
        try access.write(self.text);
    }

    /// Whether `text` is an RFC 3339 date-time.
    pub fn valid(text: []const u8) bool {
        if (text.len < 20) return false;
        const digits = struct {
            fn at(t: []const u8, i: usize, n: usize) ?u32 {
                if (i + n > t.len) return null;
                var v: u32 = 0;
                for (t[i..][0..n]) |c| {
                    if (!std.ascii.isDigit(c)) return null;
                    v = v * 10 + (c - '0');
                }
                return v;
            }
        };
        const month = digits.at(text, 5, 2) orelse return false;
        const day = digits.at(text, 8, 2) orelse return false;
        const hour = digits.at(text, 11, 2) orelse return false;
        const minute = digits.at(text, 14, 2) orelse return false;
        const second = digits.at(text, 17, 2) orelse return false;
        if (digits.at(text, 0, 4) == null or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != 't') or text[13] != ':' or text[16] != ':') return false;
        if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return false;
        var at: usize = 19;
        if (text[at] == '.') {
            at += 1;
            const start = at;
            while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
            if (at == start) return false;
        }
        if (at >= text.len) return false;
        if (text[at] == 'Z' or text[at] == 'z') return at + 1 == text.len;
        if (text[at] != '+' and text[at] != '-') return false;
        const oh = digits.at(text, at + 1, 2) orelse return false;
        const om = digits.at(text, at + 4, 2) orelse return false;
        return at + 6 == text.len and text[at + 3] == ':' and oh <= 23 and om <= 59;
    }
};

/// Seconds since 1970-01-01T00:00Z (tag 1): an integer or a float.
pub const Epoch = union(enum) {
    seconds: i64,
    fractional: f64,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Epoch {
        if (try access.tag() != 1) return error.UnexpectedType;
        return switch (try access.peek()) {
            .integer => .{ .seconds = try access.read(i64) },
            .floating => blk: {
                const f = try access.read(f64);
                if (!std.math.isFinite(f)) return error.UnsupportedValue;
                break :blk .{ .fractional = f };
            },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Epoch, access: anytype) @TypeOf(access.*).Error!void {
        try access.tag(1);
        switch (self) {
            .seconds => |s| try access.write(s),
            .fractional => |f| {
                if (!std.math.isFinite(f)) return error.UnsupportedValue;
                try access.write(f);
            },
        }
    }
};

test "RFC 3339 date-times" {
    try std.testing.expect(DateTime.valid("2013-03-21T20:04:00Z"));
    try std.testing.expect(DateTime.valid("2013-03-21T20:04:00.5+01:00"));
    try std.testing.expect(!DateTime.valid("2013-13-21T20:04:00Z"));
    try std.testing.expect(!DateTime.valid("2013-03-21 20:04:00Z"));
    try std.testing.expect(!DateTime.valid("2013-03-21T20:04:00"));
}
