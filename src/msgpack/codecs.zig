//! Extensions a type asks for by name: any extension with its type and data
//! kept, and the timestamp (type -1). An extension nobody asked for is
//! refused where a typed value is read.
const std = @import("std");

/// The tag number an extension's type travels under: the type sign-extended.
pub fn tagOf(ext_type: i8) u64 {
    return @bitCast(@as(i64, ext_type));
}
/// The extension type a tag number names, if it is one.
pub fn typeOf(number: u64) ?i8 {
    return std.math.cast(i8, @as(i64, @bitCast(number)));
}

/// Any extension: its type and its data, as they came.
pub const Ext = struct {
    type_id: i8,
    data: []const u8,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Ext {
        const type_id = typeOf(try access.tag()) orelse return error.UnexpectedType;
        return .{ .type_id = type_id, .data = try access.bytes(.prefer) };
    }
    pub fn strandSerialize(self: Ext, access: anytype) @TypeOf(access.*).Error!void {
        try access.tag(tagOf(self.type_id));
        try access.bytes(self.data);
    }
};

/// A point in time (extension type -1): seconds since 1970-01-01T00:00:00Z
/// and the nanoseconds after them, from 0 to 999 999 999. Written in the
/// smallest of the three forms that holds it: 32 bits of seconds, 30 of
/// nanoseconds beside 34 of seconds, or 32 and 64.
pub const Timestamp = struct {
    seconds: i64,
    nanoseconds: u32 = 0,

    pub const ext_type: i8 = -1;
    const max_nanoseconds = 999_999_999;

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Timestamp {
        if (try access.tag() != tagOf(ext_type)) return error.UnexpectedType;
        return decode(try access.bytes(.prefer)) orelse error.UnsupportedValue;
    }
    pub fn strandSerialize(self: Timestamp, access: anytype) @TypeOf(access.*).Error!void {
        var buffer: [12]u8 = undefined;
        const data = self.encode(&buffer) orelse return error.UnsupportedValue;
        try access.tag(tagOf(ext_type));
        try access.bytes(data);
    }

    /// The timestamp `data` holds, or null when it is no timestamp: a length
    /// other than 4, 8 or 12, or nanoseconds past 999 999 999.
    pub fn decode(data: []const u8) ?Timestamp {
        const t: Timestamp = switch (data.len) {
            4 => .{ .seconds = std.mem.readInt(u32, data[0..4], .big) },
            8 => blk: {
                const v = std.mem.readInt(u64, data[0..8], .big);
                break :blk .{ .seconds = @intCast(v & ((1 << 34) - 1)), .nanoseconds = @intCast(v >> 34) };
            },
            12 => .{ .nanoseconds = std.mem.readInt(u32, data[0..4], .big), .seconds = std.mem.readInt(i64, data[4..12], .big) },
            else => return null,
        };
        if (t.nanoseconds > max_nanoseconds) return null;
        return t;
    }
    /// The timestamp's data in its smallest form, or null for nanoseconds
    /// past 999 999 999.
    pub fn encode(self: Timestamp, buffer: *[12]u8) ?[]const u8 {
        if (self.nanoseconds > max_nanoseconds) return null;
        if (self.seconds >= 0 and self.seconds >> 34 == 0) {
            if (self.nanoseconds == 0 and self.seconds <= std.math.maxInt(u32)) {
                std.mem.writeInt(u32, buffer[0..4], @intCast(self.seconds), .big);
                return buffer[0..4];
            }
            std.mem.writeInt(u64, buffer[0..8], @as(u64, self.nanoseconds) << 34 | @as(u64, @intCast(self.seconds)), .big);
            return buffer[0..8];
        }
        std.mem.writeInt(u32, buffer[0..4], self.nanoseconds, .big);
        std.mem.writeInt(i64, buffer[4..12], self.seconds, .big);
        return buffer[0..12];
    }
};

test "a timestamp in each of its forms, and what is none" {
    var buffer: [12]u8 = undefined;
    const cases = [_]struct { t: Timestamp, len: usize }{
        .{ .t = .{ .seconds = 0 }, .len = 4 },
        .{ .t = .{ .seconds = std.math.maxInt(u32) }, .len = 4 },
        .{ .t = .{ .seconds = 1 << 32 }, .len = 8 },
        .{ .t = .{ .seconds = 0, .nanoseconds = 1 }, .len = 8 },
        .{ .t = .{ .seconds = (1 << 34) - 1, .nanoseconds = 999_999_999 }, .len = 8 },
        .{ .t = .{ .seconds = 1 << 34 }, .len = 12 },
        .{ .t = .{ .seconds = -1, .nanoseconds = 999_999_999 }, .len = 12 },
        .{ .t = .{ .seconds = std.math.minInt(i64) }, .len = 12 },
    };
    for (cases) |case| {
        const data = case.t.encode(&buffer).?;
        try std.testing.expectEqual(case.len, data.len);
        try std.testing.expectEqual(case.t, Timestamp.decode(data).?);
    }
    try std.testing.expectEqual(null, (Timestamp{ .seconds = 0, .nanoseconds = 1_000_000_000 }).encode(&buffer));
    try std.testing.expectEqual(null, Timestamp.decode(&.{ 0, 0, 0 }));
    // Nanoseconds of 2^30 - 1 in the 64-bit form.
    try std.testing.expectEqual(null, Timestamp.decode(&.{ 0xff, 0xff, 0xff, 0xfc, 0, 0, 0, 0 }));
    try std.testing.expectEqual(null, Timestamp.decode(&.{ 0x3b, 0x9a, 0xca, 0x00, 0, 0, 0, 0, 0, 0, 0, 0 }));
}
