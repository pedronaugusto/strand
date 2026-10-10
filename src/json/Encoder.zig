//! JSON wire emission. Shape and field policy belong to core.
const std = @import("std");
const core = @import("../core.zig");
const Scanner = @import("Scanner.zig");
const Decoder = @import("Decoder.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;
writer: *std.Io.Writer,
/// Non-ASCII text is written as `\u` escapes, so every byte out is ASCII.
ascii: bool = false,
/// The root container is left without its closing bracket, for a caller that
/// adds members of its own; `left_empty` says whether it held none.
leave_open: bool = false,
left_empty: bool = true,
frames: [128]Frame = undefined,
extra: std.ArrayList(Frame) = .empty,
depth: usize = 0,
keys: [128][]const u8 = undefined,
extra_keys: std.ArrayList([]const u8) = .empty,
key_count: usize = 0,
stage: [4096]u8 = undefined,
staged: usize = 0,
const Frame = struct { object: bool, check_duplicates: bool, key_start: usize, first: bool = true, value_pending: bool = false };
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
fn before(self: *Self, c: *core.Context) Error!void {
    if (self.depth == 0) return;
    const f = self.frame();
    if (f.object and f.value_pending) {
        f.value_pending = false;
        return;
    }
    if (!f.first) try self.put(",", c);
    f.first = false;
    if (f.object) f.value_pending = true;
}
fn quoted(self: *Self, spelling: []const u8, c: *core.Context) Error!void {
    // A string with nothing to escape is one piece when the stage has room.
    if (spelling.len + 2 <= self.stage.len - self.staged) {
        const found = Scanner.stringSpecial(spelling);
        if (found.at == spelling.len and !(self.ascii and found.non_ascii)) {
            self.stage[self.staged] = '"';
            @memcpy(self.stage[self.staged + 1 ..][0..spelling.len], spelling);
            self.stage[self.staged + 1 + spelling.len] = '"';
            self.staged += spelling.len + 2;
            return;
        }
    }
    try self.put("\"", c);
    var from: usize = 0;
    while (from < spelling.len) {
        const i = from + (if (self.ascii) asciiSpecial(spelling[from..]) else Scanner.stringSpecial(spelling[from..]).at);
        try self.put(spelling[from..i], c);
        if (i == spelling.len) break;
        const byte = spelling[i];
        if (byte >= 0x80) {
            // Valid UTF-8, which the caller has checked: one scalar, as one or two units.
            const length = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
            try self.escapeScalar(std.unicode.utf8Decode(spelling[i..][0..length]) catch return error.InvalidUtf8, c);
            from = i + length;
            continue;
        }
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            8 => "\\b",
            12 => "\\f",
            else => null,
        };
        if (escape) |escaped| {
            try self.put(escaped, c);
        } else {
            var buffer: [6]u8 = undefined;
            const escaped = std.mem.print(&buffer, "\\u00{x:0>2}", .{byte}) catch unreachable; // unreachable: a six-byte escape fits exactly.
            try self.put(escaped, c);
        }
        from = i + 1;
    }
    try self.put("\"", c);
}
/// One scalar past ASCII as `\u` escapes: one, or a surrogate pair.
fn escapeScalar(self: *Self, code: u21, c: *core.Context) Error!void {
    var buffer: [12]u8 = undefined;
    const escaped = if (code < 0x10000)
        std.mem.print(&buffer, "\\u{x:0>4}", .{code}) catch unreachable // unreachable: six bytes fit.
    else escaped: {
        const v = code - 0x10000;
        break :escaped std.mem.print(&buffer, "\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff) }) catch unreachable; // unreachable: twelve bytes fit.
    };
    try self.put(escaped, c);
}
/// Where text needs more than a copy when it must be ASCII: a quote, a
/// backslash, a control byte or a byte past ASCII.
fn asciiSpecial(text_bytes: []const u8) usize {
    for (text_bytes, 0..) |byte, i| if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) return i;
    return text_bytes.len;
}
pub fn boolean(self: *Self, value: bool, c: *core.Context) Error!void {
    try self.before(c);
    try self.put(if (value) "true" else "false", c);
}
pub fn integer(self: *Self, value: anytype, c: *core.Context) Error!void {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    var buffer: [bits / 3 + 3]u8 = undefined;
    const spelling = buffer[0..std.fmt.printInt(&buffer, value, 10, .lower, .{})];
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.put(spelling, c);
}
pub fn floating(self: *Self, value: anytype, c: *core.Context) Error!void {
    var buffer: [128]u8 = undefined;
    const spelling = std.mem.print(&buffer, "{}", .{value}) catch return error.NumberOutOfRange;
    if (spelling.len > c.limits.numeric_bytes) return error.LengthLimit;
    try self.before(c);
    try self.put(spelling, c);
}
pub fn text(self: *Self, value: []const u8, c: *core.Context) Error!void {
    const is_key = self.depth != 0 and self.frame().object and !self.frame().value_pending;
    if (is_key and self.frame().check_duplicates) {
        for (self.frame().key_start..self.key_count) |i| {
            const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
            try c.chargeWork(@min(value.len, prior.len));
            if (std.mem.eql(u8, value, prior)) return error.DuplicateField;
        }
        if (self.key_count < self.keys.len) self.keys[self.key_count] = value else try self.extra_keys.append(c.allocator(), value);
        self.key_count += 1;
    }
    try self.before(c);
    try self.quoted(value, c);
    if (is_key) try self.put(":", c);
}
pub const key = text;
/// A field of a struct, whose name is a constant: `"name":` in one piece, with
/// the comma that separates it from the member before.
pub fn field(self: *Self, comptime name: []const u8, c: *core.Context) Error!void {
    const f = self.frame();
    if (self.ascii or !f.object or f.check_duplicates or f.value_pending) return self.key(name, c);
    const piece = comptime "\"" ++ escapedName(name) ++ "\":";
    if (f.first) {
        f.first = false;
        try self.put(piece, c);
    } else try self.put("," ++ piece, c);
    f.value_pending = true;
}
fn escapedName(comptime name: []const u8) []const u8 {
    comptime var result: []const u8 = "";
    inline for (name) |byte| result = result ++ switch (byte) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        8 => "\\b",
        12 => "\\f",
        0...7, 11, 14...31 => std.fmt.comptimePrint("\\u00{x:0>2}", .{byte}),
        else => &[_]u8{byte},
    };
    return result;
}
pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Error!void {
    return error.UnsupportedValue;
}
pub fn scalar(self: *Self, value: u21, c: *core.Context) Error!void {
    var buffer: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(value, &buffer) catch return error.InvalidUtf8;
    try self.text(buffer[0..n], c);
}
pub fn nullValue(self: *Self, c: *core.Context) Error!void {
    try self.before(c);
    try self.put("null", c);
}
pub const unit = nullValue;
pub fn begin(self: *Self, kind: core.Kind, name: []const u8, _: usize, c: *core.Context) Error!void {
    try self.before(c);
    const object = kind == .record or kind == .map or kind == .variant;
    try self.put(if (object) "{" else "[", c);
    if (self.depth < self.frames.len) self.frames[self.depth] = .{ .object = object, .check_duplicates = kind == .map, .key_start = self.key_count } else try self.extra.append(c.allocator(), .{ .object = object, .check_duplicates = kind == .map, .key_start = self.key_count });
    self.depth += 1;
    if (kind == .variant) try self.key(name, c);
}
pub fn end(self: *Self, c: *core.Context) Error!void {
    const f = self.frame().*;
    if (f.object and f.value_pending) return error.CustomRejected;
    if (self.leave_open and self.depth == 1) {
        self.left_empty = f.first;
    } else try self.put(if (f.object) "}" else "]", c);
    if (self.depth > self.frames.len) _ = self.extra.pop();
    self.depth -= 1;
    self.key_count = f.key_start;
    self.extra_keys.shrinkRetainingCapacity(self.key_count - @min(self.key_count, self.keys.len));
}
/// Checks that `payload` is one JSON value and that it is within the limits, as
/// reading it would, without allocating: a string is looked at as it is written,
/// not unescaped. A key spelled with an escape is not compared with the others,
/// so only repeats of plain keys are found.
pub fn validateRaw(_: *Self, payload: []const u8, c: *core.Context) Error!void {
    try c.input(payload.len);
    var scanner: Scanner = .initCompleteInput(c.allocator(), payload);
    defer scanner.deinit();
    var items: [128]usize = undefined;
    var first_key: [128]usize = undefined;
    var keys: [128][]const u8 = undefined;
    var key_count: usize = 0;
    var string_len: usize = 0;
    var in_string = false;
    var is_key = false;
    while (true) {
        const state = scanner.state;
        const token = scanner.next() catch |err| return switch (err) {
            error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
            else => error.InvalidRaw,
        };
        switch (token) {
            .partial_string => |part| string_len += part.len,
            .partial_string_escaped_1 => string_len += 1,
            .partial_string_escaped_2 => string_len += 2,
            .partial_string_escaped_3 => string_len += 3,
            .partial_string_escaped_4 => string_len += 4,
            .string => |last| {
                const plain = !in_string and string_len == 0;
                if (!in_string) is_key = state == .object_start or state == .object_post_comma;
                in_string = false;
                string_len += last.len;
                try c.node();
                try c.span(string_len, is_key);
                try c.chargeWork(string_len + 1);
                if (is_key and plain) {
                    const level = scanner.depth - 1;
                    if (level < first_key.len) {
                        for (first_key[level]..key_count) |i| {
                            try c.chargeWork(@min(last.len, keys[i].len));
                            if (std.mem.eql(u8, last, keys[i])) return error.InvalidRaw;
                        }
                        if (key_count < keys.len) {
                            keys[key_count] = last;
                            key_count += 1;
                        }
                    }
                }
                if (!is_key) try countItem(&items, scanner.depth, c);
                string_len = 0;
                is_key = false;
            },
            .number => |word| {
                if (word.len > c.limits.numeric_bytes) return error.LengthLimit;
                try c.node();
                try c.chargeWork(word.len + 1);
                try countItem(&items, scanner.depth, c);
            },
            .true, .false, .null => {
                try c.node();
                try c.chargeWork(1);
                try countItem(&items, scanner.depth, c);
            },
            .object_begin, .array_begin => {
                try c.node();
                try c.chargeWork(1);
                if (scanner.depth > 1) try countItem(&items, scanner.depth - 1, c);
                if (c.depth + scanner.depth > c.limits.depth) return error.DepthLimit;
                if (scanner.depth <= items.len) {
                    items[scanner.depth - 1] = 0;
                    first_key[scanner.depth - 1] = key_count;
                }
            },
            .object_end, .array_end => if (scanner.depth < first_key.len) {
                key_count = first_key[scanner.depth];
            },
            .end_of_document => return error.InvalidRaw,
            .partial_number, .allocated_number, .allocated_string => unreachable,
        }
        // A string begun is a key when the scanner was waiting for one.
        if (!in_string and (token == .partial_string or token == .partial_string_escaped_1 or token == .partial_string_escaped_2 or token == .partial_string_escaped_3 or token == .partial_string_escaped_4)) {
            in_string = true;
            is_key = state == .object_start or state == .object_post_comma;
        }
        if (scanner.depth == 0 and !in_string) {
            const rest = scanner.next() catch return error.InvalidRaw;
            if (rest != .end_of_document) return error.InvalidRaw;
            return;
        }
    }
}
fn countItem(items: *[128]usize, depth: usize, c: *core.Context) core.EncodeError!void {
    if (depth == 0 or depth > items.len) return;
    items[depth - 1] += 1;
    if (items[depth - 1] > c.limits.container_items) return error.ItemLimit;
}
/// A value written as it came, with the two promises a line makes about every
/// value: a line break, which JSON allows only between tokens, is a space, so a
/// record stays one line; and under `ascii` a character past ASCII, which can
/// only be inside a string, is its `\u` escape. Neither changes the value.
pub fn raw(self: *Self, payload: []const u8, c: *core.Context) Error!void {
    try self.before(c);
    var from: usize = 0;
    var i: usize = 0;
    while (i < payload.len) {
        const byte = payload[i];
        if (byte == '\n' or byte == '\r') {
            try self.put(payload[from..i], c);
            try self.put(" ", c);
            i += 1;
            from = i;
        } else if (byte >= 0x80 and self.ascii) {
            try self.put(payload[from..i], c);
            const length = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidRaw;
            if (i + length > payload.len) return error.InvalidRaw;
            try self.escapeScalar(std.unicode.utf8Decode(payload[i..][0..length]) catch return error.InvalidRaw, c);
            i += length;
            from = i;
        } else i += 1;
    }
    try self.put(payload[from..], c);
}
