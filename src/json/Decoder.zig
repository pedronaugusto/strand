//! Complete JSON wire tokens as immediate core events, not a token tape.
const std = @import("std");
const core = @import("../core.zig");
const Scanner = @import("Scanner.zig");
const number = @import("number.zig");
pub const Format = enum { json };
pub const Error = core.DecodeError;
pub const capabilities: core.Capabilities = .{ .map_keys = .text_only, .bytes = false, .named_shapes = false, .nonfinite_floats = false, .variant_record = true, .max_integer_bits = std.math.maxInt(usize) };
pub const parseInteger = number.integer;
pub const parseFloat = number.floating;
scanner: Scanner,
keys: [128][]const u8 = undefined,
key_count: usize = 0,
extra_keys: std.ArrayList([]const u8) = .empty,
marks: [128]usize = undefined,
extra_marks: std.ArrayList(usize) = .empty,
reject_duplicates: bool = true,
const Self = @This();
pub fn init(c: *core.Context, bytes: []const u8) Error!Self {
    try c.input(bytes.len);
    return .{ .scanner = .initCompleteInput(c.allocator(), bytes), .reject_duplicates = c.acceptance.reject_duplicates };
}
pub fn deinit(self: *Self) void {
    self.extra_keys.deinit(self.scanner.gpa);
    self.extra_marks.deinit(self.scanner.gpa);
    self.scanner.deinit();
    self.* = undefined;
}
pub fn offset(self: *const Self) usize {
    return self.scanner.cursor;
}
pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
    // The offset before a value is before the whitespace, comma or colon in front of it.
    var from = start;
    while (from < end and (self.scanner.input[from] == ' ' or self.scanner.input[from] == '\t' or self.scanner.input[from] == '\r' or self.scanner.input[from] == '\n' or self.scanner.input[from] == ',' or self.scanner.input[from] == ':')) from += 1;
    return .{ .bytes = self.scanner.input[from..end], .lifetime = .borrowed };
}
pub fn replay(self: *const Self, start: usize, end: usize) Self {
    var result: Self = .{ .scanner = .initCompleteInput(self.scanner.gpa, self.scanner.input[0..end]), .reject_duplicates = self.reject_duplicates };
    result.scanner.cursor = start;
    return result;
}
fn mapped(c: *core.Context, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        error.ValueTooLong => error.LengthLimit,
        error.UnexpectedEndOfInput => error.UnexpectedEndOfInput,
        else => error.SyntaxError,
    };
}
fn mark(self: *const Self, depth: usize) usize {
    return if (depth < self.marks.len) self.marks[depth] else self.extra_marks.items[depth - self.marks.len];
}
fn remember(self: *Self, c: *core.Context, name: []const u8) Error!void {
    if (!self.reject_duplicates) return;
    const from = self.mark(self.scanner.depth - 1);
    for (from..self.key_count) |i| {
        const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
        try c.chargeWork(@min(name.len, prior.len));
        if (std.mem.eql(u8, name, prior)) return error.DuplicateField;
    }
    if (self.key_count < self.keys.len) self.keys[self.key_count] = name else self.extra_keys.append(c.allocator(), name) catch |err| return mapped(c, err);
    self.key_count += 1;
}
pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
    const kind = self.scanner.peekNextTokenType() catch |err| return mapped(c, err);
    const depth = self.scanner.depth;
    const key = self.scanner.state == .object_start or self.scanner.state == .object_post_comma;
    if (kind == .object_begin or kind == .array_begin) {
        if (depth >= c.limits.depth) return error.DepthLimit;
        if (depth < self.marks.len) self.marks[depth] = self.key_count else self.extra_marks.append(c.allocator(), self.key_count) catch |err| return mapped(c, err);
    }
    const token = self.scanner.nextAllocPrepared(c.allocator(), kind, .alloc_if_needed, if (kind == .number) c.limits.numeric_bytes else if (key) c.limits.key_bytes else c.limits.string_bytes) catch |err| return mapped(c, err);
    return switch (token) {
        .object_begin => .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } },
        .array_begin => .{ .begin = .{ .kind = .sequence } },
        .object_end, .array_end => blk: {
            const restore = self.mark(depth - 1);
            self.key_count = restore;
            self.extra_keys.shrinkRetainingCapacity(restore - @min(restore, self.keys.len));
            if (depth > self.marks.len) _ = self.extra_marks.pop();
            break :blk .end;
        },
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .null => if (request.expected == .unit) .unit else .none,
        .number, .allocated_number => |bytes| blk: {
            if (bytes.len > c.limits.numeric_bytes) return error.LengthLimit;
            break :blk .{ .number = .{ .bytes = bytes, .lifetime = if (token == .number) .borrowed else .owned } };
        },
        .string, .allocated_string => |bytes| blk: {
            try c.span(bytes.len, key);
            if (key) try self.remember(c, bytes);
            break :blk .{ .text = .{ .bytes = bytes, .lifetime = if (token == .string) .borrowed else .owned } };
        },
        else => error.SyntaxError,
    };
}
pub fn endInput(self: *Self, c: *core.Context) Error!void {
    if ((self.scanner.next() catch |err| return mapped(c, err)) != .end_of_document) return error.SyntaxError;
}
