//! A TOML document as core events. The document is read whole into its
//! tables when the first event is asked for (`syntax.zig`), then walked: a
//! table is a record or a map, an array a sequence, a key or a string text,
//! an integer or a float its spelling (with `+` and `_` taken out), a boolean
//! itself, and a date or a time the core's `.tag` naming its kind, then its
//! spelling as text. A typed destination never asks for a tag, so a date is
//! refused where a string belongs; `toml.LocalDate` and the other three ask
//! for it.
//!
//! TOML has no null: an optional is only ever absent, and a missing one takes
//! its default. A place in the walk is a node and a step at it (its key, its
//! value, its end), so a value can be read twice (a union tagged inside its
//! table) by walking from its place again; a failure's place in the text is
//! where its node was written (`place`).
const std = @import("std");
const core = @import("../core.zig");
const syntax = @import("syntax.zig");
const number = @import("number.zig");
const temporal = @import("temporal.zig");
pub const Format = enum { toml };
pub const Error = core.DecodeError;
pub const Version = syntax.Version;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .bytes = false,
    .nested_optional = false,
    .scalar_roots = false,
    .indefinite_containers = false,
    .max_integer_bits = 64,
    .max_float_bits = 64,
    .utf8_text = true,
};

pub const parseInteger = number.parseInteger;
pub const parseFloat = number.parseFloat;

const none = syntax.none;
/// What is next at a node: its key, its value, the text of its date or
/// time after the tag, or its end once its members are read.
const Step = enum(u2) { key, value, date, end };
/// A place in the walk, as `offset` gives it: a node and its step.
fn placeOf(node: u32, step: Step) usize {
    return @as(usize, node) << 2 | @backingInt(step);
}
const done: usize = std.math.maxInt(usize);

input: []const u8,
version: Version,
/// The document's working storage.
allocator: std.mem.Allocator,
document: ?syntax.Document,
/// Whether this walk owns the document (a replay borrows its walk's).
owner: bool,
/// The next place, and where the part being walked ends.
at: usize,
end: usize,
/// The containers open, innermost last.
frames: [64]u32,
extra: std.ArrayList(u32),
depth: usize,
/// Where in the text the document was refused, when it was.
failed_at: ?usize,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
/// The document is read onto `allocator`, charged to `c`, and given back by
/// `deinit`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8, version: Version, allocator: std.mem.Allocator) void {
    _ = c;
    self.* = .{ .input = bytes, .version = version, .allocator = allocator, .document = null, .owner = true, .at = placeOf(0, .value), .end = done, .frames = undefined, .extra = .empty, .depth = 0, .failed_at = null };
}
pub fn deinit(self: *Self) void {
    self.extra.deinit(self.allocator);
    if (self.owner) if (self.document) |*d| d.deinit(self.allocator);
    self.* = undefined;
}

fn load(self: *Self, c: *core.Context) Error!*const syntax.Document {
    if (self.document) |*d| return d;
    var failed_at: usize = 0;
    self.document = syntax.read(c, self.allocator, self.input, self.version, &failed_at) catch |err| {
        self.failed_at = failed_at;
        return err;
    };
    return &self.document.?;
}

/// The place in the walk.
pub fn offset(self: *const Self) usize {
    return self.at;
}
/// Where in the text a place in the walk was written.
pub fn place(self: *const Self, at: usize) usize {
    if (self.failed_at) |failed| return failed;
    const d = self.document orelse return 0;
    const node = at >> 2;
    if (at == done or node >= d.nodes.items.len) return self.input.len;
    return d.nodes.items[node].at;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a TOML value is no one span of its text (its table may be written in parts): read it as a type or as toml.Value");
}
/// Starts `into` over the part of the walk from `from` to `to`: one value,
/// read again.
pub fn replay(self: *const Self, into: *Self, from: usize, to: usize) void {
    into.* = .{ .input = self.input, .version = self.version, .allocator = self.allocator, .document = self.document, .owner = false, .at = from, .end = to, .frames = undefined, .extra = .empty, .depth = 0, .failed_at = null };
}

fn push(self: *Self, c: *core.Context, node: u32) Error!void {
    if (self.depth < self.frames.len) self.frames[self.depth] = node else self.extra.append(self.allocator, node) catch |err| return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
    };
    self.depth += 1;
}
fn top(self: *const Self) u32 {
    const i = self.depth - 1;
    return if (i < self.frames.len) self.frames[i] else self.extra.items[i - self.frames.len];
}
fn pop(self: *Self) void {
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
}
/// The place after `node`'s value: its next sibling's, its container's end,
/// or the walk's end.
fn after(self: *const Self, d: *const syntax.Document, node: u32) usize {
    if (self.depth == 0) return done;
    const container = self.top();
    const sibling = d.nodes.items[node].next;
    if (sibling == none) return placeOf(container, .end);
    return placeOf(sibling, if (d.nodes.items[container].kind == .table) .key else .value);
}

/// Whether the table or array being read has no more members.
pub fn atEnd(self: *Self) Error!bool {
    if (self.document == null or self.at == done) return false;
    return @as(Step, @fromBackingInt(@intCast(self.at & 3))) == .end;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const d = try self.load(c);
    if (self.at == done or self.at == self.end) return error.SyntaxError;
    const index: u32 = @intCast(self.at >> 2); // safe: a place holds a node's 32-bit position.
    const node = d.nodes.items[index];
    switch (@as(Step, @fromBackingInt(@intCast(self.at & 3)))) {
        .key => {
            self.at = placeOf(index, .value);
            return .{ .text = d.bytes(node.keyRef()) };
        },
        .date => {
            self.at = self.after(d, index);
            return .{ .text = d.bytes(node.bytesRef()) };
        },
        .end => {
            self.pop();
            self.at = self.after(d, index);
            return .end;
        },
        .value => {},
    }
    switch (node.kind) {
        .table, .array => {
            // A unit is an empty table.
            if (node.kind == .table and request.expected == .unit and node.count() == 0) {
                self.at = self.after(d, index);
                return .unit;
            }
            try self.push(c, index);
            self.at = if (node.count() == 0) placeOf(index, .end) else placeOf(node.first(), if (node.kind == .table) .key else .value);
            if (node.kind == .array) return .{ .begin = .{ .kind = .sequence, .len = node.count() } };
            const kind: core.Kind = if (request.expected == .record or request.expected == .variant) .record else .map;
            return .{ .begin = .{ .kind = kind, .len = node.count() } };
        },
        .string => {
            self.at = self.after(d, index);
            return .{ .text = d.bytes(node.bytesRef()) };
        },
        .integer, .float => {
            self.at = self.after(d, index);
            return .{ .number = d.bytes(node.bytesRef()) };
        },
        .true, .false => {
            self.at = self.after(d, index);
            return .{ .boolean = node.kind == .true };
        },
        .offset_date_time, .local_date_time, .local_date, .local_time => {
            self.at = placeOf(index, .date);
            const kind: temporal.Kind = switch (node.kind) {
                .offset_date_time => .offset_date_time,
                .local_date_time => .local_date_time,
                .local_date => .local_date,
                else => .local_time,
            };
            return .{ .tag = @backingInt(kind) };
        },
    }
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = try self.load(c);
    if (self.at != done) return error.SyntaxError;
}
