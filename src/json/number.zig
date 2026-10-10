//! Exact decimal integer conversion, with no floating intermediate.
const std = @import("std");
const core = @import("../core.zig");
pub fn integer(comptime T: type, text: []const u8, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(text.len);
    const negative = text[0] == '-';
    const start = @intFromBool(negative);
    const exponent_at = std.mem.findAny(u8, text, "eE") orelse text.len;
    const dot = std.mem.findScalar(u8, text[0..exponent_at], '.');
    const fraction = if (dot) |at| exponent_at - at - 1 else 0;
    var exponent: i64 = 0;
    if (exponent_at != text.len) {
        exponent = std.fmt.parseInt(i64, text[exponent_at + 1 ..], 10) catch return error.NumberOutOfRange;
    }
    const shift = std.math.sub(i64, exponent, std.math.cast(i64, fraction) orelse return error.NumberOutOfRange) catch return error.NumberOutOfRange;
    const digits = exponent_at - start - @intFromBool(dot != null);
    var trailing: usize = 0;
    var at = exponent_at;
    while (at > start) {
        at -= 1;
        if (text[at] == '.') continue;
        if (text[at] != '0') break;
        trailing += 1;
    }
    if (trailing == digits) return 0;
    const trim: usize = if (shift < 0) std.math.cast(usize, std.math.negate(shift) catch return error.NumberOutOfRange) orelse return error.NumberOutOfRange else 0;
    if (trim > trailing) return error.NumberOutOfRange;
    const magnitude_type = @Int(.unsigned, @max(@typeInfo(T).int.bits, 1));
    var magnitude: magnitude_type = 0;
    var seen: usize = 0;
    for (text[start..exponent_at]) |byte| {
        if (byte == '.') continue;
        seen += 1;
        if (seen > digits - trim) break;
        magnitude = std.math.mul(magnitude_type, magnitude, 10) catch return error.NumberOutOfRange;
        magnitude = std.math.add(magnitude_type, magnitude, std.math.cast(magnitude_type, byte - '0') orelse return error.NumberOutOfRange) catch return error.NumberOutOfRange;
    }
    if (shift > 0) {
        if (shift > @typeInfo(T).int.bits) return error.NumberOutOfRange;
        var n: i64 = 0;
        while (n < shift) : (n += 1) magnitude = std.math.mul(magnitude_type, magnitude, 10) catch return error.NumberOutOfRange;
    }
    if (@typeInfo(T).int.signedness == .unsigned) {
        if (negative or magnitude > std.math.maxInt(T)) return error.NumberOutOfRange;
        return @intCast(magnitude); // safe: magnitude checked against T.
    }
    if (negative) {
        const min_magnitude: magnitude_type = @as(magnitude_type, 1) << (@typeInfo(T).int.bits - 1);
        if (magnitude > min_magnitude) return error.NumberOutOfRange;
        if (magnitude == min_magnitude) return std.math.minInt(T);
        return -@as(T, @intCast(magnitude)); // safe: below signed minimum magnitude.
    }
    return std.math.cast(T, magnitude) orelse error.NumberOutOfRange;
}
pub fn floating(comptime T: type, text: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(text.len);
    const value = std.fmt.parseFloat(T, text) catch return error.NumberOutOfRange;
    if (!std.math.isFinite(value)) return error.NumberOutOfRange;
    if (exact and !try isExact(T, value, text, c)) return error.InexactNumber;
    return value;
}

fn isExact(comptime T: type, value: T, text: []const u8, c: *core.Context) core.DecodeError!bool {
    const Big = std.math.big.int.Managed;
    const sign = @intFromBool(text[0] == '-');
    const end = std.mem.findAny(u8, text, "eE") orelse text.len;
    const dot = std.mem.findScalar(u8, text[0..end], '.');
    const fraction = if (dot) |at| end - at - 1 else 0;
    const digits = try c.alloc(u8, end - sign - @intFromBool(dot != null));
    var n: usize = 0;
    for (text[sign..end]) |byte| if (byte != '.') {
        digits[n] = byte;
        n += 1;
    };
    if (std.mem.allEqual(u8, digits, '0')) return value == 0;
    if (value == 0) return false;
    const exponent: i64 = if (end == text.len) 0 else std.fmt.parseInt(i64, text[end + 1 ..], 10) catch return false;
    const scale = std.math.sub(i64, exponent, std.math.cast(i64, fraction) orelse return false) catch return false;
    const scale_abs = std.math.cast(usize, @abs(scale)) orelse return false;
    // A finite IEEE value cannot need more decimal powers than its binary
    // exponent range plus the supplied coefficient. Refuse before big work.
    if (scale_abs > std.math.floatExponentMax(T) + text.len + std.math.floatMantissaBits(T)) return false;
    try c.chargeWork(std.math.mul(usize, scale_abs + digits.len, scale_abs + digits.len) catch return error.WorkLimit);
    const allocator = c.allocator();
    var decimal = try Big.init(allocator);
    defer decimal.deinit();
    decimal.setString(10, digits) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.SyntaxError;
    const parts = std.math.frexp(@abs(value));
    const precision = std.math.floatFractionalBits(T) + 1;
    const mantissa: u128 = @intFromFloat(std.math.ldexp(@as(f128, parts.significand), precision)); // safe: significand is finite and scaled to at most 113 bits.
    var binary = try Big.initSet(allocator, mantissa);
    defer binary.deinit();
    var ten = try Big.initSet(allocator, 10);
    defer ten.deinit();
    var power = try Big.init(allocator);
    defer power.deinit();
    const power_count = std.math.cast(u32, scale_abs) orelse return false;
    try power.pow(&ten, power_count);
    if (scale >= 0) try decimal.mul(&decimal, &power) else try binary.mul(&binary, &power);
    const binary_scale = parts.exponent - precision;
    if (binary_scale >= 0) try binary.shiftLeft(&binary, @intCast(binary_scale)) // safe: nonnegative checked exponent.
    else try decimal.shiftLeft(&decimal, @intCast(-binary_scale)); // safe: negative exponent magnitude is within IEEE range.
    return decimal.eqlAbs(binary);
}

/// A complete numeric lexeme, with no surrounding whitespace or other value.
pub fn valid(bytes: []const u8) bool {
    var at: usize = 0;
    if (bytes.len == 0) return false;
    if (bytes[at] == '-') at += 1;
    if (at == bytes.len) return false;
    if (bytes[at] == '0') at += 1 else {
        if (bytes[at] < '1' or bytes[at] > '9') return false;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
    }
    if (at < bytes.len and bytes[at] == '.') {
        at += 1;
        const start = at;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
        if (at == start) return false;
    }
    if (at < bytes.len and (bytes[at] == 'e' or bytes[at] == 'E')) {
        at += 1;
        if (at < bytes.len and (bytes[at] == '+' or bytes[at] == '-')) at += 1;
        const start = at;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
        if (at == start) return false;
    }
    return at == bytes.len;
}
