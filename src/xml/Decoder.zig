//! An XML document as core events. The document is read whole into its
//! nodes when the first event is asked for (`document.zig`), then walked.
//!
//! An element read as a record or a map is its attributes, keyed `@name`,
//! then its children in order, each child element keyed by its name and a
//! text run by `$text` (white space between child elements is formatting,
//! unless the element's content is mixed). Children of one name group into a
//! sequence where the type asks for one at the first of them, wherever the
//! rest stand; asked for one value, a second child of the name is a second
//! key. An element read as anything else is its text, read as the type asks
//! (XML Schema's number and boolean forms), its attributes unknown fields.
//! The root read as a union is the arm its name names; read as a sequence,
//! or an element read as one where it is no child of a record, it is its
//! children in order.
//!
//! A place in the walk is a node, so a value can be read twice (a union
//! tagged inside its element) by walking from its place again.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const document = @import("document.zig");
const text = @import("text.zig");
pub const Format = enum { xml };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
    .variant_record = true,
    .unicode_scalar = false,
    .named_shapes = false,
    .bytes = false,
    .nested_optional = false,
    .scalar_roots = true,
    .indefinite_containers = true,
    .utf8_text = true,
};

pub const parseInteger = text.parseInteger;
pub const parseFloat = text.parseFloat;

const Frame = union(enum) {
    /// An element's attributes and children, as keys and values.
    element: struct {
        node: u32,
        at: u32,
        end: u32,
        /// The node whose value is next, its key given.
        value: ?u32 = null,
        /// White space is content: the element's content is mixed, or it
        /// holds no child element for white space to stand between.
        mixed: bool,
        /// Where this element's grouped names start in `grouped`.
        grouped: u32,
        /// A map takes namespace declarations too; a record does not.
        declarations: bool,
        /// The next key, where `atEnd` has found it.
        peeked: ?u32 = null,
    },
    /// The children of one name, from the first.
    group: struct { name: []const u8, at: u32, end: u32, left: u32 },
    /// An element's children in order.
    children: struct { at: u32, end: u32, mixed: bool },
    /// The root as a union's arm: its name, then itself.
    arm: struct { node: u32, step: u2 = 0 },
};

input: []const u8,
options: document.Options,
/// The name the root must have, if any.
root_name: ?[]const u8,
allocator: std.mem.Allocator,
doc: ?document.Document,
owner: bool,
/// The next node to read, and where the part walked ends.
at: u32,
end: ?u32,
frames: std.ArrayList(Frame),
frame_buffer: [32]Frame,
/// The names grouped into sequences in the elements open: one is a key once.
grouped: std.ArrayList(u32),
failed_at: ?usize,
/// The root value has been read.
root_done: bool = false,
/// A replay reads one value again: an element read as a child is.
replayed: bool = false,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
/// The document is read onto `allocator`, charged to `c`, and given back by
/// `deinit`.
pub fn init(self: *Self, bytes: []const u8, options: document.Options, root_name: ?[]const u8, allocator: std.mem.Allocator) void {
    self.* = .{ .input = bytes, .options = options, .root_name = root_name, .allocator = allocator, .doc = null, .owner = true, .at = 0, .end = null, .frames = .empty, .frame_buffer = undefined, .grouped = .empty, .failed_at = null };
    self.frames = .initBuffer(&self.frame_buffer);
}
pub fn deinit(self: *Self) void {
    if (self.frames.items.ptr != &self.frame_buffer) self.frames.deinit(self.allocator);
    self.grouped.deinit(self.allocator);
    if (self.owner) if (self.doc) |*d| d.deinit(self.allocator);
    self.* = undefined;
}

fn load(self: *Self, c: *core.Context) Error!*const document.Document {
    if (self.doc) |*d| return d;
    var failed_at: usize = 0;
    self.doc = document.read(c, self.allocator, self.input, self.options, &failed_at) catch |err| {
        self.failed_at = failed_at;
        return err;
    };
    const d = &self.doc.?;
    self.at = 0;
    self.end = d.nodes.items[0].end;
    return d;
}
fn oom(c: *core.Context) Error {
    return if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory;
}

/// The place in the walk.
pub fn offset(self: *const Self) usize {
    return self.at;
}
/// Where in the text a place in the walk was written.
pub fn place(self: *const Self, at: usize) usize {
    if (self.failed_at) |failed| return failed;
    const d = self.doc orelse return 0;
    if (at >= d.nodes.items.len) return d.source.len;
    return d.nodes.items[at].at;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("an XML value is no one span of its text (its entities are read in place): read it as a type or as xml.Element");
}
/// Starts `into` over the part of the walk from `from` to `to`: one value,
/// read again.
pub fn replay(self: *const Self, into: *Self, from: usize, to: usize) void {
    into.* = .{ .input = self.input, .options = self.options, .root_name = null, .allocator = self.allocator, .doc = self.doc, .owner = false, .at = @intCast(from), .end = @intCast(to), .frames = .empty, .frame_buffer = undefined, .grouped = .empty, .failed_at = null };
    into.frames = .initBuffer(&into.frame_buffer);
    into.replayed = true;
}

fn push(self: *Self, c: *core.Context, frame: Frame) Error!void {
    if (self.frames.items.len == self.frames.capacity) {
        if (self.frames.items.ptr == &self.frame_buffer) {
            var grown: std.ArrayList(Frame) = .empty;
            grown.ensureTotalCapacity(self.allocator, self.frame_buffer.len * 2) catch return oom(c);
            grown.appendSliceAssumeCapacity(self.frames.items);
            self.frames = grown;
        } else self.frames.ensureUnusedCapacity(self.allocator, 1) catch return oom(c);
    }
    self.frames.appendAssumeCapacity(frame);
}
fn top(self: *Self) ?*Frame {
    if (self.frames.items.len == 0) return null;
    return &self.frames.items[self.frames.items.len - 1];
}

/// Whether the container being read has no more members.
pub fn atEnd(self: *Self) Error!bool {
    const d = &(self.doc orelse return false);
    const frame = self.top() orelse return false;
    return switch (frame.*) {
        .element => |*e| blk: {
            if (e.value != null) break :blk false;
            const k = self.nextKey(d, e);
            e.peeked = k;
            break :blk k == null;
        },
        .group => |g| g.left == 0,
        .children => |*ch| nextChild(d, ch.at, ch.end, ch.mixed) == null,
        .arm => |a| a.step == 2,
    };
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const d = try self.load(c);
    const frame = self.top() orelse return self.root(d, c, request);
    switch (frame.*) {
        .element => |*e| {
            if (e.value) |j| {
                e.value = null;
                return self.memberValue(d, c, e, j, request);
            }
            const found = if (e.peeked) |k| k else self.nextKey(d, e);
            e.peeked = null;
            const j = found orelse {
                self.grouped.shrinkRetainingCapacity(e.grouped);
                _ = self.frames.pop();
                return .end;
            };
            const node = d.nodes.items[j];
            e.at = node.end;
            e.value = j;
            self.at = j;
            return switch (node.kind) {
                .attribute, .element => .{ .text = .{ .bytes = d.name(node), .lifetime = if (node.kind == .attribute) .transient else d.lifetime(node.name_source) } },
                .text => .{ .text = .{ .bytes = "$text", .lifetime = .borrowed } },
            };
        },
        .group => |*g| {
            if (g.left == 0) {
                _ = self.frames.pop();
                return .end;
            }
            var j = g.at;
            while (true) : (j = d.nodes.items[j].end) {
                try c.chargeWork(1);
                const node = d.nodes.items[j];
                if (node.kind == .element and std.mem.eql(u8, d.name(node), g.name)) break;
            }
            g.at = d.nodes.items[j].end;
            g.left -= 1;
            self.at = j;
            return self.element(d, c, j, request);
        },
        .children => |*ch| {
            const j = nextChild(d, ch.at, ch.end, ch.mixed) orelse {
                _ = self.frames.pop();
                return .end;
            };
            const node = d.nodes.items[j];
            ch.at = node.end;
            self.at = j;
            if (node.kind == .text) return scalar(d.value(node), c, request);
            return self.element(d, c, j, request);
        },
        .arm => |*a| {
            a.step += 1;
            switch (a.step) {
                1 => {
                    const node = d.nodes.items[a.node];
                    return .{ .text = .{ .bytes = d.name(node), .lifetime = d.lifetime(node.name_source) } };
                },
                2 => return self.element(d, c, a.node, request),
                else => {
                    _ = self.frames.pop();
                    return .end;
                },
            }
        },
    }
}

fn root(self: *Self, d: *const document.Document, c: *core.Context, request: core.Request) Error!core.Event {
    if (self.root_done) return error.SyntaxError;
    self.root_done = true;
    const r = self.at;
    if (self.replayed) return self.element(d, c, r, request);
    const node = d.nodes.items[r];
    if (self.root_name) |wanted| if (!std.mem.eql(u8, d.name(node), wanted)) return error.UnexpectedType;
    switch (request.expected) {
        // The root's name is the arm, as an element is a union's arm in a
        // field, and a map's one key.
        .variant, .unknown, .map => {
            try self.push(c, .{ .arm = .{ .node = r } });
            return .{ .begin = .{ .kind = .record, .len = 1 } };
        },
        .sequence, .tuple => return self.open(d, c, r, request),
        else => return self.element(d, c, r, request),
    }
}

/// The next node of element `e` that is a key: an attribute, a child element
/// whose name is not grouped already, a text run that is content.
fn nextKey(self: *Self, d: *const document.Document, e: anytype) ?u32 {
    var j = e.at;
    while (j < e.end) : (j = d.nodes.items[j].end) {
        const node = d.nodes.items[j];
        switch (node.kind) {
            .attribute => if (e.declarations or !node.declaration) return j,
            .text => if (e.mixed or !node.blank) return j,
            .element => {
                const name = d.name(node);
                for (self.grouped.items[e.grouped..]) |g| {
                    if (std.mem.eql(u8, d.name(d.nodes.items[g]), name)) break;
                } else return j;
            },
        }
    }
    return null;
}
/// The next child of an element read as a sequence: an element, or a text
/// run that is content.
fn nextChild(d: *const document.Document, from: u32, end: u32, mixed: bool) ?u32 {
    var j = from;
    while (j < end) : (j = d.nodes.items[j].end) {
        const node = d.nodes.items[j];
        if (node.kind == .element or (node.kind == .text and (mixed or !node.blank))) return j;
    }
    return null;
}

/// The value of member `j` of element `e`, its key given.
fn memberValue(self: *Self, d: *const document.Document, c: *core.Context, e: anytype, j: u32, request: core.Request) Error!core.Event {
    const node = d.nodes.items[j];
    if (node.kind != .element) return scalar(d.value(node), c, request);
    if (request.expected != .sequence and request.expected != .tuple) return self.element(d, c, j, request);
    // The children of this name, wherever they stand: one sequence.
    const name = d.name(node);
    var count: u32 = 0;
    var k = j;
    while (k < e.end) : (k = d.nodes.items[k].end) {
        try c.chargeWork(1);
        const other = d.nodes.items[k];
        if (other.kind == .element and std.mem.eql(u8, d.name(other), name)) count += 1;
    }
    self.grouped.append(self.allocator, j) catch return oom(c);
    try self.push(c, .{ .group = .{ .name = name, .at = j, .end = e.end, .left = count } });
    return .{ .begin = .{ .kind = .sequence, .len = count } };
}

/// Element `j` as what `request` asks for.
fn element(self: *Self, d: *const document.Document, c: *core.Context, j: u32, request: core.Request) Error!core.Event {
    const node = d.nodes.items[j];
    const attributes = node.attributes();
    const first_child = j + 1 + attributes;
    const has_elements = node.elements;
    switch (request.expected) {
        .sequence, .tuple => return self.open(d, c, j, request),
        .record, .variant => return self.members(d, c, j, false),
        .map => return self.members(d, c, j, true),
        .unknown => if (has_elements or attributes != 0) return self.members(d, c, j, true),
        .unit => {
            if (node.end != j + 1) return error.UnexpectedType;
            return .unit;
        },
        else => {},
    }
    if (has_elements) return error.UnexpectedType;
    if (ownAttributes(d, j) and c.acceptance.reject_unknown_fields) return error.UnknownField;
    // Its text: at most one run, as comments and processing instructions
    // join the text around them, and nothing else.
    if (first_child < node.end) return scalar(d.value(d.nodes.items[first_child]), c, request);
    return scalar(.{ .bytes = "", .lifetime = .borrowed }, c, request);
}
fn members(self: *Self, d: *const document.Document, c: *core.Context, j: u32, declarations: bool) Error!core.Event {
    const node = d.nodes.items[j];
    var count: usize = node.attributes();
    var k = j + 1 + node.attributes();
    while (k < node.end) : (k = d.nodes.items[k].end) {
        const child = d.nodes.items[k];
        if (child.kind == .element or node.mixed or !node.elements or !child.blank) count += 1;
    }
    // Grouped children make fewer keys than this: the record's length is
    // left open, and this bounds it.
    try c.chargeWork(count + 1);
    try c.count(count);
    try self.push(c, .{ .element = .{ .node = j, .at = j + 1, .end = node.end, .mixed = node.mixed or !node.elements, .grouped = @intCast(self.grouped.items.len), .declarations = declarations } });
    return .{ .begin = .{ .kind = .record, .len = null } };
}
fn open(self: *Self, d: *const document.Document, c: *core.Context, j: u32, request: core.Request) Error!core.Event {
    _ = request;
    const node = d.nodes.items[j];
    if (ownAttributes(d, j) and c.acceptance.reject_unknown_fields) return error.UnknownField;
    var count: usize = 0;
    const mixed = node.mixed or !node.elements;
    var k = nextChild(d, j + 1 + node.attributes(), node.end, mixed);
    while (k) |at| : (k = nextChild(d, d.nodes.items[at].end, node.end, mixed)) count += 1;
    try c.chargeWork(count + 1);
    try self.push(c, .{ .children = .{ .at = j + 1 + node.attributes(), .end = node.end, .mixed = mixed } });
    return .{ .begin = .{ .kind = .sequence, .len = count } };
}

/// Whether element `j` has an attribute that declares no namespace.
fn ownAttributes(d: *const document.Document, j: u32) bool {
    for (d.nodes.items[j + 1 ..][0..d.nodes.items[j].attributes()]) |a| if (!a.declaration) return true;
    return false;
}

/// Text as what the type asks for.
fn scalar(span: core.Span, c: *core.Context, request: core.Request) Error!core.Event {
    switch (request.expected) {
        .integer, .floating => {
            if (limit.exceeds(text.trim(span.bytes).len, c.limits.numeric_bytes)) return error.LengthLimit;
            if (!text.isNumber(span.bytes)) return error.UnexpectedType;
            return .{ .number = span };
        },
        .boolean => return .{ .boolean = text.boolean(span.bytes) orelse return error.UnexpectedType },
        .unit => {
            if (span.bytes.len != 0) return error.UnexpectedType;
            return .unit;
        },
        else => return .{ .text = span },
    }
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = try self.load(c);
    if (self.frames.items.len != 0 or !self.root_done) return error.SyntaxError;
}
