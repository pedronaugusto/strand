//! An exact decimal, `digits × 10^exponent`: how a schema's and an
//! instance's numbers compare, never as `f64`. `1.0` and `1` are equal, as
//! JSON Schema says, and `multipleOf` is decided without building either
//! number. The exponent is bounded by `Limits.exponent`; past it a number is
//! refused, never approximated.
const Decimal = @This();
const std = @import("std");
const aegis = @import("aegis");

negative: bool = false,
/// The significand's digits, ASCII, with no leading or trailing zero; empty
/// for zero.
digits: []const u8 = "",
/// The power of ten of the last digit.
exponent: i32 = 0,

pub const zero: Decimal = .{};

pub const ParseError = error{
    /// Not a JSON number.
    Invalid,
    /// An exponent past the bound.
    TooLarge,
};

/// The number `text` spells in JSON's grammar (RFC 8259 §6), its digits
/// written into `buffer`, at least as long as `text`. Both the last digit's
/// exponent and the first's must lie within `max_exponent` either way.
pub fn parse(text: []const u8, buffer: []u8, max_exponent: u32) ParseError!Decimal {
    aegis.assert.invariant(buffer.len >= text.len, "the digits fit the buffer the caller sized from the text");
    var i: usize = 0;
    const negative = i < text.len and text[i] == '-';
    if (negative) i += 1;
    if (i >= text.len) return error.Invalid;
    var n: usize = 0;
    // The integer part: 0, or digits not starting with 0.
    if (text[i] == '0') {
        i += 1;
    } else if (text[i] >= '1' and text[i] <= '9') {
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            buffer[n] = text[i];
            n += 1;
        }
    } else return error.Invalid;
    var fraction: usize = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            buffer[n] = text[i];
            n += 1;
        }
        fraction = i - start;
        if (fraction == 0) return error.Invalid;
    }
    var written: i64 = 0;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        var sign: i64 = 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) {
            if (text[i] == '-') sign = -1;
            i += 1;
        }
        const start = i;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            // Saturate: a written exponent this far out is refused below.
            if (written < 1 << 40) written = written * 10 + (text[i] - '0');
        }
        if (i == start) return error.Invalid;
        written *= sign;
    }
    if (i != text.len) return error.Invalid;
    // Leading and trailing zeros out.
    var digits = buffer[0..n];
    while (digits.len > 0 and digits[0] == '0') digits = digits[1..];
    var exponent: i64 = written - @as(i64, @intCast(fraction));
    while (digits.len > 0 and digits[digits.len - 1] == '0') {
        digits = digits[0 .. digits.len - 1];
        exponent += 1;
    }
    if (digits.len == 0) return .zero;
    const bound: i64 = max_exponent;
    const first = exponent + @as(i64, @intCast(digits.len)) - 1;
    if (exponent < -bound or exponent > bound or first < -bound or first > bound) return error.TooLarge;
    return .{ .negative = negative, .digits = digits, .exponent = @intCast(exponent) };
}

pub fn isZero(d: Decimal) bool {
    return d.digits.len == 0;
}

/// Whether it is a whole number.
pub fn isInteger(d: Decimal) bool {
    return d.digits.len == 0 or d.exponent >= 0;
}

pub fn order(a: Decimal, b: Decimal) std.math.Order {
    if (a.isZero() and b.isZero()) return .eq;
    const sa: i2 = if (a.isZero()) 0 else if (a.negative) -1 else 1;
    const sb: i2 = if (b.isZero()) 0 else if (b.negative) -1 else 1;
    if (sa != sb) return std.math.order(sa, sb);
    const magnitude = orderMagnitude(a, b);
    return if (sa < 0) magnitude.invert() else magnitude;
}

pub fn eql(a: Decimal, b: Decimal) bool {
    return a.order(b) == .eq;
}

/// |a| against |b|, both nonzero.
fn orderMagnitude(a: Decimal, b: Decimal) std.math.Order {
    // The power of ten just above the first digit decides first.
    const top_a = @as(i64, a.exponent) + @as(i64, @intCast(a.digits.len));
    const top_b = @as(i64, b.exponent) + @as(i64, @intCast(b.digits.len));
    if (top_a != top_b) return std.math.order(top_a, top_b);
    // Aligned at the first digit: the digits in order, and with no trailing
    // zeros, the longer is larger past the common part.
    const common = @min(a.digits.len, b.digits.len);
    switch (std.mem.order(u8, a.digits[0..common], b.digits[0..common])) {
        .eq => return std.math.order(a.digits.len, b.digits.len),
        else => |o| return o,
    }
}

/// Whether `a` is an integer multiple of `b`, which is positive. With `a`
/// as `A × 10^p` and `b` as `B × 10^q`, neither significand holding a
/// trailing zero: when `p ≥ q`, exactly when `A × 10^(p−q) ≡ 0 (mod B)`,
/// `10^(p−q) mod B` by square and multiply; when `p < q`, never (for `a`
/// not zero), since `A` would need `q−p` trailing zeros. A divisor of up to
/// 38 digits is worked in 256-bit integers; a longer one in `gpa`.
pub fn multipleOf(a: Decimal, b: Decimal, gpa: std.mem.Allocator) error{OutOfMemory}!bool {
    aegis.assert.invariant(!b.isZero() and !b.negative, "multipleOf's divisor is positive, as the schema checks");
    if (a.isZero()) return true;
    if (a.exponent < b.exponent) return false;
    const k: u64 = @intCast(@as(i64, a.exponent) - b.exponent);
    if (b.digits.len <= 38) return smallMultiple(a.digits, b.digits, k);
    return bigMultiple(gpa, a.digits, b.digits, k);
}

fn smallMultiple(a_digits: []const u8, b_digits: []const u8, k: u64) bool {
    const m: u256 = std.fmt.parseInt(u128, b_digits, 10) catch aegis.assert.never("38 digits fit a u128");
    var r: u256 = 0;
    for (a_digits) |c| r = (r * 10 + (c - '0')) % m;
    if (r == 0) return true;
    // 10^k mod m: every operand below m < 2^127, every product below 2^254.
    var power: u256 = 1 % m;
    var base: u256 = 10 % m;
    var e = k;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) power = (power * base) % m;
        base = (base * base) % m;
    }
    return (r * power) % m == 0;
}

fn bigMultiple(gpa: std.mem.Allocator, a_digits: []const u8, b_digits: []const u8, k: u64) error{OutOfMemory}!bool {
    const Managed = std.math.big.int.Managed;
    var m = try Managed.init(gpa);
    defer m.deinit();
    m.setString(10, b_digits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCharacter, error.InvalidBase => aegis.assert.never("the digits are decimal ASCII"),
    };
    var a = try Managed.init(gpa);
    defer a.deinit();
    a.setString(10, a_digits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCharacter, error.InvalidBase => aegis.assert.never("the digits are decimal ASCII"),
    };
    var q = try Managed.init(gpa);
    defer q.deinit();
    var r = try Managed.init(gpa);
    defer r.deinit();
    try q.divTrunc(&r, &a, &m);
    if (r.eqlZero()) return true;
    var power = try Managed.initSet(gpa, 1);
    defer power.deinit();
    var base = try Managed.initSet(gpa, 10);
    defer base.deinit();
    var t = try Managed.init(gpa);
    defer t.deinit();
    var e = k;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) {
            try t.mul(&power, &base);
            try q.divTrunc(&power, &t, &m);
        }
        try t.mul(&base, &base);
        try q.divTrunc(&base, &t, &m);
    }
    try t.mul(&r, &power);
    try q.divTrunc(&r, &t, &m);
    return r.eqlZero();
}

const testing = std.testing;

fn parsed(text: []const u8, buffer: []u8) !Decimal {
    return parse(text, buffer, 4096);
}

test "a number reads to its digits and exponent, zeros out" {
    var buf: [64]u8 = undefined;
    const d = try parsed("-120.4500e3", &buf);
    try testing.expect(d.negative);
    try testing.expectEqualStrings("12045", d.digits);
    try testing.expectEqual(@as(i32, 1), d.exponent);
    try testing.expect((try parsed("-0.0e10", &buf)).isZero());
    try testing.expect((try parsed("1.0", &buf)).isInteger());
    try testing.expect(!(try parsed("1.5", &buf)).isInteger());
    try testing.expect((try parsed("1e400", &buf)).isInteger());
    for ([_][]const u8{ "", "-", "01", "1.", ".5", "1e", "1e+", "+1", "1.5.5", "0x10", "1 ", "NaN" }) |bad| try testing.expectError(error.Invalid, parsed(bad, &buf));
    try testing.expectError(error.TooLarge, parsed("1e4097", &buf));
    try testing.expectError(error.TooLarge, parsed("1e-4097", &buf));
    try testing.expectError(error.TooLarge, parsed("1e99999999999999999999", &buf));
    try testing.expectError(error.TooLarge, parsed("12e4096", &buf));
}

test "numbers order exactly, 1.0 equal to 1" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8, std.math.Order }{
        .{ "1.0", "1", .eq },             .{ "0", "-0", .eq },                                                          .{ "1e2", "100", .eq },
        .{ "0.1", "0.10000000001", .lt }, .{ "-2", "-1", .lt },                                                         .{ "-1", "0", .lt },
        .{ "99", "1e2", .lt },            .{ "1.25", "1.2", .gt },                                                      .{ "1e-400", "0", .gt },
        .{ "-1e-400", "0", .lt },         .{ "123456789012345678901234567890", "123456789012345678901234567891", .lt },
    };
    for (cases) |c| try testing.expectEqual(c[2], (try parsed(c[0], &b1)).order(try parsed(c[1], &b2)));
}

test "multipleOf at the exponents' ends and past 38 digits" {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "1e400", "1e-400", true },                                                                                             .{ "1e-400", "1e400", false },
        .{ "7e100", "7", true },                                                                                                  .{ "0", "3", true },
        .{ "4.5", "1.5", true },                                                                                                  .{ "4.6", "1.5", false },
        .{ "19.99", "0.01", true },                                                                                               .{ "0.075", "0.0001", true },
        .{ "1e4000", "3", false },                                                                                                .{ "3e4000", "3", true },
        .{ "123456789012345678901234567890123456789012345678900", "123456789012345678901234567890123456789012345678900", true },  .{ "246913578024691357802469135780246913578024691357800", "123456789012345678901234567890123456789012345678900", true },
        .{ "246913578024691357802469135780246913578024691357801", "123456789012345678901234567890123456789012345678900", false }, .{ "1e300", "1234567890123456789012345678901234567891", false },
    };
    for (cases) |c| {
        const got = try (try parsed(c[0], &b1)).multipleOf(try parsed(c[1], &b2), testing.allocator);
        testing.expectEqual(c[2], got) catch |err| {
            std.debug.print("{s} multipleOf {s}\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "property: multipleOf and order agree with exact big-integer arithmetic" {
    const shakedown = @import("shakedown");
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gen = shakedown.gen;
            const s = case.source;
            var a_text: [96]u8 = undefined;
            var b_text: [96]u8 = undefined;
            const a_len = digitsInto(s, &a_text, 30);
            const b_len = digitsInto(s, &b_text, 60);
            const p = gen.intRange(s, i32, -40, 40);
            const q = gen.intRange(s, i32, -40, 40);
            var a_full: [128]u8 = undefined;
            var b_full: [128]u8 = undefined;
            const a_spelled = try std.mem.print(&a_full, "{s}e{d}", .{ a_text[0..a_len], p });
            const b_spelled = try std.mem.print(&b_full, "{s}e{d}", .{ b_text[0..b_len], q });
            var ab: [128]u8 = undefined;
            var bb: [128]u8 = undefined;
            const a = try parse(a_spelled, &ab, 4096);
            const b = try parse(b_spelled, &bb, 4096);
            // Exact: both scaled by 10^-min(p, q) to integers.
            const gpa = testing.allocator;
            const Managed = std.math.big.int.Managed;
            const low = @min(p, q);
            var ai = try scaled(gpa, a_text[0..a_len], p - low);
            defer ai.deinit();
            var bi = try scaled(gpa, b_text[0..b_len], q - low);
            defer bi.deinit();
            try testing.expectEqual(ai.order(bi), a.order(b));
            if (b.isZero()) return;
            var quotient = try Managed.init(gpa);
            defer quotient.deinit();
            var r = try Managed.init(gpa);
            defer r.deinit();
            try quotient.divTrunc(&r, &ai, &bi);
            try testing.expectEqual(r.eqlZero(), try a.multipleOf(b, gpa));
        }

        fn digitsInto(s: *shakedown.Source, out: []u8, most: usize) usize {
            const gen = shakedown.gen;
            const len = gen.intRange(s, usize, 1, most);
            for (out[0..len]) |*c| c.* = '0' + gen.intRange(s, u8, 0, 9);
            // Trailing zeros often, so normalization is driven.
            if (gen.boolean(s)) for (out[len / 2 .. len]) |*c| {
                c.* = '0';
            };
            if (out[0] == '0') out[0] = '1';
            return len;
        }

        fn scaled(gpa: std.mem.Allocator, digits: []const u8, shift: i32) !std.math.big.int.Managed {
            var x = try std.math.big.int.Managed.init(gpa);
            errdefer x.deinit();
            try x.setString(10, digits);
            var ten = try std.math.big.int.Managed.initSet(gpa, 10);
            defer ten.deinit();
            var power = try std.math.big.int.Managed.init(gpa);
            defer power.deinit();
            try power.pow(&ten, @intCast(shift));
            try x.mul(&x, &power);
            return x;
        }
    }.one, .{ .cases = 3000, .seed = 0x6e5 });
}
