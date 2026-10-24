//! A form written as `name=value` pairs joined by `&`, percent-encoded as the
//! WHATWG URL standard's form serializer does (`[` and `]` included, a space
//! as `+`). A record's members are named by their path (`user%5Bname%5D=ada`);
//! a sequence of values repeats its name (`tag=a&tag=b`). A null is left out,
//! so an optional reads back through its default. A form holds no sequence
//! of records or of sequences: writing one is `UnsupportedValue`.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const percent = @import("text.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

const Kind = enum { record, sequence };
const Frame = struct {
    kind: Kind,
    /// Where the record's member name being written starts in `path`, or
    /// null before its key.
    member: ?usize = null,
    /// How long the path is at the frame's own level.
    base: usize,
};

writer: *std.Io.Writer,
/// The current pair's name, encoded: the first segment, then `%5B...%5D`
/// for each one after it. Past its own bytes it moves to `spilled`.
inline_path: [4096]u8,
path_len: usize,
spilled: std.ArrayList(u8),
frames_inline: [128]Frame,
frames_extra: std.ArrayList(Frame),
depth: usize,
allocator: std.mem.Allocator,
/// Whether a pair has been written, so the next one needs its `&`.
written: bool,
const Self = @This();

/// Starts `self` over `writer`, built where it lies: its path and frames are
/// kilobytes a struct literal would build elsewhere and copy. `allocator`
/// holds a path or nesting past them.
pub fn init(self: *Self, writer: *std.Io.Writer, allocator: std.mem.Allocator) void {
    self.writer = writer;
    self.path_len = 0;
    self.spilled = .empty;
    self.frames_extra = .empty;
    self.depth = 0;
    self.allocator = allocator;
    self.written = false;
}
pub fn deinit(self: *Self) void {
    self.spilled.deinit(self.allocator);
    self.frames_extra.deinit(self.allocator);
}
fn path(self: *Self) []const u8 {
    return if (self.spilled.items.len != 0) self.spilled.items else self.inline_path[0..self.path_len];
}
fn grow(self: *Self, n: usize) Error![]u8 {
    if (self.spilled.items.len == 0 and self.path_len + n <= self.inline_path.len) {
        defer self.path_len += n;
        return self.inline_path[self.path_len..][0..n];
    }
    if (self.spilled.items.len == 0) self.spilled.appendSlice(self.allocator, self.inline_path[0..self.path_len]) catch return error.AllocationLimit;
    return self.spilled.addManyAsSlice(self.allocator, n) catch error.AllocationLimit;
}
fn shrink(self: *Self, len: usize) void {
    if (self.spilled.items.len != 0) {
        self.spilled.shrinkRetainingCapacity(len);
        if (len <= self.inline_path.len) {
            @memcpy(self.inline_path[0..len], self.spilled.items);
            self.spilled.clearRetainingCapacity();
        }
    }
    self.path_len = len;
}
fn pathLen(self: *Self) usize {
    return if (self.spilled.items.len != 0) self.spilled.items.len else self.path_len;
}
fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames_inline.len) &self.frames_inline[i] else &self.frames_extra.items[i - self.frames_inline.len];
}
fn pushFrame(self: *Self, f: Frame) Error!void {
    if (self.depth < self.frames_inline.len) self.frames_inline[self.depth] = f else self.frames_extra.append(self.allocator, f) catch return error.AllocationLimit;
    self.depth += 1;
}
fn popFrame(self: *Self) Frame {
    const f = self.frame().*;
    if (self.depth > self.frames_inline.len) _ = self.frames_extra.pop();
    self.depth -= 1;
    return f;
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.output(data.len);
    try self.writer.writeAll(data);
}
fn putEncoded(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.output(percent.encodedLength(data));
    var buffer: [256 * 3]u8 = undefined;
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, 256);
        const length = percent.encodedLength(rest[0..n]);
        percent.encode(rest[0..n], buffer[0..length]);
        try self.writer.writeAll(buffer[0..length]);
        rest = rest[n..];
    }
}
fn appendEncoded(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.chargeWork(data.len);
    percent.encode(data, try self.grow(percent.encodedLength(data)));
}

/// Where a value goes: the member whose key was written, or the sequence's
/// path. The root holds no value of its own.
fn target(self: *Self) Error!void {
    if (self.depth == 0) return error.UnsupportedValue;
    const f = self.frame();
    switch (f.kind) {
        .record => if (f.member == null) return error.CustomRejected,
        .sequence => {},
    }
}
/// After a member's value: its name comes off the path.
fn done(self: *Self) void {
    const f = self.frame();
    if (f.kind == .record) {
        self.shrink(f.base);
        f.member = null;
    }
}
/// Writes `name=` for the current path and then `value`, already encoded or not.
fn pair(self: *Self, value: []const u8, comptime encoded: bool, c: *core.Context) Error!void {
    try self.target();
    if (self.written) try self.put("&", c);
    self.written = true;
    try self.put(self.path(), c);
    try self.put("=", c);
    if (encoded) try self.put(value, c) else try self.putEncoded(value, c);
    self.done();
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.pair(if (value) "true" else "false", true, c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    if (limit.exceeds(spelling.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.pair(spelling, false, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    if (!std.math.isFinite(value)) return error.UnsupportedValue;
    var buffer: [5200]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (limit.exceeds(spelling.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.pair(spelling, false, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    if (self.depth != 0) {
        const f = self.frame();
        // A map's key comes as text.
        if (f.kind == .record and f.member == null) return self.key(value, c);
    }
    try self.pair(value, false, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.pair(value, false, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// A null is no pair.
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    _ = c;
    try self.target();
    if (self.frame().kind == .sequence) return error.UnsupportedValue;
    self.done();
}
/// A union's arm with no payload: its name with an empty value.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.pair("", true, c);
}
pub fn key(self: *Self, name: []const u8, c: *core.Context) Error!void {
    if (self.depth == 0) return error.CustomRejected;
    const f = self.frame();
    if (f.kind != .record or f.member != null) return error.CustomRejected;
    if (name.len == 0) return error.UnsupportedValue;
    f.member = self.pathLen();
    if (self.depth == 1) return self.appendEncoded(name, c);
    @memcpy(try self.grow(3), "%5B");
    try self.appendEncoded(name, c);
    @memcpy(try self.grow(3), "%5D");
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    _ = len;
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    const shape: Kind = switch (kind) {
        .record, .map => .record,
        .sequence, .tuple => .sequence,
        // A union is a record of its one arm: `shape[circle]=...`.
        .variant => .record,
        else => return error.UnsupportedValue,
    };
    if (self.depth == 0) {
        if (shape != .record) return error.UnsupportedValue;
    } else {
        try self.target();
        // A form's sequences hold values alone.
        if (self.frame().kind == .sequence) return error.UnsupportedValue;
    }
    try self.pushFrame(.{ .kind = shape, .base = self.pathLen() });
    if (kind == .variant) try self.key(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    _ = c;
    const f = self.popFrame();
    self.shrink(f.base);
    if (self.depth != 0) self.done();
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
