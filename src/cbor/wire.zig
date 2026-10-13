//! The bytes of CBOR (RFC 8949): a data item's head (its major type and its
//! argument), the shortest head for an argument, and half-precision floats.
const std = @import("std");
const core = @import("../core.zig");

pub const Major = enum(u3) { unsigned, negative, bytes, text, array, map, tag, simple };

/// An item's initial byte and argument.
pub const Head = struct {
    major: Major,
    /// The low five bits of the initial byte.
    info: u5,
    /// The argument; for major 7, the simple value or the float's bits.
    argument: u64,
    /// The head's length in bytes.
    len: usize,
    /// An indefinite length (info 31): for major 7, a break.
    indefinite: bool,
};

/// The head at `at`. A head that runs past the input, reserved additional
/// information (28 to 30), an indefinite length on an integer or a tag, and a
/// simple value under 32 written in two bytes are not well-formed.
pub fn head(bytes: []const u8, at: usize) error{SyntaxError}!Head {
    if (at >= bytes.len) return error.SyntaxError;
    const initial = bytes[at];
    const major: Major = @fromBackingInt(@intCast(initial >> 5));
    const info: u5 = @truncate(initial);
    var h: Head = .{ .major = major, .info = info, .argument = info, .len = 1, .indefinite = false };
    switch (info) {
        0...23 => {},
        24...27 => {
            const n = @as(usize, 1) << @intCast(info - 24);
            if (bytes.len - at - 1 < n) return error.SyntaxError;
            var argument: u64 = 0;
            for (bytes[at + 1 ..][0..n]) |b| argument = (argument << 8) | b;
            h.argument = argument;
            h.len = 1 + n;
            if (major == .simple and info == 24 and argument < 32) return error.SyntaxError;
        },
        28...30 => return error.SyntaxError,
        31 => switch (major) {
            .bytes, .text, .array, .map, .simple => h.indefinite = true,
            .unsigned, .negative, .tag => return error.SyntaxError,
        },
    }
    return h;
}

/// The shortest head for `argument`, into `buffer`.
pub fn encodeHead(buffer: *[9]u8, major: Major, argument: u64) []const u8 {
    const m: u8 = @as(u8, @backingInt(major)) << 5;
    if (argument < 24) {
        buffer[0] = m | @as(u8, @intCast(argument));
        return buffer[0..1];
    }
    const n: usize, const info: u8 = if (argument <= 0xff) .{ 1, 24 } else if (argument <= 0xffff) .{ 2, 25 } else if (argument <= 0xffff_ffff) .{ 4, 26 } else .{ 8, 27 };
    buffer[0] = m | info;
    var rest = argument;
    var i = n;
    while (i > 0) : (i -= 1) {
        buffer[i] = @truncate(rest);
        rest >>= 8;
    }
    return buffer[0 .. 1 + n];
}

/// The float of a head with major 7 and info 25, 26 or 27, as an event
/// holds it: a NaN's payload kept bit for bit.
pub fn float(h: Head) f128 {
    return switch (h.info) {
        25 => core.widenFloat(@as(f16, @bitCast(@as(u16, @truncate(h.argument))))),
        26 => core.widenFloat(@as(f32, @bitCast(@as(u32, @truncate(h.argument))))),
        else => core.widenFloat(@as(f64, @bitCast(h.argument))),
    };
}

/// `value` in the fewest bytes that hold it exactly (RFC 8949 4.2.2's
/// preferred serialization): half, single or double precision; a NaN as
/// the half-precision quiet NaN.
pub fn encodeFloat(buffer: *[9]u8, value: f64) []const u8 {
    if (std.math.isNan(value)) {
        buffer[0..3].* = .{ 0xf9, 0x7e, 0x00 };
        return buffer[0..3];
    }
    const half: f16 = @floatCast(value);
    if (@as(f64, half) == value) {
        buffer[0] = 0xf9;
        std.mem.writeInt(u16, buffer[1..3], @bitCast(half), .big);
        return buffer[0..3];
    }
    const single: f32 = @floatCast(value);
    if (@as(f64, single) == value) {
        buffer[0] = 0xfa;
        std.mem.writeInt(u32, buffer[1..5], @bitCast(single), .big);
        return buffer[0..5];
    }
    buffer[0] = 0xfb;
    std.mem.writeInt(u64, buffer[1..9], @bitCast(value), .big);
    return buffer[0..9];
}

test "heads and floats as RFC 8949 writes them" {
    var buffer: [9]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x17}, encodeHead(&buffer, .unsigned, 23));
    try std.testing.expectEqualSlices(u8, &.{ 0x18, 0x18 }, encodeHead(&buffer, .unsigned, 24));
    try std.testing.expectEqualSlices(u8, &.{ 0x39, 0x03, 0xe7 }, encodeHead(&buffer, .negative, 999));
    try std.testing.expectEqualSlices(u8, &.{ 0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, encodeHead(&buffer, .unsigned, std.math.maxInt(u64)));
    try std.testing.expectEqualSlices(u8, &.{ 0xf9, 0x3e, 0x00 }, encodeFloat(&buffer, 1.5));
    try std.testing.expectEqualSlices(u8, &.{ 0xfa, 0x47, 0xc3, 0x50, 0x00 }, encodeFloat(&buffer, 100000.0));
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a }, encodeFloat(&buffer, 1.1));
    try std.testing.expectEqualSlices(u8, &.{ 0xf9, 0x80, 0x00 }, encodeFloat(&buffer, -0.0));
    try std.testing.expectEqualSlices(u8, &.{ 0xf9, 0x7c, 0x00 }, encodeFloat(&buffer, std.math.inf(f64)));
    try std.testing.expectError(error.SyntaxError, head(&.{0x1c}, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{0x1f}, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{ 0xf8, 0x18 }, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{ 0x19, 0x01 }, 0));
}
