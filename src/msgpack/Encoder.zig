//! MessagePack written in the smallest format for every value, as the
//! specification asks: the shortest integer family, float 32 wherever it holds
//! the value's bits, the shortest length header. An extension is a tag (its
//! type) followed by bytes (its data). In the deterministic profile a map's
//! entries are also sorted by their encoded keys, which needs each map held
//! until it closes, on the allocator given, and a key given twice is refused.
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
    compact,
    /// Each map's entries sorted by their encoded keys, bytewise; a key given
    /// twice refused. strand's own profile: MessagePack defines none.
    deterministic,
};

writer: *std.Io.Writer,
/// The containers open, in the deterministic profile: each map held until it closes.
held: ?sorted.Stack,
/// An extension's type, given by a tag: the bytes written next are its data.
ext_type: ?i8,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, profile: Profile, allocator: ?std.mem.Allocator) void {
    self.* = .{ .writer = writer, .held = if (profile == .compact) null else .{ .allocator = allocator.? }, .ext_type = null };
}
pub fn deinit(self: *Self) void {
    if (self.held) |*h| h.deinit();
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    if (self.held) |*stack| if (stack.sink()) |h| return stack.append(h, data, c);
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// Before an item: a tag is followed only by its extension's data; in a held
/// map, where the item's entry's key or value starts.
fn item(self: *Self) Error!void {
    if (self.ext_type != null) return error.UnsupportedValue;
    if (self.held) |*stack| try stack.item();
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.item();
    try self.put(&.{if (value) 0xc3 else 0xc2}, c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    try self.item();
    var buffer: [9]u8 = undefined;
    if (value >= 0) {
        const n = std.math.cast(u64, value) orelse return error.NumberOutOfRange;
        return self.put(wire.encodeUnsigned(&buffer, n), c);
    }
    const n = std.math.cast(i64, value) orelse return error.NumberOutOfRange;
    try self.put(wire.encodeSigned(&buffer, n), c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    try self.item();
    var buffer: [9]u8 = undefined;
    // A float 32 is written as itself: widened first, a signalling NaN
    // would come back quiet.
    if (@TypeOf(value) == f32) return self.put(wire.encodeFloat32(&buffer, value), c);
    const v: f64 = @floatCast(value);
    if (std.math.isFinite(value) and @as(@TypeOf(value), @floatCast(v)) != value) return error.NumberOutOfRange;
    try self.put(wire.encodeFloat(&buffer, v), c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.item();
    var buffer: [9]u8 = undefined;
    try self.put(try wire.encodeLength(&buffer, .str, value.len), c);
    try self.put(value, c);
}
/// Binary, or an extension's data after its tag.
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    var buffer: [9]u8 = undefined;
    const ext_type = self.ext_type;
    self.ext_type = null;
    try self.item();
    const header = if (ext_type) |t| try wire.encodeExt(&buffer, t, value.len) else try wire.encodeLength(&buffer, .bin, value.len);
    try self.put(header, c);
    try self.put(value, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.item();
    try self.put(&.{0xc0}, c);
}
/// Nothing, such as a union's arm with no payload: nil.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.nullValue(c);
}
pub fn key(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.text(value, c);
}
/// An extension's type, its data the bytes written next; a type is the
/// tag's number as a signed 64-bit integer, from -128 to 127.
pub fn tag(self: *Self, number: u64, _: *core.Context) Error!void {
    if (self.ext_type != null) return error.UnsupportedValue;
    self.ext_type = std.math.cast(i8, @as(i64, @bitCast(number))) orelse return error.UnsupportedValue;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    try self.item();
    var buffer: [9]u8 = undefined;
    switch (kind) {
        .sequence, .tuple => try self.put(try wire.encodeLength(&buffer, .array, len), c),
        .record, .map => try self.put(try wire.encodeLength(&buffer, .map, len), c),
        // A union is a map of its one arm.
        .variant => try self.put(try wire.encodeLength(&buffer, .map, 1), c),
        else => return error.UnsupportedValue,
    }
    if (self.held) |*stack| try stack.open(kind == .record or kind == .map or kind == .variant);
    if (kind == .variant) try self.text(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    if (self.ext_type != null) return error.UnsupportedValue;
    const stack = &(self.held orelse return);
    var entries = (try stack.close(.bytewise, c)) orelse return;
    defer entries.deinit();
    while (entries.next()) |entry| try self.put(entry, c);
}
/// After the value: a tag left without its data is refused.
pub fn finish(self: *Self) Error!void {
    if (self.ext_type != null) return error.UnsupportedValue;
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
