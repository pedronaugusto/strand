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

/// A map being held to be sorted: its encoded entries, back to back, and
/// where each entry's key and value start.
const Held = struct {
    bytes: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Whether the next item written is a key.
    key_next: bool = true,
    /// Where the item after a tag starts: at its tag.
    tag_start: ?usize = null,
    const Entry = struct { key: usize, value: usize, end: usize = 0 };
};
/// What a container is: a map held for sorting, or anything else, written
/// where it stands.
const Frame = struct { held: ?Held = null };

writer: *std.Io.Writer,
profile: Profile,
allocator: ?std.mem.Allocator,
frames: std.ArrayList(Frame),
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, profile: Profile, allocator: ?std.mem.Allocator) void {
    self.* = .{ .writer = writer, .profile = profile, .allocator = allocator, .frames = .empty };
}
pub fn deinit(self: *Self) void {
    if (self.allocator) |a| {
        for (self.frames.items) |*f| if (f.held) |*h| {
            h.bytes.deinit(a);
            h.entries.deinit(a);
        };
        self.frames.deinit(a);
    }
}

/// The innermost map held, if any: everything inside it is written there.
fn heldMap(self: *Self) ?*Held {
    var i = self.frames.items.len;
    while (i > 0) {
        i -= 1;
        if (self.frames.items[i].held) |*h| return h;
    }
    return null;
}
fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    if (self.heldMap()) |h| {
        h.bytes.appendSlice(self.allocator.?, data) catch return error.AllocationLimit;
        return;
    }
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// Before an item: in a held map, where its entry's key or value starts.
fn item(self: *Self) Error!void {
    if (self.frames.items.len == 0) return;
    const top = &self.frames.items[self.frames.items.len - 1];
    const h = &(top.held orelse return);
    const at = h.tag_start orelse h.bytes.items.len;
    h.tag_start = null;
    if (h.key_next) {
        h.entries.append(self.allocator.?, .{ .key = at, .value = at }) catch return error.AllocationLimit;
    } else h.entries.items[h.entries.items.len - 1].value = at;
    h.key_next = !h.key_next;
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
    if (self.frames.items.len != 0) if (self.frames.items[self.frames.items.len - 1].held) |*h| {
        if (h.tag_start == null) h.tag_start = h.bytes.items.len;
    };
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
    if (self.profile != .preferred) {
        const map = kind == .record or kind == .map or kind == .variant;
        self.frames.append(self.allocator.?, .{ .held = if (map) .{} else null }) catch return error.AllocationLimit;
    }
    if (kind == .variant) try self.text(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    if (self.profile == .preferred) return;
    var f = self.frames.pop() orelse return error.CustomRejected;
    const h = &(f.held orelse return);
    const a = self.allocator.?;
    defer {
        h.bytes.deinit(a);
        h.entries.deinit(a);
    }
    const all = h.bytes.items;
    for (h.entries.items, 0..) |*e, i| e.end = if (i + 1 < h.entries.items.len) h.entries.items[i + 1].key else all.len;
    const Order = struct {
        bytes: []const u8,
        length_first: bool,
        fn less(o: @This(), x: Held.Entry, y: Held.Entry) bool {
            const kx = o.bytes[x.key..x.value];
            const ky = o.bytes[y.key..y.value];
            if (o.length_first and kx.len != ky.len) return kx.len < ky.len;
            return std.mem.order(u8, kx, ky) == .lt;
        }
    };
    try c.chargeWork(all.len + h.entries.items.len * 8);
    std.mem.sort(Held.Entry, h.entries.items, Order{ .bytes = all, .length_first = self.profile == .length_first }, Order.less);
    for (h.entries.items, 0..) |e, i| {
        if (i > 0) {
            const prior = h.entries.items[i - 1];
            if (std.mem.eql(u8, all[prior.key..prior.value], all[e.key..e.value])) return error.DuplicateField;
        }
        try self.put(all[e.key..e.end], c);
    }
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
