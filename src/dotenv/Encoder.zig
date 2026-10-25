//! A .env file written from a record: a `KEY=value` line for each member, the
//! value quoted only where it must be to read back as itself (`text.quotingOf`):
//! unquoted, in single quotes, or in double quotes with `\\`, `\"`, `\n` and
//! `\r` escaped. A key is in single quotes where it holds `=`, `#` or white
//! space. A null is a key with no `=`. What would not read back as itself is
//! refused, `UnsupportedValue`: a key that is empty, or would need quotes and
//! holds `'`; a record or a sequence as a value. A map's key given twice is
//! `DuplicateField`.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const syntax = @import("text.zig");
const Names = @import("../ini/Encoder.zig").Names;
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

writer: *std.Io.Writer,
/// Whether the root has begun.
open: bool,
/// The member whose key was written, and whose value is next.
member: ?[]const u8,
/// Whether the root is a map, whose keys are checked for one given twice.
map: bool,
keys: Names,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer) void {
    self.writer = writer;
    self.open = false;
    self.member = null;
    self.map = false;
    self.keys = .empty;
}
pub fn deinit(self: *Self, c: *core.Context) void {
    self.keys.far.deinit(c.allocator());
    self.* = undefined;
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// The key of the member being written, checked and written, with `=` after
/// it unless it is to have no value.
fn startLine(self: *Self, sign: bool, c: *core.Context) Error![]const u8 {
    const name = self.member orelse return error.CustomRejected;
    self.member = null;
    try c.chargeWork(name.len);
    if (!std.unicode.utf8ValidateSlice(name)) return error.UnsupportedValue;
    const quoting = syntax.keyQuoting(name) orelse return error.UnsupportedValue;
    if (self.map) try self.keys.add(name, c);
    if (quoting == .single) try self.put("'", c);
    try self.put(name, c);
    if (quoting == .single) try self.put("'", c);
    if (sign) try self.put("=", c);
    return name;
}
/// `KEY=value` for the member whose key was written.
fn line(self: *Self, value: []const u8, c: *core.Context) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.UnsupportedValue;
    _ = try self.startLine(true, c);
    try c.chargeWork(value.len);
    switch (syntax.quotingOf(value)) {
        .none => try self.put(value, c),
        .single => {
            try self.put("'", c);
            try self.put(value, c);
            try self.put("'", c);
        },
        .double => {
            try self.put("\"", c);
            var from: usize = 0;
            for (value, 0..) |b, i| if (syntax.doubleEscape(b)) |escape| {
                try self.put(value[from..i], c);
                try self.put(escape, c);
                from = i + 1;
            };
            try self.put(value[from..], c);
            try self.put("\"", c);
        },
    }
    try self.put("\n", c);
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.line(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    if (limit.exceeds(spelling.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.line(spelling, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    if (!std.math.isFinite(value)) return error.UnsupportedValue;
    var buffer: [5200]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (limit.exceeds(spelling.len, c.limits.numeric_bytes)) return error.LengthLimit;
    try self.line(spelling, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    // A map's key comes as text.
    if (self.open and self.member == null) return self.key(value, c);
    try self.line(value, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.line(value, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// A null is a key with no `=`.
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    _ = try self.startLine(false, c);
    try self.put("\n", c);
}
/// A union's arm with no payload: its key with an empty value.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.line("", c);
}
pub fn key(self: *Self, name: []const u8, c: *core.Context) Error!void {
    _ = c;
    if (!self.open or self.member != null) return error.CustomRejected;
    self.member = name;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    _ = name;
    _ = len;
    _ = c;
    if (self.open) return error.UnsupportedValue;
    switch (kind) {
        .record, .map => {},
        else => return error.UnsupportedValue,
    }
    self.open = true;
    self.map = kind == .map;
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (self.member != null) return error.CustomRejected;
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
