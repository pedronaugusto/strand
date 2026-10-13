//! CBOR (RFC 8949) as core events, read in one pass off the input. Every
//! well-formed item has an event: integers as their magnitude and sign (down
//! to -2^64), floats of any width, byte and text strings (borrowed where
//! definite, joined in the arena where chunked), arrays and maps of definite
//! or indefinite length, tags (`.tag`, before the item they tag) and simple
//! values (`.simple`, `undefined` among them). A typed destination takes what
//! it asked for and refuses the rest: a tag it did not ask for, `undefined`, a
//! text where bytes belong. A length is checked against the input left before
//! anything is counted or allocated for it.
const std = @import("std");
const core = @import("../core.zig");
const wire = @import("wire.zig");
pub const Format = enum { cbor };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .any,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .max_integer_bits = 65,
    .max_float_bits = 64,
};

const Frame = struct {
    map: bool,
    /// Items left in a definite container (a map's keys and values both);
    /// null for an indefinite one.
    remaining: ?u64,
    /// Items read in an indefinite map, which must be even at its break.
    read: u64 = 0,
};

input: []const u8,
at: usize,
allocator: std.mem.Allocator,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
/// A tag was read: the item it tags is next, whatever the container says.
tagged: bool,
root_done: bool,
/// An integer's magnitude, little-endian, for the event that names it.
magnitude: [9]u8,
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
    self.tagged = false;
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
/// Starts `into` over an item already read, as the root of its own input.
pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
    into.begin(self.input[0..end], from, self.allocator);
}

fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        else => error.SyntaxError,
    };
}
fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn push(self: *Self, c: *core.Context, f: Frame) Error!void {
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    if (self.depth < self.frames.len) self.frames[self.depth] = f else self.extra.append(self.allocator, f) catch |err| return failure(c, err);
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
    if (self.depth == 0 or self.tagged) return false;
    const f = self.frame();
    if (f.remaining) |n| return n == 0;
    if (self.at >= self.input.len) return error.SyntaxError;
    return self.input[self.at] == 0xff;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    if (self.depth == 0) {
        if (self.root_done and !self.tagged) return error.SyntaxError;
    } else if (!self.tagged) {
        const f = self.frame();
        if (f.remaining) |n| {
            if (n == 0) return self.pop();
            f.remaining = n - 1;
        } else {
            if (self.at >= self.input.len) return error.SyntaxError;
            if (self.input[self.at] == 0xff) {
                self.at += 1;
                if (f.map and f.read % 2 != 0) return error.SyntaxError;
                return self.pop();
            }
            f.read += 1;
        }
    }
    self.tagged = false;
    const h = try wire.head(self.input, self.at);
    if (h.major == .simple and h.indefinite) return error.SyntaxError; // a break where no indefinite container is open
    self.at += h.len;
    const event = try self.item(c, h, request);
    if (self.depth == 0 and event != .begin and event != .tag) self.root_done = true;
    return event;
}

fn item(self: *Self, c: *core.Context, h: wire.Head, request: core.Request) Error!core.Event {
    switch (h.major) {
        .unsigned => return self.integer(false, h.argument),
        .negative => return self.integer(true, h.argument),
        .bytes, .text => {
            const span = try self.string(c, h);
            if (h.major == .text) {
                if (!std.unicode.utf8ValidateSlice(span.bytes)) return error.InvalidUtf8;
                return .{ .text = span };
            }
            return .{ .bytes = span };
        },
        .array, .map => {
            const per: u64 = if (h.major == .map) 2 else 1;
            var count: ?usize = null;
            if (!h.indefinite) {
                // Every item is a byte at least: a count past the input left is
                // not well-formed, and nothing is counted for it.
                const left = self.input.len - self.at;
                if (h.argument > left / per) return error.SyntaxError;
                count = @intCast(h.argument);
            }
            try self.push(c, .{ .map = h.major == .map, .remaining = if (h.indefinite) null else h.argument * per });
            const kind: core.Kind = if (h.major == .array) .sequence else if (request.expected == .record or request.expected == .variant) .record else .map;
            return .{ .begin = .{ .kind = kind, .len = count } };
        },
        .tag => {
            self.tagged = true;
            return .{ .tag = h.argument };
        },
        .simple => return switch (h.info) {
            20 => .{ .boolean = false },
            21 => .{ .boolean = true },
            22 => if (request.expected == .unit) .unit else .none,
            25, 26, 27 => .{ .floating = wire.float(h) },
            else => .{ .simple = @intCast(h.argument) },
        },
    }
}

/// An integer's event: `-1 - argument` when `negative`.
fn integer(self: *Self, negative: bool, argument: u64) core.Event {
    const magnitude: u128 = if (negative) @as(u128, argument) + 1 else argument;
    std.mem.writeInt(u72, &self.magnitude, @intCast(magnitude), .little);
    var len: usize = 9;
    while (len > 0 and self.magnitude[len - 1] == 0) len -= 1;
    return .{ .integer = .{ .negative = negative, .magnitude = self.magnitude[0..len] } };
}

/// A byte or text string's bytes: borrowed when definite; joined in the
/// arena when chunked, each chunk a definite string of the same major type.
fn string(self: *Self, c: *core.Context, h: wire.Head) Error!core.Span {
    if (!h.indefinite) {
        if (h.argument > self.input.len - self.at) return error.SyntaxError;
        const n: usize = @intCast(h.argument);
        try c.span(n, false);
        try c.chargeWork(n);
        defer self.at += n;
        return .{ .bytes = self.input[self.at..][0..n], .lifetime = .borrowed };
    }
    // Two passes: find the chunks and their total, then join them.
    var total: usize = 0;
    var scan = self.at;
    while (true) {
        if (scan >= self.input.len) return error.SyntaxError;
        if (self.input[scan] == 0xff) break;
        const chunk = try wire.head(self.input, scan);
        if (chunk.major != h.major or chunk.indefinite) return error.SyntaxError;
        scan += chunk.len;
        if (chunk.argument > self.input.len - scan) return error.SyntaxError;
        const n: usize = @intCast(chunk.argument);
        if (h.major == .text and !std.unicode.utf8ValidateSlice(self.input[scan..][0..n])) return error.InvalidUtf8;
        scan += n;
        total += n;
        try c.chargeWork(n + 1);
    }
    try c.span(total, false);
    const out = try c.alloc(u8, total);
    var written: usize = 0;
    while (self.input[self.at] != 0xff) {
        const chunk = wire.head(self.input, self.at) catch unreachable; // unreachable: the first pass read it
        self.at += chunk.len;
        const n: usize = @intCast(chunk.argument);
        @memcpy(out[written..][0..n], self.input[self.at..][0..n]);
        written += n;
        self.at += n;
    }
    self.at += 1;
    return .{ .bytes = out, .lifetime = .owned };
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (self.depth != 0 or self.tagged or !self.root_done) return error.SyntaxError;
    if (self.at != self.input.len) return error.SyntaxError;
}
