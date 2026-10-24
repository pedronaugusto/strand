//! A form (application/x-www-form-urlencoded, WHATWG URL section 5) as core
//! events. The input is a flat list of `name=value` pairs; the names'
//! bracketed paths (`user[name]`, `tags[]`) make it a tree, which is read as
//! the type asks: the pairs that share a path are one record or sequence,
//! wherever they stand in the list. Every value is text until the type asks
//! for something else: a number in JSON's spelling, `true` or `false`, the
//! raw bytes.
//!
//! The pairs are read once into the operation's arena; a record or sequence
//! is then read by scanning them for its path, each pair taken once. A name
//! repeated where one value belongs is a duplicate field, which the core
//! refuses unless told otherwise.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const text = @import("text.zig");
const numbers = @import("../json/number.zig");
pub const Format = enum { urlencoded };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .nonfinite_floats = false,
    .scalar_roots = false,
    .max_integer_bits = std.math.maxInt(usize),
    .utf8_text = true,
};

/// A number is spelled as JSON spells one.
pub fn parseInteger(comptime T: type, lexeme: []const u8, c: *core.Context) core.DecodeError!T {
    if (!numbers.valid(lexeme)) return error.UnexpectedType;
    return numbers.integer(T, lexeme, c);
}
pub fn parseFloat(comptime T: type, lexeme: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    if (!numbers.valid(lexeme)) return error.UnexpectedType;
    return numbers.floating(T, lexeme, exact, c);
}

const Pair = struct {
    /// The name, decoded.
    name: []const u8,
    lifetime: core.Lifetime,
    /// The value as it is written.
    value: []const u8,
    /// Where the pair starts in the input.
    at: usize,
    /// How many segments the name's path has.
    depth: usize,
    taken: bool = false,
};
const Kind = enum { record, sequence };
const Frame = struct {
    kind: Kind,
    /// The path the frame reads: the first `depth` segments of the name of
    /// pair `path`. The root's depth is zero.
    path: usize,
    depth: usize,
    /// Where the next member is looked for.
    cursor: usize,
    /// A record's member whose key was read, and whose value is next.
    member: ?usize = null,
};

input: []const u8,
pairs: ?[]Pair,
frames: std.ArrayList(Frame),
allocator: std.mem.Allocator,
root_done: bool,
/// The pair read last, for a failure's place.
current: usize,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    self.* = .{ .input = bytes, .pairs = null, .frames = .empty, .allocator = c.allocator(), .root_done = false, .current = 0 };
}
pub fn deinit(self: *Self) void {
    self.frames.deinit(self.allocator);
    self.* = undefined;
}
/// Where the pair being read starts.
pub fn offset(self: *const Self) usize {
    return self.current;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a union tagged inside its record is read twice, which a form's flat pairs cannot be: declare a data codec");
}
pub fn replay(_: *const Self, _: *Self, _: usize, _: usize) void {
    @compileError("a union tagged inside its record is read twice, which a form's flat pairs cannot be: declare a data codec");
}

fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        error.AllocationLimit => error.AllocationLimit,
        else => error.SyntaxError,
    };
}

/// Splits the input into its pairs, once. Empty pairs (`a=1&&b=2`) are none.
fn load(self: *Self, c: *core.Context) Error![]Pair {
    if (self.pairs) |pairs| return pairs;
    const most = std.mem.countScalar(u8, self.input, '&') + 1;
    try c.chargeWork(self.input.len);
    const pairs = c.alloc(Pair, @min(most, self.input.len)) catch |err| return failure(c, err);
    var n: usize = 0;
    var at: usize = 0;
    while (at < self.input.len) {
        const end = std.mem.findScalarPos(u8, self.input, at, '&') orelse self.input.len;
        defer at = end + 1;
        if (end == at) continue;
        self.current = at;
        const whole = self.input[at..end];
        const equals = std.mem.findScalar(u8, whole, '=') orelse whole.len;
        const name = try self.decoded(c, whole[0..equals], true);
        if (!std.unicode.utf8ValidateSlice(name.bytes)) return error.InvalidUtf8;
        if (!text.validName(name.bytes)) return error.SyntaxError;
        if (n >= c.limits.container_items) return error.ItemLimit;
        pairs[n] = .{
            .name = name.bytes,
            .lifetime = name.lifetime,
            .value = if (equals == whole.len) "" else whole[equals + 1 ..],
            .at = at,
            .depth = text.segments(name.bytes),
        };
        n += 1;
    }
    self.pairs = pairs[0..n];
    return pairs[0..n];
}

/// `raw` decoded: borrowed when decoding changes nothing, else in the arena.
fn decoded(_: *Self, c: *core.Context, raw_bytes: []const u8, is_key: bool) Error!core.Span {
    const d = text.decodedLength(raw_bytes) catch return error.SyntaxError;
    try c.span(d.len, is_key);
    try c.chargeWork(raw_bytes.len);
    if (!d.changes) return .{ .bytes = raw_bytes, .lifetime = .borrowed };
    const out = c.alloc(u8, d.len) catch |err| return failure(c, err);
    text.decode(raw_bytes, out);
    return .{ .bytes = out, .lifetime = .owned };
}

fn frame(self: *Self) *Frame {
    return &self.frames.items[self.frames.items.len - 1];
}

const Relation = enum { none, at, under };
/// Where pair `i` stands to the frame's path: its name is the path (`at`),
/// begins with it and goes on (`under`), or neither.
fn relation(pairs: []const Pair, f: Frame, i: usize) struct { relation: Relation, work: usize } {
    const p = pairs[i];
    if (f.depth == 0) return .{ .relation = .under, .work = 0 };
    if (p.depth < f.depth) return .{ .relation = .none, .work = 0 };
    const owner = pairs[f.path].name;
    const length = text.prefixLength(owner, f.depth);
    if (p.name.len < length or !std.mem.eql(u8, p.name[0..length], owner[0..length])) return .{ .relation = .none, .work = length };
    if (p.name.len == length) return .{ .relation = .at, .work = length };
    return .{ .relation = if (p.name[length] == '[') .under else .none, .work = length };
}

/// Whether pair `i` is a member of the frame: a record's members lie under
/// its path; a sequence's elements are `path=value` and `path[]=value`.
fn member(pairs: []const Pair, f: Frame, i: usize) error{UnexpectedType}!struct { member: bool, work: usize } {
    const r = relation(pairs, f, i);
    const p = pairs[i];
    const is_member = switch (f.kind) {
        .record => r.relation == .under,
        .sequence => switch (r.relation) {
            .none => false,
            .at => true,
            // Anything deeper (`path[x]`, `path[][x]`) is no element.
            .under => if (p.depth == f.depth + 1 and text.segment(p.name, f.depth).len == 0) true else return error.UnexpectedType,
        },
    };
    return .{ .member = is_member, .work = r.work };
}

/// The next pair the frame takes, from its cursor, or null.
fn nextMember(self: *Self, c: *core.Context) Error!?usize {
    const pairs = self.pairs.?;
    const f = self.frame();
    while (f.cursor < pairs.len) : (f.cursor += 1) {
        if (pairs[f.cursor].taken) continue;
        self.current = pairs[f.cursor].at;
        const m = try member(pairs, f.*, f.cursor);
        try c.chargeWork(m.work + 1);
        if (m.member) return f.cursor;
    }
    return null;
}

/// Whether the record or sequence being read has no more members.
pub fn atEnd(self: *Self) Error!bool {
    if (self.frames.items.len == 0) return false;
    const f = self.frame();
    if (f.member != null) return false;
    const pairs = self.pairs.?;
    for (pairs[f.cursor..], f.cursor..) |p, i| {
        if (p.taken) continue;
        if ((try member(pairs, f.*, i)).member) return false;
    }
    return true;
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const pairs = try self.load(c);
    if (self.frames.items.len == 0) {
        if (self.root_done) return error.SyntaxError;
        switch (request.expected) {
            .record, .map, .unknown => {},
            else => return error.UnexpectedType,
        }
        self.root_done = true;
        try self.push(c, .{ .kind = .record, .path = 0, .depth = 0, .cursor = 0 });
        return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } };
    }
    const f = self.frame();
    switch (f.kind) {
        .sequence => {
            const i = try self.nextMember(c) orelse return self.pop();
            f.cursor = i + 1;
            return self.value(c, i, request);
        },
        .record => if (f.member) |i| {
            f.member = null;
            f.cursor = i + 1;
            return self.memberValue(c, i, request);
        } else {
            const i = try self.nextMember(c) orelse return self.pop();
            self.current = pairs[i].at;
            const key = text.segment(pairs[i].name, f.depth);
            // A record's members are named; `[]` belongs to a sequence.
            if (key.len == 0) return error.UnexpectedType;
            f.member = i;
            return .{ .text = .{ .bytes = key, .lifetime = pairs[i].lifetime } };
        },
    }
}

/// The value of a record's member whose key was pair `i`'s next segment.
fn memberValue(self: *Self, c: *core.Context, i: usize, request: core.Request) Error!core.Event {
    const pairs = self.pairs.?;
    const depth = self.frame().depth + 1;
    switch (request.expected) {
        .sequence, .tuple => {
            try self.push(c, .{ .kind = .sequence, .path = i, .depth = depth, .cursor = i });
            return .{ .begin = .{ .kind = .sequence } };
        },
        .record, .map, .variant => {
            if (pairs[i].depth == depth) return error.UnexpectedType;
            try self.push(c, .{ .kind = .record, .path = i, .depth = depth, .cursor = i });
            return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } };
        },
        // An ignored member is whatever its pairs make it.
        .unknown => if (pairs[i].depth > depth) {
            const elements = text.segment(pairs[i].name, depth).len == 0;
            try self.push(c, .{ .kind = if (elements) .sequence else .record, .path = i, .depth = depth, .cursor = i });
            return .{ .begin = .{ .kind = if (elements) .sequence else .record } };
        },
        else => {},
    }
    if (pairs[i].depth != depth) return error.UnexpectedType;
    return self.value(c, i, request);
}

/// Pair `i`'s value, taken: text, or what the type asked for spelled as text.
fn value(self: *Self, c: *core.Context, i: usize, request: core.Request) Error!core.Event {
    const pairs = self.pairs.?;
    pairs[i].taken = true;
    self.current = pairs[i].at;
    try c.node();
    const span = try self.decoded(c, pairs[i].value, false);
    switch (request.expected) {
        .bytes => return .{ .bytes = span },
        .integer, .floating => {
            if (limit.exceeds(span.bytes.len, c.limits.numeric_bytes)) return error.LengthLimit;
            return .{ .number = span };
        },
        .boolean => {
            if (std.mem.eql(u8, span.bytes, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, span.bytes, "false")) return .{ .boolean = false };
            return error.UnexpectedType;
        },
        .unit => return if (span.bytes.len == 0) .unit else error.UnexpectedType,
        .record, .map, .variant, .sequence, .tuple => return error.UnexpectedType,
        else => {
            if (!std.unicode.utf8ValidateSlice(span.bytes)) return error.InvalidUtf8;
            return .{ .text = span };
        },
    }
}

fn push(self: *Self, c: *core.Context, f: Frame) Error!void {
    if (self.frames.items.len >= c.limits.depth) return error.DepthLimit;
    self.frames.append(self.allocator, f) catch |err| return failure(c, err);
}
fn pop(self: *Self) core.Event {
    _ = self.frames.pop();
    return .end;
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    const pairs = try self.load(c);
    if (self.frames.items.len != 0) return error.SyntaxError;
    for (pairs) |p| if (!p.taken) {
        self.current = p.at;
        return error.SyntaxError;
    };
}
