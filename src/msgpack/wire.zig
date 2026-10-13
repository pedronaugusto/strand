//! The bytes of MessagePack: a value's header (its family, its argument and
//! the header's length), and the smallest header for each value, as the
//! specification asks a serializer to write.
const std = @import("std");
const core = @import("../core.zig");

pub const Family = enum { nil, boolean, unsigned, signed, float32, float64, str, bin, array, map, ext };

/// A value's header.
pub const Head = struct {
    family: Family,
    /// An integer's value (a signed one's bits), a boolean's 0 or 1, a
    /// float's bits, or the count of a string's bytes, an array's items, a
    /// map's entries or an extension's data bytes.
    argument: u64,
    /// An extension's type.
    ext_type: i8 = 0,
    /// The header's length in bytes, an extension's type included.
    len: usize,
};

/// The header at `at`. A header that runs past the input and the byte the
/// specification never uses (0xc1) are not MessagePack.
pub fn head(bytes: []const u8, at: usize) error{SyntaxError}!Head {
    if (at >= bytes.len) return error.SyntaxError;
    const b = bytes[at];
    return switch (b) {
        0x00...0x7f => .{ .family = .unsigned, .argument = b, .len = 1 },
        0x80...0x8f => .{ .family = .map, .argument = b & 0x0f, .len = 1 },
        0x90...0x9f => .{ .family = .array, .argument = b & 0x0f, .len = 1 },
        0xa0...0xbf => .{ .family = .str, .argument = b & 0x1f, .len = 1 },
        0xc0 => .{ .family = .nil, .argument = 0, .len = 1 },
        0xc1 => error.SyntaxError,
        0xc2, 0xc3 => .{ .family = .boolean, .argument = b - 0xc2, .len = 1 },
        0xc4, 0xc5, 0xc6 => sized(bytes, at, .bin, b - 0xc4),
        0xc7, 0xc8, 0xc9 => {
            var h = try sized(bytes, at, .ext, b - 0xc7);
            if (h.len >= bytes.len - at) return error.SyntaxError;
            h.ext_type = @bitCast(bytes[at + h.len]);
            h.len += 1;
            return h;
        },
        0xca => fixed(bytes, at, .float32, 4),
        0xcb => fixed(bytes, at, .float64, 8),
        0xcc, 0xcd, 0xce, 0xcf => fixed(bytes, at, .unsigned, @as(usize, 1) << @intCast(b - 0xcc)),
        0xd0, 0xd1, 0xd2, 0xd3 => {
            const n = @as(usize, 1) << @intCast(b - 0xd0);
            var h = try fixed(bytes, at, .signed, n);
            // Sign-extended to 64 bits.
            const shift: u6 = @intCast(64 - 8 * n);
            h.argument = @bitCast(@as(i64, @bitCast(h.argument << shift)) >> shift);
            return h;
        },
        0xd4, 0xd5, 0xd6, 0xd7, 0xd8 => {
            if (bytes.len - at < 2) return error.SyntaxError;
            return .{ .family = .ext, .argument = @as(u64, 1) << @intCast(b - 0xd4), .ext_type = @bitCast(bytes[at + 1]), .len = 2 };
        },
        0xd9, 0xda, 0xdb => sized(bytes, at, .str, b - 0xd9),
        0xdc, 0xdd => sized(bytes, at, .array, b - 0xdc + 1),
        0xde, 0xdf => sized(bytes, at, .map, b - 0xde + 1),
        0xe0...0xff => .{ .family = .signed, .argument = @bitCast(@as(i64, @as(i8, @bitCast(b)))), .len = 1 },
    };
}
/// A header whose argument is the `n` big-endian bytes after its first.
fn fixed(bytes: []const u8, at: usize, family: Family, n: usize) error{SyntaxError}!Head {
    if (bytes.len - at - 1 < n) return error.SyntaxError;
    var argument: u64 = 0;
    for (bytes[at + 1 ..][0..n]) |x| argument = (argument << 8) | x;
    return .{ .family = family, .argument = argument, .len = 1 + n };
}
/// A length of 1, 2 or 4 bytes, by `width` 0, 1 or 2.
fn sized(bytes: []const u8, at: usize, family: Family, width: u8) error{SyntaxError}!Head {
    return fixed(bytes, at, family, @as(usize, 1) << @intCast(width));
}

/// The smallest header for a non-negative integer.
pub fn encodeUnsigned(buffer: *[9]u8, value: u64) []const u8 {
    if (value <= 0x7f) {
        buffer[0] = @intCast(value);
        return buffer[0..1];
    }
    return big(buffer, if (value <= 0xff) 0xcc else if (value <= 0xffff) 0xcd else if (value <= 0xffff_ffff) 0xce else 0xcf, value);
}
/// The smallest header for an integer: a negative one in the signed family,
/// any other as `encodeUnsigned` writes it.
pub fn encodeSigned(buffer: *[9]u8, value: i64) []const u8 {
    if (value >= 0) return encodeUnsigned(buffer, @intCast(value));
    if (value >= -32) {
        buffer[0] = @bitCast(@as(i8, @intCast(value)));
        return buffer[0..1];
    }
    const marker: u8 = if (value >= std.math.minInt(i8)) 0xd0 else if (value >= std.math.minInt(i16)) 0xd1 else if (value >= std.math.minInt(i32)) 0xd2 else 0xd3;
    return big(buffer, marker, @bitCast(value));
}
/// `marker`, then `value`'s low bytes, as many as the marker's family holds.
fn big(buffer: *[9]u8, marker: u8, value: u64) []const u8 {
    const n: usize = @as(usize, 1) << @intCast(marker & 0x03);
    buffer[0] = marker;
    var rest = value;
    var i = n;
    while (i > 0) : (i -= 1) {
        buffer[i] = @truncate(rest);
        rest >>= 8;
    }
    return buffer[0 .. 1 + n];
}

/// `value` as float 32 when that holds its bits exactly (a negative zero, an
/// infinity and a NaN's payload included), else as float 64: the smallest
/// format, as the specification asks.
pub fn encodeFloat(buffer: *[9]u8, value: f64) []const u8 {
    const wide = core.widenFloat(value);
    const single = core.narrowFloat(f32, wide);
    if (@as(u128, @bitCast(core.widenFloat(single))) == @as(u128, @bitCast(wide))) return encodeFloat32(buffer, single);
    buffer[0] = 0xcb;
    std.mem.writeInt(u64, buffer[1..9], @bitCast(value), .big);
    return buffer[0..9];
}
pub fn encodeFloat32(buffer: *[9]u8, value: f32) []const u8 {
    buffer[0] = 0xca;
    std.mem.writeInt(u32, buffer[1..5], @bitCast(value), .big);
    return buffer[0..5];
}

/// The smallest header for a string, binary, array or map of `n` bytes,
/// items or entries; none past 2^32 - 1.
pub fn encodeLength(buffer: *[9]u8, family: Family, n: u64) error{UnsupportedValue}![]const u8 {
    if (n > std.math.maxInt(u32)) return error.UnsupportedValue;
    const fix: ?struct { u8, u64 } = switch (family) {
        .str => .{ 0xa0, 31 },
        .array => .{ 0x90, 15 },
        .map => .{ 0x80, 15 },
        .bin => null,
        else => unreachable, // unreachable: the encoder names a family with a length
    };
    if (fix) |f| if (n <= f[1]) {
        buffer[0] = f[0] | @as(u8, @intCast(n));
        return buffer[0..1];
    };
    const markers: [3]u8 = switch (family) {
        .str => .{ 0xd9, 0xda, 0xdb },
        .bin => .{ 0xc4, 0xc5, 0xc6 },
        // An array and a map have no one-byte length.
        .array => .{ 0, 0xdc, 0xdd },
        .map => .{ 0, 0xde, 0xdf },
        else => unreachable, // unreachable: as above
    };
    if (n <= 0xff and markers[0] != 0) return lengthHeader(buffer, markers[0], 1, n);
    if (n <= 0xffff) return lengthHeader(buffer, markers[1], 2, n);
    return lengthHeader(buffer, markers[2], 4, n);
}
fn lengthHeader(buffer: *[9]u8, marker: u8, width: usize, n: u64) []const u8 {
    buffer[0] = marker;
    var rest = n;
    var i = width;
    while (i > 0) : (i -= 1) {
        buffer[i] = @truncate(rest);
        rest >>= 8;
    }
    return buffer[0 .. 1 + width];
}
/// The smallest header for an extension of type `ext_type` with `n` data
/// bytes: fixext for 1, 2, 4, 8 and 16 bytes, else ext 8, 16 or 32.
pub fn encodeExt(buffer: *[9]u8, ext_type: i8, n: u64) error{UnsupportedValue}![]const u8 {
    if (n > std.math.maxInt(u32)) return error.UnsupportedValue;
    const header: []const u8 = switch (n) {
        1 => markerOnly(buffer, 0xd4),
        2 => markerOnly(buffer, 0xd5),
        4 => markerOnly(buffer, 0xd6),
        8 => markerOnly(buffer, 0xd7),
        16 => markerOnly(buffer, 0xd8),
        else => if (n <= 0xff) lengthHeader(buffer, 0xc7, 1, n) else if (n <= 0xffff) lengthHeader(buffer, 0xc8, 2, n) else lengthHeader(buffer, 0xc9, 4, n),
    };
    buffer[header.len] = @bitCast(ext_type);
    return buffer[0 .. header.len + 1];
}
fn markerOnly(buffer: *[9]u8, marker: u8) []const u8 {
    buffer[0] = marker;
    return buffer[0..1];
}

test "the smallest header for each integer, float and length" {
    var buffer: [9]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x7f}, encodeUnsigned(&buffer, 127));
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0x80 }, encodeUnsigned(&buffer, 128));
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0x01, 0x00 }, encodeUnsigned(&buffer, 256));
    try std.testing.expectEqualSlices(u8, &.{ 0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, encodeUnsigned(&buffer, std.math.maxInt(u64)));
    try std.testing.expectEqualSlices(u8, &.{0xe0}, encodeSigned(&buffer, -32));
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0xdf }, encodeSigned(&buffer, -33));
    try std.testing.expectEqualSlices(u8, &.{ 0xd1, 0xff, 0x7f }, encodeSigned(&buffer, -129));
    try std.testing.expectEqualSlices(u8, &.{ 0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0 }, encodeSigned(&buffer, std.math.minInt(i64)));
    try std.testing.expectEqualSlices(u8, &.{ 0xca, 0x3f, 0x00, 0x00, 0x00 }, encodeFloat(&buffer, 0.5));
    try std.testing.expectEqualSlices(u8, &.{ 0xcb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a }, encodeFloat(&buffer, 1.1));
    try std.testing.expectEqualSlices(u8, &.{ 0xca, 0x80, 0x00, 0x00, 0x00 }, encodeFloat(&buffer, -0.0));
    try std.testing.expectEqualSlices(u8, &.{0xbf}, try encodeLength(&buffer, .str, 31));
    try std.testing.expectEqualSlices(u8, &.{ 0xd9, 0x20 }, try encodeLength(&buffer, .str, 32));
    try std.testing.expectEqualSlices(u8, &.{ 0xc4, 0x00 }, try encodeLength(&buffer, .bin, 0));
    try std.testing.expectEqualSlices(u8, &.{ 0xdc, 0x00, 0x10 }, try encodeLength(&buffer, .array, 16));
    try std.testing.expectEqualSlices(u8, &.{ 0xdf, 0x00, 0x01, 0x00, 0x00 }, try encodeLength(&buffer, .map, 0x10000));
    try std.testing.expectError(error.UnsupportedValue, encodeLength(&buffer, .bin, 1 << 32));
    try std.testing.expectEqualSlices(u8, &.{ 0xd6, 0xff }, try encodeExt(&buffer, -1, 4));
    try std.testing.expectEqualSlices(u8, &.{ 0xc7, 0x0c, 0xff }, try encodeExt(&buffer, -1, 12));
    try std.testing.expectEqualSlices(u8, &.{ 0xc7, 0x00, 0x06 }, try encodeExt(&buffer, 6, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{0xc1}, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{ 0xcd, 0x01 }, 0));
    try std.testing.expectError(error.SyntaxError, head(&.{ 0xc7, 0x00 }, 0));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -2))), (try head(&.{ 0xd1, 0xff, 0xfe }, 0)).argument);
}
