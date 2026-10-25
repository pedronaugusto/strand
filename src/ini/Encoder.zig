//! An INI document written from a record: its members that hold a value as
//! `key = value` lines, then each member that is a record as a `[section]`
//! of its own such lines, a blank line before it. A value of more lines than
//! one is continued on lines indented by a tab, as configparser writes one.
//! A null is a key with no value where the dialect takes one, and else
//! left out, so an optional reads back through its default. What
//! would not read back as itself is refused, `UnsupportedValue`: a key with
//! a delimiter or white space at an end, a value with white space at a
//! line's end, a comment's start, or a blank last line, a section in a
//! section, a sequence, and a key written after the first section, which INI
//! would read as the section's (declare a type's keys before its sections).
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
const syntax = @import("text.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

writer: *std.Io.Writer,
dialect: syntax.Dialect,
/// 0 before the root, 1 in the root, 2 in a section.
depth: u8,
/// The member whose key was written, and whose value is next.
member: ?[]const u8,
/// Whether a section has begun, after which no key of the root may follow.
sectioned: bool,
/// Whether a line has been written, so a section needs the blank line before it.
written: bool,
const Self = @This();

pub fn init(self: *Self, writer: *std.Io.Writer, dialect: syntax.Dialect) void {
    self.* = .{ .writer = writer, .dialect = dialect, .depth = 0, .member = null, .sectioned = false, .written = false };
}
pub fn deinit(self: *Self) void {
    self.* = undefined;
}

fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// Whether `key` written before `value` reads back as itself, lowercasing included.
fn checkKey(self: *Self, name: []const u8, value: []const u8, c: *core.Context) Error!void {
    try c.chargeWork(name.len);
    if (!std.unicode.utf8ValidateSlice(name) or !syntax.writableKey(name, value, self.dialect)) return error.UnsupportedValue;
}
/// `key = value` for the member whose key was written, in the root before
/// any section or in a section.
fn line(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const name = self.member orelse return error.CustomRejected;
    self.member = null;
    if (self.depth == 1 and self.sectioned) return error.UnsupportedValue;
    if (!std.unicode.utf8ValidateSlice(value)) return error.UnsupportedValue;
    try self.checkKey(name, value, c);
    try c.chargeWork(value.len);
    if (!syntax.writableValue(value, self.dialect)) return error.UnsupportedValue;
    try self.put(name, c);
    try self.put(" ", c);
    try self.put(self.dialect.delimiters[0..1], c);
    if (syntax.spaced(value, self.dialect)) try self.put(" ", c);
    var lines = std.mem.splitScalar(u8, value, '\n');
    try self.put(lines.first(), c);
    while (lines.next()) |l| {
        try self.put("\n\t", c);
        try self.put(l, c);
    }
    try self.put("\n", c);
    self.written = true;
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
    if (self.depth != 0 and self.member == null) return self.key(value, c);
    try self.line(value, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.line(value, c);
}
pub fn scalar(_: *Self, _: u21, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
/// A null is a key with no value where the dialect takes one, and else no line.
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    const name = self.member orelse return error.UnsupportedValue;
    self.member = null;
    if (!self.dialect.keys_without_values) return;
    if (self.depth == 1 and self.sectioned) return error.UnsupportedValue;
    try self.checkKey(name, "", c);
    try self.put(name, c);
    try self.put("\n", c);
    self.written = true;
}
/// A union's arm with no payload: its key with an empty value.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    try self.line("", c);
}
pub fn key(self: *Self, name: []const u8, c: *core.Context) Error!void {
    if (self.depth == 0 or self.member != null) return error.CustomRejected;
    self.member = name;
    // A section's name is checked as one when it begins.
    _ = c;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    _ = name;
    _ = len;
    switch (kind) {
        .record, .map => {},
        else => return error.UnsupportedValue,
    }
    switch (self.depth) {
        0 => self.depth = 1,
        1 => {
            const section = self.member orelse return error.CustomRejected;
            self.member = null;
            try c.chargeWork(section.len);
            if (!std.unicode.utf8ValidateSlice(section) or !syntax.writableSection(section, self.dialect)) return error.UnsupportedValue;
            if (self.written) try self.put("\n", c);
            try self.put("[", c);
            try self.put(section, c);
            try self.put("]\n", c);
            self.written = true;
            self.sectioned = true;
            self.depth = 2;
        },
        else => return error.UnsupportedValue,
    }
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    _ = c;
    self.depth -= 1;
}
pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn raw(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
