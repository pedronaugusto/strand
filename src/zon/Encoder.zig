//! ZON text emission. Shape and field policy belong to core; this is the
//! spelling: `std.zon`'s own, byte for byte, for what both can write. A
//! container of more than two members wraps one member to a line, with a
//! trailing comma; one of one or two stays on its line; a union is `.arm` with
//! no payload and `.{ .arm = payload }` with one.
const std = @import("std");
const core = @import("../core.zig");
const Decoder = @import("Decoder.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;

writer: *std.Io.Writer,
/// Whether the layout is std's, or only the whitespace the syntax needs.
whitespace: bool,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
/// Containers open that wrap, which is how far a line is indented.
indent_level: usize,
keys: [128][]const u8,
extra_keys: std.ArrayList([]const u8),
key_count: usize,
stage: [4096]u8,
staged: usize,

/// Starts `self` over `writer`, built where it lies, field by field: its
/// frames, keys and stage are kilobytes a struct literal would build
/// elsewhere and copy.
pub fn init(self: *Self, writer: *std.Io.Writer, whitespace: bool) void {
    self.writer = writer;
    self.whitespace = whitespace;
    self.extra = .empty;
    self.depth = 0;
    self.indent_level = 0;
    self.extra_keys = .empty;
    self.key_count = 0;
    self.staged = 0;
}

const Kind = enum { record, sequence, variant };
/// A union arm is written when its payload is known: `.arm`, or `.{ .arm = `.
const Arm = enum { unknown, void, payload };
const Frame = struct {
    kind: Kind,
    check_duplicates: bool = false,
    wrap: bool,
    /// A tuple of one: `.{1}`, with no space inside.
    elide: bool,
    empty: bool = true,
    value_pending: bool = false,
    arm: Arm = .unknown,
    name: []const u8 = "",
    key_start: usize,
};
const Self = @This();

fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
/// Output is staged and written, and counted against the limit, a stage at a
/// time: a member is a handful of small pieces, and each one separately costs
/// more than the piece. A long piece skips the stage.
inline fn put(self: *Self, data: []const u8, c: *core.Context) Error!void {
    if (data.len <= self.stage.len - self.staged) {
        @memcpy(self.stage[self.staged..][0..data.len], data);
        self.staged += data.len;
        return;
    }
    return self.putAside(data, c);
}
fn putAside(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try self.flush(c);
    if (data.len <= self.stage.len / 4) {
        @memcpy(self.stage[0..data.len], data);
        self.staged = data.len;
        return;
    }
    try c.output(data.len);
    try self.writer.writeAll(data);
}
/// Everything staged goes out. A caller of `begin` ends with this.
pub fn flush(self: *Self, c: *core.Context) Error!void {
    const n = self.staged;
    if (n == 0) return;
    try c.output(n);
    self.staged = 0;
    try self.writer.writeAll(self.stage[0..n]);
}
fn space(self: *Self, c: *core.Context) Error!void {
    if (self.whitespace) try self.put(" ", c);
}
fn indent(self: *Self, c: *core.Context) Error!void {
    if (!self.whitespace) return;
    var left = self.indent_level * 4;
    while (left > 0) {
        const n = @min(left, rules.len - 2);
        try self.put(rules[2..][0..n], c);
        left -= n;
    }
}

/// A comma, a line or a space, and an indent, in the order that
/// `separate` writes them and as many as the longest line it writes.
const rules = blk: {
    var layout: [2 + 1024]u8 = @splat(' ');
    layout[0] = ',';
    layout[1] = '\n';
    break :blk layout;
};

/// What comes before a member: its comma, its line or space and its indent.
fn separate(self: *Self, c: *core.Context) Error!void {
    const f = self.frame();
    const comma = !f.empty;
    f.empty = false;
    if (f.wrap) {
        if (!self.whitespace) return if (comma) self.put(",", c);
        const indent_bytes = self.indent_level * 4;
        const lead = @intFromBool(!comma);
        // A short indent is a fixed copy of more than it needs, written over by what follows.
        if (indent_bytes + 2 - lead <= 32 and self.staged + 32 <= self.stage.len) {
            self.stage[self.staged..][0..32].* = rules[lead..][0..32].*;
            self.staged += indent_bytes + 2 - lead;
            return;
        }
        if (indent_bytes <= rules.len - 2) return self.put(rules[lead .. 2 + indent_bytes], c);
        try self.put(if (comma) ",\n" else "\n", c);
        return self.indent(c);
    }
    if (comma) try self.put(if (f.elide or !self.whitespace) "," else ", ", c) else if (!f.elide and self.whitespace) try self.put(" ", c);
}

/// A sequence's member, or a map's key.
fn member(self: *Self, c: *core.Context, name: ?[]const u8) Error!void {
    try self.separate(c);
    if (name) |label| {
        try self.identifier(label, c);
        try self.space(c);
        try self.put("=", c);
        try self.space(c);
    }
}
fn identifier(self: *Self, name: []const u8, c: *core.Context) Error!void {
    try self.put(".", c);
    if (std.zig.isValidId(name)) return self.put(name, c);
    try self.put("@", c);
    try self.quoted(name, c);
}

/// What comes before a value: nothing at the root or after a field's name; a
/// member in a tuple; the opening of a union arm that has a payload.
fn before(self: *Self, c: *core.Context) Error!void {
    if (self.depth == 0) return;
    const f = self.frame();
    switch (f.kind) {
        .sequence => try self.member(c, null),
        .record => if (f.value_pending) {
            f.value_pending = false;
        } else return error.CustomRejected,
        .variant => {
            if (f.arm != .unknown) return error.CustomRejected;
            f.arm = .payload;
            try self.put(".{", c);
            f.empty = false;
            // A one-field struct: never wrapped, never elided.
            try self.space(c);
            try self.identifier(f.name, c);
            try self.space(c);
            try self.put("=", c);
            try self.space(c);
        },
    }
}

fn quoted(self: *Self, data: []const u8, c: *core.Context) Error!void {
    try self.put("\"", c);
    try self.escaped(data, c);
    try self.put("\"", c);
}

/// `std.zig.stringEscape`: the same bytes, written in runs.
fn escaped(self: *Self, data: []const u8, c: *core.Context) Error!void {
    var from: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const b = data[i];
        const plain = b == 0x20 or b == 0x21 or (b >= 0x23 and b <= 0x5b) or (b >= 0x5d and b <= 0x7e);
        if (plain) {
            i += 1;
            continue;
        }
        try self.put(data[from..i], c);
        if (b >= 0x80) {
            const read = utf8Run(data, i);
            if (read.escape) {
                for (data[i..][0..read.len]) |byte| try self.hex(byte, c);
            } else try self.put(data[i..][0..read.len], c);
            i += read.len;
        } else {
            switch (b) {
                '\t' => try self.put("\\t", c),
                '\n' => try self.put("\\n", c),
                '\r' => try self.put("\\r", c),
                '\\' => try self.put("\\\\", c),
                '"' => try self.put("\\\"", c),
                else => try self.hex(b, c),
            }
            i += 1;
        }
        from = i;
    }
    try self.put(data[from..], c);
}
fn hex(self: *Self, byte: u8, c: *core.Context) Error!void {
    const digits = "0123456789abcdef";
    try self.put(&.{ '\\', 'x', digits[byte >> 4], digits[byte & 15] }, c);
}
/// How `std.zig.stringEscape` treats the bytes from `at`, which start a UTF-8
/// sequence or are stray: kept, or escaped. A stray or malformed byte is
/// escaped alone; the sequence of an invisible or line-ending character is
/// escaped whole.
fn utf8Run(data: []const u8, at: usize) struct { len: usize, escape: bool } {
    const len = std.unicode.utf8ByteSequenceLength(data[at]) catch return .{ .len = 1, .escape = true };
    if (at + len > data.len or !std.unicode.utf8ValidateSlice(data[at..][0..len])) return .{ .len = 1, .escape = true };
    const sequence = data[at..][0..len];
    const invisible = std.mem.eql(u8, sequence, "\u{feff}") or std.mem.eql(u8, sequence, "\u{0085}") or std.mem.eql(u8, sequence, "\u{2028}") or std.mem.eql(u8, sequence, "\u{2029}");
    return .{ .len = len, .escape = invisible };
}

pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.before(c);
    try self.put(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = if (comptime bits <= 128) decimal(&buffer, value) else buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.put(spelling, c);
}
/// An integer's digits, filling `buffer` from the end, two at a time.
fn decimal(buffer: []u8, value: anytype) []const u8 {
    const info = @typeInfo(@TypeOf(value)).int;
    var at: usize = buffer.len;
    var rest: @Int(.unsigned, @max(info.bits, 1)) = @abs(value);
    if (comptime info.bits > 64) {
        while (rest > std.math.maxInt(u64)) {
            const low: u64 = @intCast(rest % 10_000_000_000_000_000_000);
            rest /= 10_000_000_000_000_000_000;
            const stop = at;
            at = decimalDigits(buffer, at, low);
            // Nineteen digits, the zeros in front included.
            while (at > stop - 19) {
                at -= 1;
                buffer[at] = '0';
            }
        }
    }
    at = decimalDigits(buffer, at, @intCast(rest));
    if (info.signedness == .signed and value < 0) {
        at -= 1;
        buffer[at] = '-';
    }
    return buffer[at..];
}
fn decimalDigits(buffer: []u8, stop: usize, number: u64) usize {
    var rest = number;
    var at = stop;
    while (rest >= 100) : (rest /= 100) {
        at -= 2;
        buffer[at..][0..2].* = std.fmt.digits2(@intCast(rest % 100));
    }
    if (rest < 10) {
        at -= 1;
        buffer[at] = '0' + @as(u8, @intCast(rest));
    } else {
        at -= 2;
        buffer[at..][0..2].* = std.fmt.digits2(@intCast(rest));
    }
    return at;
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    var buffer: [5200]u8 = undefined;
    const spelling = if (std.math.isNan(value)) "nan" else if (std.math.isPositiveInf(value)) "inf" else if (std.math.isNegativeInf(value)) "-inf" else if (std.math.isNegativeZero(value)) "-0.0" else std.mem.print(&buffer, "{d}", .{value}) catch return error.NumberOutOfRange;
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.put(spelling, c);
}
/// An enum's name: `.name`.
pub fn symbol(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.before(c);
    try self.identifier(value, c);
}
/// A string, or a field name where a map is waiting for one.
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    if (self.depth != 0) {
        const f = self.frame();
        if (f.kind == .record and !f.value_pending) return self.key(value, c);
    }
    try self.before(c);
    try self.quoted(value, c);
}
pub fn bytes(self: *Self, value: []const u8, c: *core.Context) Error!void {
    try self.text(value, c);
}
/// A character literal, spelled as `std.zon` spells a code point.
pub fn scalar(self: *Self, value: u21, c: *core.Context) Error!void {
    try self.before(c);
    try self.put("'", c);
    switch (value) {
        ' ', '!', '"', '#'...'&', '('...'[', ']'...'~' => try self.put(&.{@intCast(value)}, c),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try self.hex(@intCast(value), c),
        '\n' => try self.put("\\n", c),
        '\r' => try self.put("\\r", c),
        '\t' => try self.put("\\t", c),
        '\\' => try self.put("\\\\", c),
        '\'' => try self.put("\\'", c),
        0x80...0x10ffff => {
            var buffer: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(value, &buffer) catch return error.InvalidUtf8;
            try self.put(buffer[0..n], c);
        },
        else => return error.InvalidUtf8,
    }
    try self.put("'", c);
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.before(c);
    try self.put("null", c);
}
/// A void payload is an arm with no braces; nowhere else is there a unit.
pub fn unit(self: *Self, c: *core.Context) Error!void {
    if (self.depth == 0) return error.UnsupportedValue;
    const f = self.frame();
    if (f.kind != .variant or f.arm != .unknown) return error.UnsupportedValue;
    f.arm = .void;
    try self.identifier(f.name, c);
}
/// A field of a struct, whose name is a constant: `.name = ` in one piece.
pub fn field(self: *Self, comptime name: []const u8, c: *core.Context) Error!void {
    const f = self.frame();
    if (f.kind != .record or f.value_pending) return error.CustomRejected;
    if (f.check_duplicates or comptime !std.zig.isValidId(name)) return self.key(name, c);
    try self.separate(c);
    if (self.whitespace) try self.put("." ++ name ++ " = ", c) else try self.put("." ++ name ++ "=", c);
    f.value_pending = true;
}
pub fn key(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const f = self.frame();
    if (f.kind != .record or f.value_pending) return error.CustomRejected;
    if (f.check_duplicates) {
        for (f.key_start..self.key_count) |i| {
            const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
            try c.chargeWork(@min(value.len, prior.len));
            if (std.mem.eql(u8, value, prior)) return error.DuplicateField;
        }
        if (self.key_count < self.keys.len) self.keys[self.key_count] = value else try self.extra_keys.append(c.allocator(), value);
        self.key_count += 1;
    }
    try self.member(c, value);
    f.value_pending = true;
}
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, len: usize, c: *core.Context) Error!void {
    try self.before(c);
    if (self.depth >= c.limits.depth) return error.DepthLimit;
    const shape: Kind = switch (kind) {
        .record, .map => .record,
        .sequence, .tuple => .sequence,
        .variant => .variant,
        else => return error.UnsupportedValue,
    };
    const entry: Frame = .{
        .kind = shape,
        .check_duplicates = kind == .map,
        .wrap = shape != .variant and len > 2,
        .elide = shape == .sequence and len == 1,
        .name = name,
        .key_start = self.key_count,
    };
    if (self.depth < self.frames.len) self.frames[self.depth] = entry else try self.extra.append(c.allocator(), entry);
    self.depth += 1;
    // A union is written once its payload is known.
    if (shape == .variant) return;
    try self.put(".{", c);
    if (entry.wrap) self.indent_level += 1;
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const f = self.frame().*;
    if (f.kind == .record and f.value_pending) return error.CustomRejected;
    switch (f.kind) {
        .variant => switch (f.arm) {
            .unknown => return error.CustomRejected,
            .void => {},
            .payload => {
                try self.space(c);
                try self.put("}", c);
            },
        },
        else => {
            if (f.wrap) self.indent_level -= 1;
            if (!f.empty) {
                if (f.wrap) {
                    if (self.whitespace) {
                        const indent_bytes = self.indent_level * 4;
                        if (indent_bytes <= rules.len - 2) {
                            // ",\n" and the indent, which `rules` holds, and the brace after.
                            try self.put(rules[0 .. 2 + indent_bytes], c);
                        } else {
                            try self.put(",\n", c);
                            try self.indent(c);
                        }
                    }
                } else if (!f.elide) try self.space(c);
            }
            try self.put("}", c);
        },
    }
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    self.key_count = f.key_start;
    self.extra_keys.shrinkRetainingCapacity(self.key_count - @min(self.key_count, self.keys.len));
}
pub fn validateRaw(_: *Self, payload: []const u8, c: *core.Context) Error!void {
    c.input(payload.len) catch |err| return encodeError(err);
    var decoder: Decoder = undefined;
    decoder.init(c, payload);
    defer decoder.deinit();
    var cursor: core.Cursor(Decoder) = .{ .backend = &decoder, .context = c };
    cursor.skip() catch |err| return encodeError(err);
    decoder.endInput(c) catch |err| return encodeError(err);
}
fn encodeError(err: core.DecodeError) core.EncodeError {
    return switch (err) {
        error.InputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.AllocationLimit, error.WorkLimit, error.OutOfMemory => |e| e,
        else => error.InvalidRaw,
    };
}
pub fn raw(self: *Self, payload: []const u8, c: *core.Context) Error!void {
    try self.before(c);
    try self.put(payload, c);
}
