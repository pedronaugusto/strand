//! S1 proof backend only. A tiny binary grammar, not a production format.
//! Each container ends explicitly; declared counts must match the actual payload.
const std = @import("std");
const core = @import("strand.core");
const core_decode = core;
pub const Format = enum { reference };
pub const Error = error{SyntaxError};
pub const capabilities: core.Capabilities = .{ .nested_optional = true, .max_integer_bits = 2040 };
input: []const u8,
position: usize = 0,
end_position: ?usize = null,
const Self = @This();
fn read(self: *Self, c: *core.Context, n: usize) core.DecodeError![]const u8 {
    @setRuntimeSafety(true);
    if (n > (self.end_position orelse self.input.len) - self.position) return error.SyntaxError;
    try c.input(n);
    const bytes = self.input[self.position..][0..n];
    self.position += n;
    return bytes;
}
pub fn next(self: *Self, c: *core.Context, _: core.Request) core.DecodeError!core.Event {
    const tag = (try self.read(c, 1))[0];
    return switch (tag) {
        0 => .end,
        1 => blk: {
            const value = (try self.read(c, 1))[0];
            if (value > 1) return error.SyntaxError;
            break :blk .{ .boolean = value != 0 };
        },
        2 => .{ .integer = .{ .magnitude = try self.read(c, 1) } },
        15, 17 => blk: {
            const len = (try self.read(c, 1))[0];
            if (len > c.limits.numeric_bytes) return error.LengthLimit;
            break :blk .{ .integer = .{ .negative = tag == 17, .magnitude = try self.read(c, len) } };
        },
        18 => blk: {
            if (16 > c.limits.numeric_bytes) return error.LengthLimit;
            const bits = std.mem.readInt(u128, (try self.read(c, 16))[0..16], .little);
            break :blk .{ .floating = @bitCast(bits) }; // safe: every u128 bit pattern is a valid f128 representation.
        },
        3, 4 => blk: {
            const len = (try self.read(c, 1))[0];
            const span: core.Span = .{ .bytes = try self.read(c, len), .lifetime = .borrowed };
            break :blk if (tag == 3) .{ .text = span } else .{ .bytes = span };
        },
        5 => .{ .begin = .{ .kind = .sequence, .len = (try self.read(c, 1))[0] } },
        6 => .{ .begin = .{ .kind = .record, .len = (try self.read(c, 1))[0] } },
        16 => blk: {
            const ordinal = (try self.read(c, 1))[0];
            if (ordinal > @backingInt(core.Kind.named_unit)) return error.SyntaxError;
            const kind: core.Kind = @fromBackingInt(@intCast(ordinal)); // safe: ordinal checked against the exhaustive contiguous Kind tags.
            const len = (try self.read(c, 1))[0];
            if ((kind == .some or kind == .newtype or kind == .variant) and len != 1) return error.SyntaxError;
            if (kind == .named_unit and len != 0) return error.SyntaxError;
            const name_len = (try self.read(c, 1))[0];
            break :blk .{ .begin = .{ .kind = kind, .name = try self.read(c, name_len), .len = len } };
        },
        12 => blk: {
            const len = (try self.read(c, 1))[0];
            break :blk .{ .begin = .{ .kind = .variant, .name = try self.read(c, len), .len = 1 } };
        },
        14 => blk: {
            const bytes = try self.read(c, 3);
            const value = std.mem.readInt(u24, bytes[0..3], .little);
            if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return error.InvalidUtf8;
            break :blk .{ .scalar = @intCast(value) }; // safe: Unicode scalar bound fits u21.
        },
        13 => .{ .begin = .{ .kind = .map, .len = (try self.read(c, 1))[0] } },
        10 => .{ .begin = .{ .kind = .sequence } },
        11 => .{ .begin = .{ .kind = .map } },
        7 => .none,
        8 => .unit,
        9 => .{ .integer = .{ .negative = true, .magnitude = try self.read(c, 1) } },
        else => error.SyntaxError,
    };
}
pub fn offset(self: *const Self) usize {
    return self.position;
}
pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
    return .{ .bytes = self.input[start..end], .lifetime = .borrowed };
}
pub fn replay(self: *const Self, start: usize, end: usize) Self {
    return .{ .input = self.input, .position = start, .end_position = end };
}
pub fn endInput(self: *Self, _: *core.Context) Error!void {
    if (self.position != (self.end_position orelse self.input.len)) return error.SyntaxError;
}

/// Fixed-buffer semantic writer. Backends meter encoded bytes before publication.
pub const Encoder = struct {
    buffer: []u8,
    used: usize = 0,
    pub const Format = Self.Format;
    pub const canonical = false;
    pub fn raw(self: *Encoder, payload: []const u8, c: *core.Context) core.EncodeError!void {
        try self.write(c, payload);
    }
    pub fn validateRaw(_: *Encoder, payload: []const u8, c: *core.Context) core.EncodeError!void {
        var backend: Self = .{ .input = payload };
        var cursor: core_decode.Cursor(Self) = .{ .backend = &backend, .context = c };
        cursor.skip() catch |err| switch (err) {
            error.InputLimit => return error.InputLimit,
            error.DepthLimit => return error.DepthLimit,
            error.ItemLimit => return error.ItemLimit,
            error.LengthLimit => return error.LengthLimit,
            error.AllocationLimit => return error.AllocationLimit,
            error.WorkLimit => return error.WorkLimit,
            else => return error.InvalidRaw,
        };
        backend.endInput(c) catch return error.InvalidRaw;
    }
    pub const Error = core.EncodeError;
    pub const capabilities: core.Capabilities = .{ .nested_optional = true, .max_integer_bits = 2040 };
    fn write(self: *Encoder, c: *core.Context, payload: []const u8) core.EncodeError!void {
        @setRuntimeSafety(true);
        try c.output(payload.len);
        if (payload.len > self.buffer.len - self.used) return error.OutputLimit;
        @memcpy(self.buffer[self.used..][0..payload.len], payload);
        self.used += payload.len;
    }
    pub fn scalar(self: *Encoder, value: u21, c: *core.Context) core.EncodeError!void {
        var encoded: [3]u8 = undefined;
        std.mem.writeInt(u24, &encoded, value, .little);
        try self.write(c, &.{14});
        try self.write(c, &encoded);
    }
    pub fn boolean(self: *Encoder, value: bool, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{ 1, @intFromBool(value) });
    }
    pub fn integer(self: *Encoder, value: anytype, c: *core.Context) core.EncodeError!void {
        const T = @TypeOf(value);
        const magnitude = @abs(value);
        if (std.math.cast(u8, magnitude)) |small| {
            if (c.limits.numeric_bytes == 0) return error.LengthLimit;
            try self.write(c, &.{ if (value < 0) @as(u8, 9) else @as(u8, 2), small });
        } else {
            const len = (@typeInfo(T).int.bits + 7) / 8;
            if (len > c.limits.numeric_bytes) return error.LengthLimit;
            const size = std.math.cast(u8, len) orelse return error.NumberOutOfRange;
            var encoded: [len]u8 = undefined;
            var remaining = magnitude;
            for (&encoded) |*byte| {
                byte.* = if (comptime @typeInfo(T).int.bits < 8) @intCast(remaining) else @truncate(remaining); // safe: low eight magnitude bits are the wire byte; higher bits are emitted next.
                remaining = if (comptime @typeInfo(T).int.bits > 8) remaining >> 8 else 0;
            }
            try c.chargeWork(len);
            try self.write(c, &.{ if (value < 0) @as(u8, 17) else @as(u8, 15), size });
            try self.write(c, &encoded);
        }
    }
    pub fn text(self: *Encoder, value: []const u8, c: *core.Context) core.EncodeError!void {
        const len = std.math.cast(u8, value.len) orelse return error.LengthLimit;
        try self.write(c, &.{ 3, len });
        try self.write(c, value);
    }
    pub fn bytes(self: *Encoder, value: []const u8, c: *core.Context) core.EncodeError!void {
        const len = std.math.cast(u8, value.len) orelse return error.LengthLimit;
        try self.write(c, &.{ 4, len });
        try self.write(c, value);
    }
    pub fn key(self: *Encoder, value: []const u8, c: *core.Context) core.EncodeError!void {
        try self.text(value, c);
    }
    pub fn nullValue(self: *Encoder, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{7});
    }
    pub fn unit(self: *Encoder, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{8});
    }
    pub fn begin(self: *Encoder, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) core.EncodeError!void {
        const size = std.math.cast(u8, len) orelse return error.ItemLimit;
        if (kind == .newtype or kind == .named_unit or kind == .named_tuple or kind == .some) {
            const n = std.math.cast(u8, name.len) orelse return error.LengthLimit;
            try self.write(c, &.{ 16, @backingInt(kind), size, n });
            try self.write(c, name);
        } else if (kind == .variant) {
            if (len != 1) return error.UnsupportedValue;
            const n = std.math.cast(u8, name.len) orelse return error.LengthLimit;
            try self.write(c, &.{ 12, n });
            try self.write(c, name);
        } else try self.write(c, &.{ if (kind == .record) @as(u8, 6) else if (kind == .map) @as(u8, 13) else @as(u8, 5), size });
    }
    pub fn end(self: *Encoder, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{0});
    }
    pub fn floating(self: *Encoder, value: anytype, c: *core.Context) core.EncodeError!void {
        if (16 > c.limits.numeric_bytes) return error.LengthLimit;
        var encoded: [16]u8 = undefined;
        std.mem.writeInt(u128, &encoded, @bitCast(@as(f128, value)), .little); // safe: float representation is emitted as little-endian bits, without arithmetic reinterpretation.
        try c.chargeWork(encoded.len);
        try self.write(c, &.{18});
        try self.write(c, &encoded);
    }
};
