//! JSON wire emission. Shape and field policy belong to core.
const std = @import("std");
const core = @import("strand.core");
const Decoder = @import("Decoder.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;
writer: *std.Io.Writer,
frames: [128]Frame = undefined,
extra: std.ArrayList(Frame) = .empty,
depth: usize = 0,
keys: [64][]const u8 = undefined,
extra_keys: std.ArrayList([]const u8) = .empty,
key_count: usize = 0,
const Frame = struct { object: bool, key_start: usize, first: bool = true, value_pending: bool = false };
const Self = @This();
fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn write(self: *Self, payload: []const u8, c: *core.Context) Error!void {
    try c.output(payload.len);
    try self.writer.writeAll(payload);
}
fn before(self: *Self, c: *core.Context) Error!void {
    if (self.depth == 0) return;
    const f = self.frame();
    if (f.object and f.value_pending) {
        f.value_pending = false;
        return;
    }
    if (!f.first) try self.write(",", c);
    f.first = false;
    if (f.object) f.value_pending = true;
}
fn quoted(self: *Self, spelling: []const u8, c: *core.Context) Error!void {
    try self.write("\"", c);
    var from: usize = 0;
    for (spelling, 0..) |byte, i| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            8 => "\\b",
            12 => "\\f",
            else => null,
        };
        if (escape) |escaped| {
            try self.write(spelling[from..i], c);
            try self.write(escaped, c);
            from = i + 1;
        } else if (byte < 0x20) {
            try self.write(spelling[from..i], c);
            var buffer: [6]u8 = undefined;
            const escaped = std.mem.print(&buffer, "\\u00{x:0>2}", .{byte}) catch unreachable; // unreachable: a six-byte escape fits exactly.
            try self.write(escaped, c);
            from = i + 1;
        }
    }
    try self.write(spelling[from..], c);
    try self.write("\"", c);
}
pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.before(c);
    try self.write(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.write(spelling, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    var buffer: [128]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{}", .{value}) catch return error.NumberOutOfRange;
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.write(spelling, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const is_key = self.depth != 0 and self.frame().object and !self.frame().value_pending;
    if (is_key) {
        for (self.frame().key_start..self.key_count) |i| {
            const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
            try c.chargeWork(@min(value.len, prior.len));
            if (std.mem.eql(u8, value, prior)) return error.DuplicateField;
        }
        if (self.key_count < self.keys.len) self.keys[self.key_count] = value else try self.extra_keys.append(c.allocator(), value);
        self.key_count += 1;
    }
    try self.before(c);
    try self.quoted(value, c);
    if (is_key) try self.write(":", c);
}
pub const key = text;
pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn scalar(self: *Self, value: u21, c: *core.Context) Error!void {
    var buffer: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(value, &buffer) catch return error.InvalidUtf8;
    try self.text(buffer[0..n], c);
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.before(c);
    try self.write("null", c);
}
pub const unit = nullValue;
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, _: usize, c: *core.Context) Error!void {
    try self.before(c);
    const object = kind == .record or kind == .map or kind == .variant;
    try self.write(if (object) "{" else "[", c);
    if (self.depth < self.frames.len) self.frames[self.depth] = .{ .object = object, .key_start = self.key_count } else try self.extra.append(c.allocator(), .{ .object = object, .key_start = self.key_count });
    self.depth += 1;
    if (kind == .variant) try self.key(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const f = self.frame().*;
    if (f.object and f.value_pending) return error.CustomRejected;
    try self.write(if (f.object) "}" else "]", c);
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    self.key_count = f.key_start;
    self.extra_keys.shrinkRetainingCapacity(self.key_count - @min(self.key_count, self.keys.len));
}
pub fn validateRaw(_: *Self, payload: []const u8, c: *core.Context) Error!void {
    var decoder = Decoder.init(c, payload) catch |err| return encodeError(err);
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
    try self.before(c);
    try self.write(payload, c);
}
