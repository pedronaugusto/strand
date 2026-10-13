//! MessagePack as core events, read in one pass off the input. Every value
//! has an event: integers as their magnitude and sign (from -2^63 to 2^64 -
//! 1), floats of either width, str (strict UTF-8) and bin apart, arrays and
//! maps, and an extension as a `.tag` holding its type (sign-extended), then
//! its data as `.bytes`. A typed destination takes what it asked for and
//! refuses the rest: an extension it did not ask for, a bin where text
//! belongs, a float where an integer does. A length is checked against the
//! input left before anything is counted or allocated for it.
const std = @import("std");
const core = @import("../core.zig");
const wire = @import("wire.zig");
pub const Format = enum { msgpack };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .any,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .indefinite_containers = false,
    .max_integer_bits = 64,
    .max_float_bits = 64,
    .utf8_text = true,
};

/// Items left in an open container, a map's keys and values both.
const Frame = struct { remaining: u64 };

input: []const u8,
at: usize,
allocator: std.mem.Allocator,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
/// An extension's data, after its `.tag` and before its `.bytes`.
payload: ?[]const u8,
root_done: bool,
/// An integer's magnitude, little-endian, for the event that names it.
magnitude: [8]u8,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    self.begin(bytes, 0, c.allocator());
}
fn begin(self: *Self, bytes: []const u8, at: usize, allocator: std.mem.Allocator) void {
    self.input = bytes;
    self.at = at;
    self.allocator = allocator;
    self.extra = .empty;
    self.depth = 0;
    self.payload = null;
    self.root_done = false;
}
pub fn deinit(self: *Self) void {
    self.extra.deinit(self.allocator);
    self.* = undefined;
}
pub fn offset(self: *const Self) usize {
    return self.at;
}
pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
    return .{ .bytes = self.input[start..end], .lifetime = .borrowed };
}
/// Starts `into` over a value already read, as the root of its own input.
pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
    into.begin(self.input[0..end], from, self.allocator);
}

fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn push(self: *Self, c: *core.Context, f: Frame) Error!void {
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    if (self.depth < self.frames.len) self.frames[self.depth] = f else self.extra.append(self.allocator, f) catch |err| return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
    };
    self.depth += 1;
}
fn pop(self: *Self) core.Event {
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    if (self.depth == 0) self.root_done = true;
    return .end;
}

/// Whether the container being read is over, without reading a member of it.
pub fn atEnd(self: *Self) Error!bool {
    if (self.depth == 0 or self.payload != null) return false;
    return self.frame().remaining == 0;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    if (self.payload) |data| {
        self.payload = null;
        if (self.depth == 0) self.root_done = true;
        try c.span(data.len, false);
        try c.chargeWork(data.len);
        return .{ .bytes = .{ .bytes = data, .lifetime = .borrowed } };
    }
    if (self.depth == 0) {
        if (self.root_done) return error.SyntaxError;
    } else {
        const f = self.frame();
        if (f.remaining == 0) return self.pop();
        f.remaining -= 1;
    }
    const h = try wire.head(self.input, self.at);
    self.at += h.len;
    const event = try self.item(c, h, request);
    if (self.depth == 0 and event != .begin and event != .tag) self.root_done = true;
    return event;
}

fn item(self: *Self, c: *core.Context, h: wire.Head, request: core.Request) Error!core.Event {
    switch (h.family) {
        .nil => return if (request.expected == .unit) .unit else .none,
        .boolean => return .{ .boolean = h.argument == 1 },
        .unsigned => return self.integer(false, h.argument),
        .signed => {
            const v: i64 = @bitCast(h.argument);
            return self.integer(v < 0, @abs(v));
        },
        .float32 => return .{ .floating = core.widenFloat(@as(f32, @bitCast(@as(u32, @intCast(h.argument))))) },
        .float64 => return .{ .floating = core.widenFloat(@as(f64, @bitCast(h.argument))) },
        .str, .bin => {
            const content = try self.contents(c, h.argument);
            if (h.family == .str) {
                if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
                return .{ .text = .{ .bytes = content, .lifetime = .borrowed } };
            }
            return .{ .bytes = .{ .bytes = content, .lifetime = .borrowed } };
        },
        .array, .map => {
            const per: u64 = if (h.family == .map) 2 else 1;
            // Every item is a byte at least: a count past the input left is
            // not MessagePack, and nothing is counted for it.
            const left = self.input.len - self.at;
            if (h.argument > left / per) return error.SyntaxError;
            try self.push(c, .{ .remaining = h.argument * per });
            const kind: core.Kind = if (h.family == .array) .sequence else if (request.expected == .record or request.expected == .variant) .record else .map;
            return .{ .begin = .{ .kind = kind, .len = @intCast(h.argument) } };
        },
        .ext => {
            if (h.argument > self.input.len - self.at) return error.SyntaxError;
            const n: usize = @intCast(h.argument);
            self.payload = self.input[self.at..][0..n];
            self.at += n;
            return .{ .tag = @bitCast(@as(i64, h.ext_type)) };
        },
    }
}

/// An integer's event: `-magnitude` when `negative`.
fn integer(self: *Self, negative: bool, magnitude: u64) core.Event {
    std.mem.writeInt(u64, &self.magnitude, magnitude, .little);
    var len: usize = 8;
    while (len > 0 and self.magnitude[len - 1] == 0) len -= 1;
    return .{ .integer = .{ .negative = negative, .magnitude = self.magnitude[0..len] } };
}

/// A string's or binary's `n` bytes, borrowed.
fn contents(self: *Self, c: *core.Context, n: u64) Error![]const u8 {
    if (n > self.input.len - self.at) return error.SyntaxError;
    const len: usize = @intCast(n);
    try c.span(len, false);
    try c.chargeWork(len);
    defer self.at += len;
    return self.input[self.at..][0..len];
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (self.depth != 0 or self.payload != null or !self.root_done) return error.SyntaxError;
    if (self.at != self.input.len) return error.SyntaxError;
}
