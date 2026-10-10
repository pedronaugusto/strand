//! JSON text as immediate core events, read in one pass straight off the
//! input: no token tape, no tokenizer state machine between the bytes and the
//! event. A container's frame says what may come next in it; a string is found
//! a vector at a time and borrowed from the input unless it has an escape.
const std = @import("std");
const core = @import("../core.zig");
const numbers = @import("number.zig");
const strings = @import("text.zig");
pub const Format = enum { json };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{ .map_keys = .text_only, .bytes = false, .named_shapes = false, .nonfinite_floats = false, .variant_record = true, .max_integer_bits = std.math.maxInt(usize), .utf8_text = true };
pub const parseInteger = numbers.integer;
pub const parseFloat = numbers.floating;

/// Where a container is: what its next byte may be.
const State = enum(u8) {
    /// Just opened: a member, or the close.
    first,
    /// After a comma: a member.
    member,
    /// After a key and its colon: the value.
    value,
    /// After a member: a comma or the close.
    after,
};
/// `check_keys`: whether this object's keys are remembered to refuse one given
/// twice. An object read as a typed record is not: mapping checks its keys.
const Frame = struct { object: bool, check_keys: bool, state: State, key_start: usize };

input: []const u8,
/// The next unread byte, whitespace already passed over.
at: usize,
/// Where the last token ended, before the whitespace after it.
last_end: usize,
allocator: std.mem.Allocator,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
keys: [128][]const u8,
extra_keys: std.ArrayList([]const u8),
key_count: usize,
reject_duplicates: bool,
root_done: bool,
const Self = @This();

/// Starts `self` over `bytes`, which the caller has charged to `c.input`. It
/// is built where it lies, field by field: its frames and keys are kilobytes
/// that a struct literal would build elsewhere and copy, unread.
pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
    self.begin(bytes, space(bytes, 0), c.allocator(), c.acceptance.reject_duplicates);
}
fn begin(self: *Self, bytes: []const u8, at: usize, allocator: std.mem.Allocator, reject_duplicates: bool) void {
    self.input = bytes;
    self.at = at;
    self.last_end = at;
    self.allocator = allocator;
    self.extra = .empty;
    self.depth = 0;
    self.extra_keys = .empty;
    self.key_count = 0;
    self.reject_duplicates = reject_duplicates;
    self.root_done = false;
}
pub fn deinit(self: *Self) void {
    self.extra.deinit(self.allocator);
    self.extra_keys.deinit(self.allocator);
    self.* = undefined;
}
/// Where the next token begins, or the comma before it.
pub fn offset(self: *const Self) usize {
    return self.at;
}
/// A value's bytes, without the separator and whitespace before it or the
/// whitespace after it. `end` is where the next token begins; the value ended
/// where the last one did.
pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
    const from = leading(self.input, start);
    const to = if (end == self.at) self.last_end else end;
    return .{ .bytes = self.input[from..@max(from, to)], .lifetime = .borrowed };
}
/// Starts `into` over a value already read, as the root of its own input.
pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
    const bounded = self.input[0..end];
    into.begin(bounded, leading(bounded, from), self.allocator, self.reject_duplicates);
}
/// Where the root value ended, for a reader that takes a value from the front
/// of its input and leaves the rest.
pub fn rootEnd(self: *const Self) ?usize {
    return if (self.root_done) self.last_end else null;
}

fn space(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len) : (at += 1) switch (bytes[at]) {
        ' ', '\t', '\r', '\n' => {},
        else => break,
    };
    return at;
}
/// Past the whitespace and one comma or colon before a value.
fn leading(bytes: []const u8, from: usize) usize {
    var at = space(bytes, from);
    if (at < bytes.len and (bytes[at] == ',' or bytes[at] == ':')) at = space(bytes, at + 1);
    return at;
}
fn failure(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        else => error.SyntaxError,
    };
}
inline fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn push(self: *Self, c: *core.Context, object: bool, check_keys: bool) Error!void {
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    const entry: Frame = .{ .object = object, .check_keys = check_keys, .state = .first, .key_start = self.key_count };
    if (self.depth < self.frames.len) self.frames[self.depth] = entry else self.extra.append(self.allocator, entry) catch |err| return failure(c, err);
    self.depth += 1;
}
/// Ends a token at `to`: the whitespace after it is passed over.
inline fn finish(self: *Self, to: usize) void {
    self.last_end = to;
    self.at = space(self.input, to);
}
fn close(self: *Self) core.Event {
    const entry = self.frame().*;
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    self.key_count = entry.key_start;
    self.extra_keys.shrinkRetainingCapacity(entry.key_start - @min(entry.key_start, self.keys.len));
    if (self.depth == 0) self.root_done = true;
    self.finish(self.at + 1);
    return .end;
}
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
inline fn byte(self: *const Self) Error!u8 {
    return if (self.at < self.input.len) self.input[self.at] else error.SyntaxError;
}

/// Whether the container being read is over, without reading a member of it.
pub fn atEnd(self: *Self) Error!bool {
    if (self.depth == 0) return false;
    const f = self.frame();
    switch (f.state) {
        .first => return try self.byte() == closer(f.object),
        .member, .value => return false,
        .after => {
            const b = try self.byte();
            if (b == closer(f.object)) return true;
            if (b != ',') return error.SyntaxError;
            self.at = space(self.input, self.at + 1);
            f.state = .member;
            return false;
        },
    }
}
inline fn closer(object: bool) u8 {
    return if (object) '}' else ']';
}

pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    if (self.depth == 0) {
        if (self.root_done) return error.SyntaxError;
        return self.value(c, request);
    }
    const f = self.frame();
    switch (f.state) {
        .first => if (try self.byte() == closer(f.object)) return self.close(),
        .member => {},
        .value => {
            f.state = .after;
            return self.value(c, request);
        },
        .after => {
            const b = try self.byte();
            if (b == closer(f.object)) return self.close();
            if (b != ',') return error.SyntaxError;
            self.at = space(self.input, self.at + 1);
        },
    }
    if (f.object) {
        f.state = .value;
        return self.key(c, f.check_keys);
    }
    f.state = .after;
    return self.value(c, request);
}

/// The next key of the object on top, the comma before it and the colon after
/// it taken, or `null` where the object closes, the close taken.
pub inline fn memberKey(self: *Self, c: *core.Context) Error!?core.Span {
    const f = self.frame();
    switch (f.state) {
        .first => if (try self.byte() == '}') {
            _ = self.close();
            return null;
        },
        .member => {},
        .after => {
            const b = try self.byte();
            if (b == '}') {
                _ = self.close();
                return null;
            }
            if (b != ',') return error.SyntaxError;
            self.at = space(self.input, self.at + 1);
        },
        .value => return error.SyntaxError,
    }
    f.state = .value;
    return (try self.key(c, f.check_keys)).text;
}

/// A key matched against names a schema spells: which of them it is, if any,
/// and the key itself.
pub const Match = struct { index: ?usize, name: []const u8 };

/// `memberKey`, matched against `names`. The one at `hint` is looked for
/// first where the key lies, quotes and all, as a writer that keeps the
/// schema's order puts it: when it is there, no string is read.
pub inline fn memberOf(self: *Self, c: *core.Context, comptime names: []const []const u8, hint: usize) Error!?Match {
    const f = self.frame();
    switch (f.state) {
        .first => if (try self.byte() == '}') {
            _ = self.close();
            return null;
        },
        .member => {},
        .after => {
            const b = try self.byte();
            if (b == '}') {
                _ = self.close();
                return null;
            }
            if (b != ',') return error.SyntaxError;
            self.at = space(self.input, self.at + 1);
        },
        .value => return error.SyntaxError,
    }
    f.state = .value;
    if (!f.check_keys and names.len != 0) switch (hint) {
        inline 0...names.len - 1 => |h| if (comptime literal(names[h])) |quoted| {
            const rest = self.input[self.at..];
            if (rest.len > quoted.len and startsWith(rest, quoted)) {
                self.finish(self.at + quoted.len);
                if (self.at >= self.input.len or self.input[self.at] != ':') return error.SyntaxError;
                self.at = space(self.input, self.at + 1);
                return .{ .index = h, .name = names[h] };
            }
        },
        else => {},
    };
    const name = (try self.key(c, f.check_keys)).text.bytes;
    inline for (names, 0..) |spelling, k| {
        if (name.len == spelling.len and std.mem.eql(u8, name, spelling)) return .{ .index = k, .name = name };
    }
    return .{ .index = null, .name = name };
}
/// Whether `bytes`, at least as long, begin with `prefix`, spelled at compile
/// time: a short one is compared a byte at a time with no call.
inline fn startsWith(bytes: []const u8, comptime prefix: []const u8) bool {
    if (prefix.len > 24) return std.mem.eql(u8, bytes[0..prefix.len], prefix);
    inline for (prefix, 0..) |b, k| if (bytes[k] != b) return false;
    return true;
}

/// A name as a key spelled with no escape, quotes included; `null` for one
/// that needs an escape, which is matched once read.
fn literal(comptime name: []const u8) ?[]const u8 {
    for (name) |b| if (b < 0x20 or b == '"' or b == '\\') return null;
    return "\"" ++ name ++ "\"";
}

/// A key and the colon after it.
inline fn key(self: *Self, c: *core.Context, check: bool) Error!core.Event {
    if (try self.byte() != '"') return error.SyntaxError;
    const name = try self.string(c, true);
    if (self.at >= self.input.len or self.input[self.at] != ':') return error.SyntaxError;
    self.at = space(self.input, self.at + 1);
    if (check) try self.remember(c, name.bytes);
    return .{ .text = name };
}

/// Moves to where the next value of the container on top begins, the comma
/// before it taken, when that is a value and not the container's end: what
/// `next` does before it reads a value, done for the readers below that read
/// one kind of value without an event. False leaves `next` to say what is there.
inline fn toValue(self: *Self) Error!bool {
    if (self.depth == 0) return !self.root_done;
    const f = self.frame();
    switch (f.state) {
        .value => {},
        .first => if (f.object or try self.byte() == ']') return false,
        .member => if (f.object) return false,
        .after => {
            if (f.object or try self.byte() != ',') return false;
            self.at = space(self.input, self.at + 1);
            f.state = .member;
        },
    }
    return true;
}
/// The value at the cursor is now being read.
inline fn reading(self: *Self) void {
    if (self.depth == 0) self.root_done = true else self.frame().state = .after;
}

/// Opens the next value if it is the container `request` expects: an object
/// for a record, a map or a variant, an array for a sequence or a tuple.
/// `null`, with nothing read, for anything else.
pub inline fn open(self: *Self, c: *core.Context, request: core.Request) Error!?@FieldType(core.Event, "begin") {
    const object = switch (request.expected) {
        .record, .map, .variant => true,
        .sequence, .tuple => false,
        else => return null,
    };
    if (!try self.toValue()) return null;
    if (try self.byte() != @as(u8, if (object) '{' else '[')) return null;
    self.reading();
    try self.push(c, object, object and self.reject_duplicates and request.expected != .record);
    self.finish(self.at + 1);
    return .{ .kind = if (!object) .sequence else if (request.expected == .map) .map else .record };
}

/// The next value's lexeme if it is a number, read; `null`, with nothing read,
/// if it is anything else.
pub inline fn number(self: *Self, c: *core.Context) Error!?[]const u8 {
    if (!try self.toValue()) return null;
    const b = try self.byte();
    if (b != '-' and (b < '0' or b > '9')) return null;
    self.reading();
    const from = self.at;
    const end = try numberEnd(self.input, from);
    if (end - from > c.limits.numeric_bytes) return error.LengthLimit;
    self.finish(end);
    return self.input[from..end];
}

/// The next value if it is a string, read; `null`, with nothing read, if it is
/// anything else.
pub fn text(self: *Self, c: *core.Context) Error!?core.Span {
    if (!try self.toValue()) return null;
    if (try self.byte() != '"') return null;
    self.reading();
    return try self.string(c, false);
}

fn value(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    switch (try self.byte()) {
        '{' => {
            try self.push(c, true, self.reject_duplicates and request.expected != .record);
            self.finish(self.at + 1);
            return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } };
        },
        '[' => {
            try self.push(c, false, false);
            self.finish(self.at + 1);
            return .{ .begin = .{ .kind = .sequence } };
        },
        '"' => {
            const span = try self.string(c, false);
            self.ended();
            return .{ .text = span };
        },
        't' => return self.word("true", .{ .boolean = true }),
        'f' => return self.word("false", .{ .boolean = false }),
        'n' => return self.word("null", if (request.expected == .unit) .unit else .none),
        '-', '0'...'9' => {
            const start = self.at;
            const end = try numberEnd(self.input, start);
            if (end - start > c.limits.numeric_bytes) return error.LengthLimit;
            self.finish(end);
            self.ended();
            return .{ .number = .{ .bytes = self.input[start..end], .lifetime = .borrowed } };
        },
        else => return error.SyntaxError,
    }
}
inline fn ended(self: *Self) void {
    if (self.depth == 0) self.root_done = true;
}
fn word(self: *Self, comptime spelling: []const u8, event: core.Event) Error!core.Event {
    if (self.input.len - self.at < spelling.len or !std.mem.eql(u8, self.input[self.at..][0..spelling.len], spelling)) return error.SyntaxError;
    self.finish(self.at + spelling.len);
    self.ended();
    return event;
}

/// The string at the cursor: borrowed from the input when it has no escape,
/// unescaped into the operation's storage when it has one.
inline fn string(self: *Self, c: *core.Context, is_key: bool) Error!core.Span {
    const start = self.at + 1;
    const body = self.input[start..];
    // The common case, a string with no escape, takes one look.
    const found = strings.special(body);
    if (found.at < body.len and body[found.at] == '"') {
        if (found.non_ascii and !std.unicode.utf8ValidateSlice(body[0..found.at])) return error.SyntaxError;
        try c.span(found.at, is_key);
        self.finish(start + found.at + 1);
        return .{ .bytes = body[0..found.at], .lifetime = .borrowed };
    }
    const end = try strings.end(body);
    const escaped = body[0..end.at];
    // Nothing is shorter unescaped, so the escaped length bounds the copy.
    const storage = try c.alloc(u8, escaped.len);
    const n = strings.unescape(escaped, storage);
    try c.span(n, is_key);
    self.finish(start + end.at + 1);
    return .{ .bytes = storage[0..n], .lifetime = .owned };
}

/// Where the number that starts at `start` ends; its grammar is checked.
inline fn numberEnd(bytes: []const u8, start: usize) Error!usize {
    var at = start;
    if (bytes[at] == '-') at += 1;
    if (at == bytes.len) return error.SyntaxError;
    if (bytes[at] == '0') {
        at += 1;
    } else if (bytes[at] >= '1' and bytes[at] <= '9') {
        at += 1;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
    } else return error.SyntaxError;
    if (at < bytes.len and bytes[at] == '.') {
        at += 1;
        const digits = at;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
        if (at == digits) return error.SyntaxError;
    }
    if (at < bytes.len and (bytes[at] == 'e' or bytes[at] == 'E')) {
        at += 1;
        if (at < bytes.len and (bytes[at] == '+' or bytes[at] == '-')) at += 1;
        const digits = at;
        while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
        if (at == digits) return error.SyntaxError;
    }
    return at;
}

pub fn endInput(self: *Self, c: *core.Context) Error!void {
    _ = c;
    if (!self.root_done or self.at != self.input.len) return error.SyntaxError;
}
