//! A JSON number, or a string holding one, as an integer of any width: the
//! answer `std.json` gives, and an answer where it has none.
//!
//! `std.json` in Zig 0.16.0 reads a number written with a fraction or an
//! exponent into an integer through an `f128`, checks it against the type's
//! largest value converted to `f128`, and then casts it through an `i128`.
//! Two inputs pass the check and fail the cast, and a failed cast is a
//! panic in a safe build and undefined behaviour in a fast one:
//!
//! - a value at or past 2^127, whatever the type: `1.8e38` into a `u128`;
//! - the type's largest value rounded up, where `f128` cannot hold it:
//!   2^127 into an `i128`, 2^120 into a `u120`.
//!
//! A line is input, and a line must never take the process down. Here the
//! bounds are the exact powers of two past each end of the type's range,
//! and the cast is straight to the type, so every whole number in range is
//! that number and every other one is `error.Overflow`. Wherever `std.json`
//! answers, the answer is the same.

const std = @import("std");

pub const Error = error{ InvalidCharacter, Overflow, InvalidNumber };

/// `slice` — a JSON number token, or the contents of a string read as one —
/// as a `T`.
pub fn fromSlice(comptime T: type, slice: []const u8) Error!T {
    const info = @typeInfo(T).int;
    if (comptime info.bits <= 64) {
        if (slice.len != 0 and slice[0] != '-') {
            var result: u64 = 0;
            var past = false;
            const limit: u64 = @intCast(std.math.maxInt(T));
            for (slice) |c| {
                if (c < '0' or c > '9') break;
                const decimal = c - '0';
                // A type whose largest value is one digit long overflows on
                // its first. Past the type, the rest must still be digits
                // for the answer to be `Overflow` rather than `parseInt`'s.
                if (result > limit / 10 or
                    (result == limit / 10 and decimal > limit % 10)) past = true;
                result = result *% 10 +% decimal;
            } else return if (past) error.Overflow else @intCast(result);
        }
    } else if (comptime info.bits <= 128) {
        if (wide(T, slice)) |answer| return answer;
    }
    if (std.json.isNumberFormattedLikeAnInteger(slice)) return std.fmt.parseInt(T, slice, 10);
    return fromFloat(T, try std.fmt.parseFloat(f128, slice));
}

/// Plain digits, with a minus or without, read into a type of 65 to 128
/// bits without `std.fmt.parseInt`'s generality: nineteen digits at a time
/// in 64 bits, and one 128-bit multiply to put two runs together. Null for
/// anything else, which `parseInt` then answers: an underscore, a plus
/// sign, an empty string, more than 39 digits.
fn wide(comptime T: type, slice: []const u8) ?Error!T {
    const negative = slice.len != 0 and slice[0] == '-';
    const digits = slice[@intFromBool(negative)..];
    if (digits.len == 0 or digits.len > 39) return null;
    const magnitude: u128 = if (digits.len <= 19)
        run(digits) orelse return null
    else blk: {
        const split = digits.len - 19;
        const low = run(digits[split..]) orelse return null;
        if (split <= 19) {
            const high = run(digits[0..split]) orelse return null;
            break :blk @as(u128, high) * 10_000_000_000_000_000_000 + low;
        }
        // 39 digits: the first, then 19 and 19.
        const middle = run(digits[1..split]) orelse return null;
        const top = run(digits[0..1]) orelse return null;
        const below = @as(u128, middle) * 10_000_000_000_000_000_000 + low;
        const scaled = @mulWithOverflow(@as(u128, top), 100_000_000_000_000_000_000_000_000_000_000_000_000);
        const sum = @addWithOverflow(scaled[0], below);
        if (scaled[1] != 0 or sum[1] != 0) return error.Overflow;
        break :blk sum[0];
    };
    const signed: i129 = if (negative) -@as(i129, magnitude) else magnitude;
    return std.math.cast(T, signed) orelse error.Overflow;
}

/// Up to nineteen decimal digits as a `u64`; null if any byte is not one.
inline fn run(digits: []const u8) ?u64 {
    var n: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// A whole `float` as a `T`, or `error.Overflow` outside `T`'s range, which
/// is checked against the exact powers of two past each end of it.
pub fn fromFloat(comptime T: type, float: f128) Error!T {
    if (!std.math.isFinite(float)) return error.Overflow;
    if (@round(float) != float) return error.InvalidNumber;
    const info = @typeInfo(T).int;
    if (comptime info.bits == 0) return if (float == 0) 0 else error.Overflow;
    const magnitude_bits = if (info.signedness == .signed) info.bits - 1 else info.bits;
    // A power of two, so exact; infinite for a type wider than `f128`
    // reaches, which every finite value is then below.
    const past: f128 = comptime std.math.ldexp(@as(f128, 1), magnitude_bits);
    if (float >= past) return error.Overflow;
    if (info.signedness == .signed) {
        if (float < -past) return error.Overflow;
    } else if (float < 0) return error.Overflow;
    if (comptime info.bits <= 128) return @intFromFloat(float);
    // The compiler converts a float to at most 128 bits. Below 2^127 that
    // is the whole of it; above, a whole `f128` is its 113-bit significand
    // shifted left.
    if (@abs(float) < 0x1p127) return @intCast(@as(i128, @intFromFloat(float)));
    const unsigned_type = @Int(.unsigned, info.bits);
    const split = std.math.frexp(@abs(float));
    const significand: u128 = @intFromFloat(std.math.ldexp(split.significand, 113));
    const magnitude = @as(unsigned_type, significand) << @intCast(split.exponent - 113);
    if (float < 0) return @bitCast(0 -% magnitude);
    return @intCast(magnitude);
}

//=========================================================================
// Tests. The differential property over whole lines is in `strand_test.zig`.
//=========================================================================

const testing = std.testing;

test "a whole number std.json cannot cast is read as the number it is" {
    // Each of these panics in `std.json`'s `sliceToInt`.
    try testing.expectEqual(@as(u128, 180_000_000_000_000_000_000_000_000_000_000_000_000), try fromSlice(u128, "1.8e38"));
    try testing.expectEqual(@as(u128, 1 << 127), try fromSlice(u128, "1.7014118346046923173168730371588410572e38"));
    try testing.expectEqual(@as(u256, 1 << 200), try fromSlice(u256, "1.606938044258990275541962092341162602522202993782792835301376e60"));
    // And these are past the type: the largest value rounded up.
    try testing.expectError(error.Overflow, fromSlice(u128, "3.402823669209384634633746074317682114555e38"));
    try testing.expectError(error.Overflow, fromSlice(i128, "1.7014118346046923173168730371588410572e38"));
    try testing.expectError(error.Overflow, fromSlice(u120, "1.329227995784915872903807060280344576e36"));
    try testing.expectError(error.Overflow, fromSlice(u256, "1.2e77"));
    try testing.expectError(error.Overflow, fromSlice(u128, "1e5000"));
    try testing.expectError(error.Overflow, fromSlice(i128, "-1e5000"));
    // The bottom of a signed range is exact, and is read.
    try testing.expectEqual(@as(i128, std.math.minInt(i128)), try fromSlice(i128, "-1.7014118346046923173168730371588410572e38"));
    try testing.expectEqual(@as(u8, 0), try fromSlice(u8, "-0.0"));
    try testing.expectError(error.InvalidNumber, fromSlice(u128, "2.5"));
}

test "wherever std.json answers, the answer is the same" {
    var prng: std.Random.DefaultPrng = .init(0x1a7_5eed);
    const random = prng.random();
    var buffer: [64]u8 = undefined;
    const fixed = [_][]const u8{
        "0",                    "-0",                   "00",                   "007",                  "-",                                       "",                                        "+1",                                       "1_000",                                    "0x10",                                      "1e2",   "1.0", "-1",    "1x",
        "18446744073709551615", "18446744073709551616", "-9223372036854775808", "-9223372036854775809", "340282366920938463463374607431768211455", "340282366920938463463374607431768211456", "-170141183460469231731687303715884105728", "-170141183460469231731687303715884105729", "99999999999999999999999999999999999999999", "1.5e3", "2.5", "1e999", "-1e999",
        "1e-3",
    };
    for (0..20_000) |i| {
        const text = if (i < fixed.len) fixed[i] else switch (random.uintLessThan(u8, 4)) {
            0 => try std.mem.print(&buffer, "{d}", .{random.int(i128) >> random.int(u7)}),
            1 => try std.mem.print(&buffer, "{d}", .{random.int(u128) >> random.int(u7)}),
            2 => try std.mem.print(&buffer, "{d}e{d}", .{ random.int(u32), random.uintLessThan(u8, 30) }),
            else => try std.mem.print(&buffer, "-{d}.{d}e{d}", .{ random.int(u8), random.int(u8), random.uintLessThan(u8, 40) }),
        };
        inline for (.{ u0, u1, i1, u8, i8, u32, i32, u64, i64, u65, i65, u100, i100, u128, i128 }) |Int| {
            if (!stdPanics(Int, text)) {
                const theirs = stdSliceToInt(Int, text);
                const ours = fromSlice(Int, text);
                errdefer std.debug.print("{s} as {s}\n", .{ text, @typeName(Int) });
                if (theirs) |value| {
                    try testing.expectEqual(value, try ours);
                } else |err| try testing.expectError(err, ours);
            }
        }
    }
}

/// `std.json`'s `sliceToInt` (private there), for the test to hold this to.
fn stdSliceToInt(comptime T: type, slice: []const u8) !T {
    const Holder = struct { n: T };
    var buffer: [128]u8 = undefined;
    std.debug.assert(slice.len <= buffer.len - 8);
    // unreachable: the test bounds slice length below the fixed buffer capacity minus the eight envelope bytes.
    const line = std.mem.print(&buffer, "{{\"n\":\"{s}\"}}", .{slice}) catch unreachable;
    var memory: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const parsed = try std.json.parseFromSliceLeaky(Holder, fixed.allocator(), line, .{});
    return parsed.n;
}

/// Whether `sliceToInt(T, slice)` reaches its cast with a value it cannot
/// hold: whole, in the range its check allows, and not an `i128`.
fn stdPanics(comptime T: type, slice: []const u8) bool {
    if (std.json.isNumberFormattedLikeAnInteger(slice)) return false;
    const float = std.fmt.parseFloat(f128, slice) catch return false;
    if (@round(float) != float) return false;
    if (float > @as(f128, @floatFromInt(std.math.maxInt(T)))) return false;
    if (float < @as(f128, @floatFromInt(std.math.minInt(T)))) return false;
    const past_i128 = comptime std.math.ldexp(@as(f128, 1), 127);
    if (float >= past_i128 or float < -past_i128) return true;
    return std.math.cast(T, @as(i128, @intFromFloat(float))) == null;
}
