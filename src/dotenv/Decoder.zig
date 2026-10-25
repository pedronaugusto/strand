//! A .env file as core events: a record of its keys, read as python-dotenv
//! reads them (`text.zig`): `KEY=value` and `export KEY=value` lines, a value
//! unquoted, trimmed and cut at a `#` after white space, or in single or
//! double quotes across lines with their escapes, and a key with no `=`.
//! Nothing is interpolated: `$` is text. Every value is text until the type
//! asks, typed as INI's values are (`ini/Decoder.zig`'s `typed`): a number in
//! JSON's spelling, a boolean as configparser's `getboolean` reads one. An
//! empty value is empty text, as python-dotenv's `""`, and a key with no `=`
//! a null, as its `None`, where the type takes one. A key given twice
//! is refused, where python-dotenv keeps the last; a line python-dotenv skips
//! as an error is a syntax error. A value with no escape read is borrowed
//! from the input; one with escapes is unescaped in the arena.
const std = @import("std");
const core = @import("../core.zig");
const text = @import("text.zig");
const ini = @import("../ini/Decoder.zig");
pub const Format = enum { dotenv };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
    .unicode_scalar = false,
    .named_shapes = false,
    .nonfinite_floats = false,
    .scalar_roots = false,
    .max_integer_bits = std.math.maxInt(usize),
    .utf8_text = true,
};
pub const parseInteger = ini.parseInteger;
pub const parseFloat = ini.parseFloat;

const Phase = enum { start, members, done };
/// A binding, and whether its key is the reader's own: a quoted key with a
/// carriage return in it, which reads as a line feed.
const Entry = struct { binding: text.Binding, key_lifetime: core.Lifetime };

input: []const u8,
loaded: bool,
bindings: std.ArrayList(Entry),
allocator: std.mem.Allocator,
phase: Phase,
/// The next binding, and whether its key has been read.
member: usize,
key_read: bool,
/// Where the binding being read starts, for a failure's place.
current: usize,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    self.* = .{
        .input = bytes,
        .loaded = false,
        .bindings = .empty,
        .allocator = c.allocator(),
        .phase = .start,
        .member = 0,
        .key_read = false,
        .current = 0,
    };
}
pub fn deinit(self: *Self) void {
    self.bindings.deinit(self.allocator);
    self.* = undefined;
}
/// Where the binding being read starts.
pub fn offset(self: *const Self) usize {
    return self.current;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a union tagged inside its record is read twice, which a .env file's lines are not: declare a data codec");
}
pub fn replay(_: *const Self, _: *Self, _: usize, _: usize) void {
    @compileError("a union tagged inside its record is read twice, which a .env file's lines are not: declare a data codec");
}

fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        error.AllocationLimit => error.AllocationLimit,
        else => error.SyntaxError,
    };
}

/// Reads the file's bindings, once.
fn load(self: *Self, c: *core.Context) Error!void {
    if (self.loaded) return;
    self.loaded = true;
    const input = self.input;
    try c.chargeWork(input.len);
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const a = self.allocator;
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(a);
    // A byte-order mark first is not text, as python-dotenv takes it off.
    var at: usize = if (std.mem.startsWith(u8, input, "\u{feff}")) 3 else 0;
    while (at < input.len) {
        self.current = at;
        const step = text.next(input, at) catch return error.SyntaxError;
        at = step.next;
        var b = step.binding orelse continue;
        self.current = b.at;
        if (self.bindings.items.len >= c.limits.container_items) return error.ItemLimit;
        try c.chargeWork(b.key.len);
        var lifetime: core.Lifetime = .borrowed;
        if (std.mem.findScalar(u8, b.key, '\r') != null) {
            const out = c.alloc(u8, b.key.len) catch |err| return failure(c, err);
            b.key = out[0..text.lineFeeds(b.key, out)];
            lifetime = .owned;
        }
        if ((keys.getOrPut(a, b.key) catch |err| return failure(c, err)).found_existing) return error.DuplicateField;
        self.bindings.append(a, .{ .binding = b, .key_lifetime = lifetime }) catch |err| return failure(c, err);
    }
}

pub fn atEnd(self: *Self) Error!bool {
    return self.phase == .members and !self.key_read and self.member == self.bindings.items.len;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    try self.load(c);
    switch (self.phase) {
        .done => return error.SyntaxError,
        .start => {
            switch (request.expected) {
                .record, .map, .unknown => {},
                else => return error.UnexpectedType,
            }
            self.phase = .members;
            return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record, .len = self.bindings.items.len } };
        },
        .members => {
            if (self.member == self.bindings.items.len and !self.key_read) {
                self.phase = .done;
                return .end;
            }
            const entry = self.bindings.items[self.member];
            const b = entry.binding;
            self.current = b.at;
            try c.node();
            if (!self.key_read) {
                self.key_read = true;
                try c.span(b.key.len, true);
                return .{ .text = .{ .bytes = b.key, .lifetime = entry.key_lifetime } };
            }
            self.key_read = false;
            self.member += 1;
            const v = b.value orelse {
                if (request.nullable or request.expected == .unknown) return .none;
                return error.UnexpectedType;
            };
            const s = try self.value(c, v);
            if (s.bytes.len == 0) return switch (request.expected) {
                .unit => .unit,
                .bytes => .{ .bytes = s },
                else => .{ .text = s },
            };
            return ini.typed(c, s, request);
        },
    }
}

/// A value's text: borrowed, or unescaped in the arena.
fn value(self: *Self, c: *core.Context, v: text.Value) Error!core.Span {
    _ = self;
    if (!text.rewritten(v)) {
        try c.span(v.body.len, false);
        return .{ .bytes = v.body, .lifetime = .borrowed };
    }
    try c.chargeWork(v.body.len);
    // An escape is longer than what it stands for: the body bounds the text.
    const out = c.alloc(u8, v.body.len) catch |err| return failure(c, err);
    const n = text.unescape(v, out);
    try c.span(n, false);
    return .{ .bytes = out[0..n], .lifetime = .owned };
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    try self.load(c);
    if (self.phase != .done) return error.SyntaxError;
}
