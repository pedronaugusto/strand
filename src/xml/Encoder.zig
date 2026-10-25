//! XML written from core events, as it comes. The root is an element of the
//! name the write is given (a union's root is its arm's element); a record's
//! or a map's members are its attributes (keys `@name`, before any child),
//! its character data (`$text`) and its children (any other key), a
//! sequence repeated elements of its key's name, a union an element holding
//! its arm's. Text is escaped where XML needs it (in attributes white space
//! too, so a reader's normalization gives it back), and a character XML
//! cannot hold is refused. A null has no spelling: an optional field that is
//! null is left out, and a null anywhere else is refused.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const xml_text = @import("text.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

/// How written XML is laid out: on one line, or a child element to a line,
/// indented as `json.write` indents (an element that holds text keeps its
/// children on its line, since white space there would be content).
pub const Whitespace = enum { minified, indent_1, indent_2, indent_3, indent_4, indent_8, indent_tab };

/// Where the next value goes.
const Slot = union(enum) {
    /// The document's root element, of this name.
    root: []const u8,
    /// A child element of this name.
    child: []const u8,
    /// An attribute of the open start tag.
    attribute: []const u8,
    /// Character data.
    text,
    /// None: a record or map waits for a key.
    none,
};
const Frame = struct {
    kind: enum { element, sequence, wrapper, transparent },
    /// The element's name; a sequence's items' name.
    name: []const u8,
    /// The start tag is not closed: attributes may still come.
    open_tag: bool = false,
    children: bool = false,
    text: bool = false,
    /// A map's keys come as text.
    map: bool = false,
    /// Where this element's attribute names start in `attributes`.
    attributes_start: usize = 0,
};

writer: *std.Io.Writer,
allocator: ?std.mem.Allocator,
indent: []const u8,
stack: std.ArrayList(Frame),
frames: [64]Frame,
/// The attribute names of the start tags open, to refuse one given twice.
attributes: std.ArrayList([]const u8),
attribute_buffer: [32][]const u8,
slot: Slot,
/// Namespace declarations for the root's start tag.
namespaces: []const Namespace,
done: bool,
const Self = @This();

pub const Namespace = struct {
    /// Empty for the default namespace.
    prefix: []const u8 = "",
    uri: []const u8,
};

pub fn init(self: *Self, writer: *std.Io.Writer, root: []const u8, whitespace: Whitespace, namespaces: []const Namespace, allocator: ?std.mem.Allocator) void {
    self.* = .{ .writer = writer, .allocator = allocator, .indent = indentUnit(whitespace), .stack = .empty, .frames = undefined, .attributes = .empty, .attribute_buffer = undefined, .slot = .{ .root = root }, .namespaces = namespaces, .done = false };
    self.stack = .initBuffer(&self.frames);
    self.attributes = .initBuffer(&self.attribute_buffer);
}
pub fn deinit(self: *Self) void {
    if (self.stack.items.ptr != &self.frames) self.stack.deinit(self.allocator.?);
    if (self.attributes.items.ptr != &self.attribute_buffer) self.attributes.deinit(self.allocator.?);
}
fn indentUnit(whitespace: Whitespace) []const u8 {
    return switch (whitespace) {
        .minified => "",
        .indent_1 => " ",
        .indent_2 => "  ",
        .indent_3 => "   ",
        .indent_4 => "    ",
        .indent_8 => "        ",
        .indent_tab => "\t",
    };
}

fn put(self: *Self, out: []const u8, c: *core.Context) Error!void {
    try c.output(out.len);
    try self.writer.writeAll(out);
}
fn escaped(self: *Self, value: []const u8, attribute: bool, c: *core.Context) Error!void {
    if (xml_text.forbidden(value) != null) return error.UnsupportedValue;
    try c.output(xml_text.escapedLength(value, attribute));
    try xml_text.escape(self.writer, value, attribute);
}
fn top(self: *Self) ?*Frame {
    if (self.stack.items.len == 0) return null;
    return &self.stack.items[self.stack.items.len - 1];
}
/// The element frame innermost, which holds what is written now.
fn element(self: *Self) ?*Frame {
    var i = self.stack.items.len;
    while (i > 0) {
        i -= 1;
        const f = &self.stack.items[i];
        if (f.kind == .element or f.kind == .wrapper) return f;
    }
    return null;
}
fn pushFrame(self: *Self, frame: Frame) Error!void {
    if (self.stack.items.len == self.stack.capacity) {
        const allocator = self.allocator orelse return error.DepthLimit;
        if (self.stack.items.ptr == &self.frames) {
            var grown: std.ArrayList(Frame) = .empty;
            try grown.ensureTotalCapacity(allocator, self.frames.len * 2);
            grown.appendSliceAssumeCapacity(self.stack.items);
            self.stack = grown;
        } else try self.stack.ensureUnusedCapacity(allocator, 1);
    }
    self.stack.appendAssumeCapacity(frame);
}
/// How many element frames are open: the depth of an indented line.
fn level(self: *Self) usize {
    var n: usize = 0;
    for (self.stack.items) |f| if (f.kind == .element or f.kind == .wrapper) {
        n += 1;
    };
    return n;
}
fn newline(self: *Self, depth: usize, c: *core.Context) Error!void {
    if (self.indent.len == 0) return;
    try self.put("\n", c);
    for (0..depth) |_| try self.put(self.indent, c);
}
/// Closes the innermost element's start tag, if it is open.
fn closeTag(self: *Self, c: *core.Context) Error!void {
    const f = self.element() orelse return;
    if (!f.open_tag) return;
    f.open_tag = false;
    self.attributes.shrinkRetainingCapacity(f.attributes_start);
    try self.put(">", c);
}
/// Where the next value goes, taken: a record's slot is used once.
fn take(self: *Self) Error!Slot {
    if (self.done) return error.UnsupportedValue;
    const slot = self.slot;
    if (self.top()) |f| {
        switch (f.kind) {
            // Every item of a sequence is an element of its name.
            .sequence => return .{ .child = f.name },
            else => {},
        }
    }
    self.slot = .none;
    return slot;
}
fn checkName(name: []const u8) Error!void {
    if (!xml_text.isWholeName(name)) return error.UnsupportedValue;
}
/// The start of an element named `name`, as a child of what is open.
fn startTag(self: *Self, name: []const u8, c: *core.Context) Error!void {
    try checkName(name);
    try self.closeTag(c);
    const depth = self.level();
    if (self.element()) |parent| {
        if (!parent.text) try self.newline(depth, c);
        parent.children = true;
    }
    try self.put("<", c);
    try self.put(name, c);
    if (self.stack.items.len == 0 and depth == 0) {
        for (self.namespaces) |ns| {
            try self.put(if (ns.prefix.len == 0) " xmlns" else " xmlns:", c);
            if (ns.prefix.len != 0) {
                try checkName(ns.prefix);
                try self.put(ns.prefix, c);
            }
            try self.put("=\"", c);
            try self.escaped(ns.uri, true, c);
            try self.put("\"", c);
        }
    }
}
/// A whole element holding `value` as its text.
fn textElement(self: *Self, name: []const u8, value: []const u8, c: *core.Context) Error!void {
    try self.startTag(name, c);
    try self.put(">", c);
    try self.escaped(value, false, c);
    try self.put("</", c);
    try self.put(name, c);
    try self.put(">", c);
}
fn endTag(self: *Self, f: Frame, c: *core.Context) Error!void {
    if (f.open_tag) {
        self.attributes.shrinkRetainingCapacity(f.attributes_start);
        return self.put("/>", c);
    }
    if (f.children and !f.text) try self.newline(self.level(), c);
    try self.put("</", c);
    try self.put(f.name, c);
    try self.put(">", c);
}
fn finishRoot(self: *Self) void {
    if (self.stack.items.len == 0) self.done = true;
}

/// A scalar's spelling where the next value goes.
fn scalarValue(self: *Self, value: []const u8, c: *core.Context) Error!void {
    // A map's key comes as text.
    if (self.top()) |f| if (f.map and self.slot == .none) return self.key(value, c);
    switch (try self.take()) {
        .root, .child => |name| try self.textElement(name, value, c),
        .attribute => |name| {
            const f = self.element() orelse return error.UnsupportedValue;
            if (!f.open_tag) return error.UnsupportedValue;
            try self.put(" ", c);
            try self.put(name, c);
            try self.put("=\"", c);
            try self.escaped(value, true, c);
            try self.put("\"", c);
        },
        .text => {
            try self.closeTag(c);
            if (self.element()) |f| f.text = true;
            try self.escaped(value, false, c);
        },
        .none => return error.UnsupportedValue,
    }
    self.finishRoot();
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.scalarValue(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    var buffer: [160]u8 = undefined;
    const spelled = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (limit.exceeds(spelled.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.scalarValue(spelled, c);
}
/// The shortest spelling that reads back as the same value, or XML Schema's
/// `INF`, `-INF` and `NaN`.
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    if (std.math.isNan(value)) return self.scalarValue("NaN", c);
    if (std.math.isInf(value)) return self.scalarValue(if (value < 0) "-INF" else "INF", c);
    var buffer: [128]u8 = undefined;
    const magnitude = @abs(value);
    const decimals = magnitude == 0 or (magnitude >= 1e-5 and magnitude < 1e16);
    const spelled = (if (decimals) std.mem.print(&buffer, "{d}", .{value}) else std.mem.print(&buffer, "{e}", .{value})) catch return error.NumberOutOfRange;
    if (limit.exceeds(spelled.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.scalarValue(spelled, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.scalarValue(value, c);
}
pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn nullValue(_: *Self, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// Nothing, such as a union's arm with no payload: an empty element.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    switch (try self.take()) {
        .root, .child => |name| {
            try self.startTag(name, c);
            try self.put("/>", c);
        },
        .attribute => |name| {
            const f = self.element() orelse return error.UnsupportedValue;
            if (!f.open_tag) return error.UnsupportedValue;
            try self.put(" ", c);
            try self.put(name, c);
            try self.put("=\"\"", c);
        },
        .text => {},
        .none => return error.UnsupportedValue,
    }
    self.finishRoot();
}
/// A member's key: where its value goes.
pub fn key(self: *Self, name: []const u8, c: *core.Context) Error!void {
    if (self.slot != .none) return error.UnsupportedValue;
    if (name.len > 0 and name[0] == '@') {
        const attribute = name[1..];
        try checkName(attribute);
        const f = self.element() orelse return error.UnsupportedValue;
        if (!f.open_tag) return error.UnsupportedValue;
        for (self.attributes.items[f.attributes_start..]) |prior| {
            try c.chargeWork(@min(prior.len, attribute.len) + 1);
            if (std.mem.eql(u8, prior, attribute)) return error.DuplicateField;
        }
        try self.keepAttribute(attribute);
        self.slot = .{ .attribute = attribute };
    } else if (std.mem.eql(u8, name, "$text")) {
        self.slot = .text;
    } else {
        try checkName(name);
        self.slot = .{ .child = name };
    }
}
fn keepAttribute(self: *Self, name: []const u8) Error!void {
    if (self.attributes.items.len == self.attributes.capacity) {
        const allocator = self.allocator orelse return error.OutOfMemory;
        if (self.attributes.items.ptr == &self.attribute_buffer) {
            var grown: std.ArrayList([]const u8) = .empty;
            try grown.ensureTotalCapacity(allocator, self.attribute_buffer.len * 2);
            grown.appendSliceAssumeCapacity(self.attributes.items);
            self.attributes = grown;
        } else try self.attributes.ensureUnusedCapacity(allocator, 1);
    }
    self.attributes.appendAssumeCapacity(name);
}

pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    _ = len;
    if (self.top()) |f| if (f.map and self.slot == .none) return error.UnsupportedValue;
    const slot = try self.take();
    switch (kind) {
        .record, .map => switch (slot) {
            .root, .child => |element_name| {
                try self.startTag(element_name, c);
                try self.pushFrame(.{ .kind = .element, .name = element_name, .open_tag = true, .map = kind == .map, .attributes_start = self.attributes.items.len });
            },
            else => return error.UnsupportedValue,
        },
        .sequence, .tuple => switch (slot) {
            // A sequence repeats its key's element; a sequence's item or the
            // root has no name to repeat.
            .child => |element_name| {
                if (self.top()) |f| if (f.kind == .sequence) return error.UnsupportedValue;
                try self.pushFrame(.{ .kind = .sequence, .name = element_name });
            },
            else => return error.UnsupportedValue,
        },
        .variant => switch (slot) {
            // The root is the arm's element; anywhere else an element
            // holds it.
            .root => {
                try self.pushFrame(.{ .kind = .transparent, .name = "" });
                self.slot = .{ .child = name };
            },
            .child => |element_name| {
                try self.startTag(element_name, c);
                try self.put(">", c);
                try self.pushFrame(.{ .kind = .wrapper, .name = element_name, .attributes_start = self.attributes.items.len });
                self.slot = .{ .child = name };
            },
            else => return error.UnsupportedValue,
        },
        else => return error.UnsupportedValue,
    }
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const f = self.stack.pop() orelse return error.UnsupportedValue;
    self.slot = .none;
    switch (f.kind) {
        .element, .wrapper => try self.endTag(f, c),
        .sequence, .transparent => {},
    }
    self.finishRoot();
}
/// After the value: nothing is left open.
pub fn finish(self: *Self) Error!void {
    if (!self.done or self.stack.items.len != 0) return error.UnsupportedValue;
}
