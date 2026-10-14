//! A YAML stream as core events. The stream is read whole into its nodes
//! when the first event is asked for (`document.zig`), then walked: a mapping
//! is a record or a map, a sequence a sequence, a quoted or block scalar text,
//! and an alias the node its anchor is on, walked again where the alias is.
//!
//! A plain scalar is resolved by where it is, as YAML lets an application
//! resolve one: what the type asks for (text, a number, a boolean, nothing)
//! when its spelling is one, and otherwise what the core schema says it is
//! (null, a boolean, an integer, a float, else a string), which is also what
//! a type that asks for nothing in particular, such as `yaml.Value`, gets.
//! So `version: 1.10` reads into a string as `1.10` and into a float as 1.1,
//! and `enabled: yes` is no boolean, only the string `yes`.
//!
//! A place in the walk is a node, so a value can be read twice (a union tagged
//! inside its mapping) by walking from its place again; a failure's place in
//! the text is where its node was written (`place`).
const std = @import("std");
const core = @import("../core.zig");
const document = @import("document.zig");
const schema = @import("schema.zig");
pub const Format = enum { yaml };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .any,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .bytes = false,
    .nested_optional = false,
    .indefinite_containers = false,
    .utf8_text = true,
};

pub const parseInteger = schema.parseInteger;
pub const parseFloat = schema.parseFloat;

/// What is read: one document, or the stream as a sequence of its documents.
pub const Root = enum { document, stream };

/// A collection being walked: where its members end, and where the walk goes
/// once they have (after an alias, back to where the alias is).
const Frame = struct { end: u32, resume_at: u32 };

input: []const u8,
root: Root,
/// The stream's working storage.
allocator: std.mem.Allocator,
stream: ?document.Document,
/// Whether this walk owns the stream (a replay borrows its walk's).
owner: bool,
/// The next node, and where the part being walked ends (`null` until the
/// stream is read: the whole of it).
at: u32,
end: ?u32,
frames: [64]Frame,
extra: std.ArrayList(Frame),
depth: usize,
/// Where in the text the stream was refused, when it was.
failed_at: ?usize,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
/// The stream is read onto `allocator`, charged to `c`, and given back by
/// `deinit`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8, root: Root, allocator: std.mem.Allocator) void {
    _ = c;
    self.* = .{ .input = bytes, .root = root, .allocator = allocator, .stream = null, .owner = true, .at = 0, .end = null, .frames = undefined, .extra = .empty, .depth = 0, .failed_at = null };
}
pub fn deinit(self: *Self) void {
    self.extra.deinit(self.allocator);
    if (self.owner) if (self.stream) |*d| d.deinit(self.allocator);
    self.* = undefined;
}

fn load(self: *Self, c: *core.Context) Error!*const document.Document {
    if (self.stream) |*d| return d;
    var failed_at: usize = 0;
    self.stream = document.read(c, self.allocator, self.input, &failed_at) catch |err| {
        self.failed_at = failed_at;
        return err;
    };
    const d = &self.stream.?;
    switch (self.root) {
        .stream => {
            self.at = 0;
            self.end = d.nodes.items[0].end;
        },
        .document => switch (d.documents()) {
            // No document is an empty one: null.
            0 => {
                const at: u32 = @intCast(self.input.len); // safe: below 4 GiB, as `read` checked.
                d.nodes.append(self.allocator, .{ .kind = .scalar, .data = .{}, .end = 2, .at = at }) catch |err| return switch (err) {
                    error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
                };
                self.at = 1;
                self.end = 2;
            },
            1 => {
                self.at = 1;
                self.end = d.nodes.items[1].end;
            },
            else => {
                // A second document where one is read.
                self.failed_at = d.nodes.items[d.nodes.items[1].end].at;
                return error.SyntaxError;
            },
        },
    }
    return d;
}

/// The place in the walk.
pub fn offset(self: *const Self) usize {
    return self.at;
}
/// Where in the text a place in the walk was written.
pub fn place(self: *const Self, at: usize) usize {
    if (self.failed_at) |failed| return failed;
    const d = self.stream orelse return 0;
    if (at >= d.nodes.items.len) return self.input.len;
    return d.nodes.items[at].at;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a YAML value is no one span of its text (an alias repeats another node): read it as a type or as yaml.Value");
}
/// Starts `into` over the part of the walk from `from` to `to`: one value,
/// read again.
pub fn replay(self: *const Self, into: *Self, from: usize, to: usize) void {
    into.* = .{ .input = self.input, .root = self.root, .allocator = self.allocator, .stream = self.stream, .owner = false, .at = @intCast(from), .end = @intCast(to), .frames = undefined, .extra = .empty, .depth = 0, .failed_at = null };
}

fn push(self: *Self, c: *core.Context, frame: Frame) Error!void {
    if (self.depth < self.frames.len) self.frames[self.depth] = frame else self.extra.append(self.allocator, frame) catch |err| return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
    };
    self.depth += 1;
}
fn top(self: *const Self) Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) self.frames[i] else self.extra.items[i - self.frames.len];
}
fn pop(self: *Self) void {
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
}

/// Whether the collection being read has no more members.
pub fn atEnd(self: *Self) Error!bool {
    if (self.stream == null or self.depth == 0) return false;
    return self.at == self.top().end;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const d = try self.load(c);
    if (self.depth > 0) {
        const frame = self.top();
        if (self.at == frame.end) {
            self.pop();
            self.at = frame.resume_at;
            return .end;
        }
    } else if (self.at == self.end.?) return error.SyntaxError;
    var index = self.at;
    var resume_at = d.nodes.items[index].end;
    if (d.nodes.items[index].kind == .alias) {
        // An alias is its anchor's node, walked again, and charged again
        // before it is: the whole of what it repeats.
        resume_at = index + 1;
        index = d.nodes.items[index].target();
        try c.chargeWork(d.nodes.items[index].weight());
    }
    const node = d.nodes.items[index];
    switch (node.kind) {
        .alias => unreachable, // unreachable: an alias names a node that is no alias.
        .sequence, .mapping => {
            // A unit is an empty mapping.
            if (node.kind == .mapping and request.expected == .unit and node.count() == 0) {
                self.at = resume_at;
                return .unit;
            }
            try self.push(c, .{ .end = node.end, .resume_at = resume_at });
            self.at = index + 1;
            if (node.kind == .sequence) return .{ .begin = .{ .kind = .sequence, .len = node.count() } };
            const kind: core.Kind = if (request.expected == .record or request.expected == .variant) .record else .map;
            return .{ .begin = .{ .kind = kind, .len = node.count() } };
        },
        .scalar => {
            self.at = resume_at;
            return scalar(d, node, request, c);
        },
    }
}

/// A scalar as the event its tag, or the type and its spelling, make it.
fn scalar(d: *const document.Document, node: document.Node, request: core.Request, c: *core.Context) Error!core.Event {
    const span = d.bytes(node);
    const text = span.bytes;
    switch (node.tag) {
        .none => if (node.style != .plain) return .{ .text = span },
        .non_specific, .str => return .{ .text = span },
        .null => return if (request.expected == .unit) .unit else .none,
        .bool => return .{ .boolean = schema.boolean(text).? },
        .int, .float => return number(span, c),
        .seq, .map => unreachable, // unreachable: refused on a scalar when read.
    }
    // A plain scalar: what the type asks for, where its spelling is one.
    if (request.nullable and schema.isNull(text)) return .none;
    switch (request.expected) {
        .text, .symbol => return .{ .text = span },
        .boolean => if (schema.boolean(text)) |b| return .{ .boolean = b },
        .integer, .floating => if (schema.number(text) != null) return number(span, c),
        .unit => if (schema.isNull(text)) return .unit,
        else => {},
    }
    return switch (schema.resolve(text)) {
        .null => .none,
        .boolean => .{ .boolean = schema.boolean(text).? },
        .integer, .float => number(span, c),
        .string => .{ .text = span },
    };
}
fn number(span: core.Span, c: *core.Context) Error!core.Event {
    if (span.bytes.len > c.limits.numeric_bytes) return error.LengthLimit;
    return .{ .number = span };
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = try self.load(c);
    if (self.depth != 0 or self.at != self.end.?) return error.SyntaxError;
}
