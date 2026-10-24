//! CSV (RFC 4180) as core events: a document is a sequence of rows, a row a
//! record named by the header or a tuple by position, a field a value. Every
//! field is text until the type asks for something else: a number in JSON's
//! spelling, `true` or `false`, the raw bytes, or a null, which an empty
//! unquoted field is where the type takes one. A quoted field with no doubled
//! quote, and every unquoted one, is borrowed from the input.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const text = @import("text.zig");
const numbers = @import("../json/number.zig");
pub const Format = enum { csv };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
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

/// What the input is: a whole document, or one record read by a `Reader`.
pub const Mode = enum { document, row };
const Frame = enum { none, rows, record, tuple, done };

input: []const u8,
at: usize,
dialect: text.Dialect,
mode: Mode,
/// The header's names; a `Reader` hands them over for each row.
names: []const core.Span,
header_read: bool,
frame: Frame,
/// The row being read: the field it is at, whether its key was read, and
/// whether its last field ended the record.
field_index: usize,
key_read: bool,
row_done: bool,
/// Where the row being read starts, for a failure's place.
row_start: usize,
root_done: bool,
const Self = @This();

/// Starts `self` over `bytes`, a whole document, which the caller has charged
/// to `c.input`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    _ = c;
    self.* = .{
        .input = bytes,
        .at = 0,
        .dialect = .{},
        .mode = .document,
        .names = &.{},
        .header_read = false,
        .frame = .none,
        .field_index = 0,
        .key_read = false,
        .row_done = false,
        .row_start = 0,
        .root_done = false,
    };
}
pub fn deinit(self: *Self) void {
    self.* = undefined;
}
/// Where the row being read starts.
pub fn offset(self: *const Self) usize {
    return self.row_start;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a union tagged inside its record is read twice, which a CSV row's fields are not laid out for: declare a data codec");
}
pub fn replay(_: *const Self, _: *Self, _: usize, _: usize) void {
    @compileError("a union tagged inside its record is read twice, which a CSV row's fields are not laid out for: declare a data codec");
}

/// The header's names, read from the first record into the arena.
fn readHeader(self: *Self, c: *core.Context) Error!void {
    self.header_read = true;
    if (!self.dialect.header) return;
    self.at = text.skipBlank(self.input, self.at);
    if (self.at >= self.input.len) return;
    var count: usize = 0;
    var scan = self.at;
    while (true) {
        const f = text.field(self.input, scan, self.dialect) catch return error.SyntaxError;
        count += 1;
        if (f.after != .delimiter) break;
        scan = f.end + 1;
    }
    if (count > c.limits.container_items) return error.ItemLimit;
    const names = try c.alloc(core.Span, count);
    for (names) |*name| {
        const f = text.field(self.input, self.at, self.dialect) catch return error.SyntaxError;
        name.* = try self.span(c, f, true);
        if (!std.unicode.utf8ValidateSlice(name.bytes)) return error.InvalidUtf8;
        self.at = if (f.after == .delimiter) f.end + 1 else text.pastEnd(self.input, f.end);
    }
    self.names = names;
}

/// A field's value: borrowed, or with its doubled quotes made single in the arena.
fn span(self: *Self, c: *core.Context, f: text.Field, is_key: bool) Error!core.Span {
    if (!f.escaped) {
        try c.span(f.bytes.len, is_key);
        return .{ .bytes = f.bytes, .lifetime = .borrowed };
    }
    const length = text.unescapedLength(f.bytes, self.dialect.quote);
    try c.span(length, is_key);
    try c.chargeWork(f.bytes.len);
    const out = try c.alloc(u8, length);
    text.unescape(f.bytes, self.dialect.quote, out);
    return .{ .bytes = out, .lifetime = .owned };
}

/// Whether the rows or the row being read has nothing more.
pub fn atEnd(self: *Self) Error!bool {
    return switch (self.frame) {
        .none, .done => false,
        .rows => text.skipBlank(self.input, self.at) >= self.input.len,
        .record => !self.key_read and self.field_index == self.names.len,
        .tuple => self.row_done,
    };
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    switch (self.frame) {
        .done => return error.SyntaxError,
        .none => switch (self.mode) {
            .document => {
                switch (request.expected) {
                    .sequence, .tuple, .unknown => {},
                    else => return error.UnexpectedType,
                }
                if (!self.header_read) try self.readHeader(c);
                self.frame = .rows;
                return .{ .begin = .{ .kind = .sequence } };
            },
            .row => return self.beginRow(request),
        },
        .rows => {
            self.at = text.skipBlank(self.input, self.at);
            if (self.at >= self.input.len) {
                self.frame = .done;
                return .end;
            }
            return self.beginRow(request);
        },
        .record => {
            if (self.key_read) {
                self.key_read = false;
                return self.value(c, request);
            }
            if (self.field_index == self.names.len) return self.endRow();
            // A record that ended before the header did.
            if (self.row_done) return error.SyntaxError;
            self.key_read = true;
            try c.node();
            return .{ .text = self.names[self.field_index] };
        },
        .tuple => {
            if (self.row_done) return self.endRow();
            return self.value(c, request);
        },
    }
}

fn beginRow(self: *Self, request: core.Request) Error!core.Event {
    self.row_start = self.at;
    self.field_index = 0;
    self.key_read = false;
    self.row_done = false;
    switch (request.expected) {
        .record, .map => {
            if (!self.dialect.header) return error.UnexpectedType;
            self.frame = .record;
            return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record, .len = self.names.len } };
        },
        .tuple, .sequence, .unknown => {
            self.frame = .tuple;
            return .{ .begin = .{ .kind = .sequence } };
        },
        else => return error.UnexpectedType,
    }
}

/// The row's end: its last field ended the record, or a field more than the
/// header names follows.
fn endRow(self: *Self) Error!core.Event {
    if (!self.row_done) return error.SyntaxError;
    self.at = text.pastEnd(self.input, self.at);
    self.frame = if (self.mode == .document) .rows else .done;
    return .end;
}

/// The next field of the row, taken: text, or what the type asked for.
fn value(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    if (self.row_done) return error.SyntaxError;
    try c.node();
    const f = text.field(self.input, self.at, self.dialect) catch return error.SyntaxError;
    self.field_index += 1;
    if (f.after == .delimiter) {
        self.at = f.end + 1;
    } else {
        self.at = f.end;
        self.row_done = true;
    }
    if (f.bytes.len == 0 and !f.quoted) {
        if (request.nullable) return .none;
        if (request.expected == .unit) return .unit;
    }
    const s = try self.span(c, f, false);
    switch (request.expected) {
        .bytes => return .{ .bytes = s },
        .integer, .floating => {
            if (limit.exceeds(s.bytes.len, c.limits.numeric_bytes)) return error.LengthLimit;
            return .{ .number = s };
        },
        .boolean => {
            if (std.mem.eql(u8, s.bytes, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, s.bytes, "false")) return .{ .boolean = false };
            return error.UnexpectedType;
        },
        .record, .map, .variant, .sequence, .tuple, .unit => return error.UnexpectedType,
        else => {
            if (!std.unicode.utf8ValidateSlice(s.bytes)) return error.InvalidUtf8;
            return .{ .text = s };
        },
    }
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (self.frame != .done) return error.SyntaxError;
    if (text.skipBlank(self.input, self.at) != self.input.len) return error.SyntaxError;
}
