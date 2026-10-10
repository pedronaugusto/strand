//! ZON text as immediate core events: no token tape, no syntax tree, no
//! sentinel-terminated copy of the input. The grammar is the subset of Zig that
//! `std.zon` reads (literals, anonymous struct and tuple initialisers, enum
//! literals, strings, character and number literals, comments), read in one
//! pass by a small state machine. Nothing else is syntax here, so nothing else
//! can run: no identifier but `true`, `false`, `null`, `inf` and `nan`, no
//! import, call or operator but the minus of a number.
const std = @import("std");
const core = @import("../core.zig");
const number = @import("number.zig");
const text = @import("text.zig");
pub const Format = enum { zon };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{
    .map_keys = .text_only,
    .named_shapes = false,
    .variant_record = false,
    .max_integer_bits = std.math.maxInt(usize),
    .max_float_bits = std.math.maxInt(usize),
};
pub const parseInteger = number.integer;
pub const parseFloat = number.floating;

/// What a container holds, which its first element decides.
const Kind = enum { record, sequence, variant };
/// Where the container is: what its next token may be.
const State = enum { start, value, after_value, after_comma };
const Frame = struct { kind: Kind, state: State, key_start: usize };
/// A void variant is one token and three events; the last two wait here.
const Pending = enum { none, unit, end };

input: []const u8,
at: usize,
allocator: std.mem.Allocator,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
keys: [128][]const u8,
extra_keys: std.ArrayList([]const u8),
key_count: usize,
pending: Pending,
/// Where the last token ended, before the trivia after it.
last_end: usize,
root_done: bool,
digits: [12]u8 = undefined,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`. It
/// is built where it lies, field by field: its frames and keys are kilobytes
/// that a struct literal would build elsewhere and copy, unread.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    self.begin(bytes, text.skipTrivia(bytes, 0), c.allocator());
}
fn begin(self: *Self, bytes: []const u8, at: usize, allocator: std.mem.Allocator) void {
    self.input = bytes;
    self.at = at;
    self.allocator = allocator;
    self.extra = .empty;
    self.depth = 0;
    self.extra_keys = .empty;
    self.key_count = 0;
    self.pending = .none;
    self.last_end = 0;
    self.root_done = false;
}
pub fn deinit(self: *Self) void {
    self.extra.deinit(self.allocator);
    self.extra_keys.deinit(self.allocator);
    self.* = undefined;
}
/// Where the next token begins, past the whitespace and comments before it.
pub fn offset(self: *const Self) usize {
    return self.at;
}
/// A value's source, without the whitespace and comments around it. `end` is
/// where the next token begins; the value ended where the last one did.
pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
    const from = text.skipTrivia(self.input[0..end], start);
    const to = if (end == self.at) self.last_end else end;
    return .{ .bytes = self.input[from..@max(from, to)], .lifetime = .borrowed };
}
/// Starts `into` over a value already read, as the root of its own input.
pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
    const bounded = self.input[0..end];
    into.begin(bounded, text.skipTrivia(bounded, from), self.allocator);
}

fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        else => error.SyntaxError,
    };
}
fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn push(self: *Self, c: *core.Context, kind: Kind, state: State) Error!void {
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    const entry: Frame = .{ .kind = kind, .state = state, .key_start = self.key_count };
    if (self.depth < self.frames.len) self.frames[self.depth] = entry else self.extra.append(self.allocator, entry) catch |err| return failure(c, err);
    self.depth += 1;
}
fn pop(self: *Self) void {
    const entry = self.frame().*;
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    self.key_count = entry.key_start;
    self.extra_keys.shrinkRetainingCapacity(entry.key_start - @min(entry.key_start, self.keys.len));
    if (self.depth == 0) self.root_done = true;
}
/// A field name may be given once in a struct, whether or not anyone asks for it.
fn remember(self: *Self, c: *core.Context, name: []const u8) Error!void {
    const from = self.frame().key_start;
    for (from..self.key_count) |i| {
        const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
        try c.chargeWork(@min(name.len, prior.len));
        if (std.mem.eql(u8, name, prior)) return error.DuplicateField;
    }
    if (self.key_count < self.keys.len) self.keys[self.key_count] = name else self.extra_keys.append(self.allocator, name) catch |err| return failure(c, err);
    self.key_count += 1;
}

/// The byte at the cursor, after whitespace and comments.
fn peek(self: *Self) ?u8 {
    self.at = text.skipTrivia(self.input, self.at);
    return if (self.at < self.input.len) self.input[self.at] else null;
}

/// Whether the container being read is over, without reading a member of it.
pub fn atEnd(self: *Self) Error!bool {
    switch (self.pending) {
        .none => {},
        .unit => return false,
        .end => return true,
    }
    if (self.depth == 0) return false;
    const f = self.frame();
    while (true) switch (f.state) {
        .start, .after_comma => return (self.peek() orelse return error.SyntaxError) == '}',
        .value => return false,
        .after_value => {
            const b = self.peek() orelse return error.SyntaxError;
            if (b == '}') return true;
            if (b != ',') return error.SyntaxError;
            self.at += 1;
            f.state = .after_comma;
        },
    };
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const event = try self.step(c, request);
    // Whatever lies between this token and the next belongs to neither: `at` is
    // where the next one begins, which is where a failure at it is.
    self.last_end = self.at;
    self.at = text.skipTrivia(self.input, self.at);
    return event;
}
fn step(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    switch (self.pending) {
        .none => {},
        .unit => {
            self.pending = .end;
            return .unit;
        },
        .end => {
            self.pending = .none;
            return .end;
        },
    }
    if (self.depth == 0) {
        if (self.root_done) return error.SyntaxError;
        return self.value(c, request);
    }
    const f = self.frame();
    while (true) switch (f.state) {
        .start, .after_comma => {
            const b = self.peek() orelse return error.SyntaxError;
            if (b == '}') return self.close();
            switch (f.kind) {
                .sequence => {
                    f.state = .after_value;
                    return self.value(c, request);
                },
                // A union holds the one field it was opened with.
                .variant => return error.UnexpectedType,
                .record => {
                    f.state = .value;
                    return self.key(c);
                },
            }
        },
        .value => {
            f.state = .after_value;
            return self.value(c, request);
        },
        .after_value => {
            const b = self.peek() orelse return error.SyntaxError;
            if (b == '}') return self.close();
            if (b != ',') return error.SyntaxError;
            self.at += 1;
            f.state = .after_comma;
        },
    };
}
fn close(self: *Self) core.Event {
    self.at += 1;
    self.pop();
    return .end;
}

/// `.name =`: the field's name as text.
fn key(self: *Self, c: *core.Context) Error!core.Event {
    const name = try self.fieldName(c, true);
    if (self.peek() != '=') return error.SyntaxError;
    self.at += 1;
    try self.remember(c, name.bytes);
    return .{ .text = name };
}

/// A `.` and the name after it, an identifier or a quoted one.
fn fieldName(self: *Self, c: *core.Context, is_key: bool) Error!core.Span {
    if (self.peek() != '.') return error.SyntaxError;
    self.at += 1;
    const b = self.peek() orelse return error.SyntaxError;
    if (text.identifierStart(b)) {
        const start = self.at;
        self.at = text.identifierEnd(self.input, start);
        try c.span(self.at - start, is_key);
        return .{ .bytes = self.input[start..self.at], .lifetime = .borrowed };
    }
    if (b != '@') return error.SyntaxError;
    self.at += 1;
    if (self.at >= self.input.len or self.input[self.at] != '"') return error.SyntaxError;
    return self.quoted(c, is_key);
}

fn value(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const b = self.peek() orelse return error.SyntaxError;
    switch (b) {
        '.' => {
            const look = text.skipTrivia(self.input, self.at + 1);
            if (look < self.input.len and self.input[look] == '{') {
                self.at = look + 1;
                return self.open(c, request);
            }
            return self.symbol(c, request);
        },
        '"' => return self.stringEvent(try self.quoted(c, false), request),
        '\\' => return self.stringEvent(try self.multiline(c), request),
        '\'' => return self.character(c, request),
        '-' => return self.negative(c),
        '0'...'9' => {
            const start = self.at;
            const end = text.numberEnd(self.input, start);
            if (end - start > c.limits.numeric_bytes) return error.LengthLimit;
            self.at = end;
            return self.numberEvent(self.input[start..end], .borrowed);
        },
        else => {
            if (!text.identifierStart(b)) return error.SyntaxError;
            const start = self.at;
            self.at = text.identifierEnd(self.input, start);
            const word = self.input[start..self.at];
            self.markScalar();
            if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
            if (std.mem.eql(u8, word, "null")) return .none;
            if (std.mem.eql(u8, word, "inf")) return .{ .floating = std.math.inf(f128) };
            if (std.mem.eql(u8, word, "nan")) return .{ .floating = std.math.nan(f128) };
            return error.SyntaxError;
        },
    }
}
/// A scalar at the root is the whole document.
fn markScalar(self: *Self) void {
    if (self.depth == 0) self.root_done = true;
}
fn numberEvent(self: *Self, spelling: []const u8, lifetime: core.Lifetime) core.Event {
    self.markScalar();
    return .{ .number = .{ .bytes = spelling, .lifetime = lifetime } };
}

/// `-` and a number or `inf`, which may stand apart.
fn negative(self: *Self, c: *core.Context) Error!core.Event {
    const start = self.at;
    self.at += 1;
    const b = self.peek() orelse return error.SyntaxError;
    if (std.ascii.isDigit(b)) {
        const end = text.numberEnd(self.input, self.at);
        if (end - self.at + 1 > c.limits.numeric_bytes) return error.LengthLimit;
        // A minus and its number are one spelling when they touch.
        if (start + 1 == self.at) {
            self.at = end;
            return self.numberEvent(self.input[start..end], .borrowed);
        }
        const spelling = try c.alloc(u8, end - self.at + 1);
        spelling[0] = '-';
        @memcpy(spelling[1..], self.input[self.at..end]);
        self.at = end;
        return self.numberEvent(spelling, .owned);
    }
    if (!text.identifierStart(b)) return error.SyntaxError;
    const end = text.identifierEnd(self.input, self.at);
    if (!std.mem.eql(u8, self.input[self.at..end], "inf")) return error.SyntaxError;
    self.at = end;
    self.markScalar();
    return .{ .floating = -std.math.inf(f128) };
}

/// What a string literal is, which only the type asked for says: text, or any
/// bytes the literal's escapes can spell.
fn stringEvent(self: *Self, span: core.Span, request: core.Request) Error!core.Event {
    self.markScalar();
    return switch (request.expected) {
        .bytes => .{ .bytes = span },
        // A name is not a string.
        .symbol, .variant => error.UnexpectedType,
        else => .{ .text = span },
    };
}

/// A character literal is a number to everything but a Unicode scalar.
fn character(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const read = text.character(self.input, self.at) catch |err| return failure(c, err);
    self.at = read.end;
    self.markScalar();
    if (request.expected == .scalar) return .{ .scalar = read.value };
    const spelling = std.mem.print(&self.digits, "{d}", .{read.value}) catch unreachable; // unreachable: a code point has seven digits at most.
    return .{ .number = .{ .bytes = spelling, .lifetime = .transient } };
}

/// `"..."` from the opening quote: borrowed if it holds no escape, else
/// unescaped into the result's arena.
fn quoted(self: *Self, c: *core.Context, is_key: bool) Error!core.Span {
    const open_at = self.at;
    const end = text.stringEnd(self.input, open_at + 1) catch |err| return failure(c, err);
    self.at = end + 1;
    const body = self.input[open_at + 1 .. end];
    if (std.mem.findScalar(u8, body, '\\') == null) {
        try c.span(body.len, is_key);
        return .{ .bytes = body, .lifetime = .borrowed };
    }
    const token = self.input[open_at .. end + 1];
    const length = text.unescapedLength(token) catch |err| return failure(c, err);
    try c.span(length, is_key);
    try c.chargeWork(body.len);
    const out = try c.alloc(u8, length);
    text.unescape(token, out);
    return .{ .bytes = out, .lifetime = .owned };
}

/// Lines that begin `\\`, joined by newlines; whitespace and comments may lie between them.
fn multiline(self: *Self, c: *core.Context) Error!core.Span {
    const first = self.at;
    var lines: usize = 0;
    var total: usize = 0;
    var scan = first;
    var last_end = first;
    while (true) {
        const line = text.multilineLine(self.input, scan) orelse return error.SyntaxError;
        lines += 1;
        total += line.content.len + @intFromBool(lines > 1);
        last_end = line.content_end;
        const after = text.skipTrivia(self.input, line.next);
        if (text.multilineLine(self.input, after) == null) break;
        scan = after;
    }
    self.at = last_end;
    try c.span(total, false);
    if (lines == 1) return .{ .bytes = text.multilineLine(self.input, first).?.content, .lifetime = .borrowed };
    try c.chargeWork(total);
    const out = try c.alloc(u8, total);
    var written: usize = 0;
    var scan_again = first;
    for (0..lines) |n| {
        const line = text.multilineLine(self.input, scan_again).?;
        if (n != 0) {
            out[written] = '\n';
            written += 1;
        }
        @memcpy(out[written..][0..line.content.len], line.content);
        written += line.content.len;
        scan_again = text.skipTrivia(self.input, line.next);
    }
    return .{ .bytes = out, .lifetime = .owned };
}

/// `.name` where a value belongs: an enum's name, or a union arm with no payload.
fn symbol(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const name = try self.fieldName(c, false);
    self.markScalar();
    switch (request.expected) {
        .variant => {
            self.pending = .unit;
            return .{ .begin = .{ .kind = .variant, .name = name.bytes, .len = 1 } };
        },
        .symbol, .unknown => return .{ .text = name },
        else => return error.UnexpectedType,
    }
}

/// `.{` has been read.
fn open(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const b = self.peek() orelse return error.SyntaxError;
    const fields = b == '.' and self.fieldFollows();
    if (request.expected == .variant) {
        if (!fields) {
            try self.push(c, .sequence, .start);
            return .{ .begin = .{ .kind = .sequence } };
        }
        const name = try self.fieldName(c, false);
        if (self.peek() != '=') return error.SyntaxError;
        self.at += 1;
        try self.push(c, .variant, .value);
        return .{ .begin = .{ .kind = .variant, .name = name.bytes, .len = 1 } };
    }
    // Empty braces are whatever was asked for.
    const named = fields or (b == '}' and (request.expected == .record or request.expected == .map));
    try self.push(c, if (named) .record else .sequence, .start);
    return .{ .begin = .{ .kind = if (!named) .sequence else if (request.expected == .map) .map else .record } };
}

/// Whether the cursor, on a dot, is at `.name =`: a field of a struct, and not
/// an enum literal that is the first element of a tuple.
fn fieldFollows(self: *Self) bool {
    var at = text.skipTrivia(self.input, self.at + 1);
    if (at >= self.input.len) return false;
    if (text.identifierStart(self.input[at])) {
        at = text.identifierEnd(self.input, at);
    } else if (self.input[at] == '@') {
        at += 1;
        if (at >= self.input.len or self.input[at] != '"') return false;
        at = (text.stringEnd(self.input, at + 1) catch return false) + 1;
    } else return false;
    at = text.skipTrivia(self.input, at);
    return at < self.input.len and self.input[at] == '=';
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (self.depth != 0 or self.pending != .none) return error.SyntaxError;
    if (self.peek() != null) return error.SyntaxError;
}
