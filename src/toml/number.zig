//! TOML's integers and floats: the grammar, a spelling with its `+` and
//! underscores taken out (what the decoder hands on), and the conversion of
//! that spelling into a Zig number. Integers are TOML's signed 64-bit profile;
//! a float holds what a binary64 holds, rounded once into the destination.
const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json/number.zig");

pub const Kind = enum { integer, float };

/// What a number's spelling is, and how long its normal spelling is: the
/// spelling with no `+` and no `_`. `null` when it is no TOML number.
pub fn scan(token: []const u8) ?struct { kind: Kind, len: usize } {
    if (token.len == 0) return null;
    var len = token.len - std.mem.countScalar(u8, token, '_');
    var at: usize = 0;
    // A sign is allowed on decimals and on inf and nan, not after a prefix.
    if (token[0] == '+' or token[0] == '-') {
        if (token[0] == '+') len -= 1;
        at = 1;
    }
    const body = token[at..];
    if (std.mem.eql(u8, body, "inf") or std.mem.eql(u8, body, "nan")) return .{ .kind = .float, .len = len };
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'o' or body[1] == 'b')) {
        if (at != 0) return null;
        const radix: u8 = switch (body[1]) {
            'x' => 16,
            'o' => 8,
            else => 2,
        };
        if (!digits(body[2..], radix)) return null;
        return .{ .kind = .integer, .len = len };
    }
    // The integer part: one zero, or digits not led by a zero.
    const fraction_at = std.mem.findAny(u8, body, ".eE") orelse body.len;
    const whole = body[0..fraction_at];
    if (!digits(whole, 10) or (whole.len > 1 and whole[0] == '0')) return null;
    if (fraction_at == body.len) return .{ .kind = .integer, .len = len };
    var rest = body[fraction_at..];
    if (rest[0] == '.') {
        const exponent_at = std.mem.findAny(u8, rest, "eE") orelse rest.len;
        if (!digits(rest[1..exponent_at], 10)) return null;
        rest = rest[exponent_at..];
    }
    if (rest.len != 0) {
        var exponent = rest[1..];
        if (exponent.len != 0 and (exponent[0] == '+' or exponent[0] == '-')) exponent = exponent[1..];
        if (!digits(exponent, 10)) return null;
    }
    return .{ .kind = .float, .len = len };
}

/// One or more digits of `radix`, an underscore only between two of them.
fn digits(bytes: []const u8, radix: u8) bool {
    if (bytes.len == 0 or bytes[0] == '_' or bytes[bytes.len - 1] == '_') return false;
    var previous: u8 = 0;
    for (bytes) |byte| {
        if (byte == '_') {
            if (previous == '_') return false;
        } else if (std.fmt.charToDigit(byte, radix)) |_| {} else |_| return false;
        previous = byte;
    }
    return true;
}

/// `token`'s normal spelling into `out`, which is `scan`'s length.
pub fn normalize(token: []const u8, out: []u8) void {
    var n: usize = 0;
    for (token, 0..) |byte, i| {
        if (byte == '_' or (i == 0 and byte == '+')) continue;
        out[n] = byte;
        n += 1;
    }
    std.debug.assert(n == out.len);
}

/// A normal spelling's integer, or null for one that is not an integer's or
/// is out of the signed 64-bit range.
pub fn integerValue(spelling: []const u8) ?i64 {
    if (spelling.len > 2 and spelling[0] == '0') switch (spelling[1]) {
        'x', 'o', 'b' => {
            const radix: u8 = switch (spelling[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            for (spelling[2..]) |byte| _ = std.fmt.charToDigit(byte, radix) catch return null;
            return std.fmt.parseInt(i64, spelling[2..], radix) catch null;
        },
        else => {},
    };
    const unsigned = if (spelling.len > 0 and spelling[0] == '-') spelling[1..] else spelling;
    if (unsigned.len == 0 or (unsigned.len > 1 and unsigned[0] == '0')) return null;
    for (unsigned) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(i64, spelling, 10) catch null;
}

/// Whether a normal spelling is a float's.
fn isFloat(spelling: []const u8) bool {
    if (spelling.len == 0 or spelling[0] == '+' or std.mem.findScalar(u8, spelling, '_') != null) return false;
    const s = scan(spelling) orelse return false;
    return s.kind == .float;
}

/// A normal spelling as a `T`: an integer's, checked against `T`.
pub fn parseInteger(comptime T: type, spelling: []const u8, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    const value = integerValue(spelling) orelse {
        // A float is no integer; anything else is no number of TOML's.
        return if (isFloat(spelling)) error.UnexpectedType else error.SyntaxError;
    };
    return std.math.cast(T, value) orelse error.NumberOutOfRange;
}

/// A normal spelling as a `T`: a float's, rounded once from its decimal
/// digits, or an integer's, exact or refused when `exact` asks.
pub fn parseFloat(comptime T: type, spelling: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    const negative = spelling.len > 0 and spelling[0] == '-';
    const body = if (negative) spelling[1..] else spelling;
    if (std.mem.eql(u8, body, "inf")) return if (negative) -std.math.inf(T) else std.math.inf(T);
    if (std.mem.eql(u8, body, "nan")) return if (negative) -std.math.nan(T) else std.math.nan(T);
    if (integerValue(spelling)) |value| {
        const result: T = @floatFromInt(value);
        if (!std.math.isFinite(result)) return error.NumberOutOfRange;
        if (exact and (@abs(result) >= 0x1p63 or @as(i64, @intFromFloat(result)) != value)) return error.InexactNumber;
        return result;
    }
    if (!isFloat(spelling)) return error.SyntaxError;
    // A decimal float's normal spelling is a JSON number.
    return json.floating(T, spelling, exact, c);
}

test "the grammar, and each spelling's normal form" {
    const valid = [_]struct { []const u8, Kind, []const u8 }{
        .{ "+99", .integer, "99" },            .{ "-17", .integer, "-17" },
        .{ "5_349_221", .integer, "5349221" }, .{ "0xdead_beef", .integer, "0xdeadbeef" },
        .{ "0o755", .integer, "0o755" },       .{ "0b1101_0110", .integer, "0b11010110" },
        .{ "+1.0", .float, "1.0" },            .{ "5e+22", .float, "5e+22" },
        .{ "-2E-2", .float, "-2E-2" },         .{ "224_617.445_991_228", .float, "224617.445991228" },
        .{ "+inf", .float, "inf" },            .{ "-nan", .float, "-nan" },
        .{ "1e06", .float, "1e06" },           .{ "-0", .integer, "-0" },
    };
    for (valid) |case| {
        const s = scan(case[0]).?;
        try std.testing.expectEqual(case[1], s.kind);
        var buffer: [32]u8 = undefined;
        normalize(case[0], buffer[0..s.len]);
        try std.testing.expectEqualStrings(case[2], buffer[0..s.len]);
    }
    for ([_][]const u8{ ".7", "7.", "3.e+20", "01", "1__0", "_1", "1_", "+0x1", "0x", "0b2", "1e", "1.0e", "inf_", "+-1", "Inf", "0X1", "1e1.5", "-0x1" }) |token|
        try std.testing.expectEqual(null, scan(token));
}

test "a spelling as an integer and as a float" {
    var c: core.Context = .init(std.testing.allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(i64, 0xdeadbeef), try parseInteger(i64, "0xdeadbeef", &c));
    try std.testing.expectEqual(std.math.minInt(i64), try parseInteger(i64, "-9223372036854775808", &c));
    try std.testing.expectError(error.NumberOutOfRange, parseInteger(u8, "256", &c));
    try std.testing.expectError(error.UnexpectedType, parseInteger(i64, "1.5", &c));
    try std.testing.expectError(error.SyntaxError, parseInteger(i64, "9223372036854775808", &c));
    try std.testing.expectEqual(@as(f64, 1.5e3), try parseFloat(f64, "1.5e3", false, &c));
    try std.testing.expectEqual(@as(f32, 0.1), try parseFloat(f32, "0.1", false, &c));
    try std.testing.expectEqual(@as(f64, 255), try parseFloat(f64, "0xff", true, &c));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-inf", false, &c)));
    try std.testing.expect(std.math.signbit(try parseFloat(f64, "-nan", false, &c)));
    try std.testing.expectError(error.InexactNumber, parseFloat(f32, "16777217", true, &c));
}
