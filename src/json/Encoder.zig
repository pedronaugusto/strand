//! JSON wire emission. Shape and field policy belong to core.
const std = @import("std");
const core = @import("../core.zig");
const strings = @import("text.zig");
const Decoder = @import("Decoder.zig");
pub const Format = Decoder.Format;
pub const capabilities = Decoder.capabilities;
pub const canonical = false;
pub const Error = core.EncodeError || std.Io.Writer.Error;
/// Mapping does not check text for UTF-8: the run scan below sees every high
/// byte, and only a run that has one is checked.
pub const validates_text = true;
writer: *std.Io.Writer,
frames: [128]Frame,
extra: std.ArrayList(Frame),
depth: usize,
keys: [128][]const u8,
extra_keys: std.ArrayList([]const u8),
key_count: usize,
/// Where output waits to be counted and published: the writer's own unused
/// buffer when it has room, `local` when it has not.
stage: []u8,
staged: usize,
local: [512]u8,
const Frame = struct { object: bool, check_duplicates: bool, key_start: usize, first: bool = true, value_pending: bool = false };
const Self = @This();
/// Starts `self` over `writer`, built where it lies, field by field: its frames,
/// keys and stage are kilobytes a struct literal would build elsewhere and copy.
pub fn init(self: *Self, writer: *std.Io.Writer) void {
    self.writer = writer;
    self.extra = .empty;
    self.depth = 0;
    self.extra_keys = .empty;
    self.key_count = 0;
    self.restage();
}
pub fn deinit(self: *Self, c: *core.Context) void {
    self.extra.deinit(c.allocator());
    self.extra_keys.deinit(c.allocator());
    self.* = undefined;
}
fn frame(self: *Self) *Frame {
    const i = self.depth - 1;
    return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
}
fn restage(self: *Self) void {
    const free = self.writer.unusedCapacitySlice();
    self.stage = if (free.len >= 256) free else &self.local;
    self.staged = 0;
}
/// Output is staged, then counted against the limit and published a stage at
/// a time: a member is a handful of small pieces, and each one separately
/// costs more than the piece. Staged in the writer's own buffer, a stage is
/// published by moving the writer's end over it, with no copy; nothing past
/// that end is the writer's until then, so a refused stage leaves nothing.
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
    self.restage();
}
/// Everything staged goes out. A caller of `begin` ends with this.
pub fn flush(self: *Self, c: *core.Context) Error!void {
    const n = self.staged;
    if (n == 0) return;
    try c.output(n);
    if (self.stage.ptr != @as([*]u8, &self.local)) {
        self.writer.end += n;
    } else try self.writer.writeAll(self.local[0..n]);
    self.restage();
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
        const found = strings.special(spelling);
        if (found.at == spelling.len) {
            if (found.non_ascii and !std.unicode.utf8ValidateSlice(spelling)) return error.InvalidUtf8;
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
        // A run ends before a byte no UTF-8 sequence holds, so each run is
        // checked whole.
        const found = strings.special(spelling[from..]);
        const i = from + found.at;
        if (found.non_ascii and !std.unicode.utf8ValidateSlice(spelling[from..i])) return error.InvalidUtf8;
        try self.put(spelling[from..i], c);
        if (i == spelling.len) break;
        const byte = spelling[i];
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
    if (!f.object or f.check_duplicates or f.value_pending) return self.key(name, c);
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
    try self.put(if (f.object) "}" else "]", c);
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
