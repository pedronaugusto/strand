//! ZON number literals as the Zig language spells them, read into any integer
//! or float width. The grammar is std's own `parseNumberLiteral`, so what is a
//! number here is what is a number to `std.zon`; the value is read here, with
//! checked arithmetic, because std reads integers to 64 bits and floats to
//! `f128` and this core promises the destination's width.
const std = @import("std");
const core = @import("strand.core");
const literal = std.zig.number_literal;

/// An integer from a literal, with its sign if it has one. An integral float
/// literal (`1.0`, `2e3`) is an integer, as in std.
pub fn integer(comptime T: type, spelling: []const u8, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    // Wide enough for a digit and a radix, whatever the destination holds.
    return wide(T, @Int(.unsigned, @max(@typeInfo(T).int.bits, 8)), spelling);
}

fn wide(comptime T: type, comptime W: type, spelling: []const u8) core.DecodeError!T {
    const negative = spelling.len != 0 and spelling[0] == '-';
    const body = if (negative) spelling[1..] else spelling;
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return error.SyntaxError;
    const value: W = switch (literal.parseNumberLiteral(body)) {
        .failure => return error.SyntaxError,
        // Zig's own refusal: a negative zero is `-0.0`, never `-0`.
        .int => |small| if (negative and small == 0) return error.SyntaxError else std.math.cast(W, small) orelse return error.NumberOutOfRange,
        .big_int => |base| try digits(W, body, @backingInt(base)),
        .float => |base| switch (base) {
            .decimal => try integralDecimal(W, body),
            .hex => try integralHex(W, body),
        },
    };
    return signed(T, W, value, negative);
}

/// A magnitude and a sign as the destination: nothing is truncated.
fn signed(comptime T: type, comptime W: type, value: W, negative: bool) core.DecodeError!T {
    const info = @typeInfo(T).int;
    if (info.signedness == .unsigned) {
        if (negative and value != 0) return error.NumberOutOfRange;
        return std.math.cast(T, value) orelse error.NumberOutOfRange;
    }
    if (negative) {
        // The magnitude of the minimum is one past the maximum.
        const limit: W = if (info.bits == 0) 0 else @as(W, 1) << (info.bits - 1);
        if (value > limit) return error.NumberOutOfRange;
        if (value == limit) return std.math.minInt(T);
        return -@as(T, @intCast(value)); // safe: below the minimum's magnitude, so within the destination.
    }
    return std.math.cast(T, value) orelse error.NumberOutOfRange;
}

/// The digits of an integer literal that does not fit 64 bits, `_` skipped.
fn digits(comptime W: type, body: []const u8, base: u8) core.DecodeError!W {
    var at: usize = if (base == 10) 0 else 2;
    var value: W = 0;
    while (at < body.len) : (at += 1) {
        const byte = body[at];
        if (byte == '_') continue;
        const digit = std.fmt.charToDigit(byte, base) catch return error.SyntaxError;
        value = std.math.mul(W, value, base) catch return error.NumberOutOfRange;
        value = std.math.add(W, value, digit) catch return error.NumberOutOfRange;
    }
    return value;
}

/// A decimal literal with a fraction or an exponent, if its value is whole:
/// digits and a power of ten, never a rounded float.
fn integralDecimal(comptime W: type, body: []const u8) core.DecodeError!W {
    var mantissa: W = 0;
    var fraction: usize = 0;
    var zeros: usize = 0;
    var at: usize = 0;
    var in_fraction = false;
    while (at < body.len) : (at += 1) {
        const byte = body[at];
        switch (byte) {
            '_' => continue,
            '.' => in_fraction = true,
            'e', 'E' => break,
            else => {
                const digit = byte - '0';
                mantissa = std.math.mul(W, mantissa, 10) catch return error.NumberOutOfRange;
                mantissa = std.math.add(W, mantissa, digit) catch return error.NumberOutOfRange;
                zeros = if (digit == 0) zeros + 1 else 0;
                if (in_fraction) fraction += 1;
            },
        }
    }
    var exponent: i64 = 0;
    if (at < body.len) {
        at += 1;
        var negative = false;
        if (body[at] == '+' or body[at] == '-') {
            negative = body[at] == '-';
            at += 1;
        }
        var magnitude: i64 = 0;
        for (body[at..]) |byte| {
            if (byte == '_') continue;
            // Past this the value is out of range or zero whatever the digits say.
            if (magnitude < 1 << 40) magnitude = magnitude * 10 + (byte - '0');
        }
        exponent = if (negative) -magnitude else magnitude;
    }
    if (mantissa == 0) return 0;
    var scale: i64 = exponent - @as(i64, @intCast(fraction)); // safe: a fraction is at most the literal's length.
    if (scale < 0) {
        // Only trailing zeros of the digits may be given back.
        var drop = -scale;
        if (drop > zeros) return error.InexactNumber;
        while (drop > 0) : (drop -= 1) mantissa /= 10;
        scale = 0;
    }
    // Each factor of ten is a digit: past the width of W there is no value.
    if (scale > @typeInfo(W).int.bits) return error.NumberOutOfRange;
    while (scale > 0) : (scale -= 1) mantissa = std.math.mul(W, mantissa, 10) catch return error.NumberOutOfRange;
    return mantissa;
}

fn integralHex(comptime W: type, body: []const u8) core.DecodeError!W {
    const value = std.fmt.parseFloat(f128, body) catch return error.SyntaxError;
    if (!std.math.isFinite(value) or value != @floor(value)) return error.InexactNumber;
    if (value >= std.math.ldexp(@as(f128, 1), @typeInfo(W).int.bits)) return error.NumberOutOfRange;
    return @intFromFloat(value);
}

/// A float from a literal, correctly rounded to `T` once. An integer literal is
/// a float, as in std. `exact` refuses a value `T` cannot hold; it is decided
/// in `f128`, so a decimal with more digits than `f128` keeps is refused.
pub fn floating(comptime T: type, spelling: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    const negative = spelling.len != 0 and spelling[0] == '-';
    const body = if (negative) spelling[1..] else spelling;
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return error.SyntaxError;
    const kind = literal.parseNumberLiteral(body);
    if (negative and kind == .int and kind.int == 0) return error.SyntaxError;
    const value: T = switch (kind) {
        .failure => return error.SyntaxError,
        .float => std.fmt.parseFloat(T, body) catch return error.SyntaxError,
        .int, .big_int => try wholeAsFloat(T, kind, body),
    };
    if (!std.math.isFinite(value)) return error.NumberOutOfRange;
    if (exact and !try isExact(T, value, kind, body)) return error.InexactNumber;
    return if (negative) -value else value;
}

fn wholeAsFloat(comptime T: type, kind: literal.Result, body: []const u8) core.DecodeError!T {
    switch (kind) {
        .int => |small| return @floatFromInt(small),
        .big_int => |base| {
            // Accumulated in f128: exact to 113 bits, the nearest beyond them.
            var value: f128 = 0;
            const radix: u8 = @backingInt(base);
            var at: usize = if (radix == 10) 0 else 2;
            while (at < body.len) : (at += 1) {
                if (body[at] == '_') continue;
                const digit = std.fmt.charToDigit(body[at], radix) catch return error.SyntaxError;
                value = value * @as(f128, @floatFromInt(radix)) + @as(f128, @floatFromInt(digit));
            }
            return @floatCast(value);
        },
        else => unreachable,
    }
}

fn isExact(comptime T: type, value: T, kind: literal.Result, body: []const u8) core.DecodeError!bool {
    const reference: f128 = switch (kind) {
        .float => std.fmt.parseFloat(f128, body) catch return error.SyntaxError,
        .int => |small| @floatFromInt(small),
        .big_int => @as(f128, try wholeAsFloat(f128, kind, body)),
        .failure => unreachable,
    };
    return @as(f128, value) == reference;
}
