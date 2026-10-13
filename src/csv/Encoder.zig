//! CSV written as RFC 4180 writes it: the header's names, then a record per
//! row, CRLF after each (or LF), a field quoted when it holds the delimiter,
//! the quote or a line break, or is empty text, with its quotes doubled. A
//! row's fields go in the header's order: one the core leaves out (a null
//! omitted, a default left off) is an empty field. A null is an empty field.
//! A field holds a value alone: a record, a sequence or a union in one is
//! `UnsupportedValue`.
const std = @import("std");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const fields = @import("text.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

const Frame = enum { none, rows, record, tuple, done };

writer: *std.Io.Writer,
dialect: fields.Dialect,
mode: Decoder.Mode,
/// The header's names, which a struct row's fields are matched against.
names: []const []const u8,
/// Whether the header line is written before the first row.
write_header: bool,
frame: Frame,
/// The column the next field of a row is, and the one a key named.
column: usize,
pending: ?usize,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, dialect: fields.Dialect, mode: Decoder.Mode, names: []const []const u8, write_header: bool) void {
    self.* = .{
        .writer = writer,
        .dialect = dialect,
        .mode = mode,
        .names = names,
        .write_header = write_header,
        .frame = .none,
        .column = 0,
        .pending = null,
    };
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// One field: the delimiter before it unless it is the row's first, then
/// its bytes, quoted where they must be.
fn putField(self: *Self, value: []const u8, quote_empty: bool, c: *core.Context) Error!void {
    if (self.column > 0) try self.put(&.{self.dialect.delimiter}, c);
    self.column += 1;
    const quoted = if (value.len == 0) quote_empty else fields.needsQuotes(value, self.dialect);
    if (!quoted) return self.put(value, c);
    try c.chargeWork(value.len);
    try self.put(&.{self.dialect.quote}, c);
    var rest = value;
    while (std.mem.findScalar(u8, rest, self.dialect.quote)) |q| {
        try self.put(rest[0 .. q + 1], c);
        try self.put(&.{self.dialect.quote}, c);
        rest = rest[q + 1 ..];
    }
    try self.put(rest, c);
    try self.put(&.{self.dialect.quote}, c);
}
fn header(self: *Self, c: *core.Context) Error!void {
    if (!self.write_header) return;
    self.write_header = false;
    self.column = 0;
    for (self.names) |name| try self.putField(name, true, c);
    try self.put(self.dialect.ending(), c);
}

/// Where a value goes: the column a key named in a struct row, or the next
/// one of a tuple row.
fn target(self: *Self) Error!void {
    switch (self.frame) {
        .record => {
            const column = self.pending orelse return error.CustomRejected;
            self.pending = null;
            _ = column;
        },
        .tuple => {},
        else => return error.UnsupportedValue,
    }
}
/// A value's field.
fn scalarField(self: *Self, value: []const u8, quote_empty: bool, c: *core.Context) Error!void {
    try self.target();
    try self.putField(value, quote_empty, c);
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.scalarField(if (value) "true" else "false", false, c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.scalarField(spelling, false, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    if (!std.math.isFinite(value)) return error.UnsupportedValue;
    var buffer: [5200]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.scalarField(spelling, false, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    // A map row's key comes as text.
    if (self.frame == .record and self.pending == null) return self.key(value, c);
    try self.scalarField(value, true, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.scalarField(value, true, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// A null is an empty field, unquoted.
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.scalarField("", false, c);
}
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.scalarField("", false, c);
}
/// A struct row's field name: the header's column it is, past any the row
/// left out, which are empty fields.
pub fn key(self: *Self, name: []const u8, c: *core.Context) Error!void {
    if (self.frame != .record or self.pending != null) return error.CustomRejected;
    try c.chargeWork(name.len);
    const column = for (self.names[self.column..], self.column..) |n, i| {
        if (std.mem.eql(u8, n, name)) break i;
    } else return error.UnsupportedValue;
    while (self.column < column) try self.putField("", false, c);
    self.pending = column;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    _ = name;
    _ = len;
    const row = kind == .record or kind == .map or kind == .tuple or kind == .sequence;
    switch (self.frame) {
        .none => if (self.mode == .document) {
            if (kind != .sequence and kind != .tuple) return error.UnsupportedValue;
            try self.header(c);
            self.frame = .rows;
            return;
        },
        .rows => {},
        else => return error.UnsupportedValue,
    }
    if (!row) return error.UnsupportedValue;
    if (self.frame == .none) try self.header(c);
    self.column = 0;
    self.pending = null;
    self.frame = if (kind == .record or kind == .map) .record else .tuple;
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    switch (self.frame) {
        .record, .tuple => {
            if (self.frame == .record) {
                if (self.pending != null) return error.CustomRejected;
                while (self.column < self.names.len) try self.putField("", false, c);
            }
            try self.put(self.dialect.ending(), c);
            self.frame = if (self.mode == .document) .rows else .done;
        },
        .rows => self.frame = .done,
        else => return error.CustomRejected,
    }
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
