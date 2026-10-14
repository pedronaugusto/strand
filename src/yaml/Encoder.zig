//! YAML written from core events, as it comes: block mappings and sequences
//! indented by two, a collection inside a sequence's entry started on the
//! entry's line, an empty collection as `{}` or `[]`. A string is plain where
//! it reads back as the same string and double-quoted where it would not (it
//! looks like a number, a boolean or null, or holds what plain text cannot),
//! with every character that is not printable escaped. A float is the
//! shortest spelling that reads back as the same binary64, `.inf`, `-.inf` or
//! `.nan`. A key that is a collection is written in flow style after `? `, as
//! is a key too long for an implicit one. No tags, anchors or comments.
const std = @import("std");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const schema = @import("schema.zig");
const scanner = @import("scanner.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

/// Where a block collection stands: the stream's root, a mapping's value
/// (after `key:`), or a sequence's entry (after `- `), where its first member
/// goes on the same line.
const Placement = enum { root, value, entry };
const Frame = struct {
    mapping: bool,
    /// A map's keys are checked for one given twice; a record's are the
    /// type's own.
    map: bool = false,
    /// Where this map's keys start among those kept.
    key_start: usize = 0,
    flow: bool,
    /// The column a block collection's members start at.
    indent: usize,
    placement: Placement,
    count: usize = 0,
    /// A mapping waits for a key.
    key_next: bool = true,
    /// The key being written is explicit (`? `): its `:` goes on a line of its own.
    explicit: bool = false,
};
/// A key longer than this is written after `? `: an implicit key is held to
/// 1024 characters.
const implicit_key_max = 1000;

writer: *std.Io.Writer,
stack: std.ArrayList(Frame),
/// Where the collections open are held past `frames`, if anywhere.
allocator: ?std.mem.Allocator,
frames: [64]Frame,
/// The scalar keys of the maps open, as what they are.
keys: std.ArrayList(Key),
key_buffer: [128]Key,
/// The string being double-quoted.
quoting: []const u8,
/// The root value is written.
done: bool,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, allocator: ?std.mem.Allocator) void {
    self.* = .{ .writer = writer, .stack = .empty, .allocator = allocator, .frames = undefined, .keys = .empty, .key_buffer = undefined, .quoting = "", .done = false };
    self.stack = .initBuffer(&self.frames);
    self.keys = .initBuffer(&self.key_buffer);
}
pub fn deinit(self: *Self) void {
    if (self.stack.items.ptr != &self.frames) self.stack.deinit(self.allocator.?);
    if (self.keys.items.ptr != &self.key_buffer) self.keys.deinit(self.allocator.?);
}

/// A scalar key as what it is: two keys are the same when they are the same
/// value, as a reader compares them. A string is its bytes, the caller's
/// while the write lasts.
const Key = struct {
    kind: schema.Kind,
    bits: u128 = 0,
    text: []const u8 = "",
    fn eql(a: Key, b: Key) bool {
        return a.kind == b.kind and a.bits == b.bits and std.mem.eql(u8, a.text, b.text);
    }
};
/// Checks a scalar about to be written: a map's key given twice is refused.
fn checkKey(self: *Self, key_: Key, c: *core.Context) Error!void {
    const frame = self.top() orelse return;
    if (!frame.map or !frame.key_next) return;
    for (self.keys.items[frame.key_start..]) |prior| {
        try c.chargeWork(@min(prior.text.len, key_.text.len) + 1);
        if (prior.eql(key_)) return error.DuplicateField;
    }
    if (self.keys.items.len == self.keys.capacity) {
        // Past the keys kept inline: on the allocator given, if one was.
        const allocator = self.allocator orelse return error.OutOfMemory;
        if (self.keys.items.ptr == &self.key_buffer) {
            var grown: std.ArrayList(Key) = .empty;
            try grown.ensureTotalCapacity(allocator, self.key_buffer.len * 2);
            grown.appendSliceAssumeCapacity(self.keys.items);
            self.keys = grown;
        } else try self.keys.ensureUnusedCapacity(allocator, 1);
    }
    self.keys.appendAssumeCapacity(key_);
}

fn put(self: *Self, out: []const u8, c: *core.Context) Error!void {
    try c.output(out.len);
    try self.writer.writeAll(out);
}
fn spaces(self: *Self, n: usize, c: *core.Context) Error!void {
    try c.output(n);
    try self.writer.splatByteAll(' ', n);
}
fn top(self: *Self) ?*Frame {
    if (self.stack.items.len == 0) return null;
    return &self.stack.items[self.stack.items.len - 1];
}
fn pushFrame(self: *Self, frame: Frame) Error!void {
    if (self.stack.items.len == self.stack.capacity) {
        // Deeper than `frames`: held on the allocator given, if one was.
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

/// What goes before the start of a block collection's member: the line
/// break after `key:` before its first, and each member's indentation, but
/// the first of a collection that starts on its entry's line.
fn memberStart(self: *Self, frame: *Frame, c: *core.Context) Error!void {
    if (frame.count == 0 and frame.placement == .value) try self.put("\n", c);
    if (!(frame.count == 0 and frame.placement == .entry)) try self.spaces(frame.indent, c);
}

/// What a scalar or a collection is placed after: written before it, as
/// where it stands asks. `len` is the length of the scalar about to be
/// written, null for a collection.
fn before(self: *Self, len: ?usize, c: *core.Context) Error!void {
    if (self.done) return error.UnsupportedValue;
    const frame = self.top() orelse return;
    if (frame.flow) {
        if (frame.mapping and !frame.key_next) return;
        if (frame.count > 0) try self.put(", ", c);
        return;
    }
    if (!frame.mapping) {
        try self.memberStart(frame, c);
        return self.put("- ", c);
    }
    if (!frame.key_next) return;
    // A key: implicit when it is a short scalar.
    try self.memberStart(frame, c);
    const n = len orelse {
        frame.explicit = true;
        return self.put("? ", c);
    };
    if (n > implicit_key_max) {
        frame.explicit = true;
        try self.put("? ", c);
    }
}
/// After a scalar or a collection: what its place asks for next.
fn after(self: *Self, c: *core.Context) Error!void {
    const frame = self.top() orelse {
        self.done = true;
        return;
    };
    if (frame.flow) {
        if (frame.mapping and frame.key_next) {
            try self.put(": ", c);
            frame.key_next = false;
            return;
        }
        frame.count += 1;
        frame.key_next = true;
        return;
    }
    if (frame.mapping and frame.key_next) {
        if (frame.explicit) {
            try self.put("\n", c);
            try self.spaces(frame.indent, c);
        }
        try self.put(":", c);
        frame.key_next = false;
        frame.explicit = false;
        return;
    }
    frame.count += 1;
    frame.key_next = true;
}

/// A scalar's spelling, placed.
fn scalarValue(self: *Self, spelled: []const u8, c: *core.Context) Error!void {
    try self.placed(spelled.len, spelled, c);
}
/// A scalar of `len` bytes, placed: `spelled`, or `value` double-quoted.
fn placed(self: *Self, len: usize, spelled: ?[]const u8, c: *core.Context) Error!void {
    try self.before(len, c);
    const frame = self.top();
    const in_value = if (frame) |f| !f.flow and f.mapping and !f.key_next else false;
    if (in_value) try self.put(" ", c);
    try c.output(len);
    if (spelled) |bytes_| try self.writer.writeAll(bytes_) else try quote(self.writer, self.quoting);
    const ends_line = if (frame) |f| !f.flow and !(f.mapping and f.key_next) else true;
    if (ends_line) try self.put("\n", c);
    try self.after(c);
}
/// A string, plain where that reads back as itself, double-quoted otherwise.
fn string(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const flow = if (self.top()) |f| f.flow else false;
    if (plain(value, flow)) return self.scalarValue(value, c);
    var counting: std.Io.Writer.Discarding = .init(&.{});
    quote(&counting.writer, value) catch unreachable; // unreachable: counting fails at nothing.
    self.quoting = value;
    try self.placed(std.math.cast(usize, counting.fullCount()) orelse return error.OutputLimit, null, c);
}

/// Whether `value` is written plain: it reads back as the same string,
/// in a flow collection when `flow` says it is in one.
pub fn plain(value: []const u8, flow: bool) bool {
    if (value.len == 0 or value.len > 512) return false;
    if (schema.resolve(value) != .string) return false;
    switch (value[0]) {
        '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`', ' ' => return false,
        else => {},
    }
    if (std.mem.startsWith(u8, value, "...")) return false;
    const last = value[value.len - 1];
    if (last == ' ' or last == ':') return false;
    var i: usize = 0;
    while (i < value.len) {
        const b = value[i];
        if (b < 0x80) {
            if (b < 0x20 or b == 0x7f) return false;
            if (b == ':' and i + 1 < value.len and value[i + 1] == ' ') return false;
            if (b == ' ' and i + 1 < value.len and value[i + 1] == '#') return false;
            if (flow and (b == ',' or b == '[' or b == ']' or b == '{' or b == '}')) return false;
            i += 1;
            continue;
        }
        const char = scanner.decodeChar(value[i..]) orelse return false;
        const cp = char.cp;
        const len = char.len;
        if (!printable(cp) or cp == 0x85 or cp == 0x2028 or cp == 0x2029 or cp == 0xFEFF) return false;
        i += len;
    }
    return true;
}
fn printable(cp: u21) bool {
    return switch (cp) {
        0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85, 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
}
/// `value` double-quoted, every character that is not printable, and the
/// line breaks, escaped.
pub fn quote(out: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    var i: usize = 0;
    while (i < value.len) {
        const b = value[i];
        if (b < 0x80) {
            switch (b) {
                '"' => try out.writeAll("\\\""),
                '\\' => try out.writeAll("\\\\"),
                '\n' => try out.writeAll("\\n"),
                '\t' => try out.writeAll("\\t"),
                '\r' => try out.writeAll("\\r"),
                0 => try out.writeAll("\\0"),
                0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try out.print("\\x{X:0>2}", .{b}),
                else => try out.writeByte(b),
            }
            i += 1;
            continue;
        }
        // The input is UTF-8, as text is checked before it is written.
        const char = scanner.decodeChar(value[i..]) orelse scanner.decodeChar("\u{FFFD}").?;
        const len = @min(char.len, value.len - i);
        const cp = char.cp;
        if (printable(cp) and cp != 0x85 and cp != 0xFEFF and cp != 0x2028 and cp != 0x2029) {
            try out.writeAll(value[i..][0..len]);
        } else if (cp == 0x85) {
            try out.writeAll("\\N");
        } else if (cp == 0x2028) {
            try out.writeAll("\\L");
        } else if (cp == 0x2029) {
            try out.writeAll("\\P");
        } else if (cp <= 0xFFFF) {
            try out.print("\\u{X:0>4}", .{cp});
        } else try out.print("\\U{X:0>8}", .{cp});
        i += len;
    }
    try out.writeByte('"');
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.checkKey(.{ .kind = .boolean, .bits = @intFromBool(value) }, c);
    try self.scalarValue(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    // An integer past 128 bits is no key a reader of this format compares.
    if (std.math.cast(i128, value)) |n| try self.checkKey(.{ .kind = .integer, .bits = @bitCast(n) }, c);
    var buffer: [48]u8 = undefined;
    const spelled = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (spelled.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.scalarValue(spelled, c);
}
/// The shortest spelling that reads back as the same binary64, with a
/// fraction or an exponent so that it reads as a float.
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    const v: f64 = @floatCast(value);
    try self.checkKey(.{ .kind = .float, .bits = if (std.math.isNan(v)) 1 else if (v == 0) 0 else @as(u64, @bitCast(v)) }, c);
    if (std.math.isFinite(value) and @as(@TypeOf(value), @floatCast(v)) != value) return error.NumberOutOfRange;
    if (std.math.isNan(v)) return self.scalarValue(".nan", c);
    if (std.math.isInf(v)) return self.scalarValue(if (v < 0) "-.inf" else ".inf", c);
    var buffer: [64]u8 = undefined;
    const magnitude = @abs(v);
    const decimals = magnitude == 0 or (magnitude >= 1e-5 and magnitude < 1e16);
    const spelled = (if (decimals) std.mem.print(&buffer, "{d}", .{v}) else std.mem.print(&buffer, "{e}", .{v})) catch return error.NumberOutOfRange;
    if (spelled.len > c.limits.numeric_bytes) return error.LengthLimit;
    if (std.mem.findAny(u8, spelled, ".e") != null) return self.scalarValue(spelled, c);
    var with_fraction: [66]u8 = undefined;
    @memcpy(with_fraction[0..spelled.len], spelled);
    @memcpy(with_fraction[spelled.len..][0..2], ".0");
    try self.scalarValue(with_fraction[0 .. spelled.len + 2], c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.checkKey(.{ .kind = .string, .text = value }, c);
    try self.string(value, c);
}
pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.checkKey(.{ .kind = .null }, c);
    try self.scalarValue("null", c);
}
/// Nothing, such as a union's arm with no payload: null.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.checkKey(.{ .kind = .null }, c);
    try self.scalarValue("null", c);
}
/// A record's field name: a key.
pub fn key(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const frame = self.top() orelse return error.UnsupportedValue;
    if (!frame.mapping or !frame.key_next) return error.UnsupportedValue;
    try self.string(value, c);
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, _: usize, c: *core.Context) Error!void {
    const mapping = switch (kind) {
        .record, .map, .variant => true,
        .sequence, .tuple => false,
        else => return error.UnsupportedValue,
    };
    try self.before(null, c);
    const parent = self.top();
    // A collection inside a flow collection, or as a key, is in flow style.
    const flow = if (parent) |p| p.flow or (p.mapping and p.key_next) else false;
    const map = kind == .map;
    const key_start = self.keys.items.len;
    if (flow) {
        try self.put(if (mapping) "{" else "[", c);
        try self.pushFrame(.{ .mapping = mapping, .map = map, .key_start = key_start, .flow = true, .indent = 0, .placement = .root });
    } else {
        const placement: Placement = if (parent == null) .root else if (parent.?.mapping) .value else .entry;
        const indent: usize = if (parent) |p| p.indent + 2 else 0;
        try self.pushFrame(.{ .mapping = mapping, .map = map, .key_start = key_start, .flow = false, .indent = indent, .placement = placement });
    }
    // A union is a mapping of its one arm.
    if (kind == .variant) try self.string(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const frame = self.stack.pop() orelse return error.UnsupportedValue;
    if (frame.mapping and !frame.key_next) return error.UnsupportedValue;
    self.keys.shrinkRetainingCapacity(frame.key_start);
    if (frame.flow) {
        try self.put(if (frame.mapping) "}" else "]", c);
    } else if (frame.count == 0) {
        // An empty collection, in flow style where it stands.
        if (frame.placement == .value) try self.put(" ", c);
        try self.put(if (frame.mapping) "{}\n" else "[]\n", c);
    }
    try self.after(c);
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    @compileError("YAML has no Raw value");
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    @compileError("YAML has no Raw value");
}

/// After the value: the document is whole.
pub fn finish(self: *Self) Error!void {
    if (!self.done or self.stack.items.len != 0) return error.UnsupportedValue;
}
