//! CBOR written with RFC 8949's preferred serialization: the shortest head for
//! every argument, the shortest float that holds a value exactly, definite
//! lengths. In a deterministic profile a map's entries are also sorted, by
//! their encoded keys bytewise (4.2.1, core deterministic encoding) or shorter
//! keys first (4.2.3, length-first), which needs each map held until it
//! closes: those profiles write through a buffer on the allocator given, and a
//! key given twice is refused.
const std = @import("std");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const wire = @import("wire.zig");
const sorted = @import("../binary/sorted.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

/// How maps are ordered.
pub const Profile = enum {
    /// In the order the value gives: streamed, nothing held.
    preferred,
    /// RFC 8949 4.2.1: keys sorted bytewise by their encodings.
    deterministic,
    /// RFC 8949 4.2.3: shorter encoded keys first, then bytewise.
    length_first,
};

writer: *std.Io.Writer,
profile: Profile,
/// The containers open, in a deterministic profile: each map held until it closes.
held: ?sorted.Stack,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, profile: Profile, allocator: ?std.mem.Allocator) void {
    self.* = .{ .writer = writer, .profile = profile, .held = if (profile == .preferred) null else .{ .allocator = allocator.? } };
}
pub fn deinit(self: *Self) void {
    if (self.held) |*h| h.deinit();
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    if (self.held) |*stack| if (stack.sink()) |h| return stack.append(h, data, c);
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// Before an item: in a held map, where its entry's key or value starts.
fn item(self: *Self) Error!void {
    if (self.held) |*stack| try stack.item();
}
fn putHead(self: *Self, major: wire.Major, argument: u64, c: *core.Context) Error!void {
    var buffer: [9]u8 = undefined;
    try self.put(wire.encodeHead(&buffer, major, argument), c);
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.item();
    try self.put(&.{if (value) 0xf5 else 0xf4}, c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    try self.item();
    if (value >= 0) {
        const n = std.math.cast(u64, value) orelse return error.NumberOutOfRange;
        return self.putHead(.unsigned, n, c);
    }
    // -1 - value, which for the most negative of a wide type is 2^64 - 1 at most.
    const magnitude = std.math.cast(u64, -(@as(i129, value) + 1)) orelse return error.NumberOutOfRange;
    try self.putHead(.negative, magnitude, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    const v: f64 = @floatCast(value);
    if (std.math.isFinite(value) and @as(@TypeOf(value), @floatCast(v)) != value) return error.NumberOutOfRange;
    try self.item();
    var buffer: [9]u8 = undefined;
    try self.put(wire.encodeFloat(&buffer, v), c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.item();
    try self.putHead(.text, value.len, c);
    try self.put(value, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.item();
    try self.putHead(.bytes, value.len, c);
    try self.put(value, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.item();
    try self.put(&.{0xf6}, c);
}
/// Nothing, such as a union's arm with no payload: `null`.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.nullValue(c);
}
pub fn key(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.text(value, c);
}
/// A tag on the item after it: no item of its own.
pub fn tag(self: *Self, number: u64, c: *core.Context) Error!void {
    // The tagged item is the same entry's key or value, starting here.
    if (self.held) |*stack| stack.prefix();
    try self.putHead(.tag, number, c);
}
pub fn simple(self: *Self, value: u8, c: *core.Context) Error!void {
    if (value >= 24 and value < 32) return error.UnsupportedValue;
    try self.item();
    try self.putHead(.simple, value, c);
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    try self.item();
    switch (kind) {
        .sequence, .tuple => try self.putHead(.array, len, c),
        .record, .map => try self.putHead(.map, len, c),
        // A union is a map of its one arm.
        .variant => try self.putHead(.map, 1, c),
        else => return error.UnsupportedValue,
    }
    // Preferred serialization keeps nothing: every container is written as
    // it comes. A deterministic profile keeps each map until it closes.
    if (self.held) |*stack| try stack.open(kind == .record or kind == .map or kind == .variant);
    if (kind == .variant) try self.text(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const stack = &(self.held orelse return);
    var entries = (try stack.close(if (self.profile == .length_first) .length_first else .bytewise, c)) orelse return;
    defer entries.deinit();
    while (entries.next()) |entry| try self.put(entry, c);
}
pub fn validateRaw(_: *Self, payload: []const u8, c: *core.Context) Error!void {
    c.input(payload.len) catch |err| return encodeError(err);
    var decoder: Decoder = undefined;
    decoder.init(c, payload);
    defer decoder.deinit();
    var cursor: core.Cursor(Decoder) = .{ .backend = &decoder, .context = c };
    cursor.skip() catch |err| return encodeError(err);
    decoder.endInput(c) catch |err| return encodeError(err);
}
fn encodeError(err: core.DecodeError) core.EncodeError {
    return switch (err) {
        error.InputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.AllocationLimit, error.WorkLimit, error.OutOfMemory => |e| e,
        else => error.InvalidRaw,
    };
}
pub fn raw(self: *Self, payload: []const u8, c: *core.Context) Error!void {
    try self.item();
    try self.put(payload, c);
}
