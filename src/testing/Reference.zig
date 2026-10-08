//! S1 proof backend only. A tiny binary grammar, not a production format.
//! Each container ends explicitly; declared counts must match the actual payload.
const std = @import("std");
const core = @import("../core.zig");
const core_decode = @import("../core/decode.zig");
pub const Format = enum { reference };
pub const Error = error{SyntaxError};
pub const capabilities: core.Capabilities = .{};
input: []const u8,
position: usize = 0,
const Self = @This();
fn read(self: *Self, c: *core.Context, n: usize) core.DecodeError![]const u8 {
    @setRuntimeSafety(true);
    if (n > self.input.len - self.position) return error.SyntaxError;
    try c.input(n);
    const bytes = self.input[self.position..][0..n];
    self.position += n;
    return bytes;
}
pub fn next(self: *Self, c: *core.Context) core.DecodeError!core.Event {
    const tag = (try self.read(c, 1))[0];
    return switch (tag) {
        0 => .end,
        1 => blk: {
            const value = (try self.read(c, 1))[0];
            if (value > 1) return error.SyntaxError;
            break :blk .{ .boolean = value != 0 };
        },
        2 => .{ .integer = .{ .magnitude = try self.read(c, 1) } },
        3, 4 => blk: {
            const len = (try self.read(c, 1))[0];
            const span: core.Span = .{ .bytes = try self.read(c, len), .lifetime = .borrowed };
            break :blk if (tag == 3) .{ .text = span } else .{ .bytes = span };
        },
        5 => .{ .begin = .{ .kind = .sequence, .len = (try self.read(c, 1))[0] } },
        6 => .{ .begin = .{ .kind = .record, .len = (try self.read(c, 1))[0] } },
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
pub fn endInput(self: *Self, _: *core.Context) Error!void {
    if (self.position != self.input.len) return error.SyntaxError;
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
    pub const capabilities: core.Capabilities = .{};
    fn write(self: *Encoder, c: *core.Context, payload: []const u8) core.EncodeError!void {
        @setRuntimeSafety(true);
        try c.output(payload.len);
        if (payload.len > self.buffer.len - self.used) return error.OutputLimit;
        @memcpy(self.buffer[self.used..][0..payload.len], payload);
        self.used += payload.len;
    }
    pub fn boolean(self: *Encoder, value: bool, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{ 1, @intFromBool(value) });
    }
    pub fn integer(self: *Encoder, value: anytype, c: *core.Context) core.EncodeError!void {
        if (value < 0) {
            const magnitude = std.math.cast(u8, std.math.absCast(value)) orelse return error.NumberOutOfRange;
            try self.write(c, &.{ 9, magnitude });
        } else {
            const magnitude = std.math.cast(u8, value) orelse return error.NumberOutOfRange;
            try self.write(c, &.{ 2, magnitude });
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
    pub fn begin(self: *Encoder, kind: core.Kind, _: []const u8, len: usize, c: *core.Context) core.EncodeError!void {
        const size = std.math.cast(u8, len) orelse return error.ItemLimit;
        try self.write(c, &.{ if (kind == .record or kind == .map) @as(u8, 6) else @as(u8, 5), size });
    }
    pub fn end(self: *Encoder, c: *core.Context) core.EncodeError!void {
        try self.write(c, &.{0});
    }
    pub fn floating(_: *Encoder, _: anytype, _: *core.Context) core.EncodeError!void {
        return error.UnsupportedValue;
    }
};
