//! An INI document as core events: a record whose members are the keys
//! before its first section, then each `[section]`, a record of its keys.
//! Lines are read as Python's configparser reads them, in the dialect
//! given: a comment line or a blank one is nothing, a line indented deeper
//! than its key's continues the key's value (a blank line within kept as an
//! empty one), a key ends at the first delimiter, and white space around a
//! key or a value is not part of it. Every value is text until the type asks
//! for something else: a number in JSON's spelling, a boolean as
//! configparser's `getboolean` reads one (`1`, `yes`, `true`, `on`, and
//! their opposites, in any case), the raw bytes, or a null, which an empty
//! value or a key with no value is where the type takes one. A section, or
//! a key in one, given twice is refused, as configparser's strict mode does.
//! A value on one line is borrowed from the input; one continued is joined
//! in the arena.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const text = @import("text.zig");
const numbers = @import("../json/number.zig");
pub const Format = enum { ini };
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

/// A key, as the dialect folds it, and where its value's lines are in
/// `pieces`; none for a key with no value.
const Entry = struct { key: []const u8, lifetime: core.Lifetime, at: usize, first: usize, lines: ?usize };
/// A section and where its keys are in `entries`. The first is the keys
/// before any section, with no name of its own.
const Section = struct { name: []const u8, at: usize, first: usize, count: usize };
const Phase = enum { start, root, section, done };

input: []const u8,
dialect: text.Dialect,
loaded: bool,
sections: std.ArrayList(Section),
entries: std.ArrayList(Entry),
/// Each value's lines, in order; a continued value's lie together.
pieces: std.ArrayList([]const u8),
allocator: std.mem.Allocator,
phase: Phase,
/// The root's next member: a key of the first section, then a section.
member: usize,
/// The section being read, and its next key.
section: usize,
cursor: usize,
key_read: bool,
/// Where the line being read starts, for a failure's place.
current: usize,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8, dialect: text.Dialect) void {
    self.* = .{
        .input = bytes,
        .dialect = dialect,
        .loaded = false,
        .sections = .empty,
        .entries = .empty,
        .pieces = .empty,
        .allocator = c.allocator(),
        .phase = .start,
        .member = 0,
        .section = 0,
        .cursor = 0,
        .key_read = false,
        .current = 0,
    };
}
pub fn deinit(self: *Self) void {
    self.sections.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.pieces.deinit(self.allocator);
    self.* = undefined;
}
/// Where the line being read starts.
pub fn offset(self: *const Self) usize {
    return self.current;
}
pub fn raw(_: *const Self, _: usize, _: usize) core.Span {
    @compileError("a union tagged inside its record is read twice, which an INI document's lines are not: declare a data codec");
}
pub fn replay(_: *const Self, _: *Self, _: usize, _: usize) void {
    @compileError("a union tagged inside its record is read twice, which an INI document's lines are not: declare a data codec");
}

fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        error.AllocationLimit => error.AllocationLimit,
        else => error.SyntaxError,
    };
}

/// Reads the document's lines into sections, keys and value lines, once,
/// as configparser's `_read` does.
fn load(self: *Self, c: *core.Context) Error!void {
    if (self.loaded) return;
    self.loaded = true;
    const input = self.input;
    try c.chargeWork(input.len);
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const a = self.allocator;
    self.sections.append(a, .{ .name = "", .at = 0, .first = 0, .count = 0 }) catch |err| return failure(c, err);
    const d = self.dialect;
    // A byte-order mark, which editors on Windows put first, is not text.
    var at: usize = if (std.mem.startsWith(u8, input, "\u{feff}")) 3 else 0;
    var indent_level: usize = 0;
    var option: ?usize = null;
    // A section or a key in one given twice is refused, as configparser's strict mode does.
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(a);
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(a);
    while (at < input.len) {
        const l = text.line(input, at);
        self.current = at;
        at = l.next;
        const content = text.content(l.bytes, d);
        if (content.text.len == 0) {
            if (!d.continuation) continue;
            // A blank line within a value is an empty line of it; a comment is nothing.
            if (!content.commented) if (option) |o| if (self.entries.items[o].lines) |*n| {
                self.pieces.append(a, "") catch |err| return failure(c, err);
                n.* += 1;
            };
            continue;
        }
        const indent = text.indentation(l.bytes);
        if (d.continuation and option != null and indent > indent_level) {
            // A key with no value has none to continue (configparser's MultilineContinuationError).
            const e = &self.entries.items[option.?];
            const n = e.lines orelse return error.SyntaxError;
            self.pieces.append(a, content.text) catch |err| return failure(c, err);
            e.lines = n + 1;
            continue;
        }
        indent_level = indent;
        if (text.sectionName(content.text)) |name| {
            if (self.sections.items.len > c.limits.container_items) return error.ItemLimit;
            try c.chargeWork(name.len);
            if ((names.getOrPut(a, name) catch |err| return failure(c, err)).found_existing) return error.DuplicateField;
            keys.clearRetainingCapacity();
            self.sections.append(a, .{ .name = name, .at = self.current, .first = self.entries.items.len, .count = 0 }) catch |err| return failure(c, err);
            option = null;
            continue;
        }
        const s = &self.sections.items[self.sections.items.len - 1];
        if (s.count >= c.limits.container_items) return error.ItemLimit;
        const delimiter = std.mem.findAny(u8, content.text, d.delimiters);
        const written = text.trim(if (delimiter) |i| content.text[0..i] else content.text);
        if (written.len == 0) return error.SyntaxError;
        if (delimiter == null and !d.keys_without_values) return error.SyntaxError;
        const name = try self.folded(c, written);
        if ((keys.getOrPut(a, name.bytes) catch |err| return failure(c, err)).found_existing) return error.DuplicateField;
        var lines: ?usize = null;
        if (delimiter) |i| {
            self.pieces.append(a, text.trim(content.text[i + 1 ..])) catch |err| return failure(c, err);
            lines = 1;
        }
        self.entries.append(a, .{ .key = name.bytes, .lifetime = name.lifetime, .at = self.current, .first = self.pieces.items.len - @intFromBool(lines != null), .lines = lines }) catch |err| return failure(c, err);
        s.count += 1;
        option = self.entries.items.len - 1;
    }
}

/// How many members the root has: the first section's keys, then the sections after it.
fn rootMembers(self: *const Self) usize {
    return self.sections.items[0].count + self.sections.items.len - 1;
}

/// Whether the record being read has no more members.
pub fn atEnd(self: *Self) Error!bool {
    return switch (self.phase) {
        .start, .done => false,
        .root => !self.key_read and self.member == self.rootMembers(),
        .section => !self.key_read and self.cursor == self.sections.items[self.section].count,
    };
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    try self.load(c);
    switch (self.phase) {
        .done => return error.SyntaxError,
        .start => {
            switch (request.expected) {
                .record, .map, .unknown => {},
                else => return error.UnexpectedType,
            }
            self.phase = .root;
            return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record, .len = self.rootMembers() } };
        },
        .root => {
            const top = self.sections.items[0];
            if (self.key_read) {
                self.key_read = false;
                const m = self.member;
                self.member += 1;
                if (m < top.count) return self.value(c, self.entries.items[top.first + m], request);
                // A section: a record of its keys.
                switch (request.expected) {
                    .record, .map, .unknown => {},
                    else => return error.UnexpectedType,
                }
                self.phase = .section;
                self.section = m - top.count + 1;
                self.cursor = 0;
                const s = self.sections.items[self.section];
                return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record, .len = s.count } };
            }
            if (self.member == self.rootMembers()) {
                self.phase = .done;
                return .end;
            }
            self.key_read = true;
            try c.node();
            if (self.member < top.count) return self.key(self.entries.items[top.first + self.member]);
            const s = self.sections.items[self.member - top.count + 1];
            self.current = s.at;
            try c.span(s.name.len, true);
            return .{ .text = .{ .bytes = s.name, .lifetime = .borrowed } };
        },
        .section => {
            const s = self.sections.items[self.section];
            if (self.key_read) {
                self.key_read = false;
                defer self.cursor += 1;
                return self.value(c, self.entries.items[s.first + self.cursor], request);
            }
            if (self.cursor == s.count) {
                self.phase = .root;
                return .end;
            }
            self.key_read = true;
            try c.node();
            return self.key(self.entries.items[s.first + self.cursor]);
        },
    }
}

/// A key as written, lowercased where the dialect says and that changes it.
fn folded(self: *Self, c: *core.Context, written: []const u8) Error!core.Span {
    try c.chargeWork(written.len);
    if (!self.dialect.lowercase_keys or !text.needsLower(written)) {
        try c.span(written.len, true);
        return .{ .bytes = written, .lifetime = .borrowed };
    }
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    text.lower(written, &out.writer) catch return failure(c, error.OutOfMemory);
    const lowered = out.toOwnedSlice() catch |err| return failure(c, err);
    try c.span(lowered.len, true);
    return .{ .bytes = lowered, .lifetime = .owned };
}
/// An entry's key.
fn key(self: *Self, e: Entry) core.Event {
    self.current = e.at;
    return .{ .text = .{ .bytes = e.key, .lifetime = e.lifetime } };
}

/// An entry's value: its line, or its lines joined by line feeds with the
/// blank ones at the end left off, in the arena.
fn joined(self: *Self, c: *core.Context, e: Entry) Error!core.Span {
    const lines = self.pieces.items[e.first..][0..e.lines.?];
    var n = lines.len;
    while (n > 1 and lines[n - 1].len == 0) n -= 1;
    if (n == 1) {
        try c.span(lines[0].len, false);
        return .{ .bytes = lines[0], .lifetime = .borrowed };
    }
    var length: usize = n - 1;
    for (lines[0..n]) |l| length += l.len;
    try c.span(length, false);
    try c.chargeWork(length);
    const out = c.alloc(u8, length) catch |err| return failure(c, err);
    var w = std.Io.Writer.fixed(out);
    for (lines[0..n], 0..) |l, i| {
        // unreachable: `out` holds the lines and the line feeds between them.
        if (i > 0) w.writeByte('\n') catch unreachable;
        // unreachable: as above.
        w.writeAll(l) catch unreachable;
    }
    return .{ .bytes = out, .lifetime = .owned };
}

/// An entry's value, taken: text, or what the type asked for.
fn value(self: *Self, c: *core.Context, e: Entry, request: core.Request) Error!core.Event {
    self.current = e.at;
    try c.node();
    if (e.lines == null) {
        if (request.nullable or request.expected == .unknown) return .none;
        return error.UnexpectedType;
    }
    const s = try self.joined(c, e);
    if (s.bytes.len == 0) {
        if (request.nullable) return .none;
        if (request.expected == .unit) return .unit;
    }
    switch (request.expected) {
        .bytes => return .{ .bytes = s },
        .integer, .floating => {
            if (limit.exceeds(s.bytes.len, c.limits.numeric_bytes)) return error.LengthLimit;
            return .{ .number = s };
        },
        .boolean => return .{ .boolean = text.boolean(s.bytes) orelse return error.UnexpectedType },
        .record, .map, .variant, .sequence, .tuple, .unit => return error.UnexpectedType,
        else => return .{ .text = s },
    }
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    try self.load(c);
    if (self.phase != .done) return error.SyntaxError;
}
