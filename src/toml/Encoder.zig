//! TOML written from core events. A table's plain values come before the
//! tables under it in TOML (after `[a]`, every key is `a`'s until the next
//! header), and the events give a type's members in declaration order, so
//! the document is held as a tree on the allocator given, then written whole
//! once the root closes: each table's values as `key = value` lines, then its
//! tables under `[path]` headers, an array whose elements are all tables as
//! `[[path]]` sections, anything else inline. Strings are basic strings,
//! floats the shortest spelling that reads back as the same binary64, dates
//! and times RFC 3339's spelling with seconds. The output reads as TOML 1.0
//! and as 1.1.
//!
//! TOML has no null: a null is refused, unless the write leaves optional
//! fields that are null out of their tables (`WriteOptions.nulls`).
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const strings = @import("text.zig");
const temporal = @import("temporal.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

const Node = union(enum) {
    table: *Table,
    array: *Array,
    /// A value's spelling, written as it is.
    scalar: []const u8,
};
const Entry = struct { key: []const u8, node: Node };
const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// A map's keys are checked for one given twice; a record's are the type's own.
    map: bool,
    /// The key the next value is written under.
    key: ?[]const u8 = null,
};
const Array = struct { items: std.ArrayList(Node) = .empty };

writer: *std.Io.Writer,
arena: std.heap.ArenaAllocator,
/// The containers open, innermost last.
stack: std.ArrayList(Node),
root: ?Node,
/// How the root is written: as a document, its sections under `path`, or
/// inline, as one value.
layout: Layout,
path: []const []const u8,
/// A date's or a time's kind, given by a tag: the text written next is its spelling.
kind: ?temporal.Kind,
const Self = @This();

pub const Layout = enum { document, inline_value };

pub fn init(self: *Self, writer: *std.Io.Writer, allocator: std.mem.Allocator, layout: Layout, path: []const []const u8) void {
    self.* = .{ .writer = writer, .arena = .init(allocator), .stack = .empty, .root = null, .layout = layout, .path = path, .kind = null };
}
pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn fail(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnsupportedValue,
    };
}

/// Places `node` where the next value goes: under the open table's key, at
/// the end of the open array, or as the root.
fn place(self: *Self, node: Node, c: *core.Context) Error!void {
    const a = self.arena.allocator();
    if (self.kind != null) return error.UnsupportedValue;
    if (self.stack.items.len == 0) {
        if (self.root != null or (self.layout == .document and node != .table)) return error.UnsupportedValue;
        self.root = node;
        // A scalar root, written inline, is whole as it is placed.
        if (node == .scalar) return self.inlineValue(node, c);
        return;
    }
    switch (self.stack.items[self.stack.items.len - 1]) {
        .table => |t| {
            const name = t.key orelse return error.UnsupportedValue;
            t.key = null;
            t.entries.append(a, .{ .key = name, .node = node }) catch |err| return fail(err);
        },
        .array => |arr| arr.items.append(a, node) catch |err| return fail(err),
        .scalar => unreachable, // unreachable: only containers are open.
    }
}
/// A value spelled by `print`, placed.
fn spell(self: *Self, comptime spelling: []const u8, args: anytype, c: *core.Context) Error!void {
    const spelled = self.arena.allocator().print(spelling, args) catch |err| return fail(err);
    try self.place(.{ .scalar = spelled }, c);
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.place(.{ .scalar = if (value) "true" else "false" }, c);
}
/// TOML's integers are signed 64-bit.
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const n = std.math.cast(i64, value) orelse return error.NumberOutOfRange;
    try self.spell("{d}", .{n}, c);
}
/// The shortest spelling that reads back as the same binary64, with a
/// fraction or an exponent so that it reads as a float.
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    const v: f64 = @floatCast(value);
    if (std.math.isFinite(value) and @as(@TypeOf(value), @floatCast(v)) != value) return error.NumberOutOfRange;
    if (std.math.isNan(v)) return self.place(.{ .scalar = if (std.math.signbit(v)) "-nan" else "nan" }, c);
    if (std.math.isInf(v)) return self.place(.{ .scalar = if (v < 0) "-inf" else "inf" }, c);
    var buffer: [64]u8 = undefined;
    const magnitude = @abs(v);
    const decimals = magnitude == 0 or (magnitude >= 1e-5 and magnitude < 1e16);
    const spelled = (if (decimals) std.mem.print(&buffer, "{d}", .{v}) else std.mem.print(&buffer, "{e}", .{v})) catch return error.NumberOutOfRange;
    if (limit.exceeds(spelled.len, c.limits.numeric_bytes)) return error.LengthLimit;
    const float = std.mem.findAny(u8, spelled, ".e") != null;
    try self.spell("{s}{s}", .{ spelled, if (float) "" else ".0" }, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    // A map's key comes as text where a table waits for one.
    if (self.kind == null and self.stack.items.len > 0) switch (self.stack.items[self.stack.items.len - 1]) {
        .table => |t| if (t.key == null) return self.key(value, c),
        else => {},
    };
    if (self.kind) |kind| {
        self.kind = null;
        // The spelling of a date or a time, written bare: checked, as Raw is.
        const parts = temporal.parse(value) orelse return error.UnsupportedValue;
        if (parts.kind != kind or !temporal.valid(parts)) return error.UnsupportedValue;
        var buffer: [temporal.max_len]u8 = undefined;
        const spelled = temporal.format(parts, &buffer);
        const copy = self.arena.allocator().dupe(u8, spelled) catch |err| return fail(err);
        return self.place(.{ .scalar = copy }, c);
    }
    try self.place(.{ .scalar = try self.quote(value) }, c);
}
/// `value` as a basic string, in the tree's storage.
fn quote(self: *Self, value: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
    _ = strings.quoted(&out.writer, value) catch return error.OutOfMemory;
    return out.written();
}
pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// TOML has no null.
pub fn nullValue(_: *Self, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// Nothing, such as a union's arm with no payload: an empty table.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.begin(.map, "", 0, c);
    try self.end(c);
}
pub fn key(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const t = self.stack.items[self.stack.items.len - 1].table;
    if (t.map) for (t.entries.items) |entry| {
        try c.chargeWork(@min(entry.key.len, value.len) + 1);
        if (std.mem.eql(u8, entry.key, value)) return error.DuplicateField;
    };
    t.key = self.arena.allocator().dupe(u8, value) catch |err| return fail(err);
}
/// A date's or a time's kind (`temporal.Kind`); its spelling is the text written next.
pub fn tag(self: *Self, number: u64, _: *core.Context) Error!void {
    if (self.kind != null) return error.UnsupportedValue;
    self.kind = std.enums.fromInt(temporal.Kind, number) orelse return error.UnsupportedValue;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, _: usize, c: *core.Context) Error!void {
    const a = self.arena.allocator();
    const node: Node = switch (kind) {
        .record, .map, .variant => blk: {
            const t = a.create(Table) catch |err| return fail(err);
            t.* = .{ .map = kind == .map };
            // A union is a table of its one arm.
            if (kind == .variant) t.key = a.dupe(u8, name) catch |err| return fail(err);
            break :blk .{ .table = t };
        },
        .sequence, .tuple => blk: {
            const arr = a.create(Array) catch |err| return fail(err);
            arr.* = .{};
            break :blk .{ .array = arr };
        },
        else => return error.UnsupportedValue,
    };
    try self.place(node, c);
    self.stack.append(a, node) catch |err| return fail(err);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    if (self.kind != null) return error.UnsupportedValue;
    _ = self.stack.pop();
    if (self.stack.items.len == 0) try self.document(c);
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    @compileError("TOML has no Raw value");
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    @compileError("TOML has no Raw value");
}

// Writing the tree.

fn put(self: *Self, bytes_: []const u8, c: *core.Context) Error!void {
    try c.output(bytes_.len);
    try self.writer.writeAll(bytes_);
}
/// Whether a value is written under a header of its own: a table, and an
/// array that holds tables alone.
fn section(node: Node) bool {
    return switch (node) {
        .table => true,
        .array => |arr| arr.items.items.len > 0 and for (arr.items.items) |item| {
            if (item != .table) break false;
        } else true,
        .scalar => false,
    };
}
fn writeKey(self: *Self, value: []const u8, c: *core.Context) Error!void {
    if (strings.bare(value)) return self.put(value, c);
    try self.put(try self.quote(value), c);
}
fn writePath(self: *Self, path: []const []const u8, c: *core.Context) Error!void {
    for (path, 0..) |part, i| {
        if (i > 0) try self.put(".", c);
        try self.writeKey(part, c);
    }
}
fn inlineValue(self: *Self, node: Node, c: *core.Context) Error!void {
    switch (node) {
        .scalar => |s| try self.put(s, c),
        .array => |arr| {
            try self.put("[", c);
            for (arr.items.items, 0..) |item, i| {
                if (i > 0) try self.put(", ", c);
                try self.inlineValue(item, c);
            }
            try self.put("]", c);
        },
        .table => |t| {
            if (t.entries.items.len == 0) return self.put("{}", c);
            try self.put("{ ", c);
            for (t.entries.items, 0..) |entry, i| {
                if (i > 0) try self.put(", ", c);
                try self.writeKey(entry.key, c);
                try self.put(" = ", c);
                try self.inlineValue(entry.node, c);
            }
            try self.put(" }", c);
        },
    }
}
/// A table's values, then its sections, `path` naming it.
fn table(self: *Self, t: *Table, path: *std.ArrayList([]const u8), c: *core.Context) Error!void {
    for (t.entries.items) |entry| if (!section(entry.node)) {
        try self.writeKey(entry.key, c);
        try self.put(" = ", c);
        try self.inlineValue(entry.node, c);
        try self.put("\n", c);
    };
    for (t.entries.items) |entry| if (section(entry.node)) {
        path.append(self.arena.allocator(), entry.key) catch |err| return fail(err);
        defer _ = path.pop();
        switch (entry.node) {
            .table => |sub| {
                // A table with no values of its own but tables under it is
                // made by their headers; one with nothing at all needs its own.
                const values = for (sub.entries.items) |e| {
                    if (!section(e.node)) break true;
                } else false;
                if (values or sub.entries.items.len == 0) {
                    try self.header(path.items, "[", "]", c);
                }
                try self.table(sub, path, c);
            },
            .array => |arr| for (arr.items.items) |item| {
                try self.header(path.items, "[[", "]]", c);
                try self.table(item.table, path, c);
            },
            .scalar => unreachable, // unreachable: a scalar is no section.
        }
    };
}
fn header(self: *Self, path: []const []const u8, open: []const u8, close: []const u8, c: *core.Context) Error!void {
    if (c.outputUsed() > 0) try self.put("\n", c);
    try self.put(open, c);
    try self.writePath(path, c);
    try self.put(close, c);
    try self.put("\n", c);
}
fn document(self: *Self, c: *core.Context) Error!void {
    if (self.layout == .inline_value) return self.inlineValue(self.root.?, c);
    var path: std.ArrayList([]const u8) = .empty;
    path.appendSlice(self.arena.allocator(), self.path) catch |err| return fail(err);
    try self.table(self.root.?.table, &path, c);
}

/// After the value: the document is written once its root closes.
pub fn finish(self: *Self) Error!void {
    if (self.root == null or self.stack.items.len != 0) return error.UnsupportedValue;
}
