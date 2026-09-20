//! Complete-input JSON scanner used by strand's typed hot path.
//!
//! `std.json` owns the typed parser. This implements its token-source
//! contract for the one case strand has already established before parsing:
//! one complete value in one contiguous slice. Keeping that narrower contract
//! lets strings find their closing quote or next escape a vector at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Token = std.json.Token;
pub const TokenType = std.json.TokenType;
pub const AllocWhen = std.json.AllocWhen;
pub const Error = error{ SyntaxError, UnexpectedEndOfInput };
pub const NextError = Error || Allocator.Error || error{BufferUnderrun};
pub const AllocError = Error || Allocator.Error || error{ValueTooLong};
pub const PeekError = Error || error{BufferUnderrun};
pub const SkipError = Error || Allocator.Error;
pub const AllocIntoArrayListError = AllocError || error{BufferUnderrun};

const Mode = enum { object, array };
const State = enum {
    value,
    post_value,
    object_start,
    object_post_comma,
    array_start,
    string,
    string_escape,
};

allocator: Allocator,
input: []const u8,
cursor: usize = 0,
value_start: usize = 0,
state: State = .value,
string_is_object_key: bool = false,
inline_stack: [64]Mode = undefined,
extra_stack: std.ArrayList(Mode) = .empty,
depth: usize = 0,
diagnostics: ?*std.json.Diagnostics = null,

pub fn initCompleteInput(allocator: Allocator, input: []const u8) @This() {
    return .{ .allocator = allocator, .input = input };
}

pub fn deinit(self: *@This()) void {
    self.extra_stack.deinit(self.allocator);
    self.* = undefined;
}

pub fn enableDiagnostics(self: *@This(), diagnostics: *std.json.Diagnostics) void {
    diagnostics.cursor_pointer = &self.cursor;
    self.diagnostics = diagnostics;
}

pub fn stackHeight(self: *const @This()) usize {
    return self.depth;
}

pub fn ensureTotalStackCapacity(self: *@This(), height: usize) Allocator.Error!void {
    if (height > self.inline_stack.len)
        try self.extra_stack.ensureTotalCapacity(self.allocator, height - self.inline_stack.len);
}

fn push(self: *@This(), mode: Mode) Allocator.Error!void {
    if (self.depth < self.inline_stack.len) {
        self.inline_stack[self.depth] = mode;
    } else {
        try self.extra_stack.append(self.allocator, mode);
    }
    self.depth += 1;
}

fn pop(self: *@This()) ?Mode {
    if (self.depth == 0) return null;
    self.depth -= 1;
    if (self.depth < self.inline_stack.len) return self.inline_stack[self.depth];
    return self.extra_stack.pop();
}

fn top(self: *const @This()) ?Mode {
    if (self.depth == 0) return null;
    const i = self.depth - 1;
    return if (i < self.inline_stack.len) self.inline_stack[i] else self.extra_stack.items[i - self.inline_stack.len];
}

fn skipWhitespace(self: *@This()) void {
    while (self.cursor < self.input.len) : (self.cursor += 1) switch (self.input[self.cursor]) {
        ' ', '\t', '\r' => {},
        '\n' => if (self.diagnostics) |diag| {
            diag.line_number += 1;
            diag.line_start_cursor = self.cursor;
        },
        else => return,
    };
}

fn byte(self: *const @This()) Error!u8 {
    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
    return self.input[self.cursor];
}

fn prepare(self: *@This()) Error!TokenType {
    while (true) switch (self.state) {
        .value => {
            self.skipWhitespace();
            const c = try self.byte();
            return switch (c) {
                '{' => .object_begin,
                '[' => .array_begin,
                '"' => .string,
                '-', '0'...'9' => .number,
                't' => .true,
                'f' => .false,
                'n' => .null,
                else => error.SyntaxError,
            };
        },
        .object_start => {
            self.skipWhitespace();
            return switch (try self.byte()) {
                '"' => .string,
                '}' => .object_end,
                else => error.SyntaxError,
            };
        },
        .object_post_comma => {
            self.skipWhitespace();
            return switch (try self.byte()) {
                '"' => .string,
                else => error.SyntaxError,
            };
        },
        .array_start => {
            self.skipWhitespace();
            if (try self.byte() == ']') return .array_end;
            self.state = .value;
        },
        .post_value => {
            self.skipWhitespace();
            if (self.cursor == self.input.len) {
                if (self.depth == 0) return .end_of_document;
                return error.UnexpectedEndOfInput;
            }
            const c = self.input[self.cursor];
            if (self.string_is_object_key) {
                if (c != ':') return error.SyntaxError;
                self.string_is_object_key = false;
                self.cursor += 1;
                self.state = .value;
                continue;
            }
            switch (c) {
                '}' => return .object_end,
                ']' => return .array_end,
                ',' => {
                    self.cursor += 1;
                    self.state = switch (self.top() orelse return error.SyntaxError) {
                        .object => .object_post_comma,
                        .array => .value,
                    };
                },
                else => return error.SyntaxError,
            }
        },
        .string, .string_escape => return .string,
    };
}

pub fn peekNextTokenType(self: *@This()) PeekError!TokenType {
    return self.prepare();
}

pub fn next(self: *@This()) NextError!Token {
    while (true) {
        switch (self.state) {
            .string => return self.nextString(),
            .string_escape => return self.nextStringEscape(),
            else => {},
        }

        const kind = try self.prepare();
        switch (kind) {
            .object_begin => {
                try self.push(.object);
                self.cursor += 1;
                self.state = .object_start;
                return .object_begin;
            },
            .array_begin => {
                try self.push(.array);
                self.cursor += 1;
                self.state = .array_start;
                return .array_begin;
            },
            .object_end => {
                if (self.pop() != .object) return error.SyntaxError;
                self.cursor += 1;
                self.state = .post_value;
                return .object_end;
            },
            .array_end => {
                if (self.pop() != .array) return error.SyntaxError;
                self.cursor += 1;
                self.state = .post_value;
                return .array_end;
            },
            .string => {
                self.string_is_object_key = self.state == .object_start or self.state == .object_post_comma;
                self.cursor += 1;
                self.value_start = self.cursor;
                self.state = .string;
            },
            .number => return self.nextNumber(),
            .true => return self.nextLiteral("true", .true),
            .false => return self.nextLiteral("false", .false),
            .null => return self.nextLiteral("null", .null),
            .end_of_document => return .end_of_document,
        }
    }
}

fn nextLiteral(self: *@This(), comptime word: []const u8, token: Token) Error!Token {
    for (word) |want| {
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] != want) return error.SyntaxError;
        self.cursor += 1;
    }
    self.state = .post_value;
    return token;
}

fn nextNumber(self: *@This()) Error!Token {
    const start = self.cursor;
    if (self.input[self.cursor] == '-') {
        self.cursor += 1;
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
    }
    if (self.input[self.cursor] == '0') {
        self.cursor += 1;
    } else if (self.input[self.cursor] >= '1' and self.input[self.cursor] <= '9') {
        self.cursor += 1;
        while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
    } else return error.SyntaxError;

    if (self.cursor < self.input.len and self.input[self.cursor] == '.') {
        self.cursor += 1;
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (!isDigit(self.input[self.cursor])) return error.SyntaxError;
        while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
    }
    if (self.cursor < self.input.len and (self.input[self.cursor] == 'e' or self.input[self.cursor] == 'E')) {
        self.cursor += 1;
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') {
            self.cursor += 1;
            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        }
        if (!isDigit(self.input[self.cursor])) return error.SyntaxError;
        while (self.cursor < self.input.len and isDigit(self.input[self.cursor])) self.cursor += 1;
    }
    self.state = .post_value;
    return .{ .number = self.input[start..self.cursor] };
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub const Special = struct { at: usize, non_ascii: bool };

/// Finds JSON's three interesting classes inside a raw string run. ASCII
/// text is cleared a vector at a time; UTF-8 is validated once for the whole
/// run only when a vector observed a high bit.
pub fn stringSpecial(bytes: []const u8) Special {
    var i: usize = 0;
    var non_ascii = false;
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |width| {
            const V = @Vector(width, u8);
            const quote: V = @splat('"');
            const slash: V = @splat('\\');
            const control: V = @splat(0x20);
            const high: V = @splat(0x80);
            while (i + width <= bytes.len) : (i += width) {
                const v: V = bytes[i..][0..width].*;
                const hits = (v == quote) | (v == slash) | (v < control);
                if (@reduce(.Or, hits)) {
                    const at = std.simd.firstTrue(hits).?;
                    for (bytes[i..][0..at]) |c| non_ascii = non_ascii or c >= 0x80;
                    return .{ .at = i + at, .non_ascii = non_ascii };
                }
                non_ascii = non_ascii or @reduce(.Or, (v & high) == high);
            }
        }
    }
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return .{ .at = i, .non_ascii = non_ascii };
        non_ascii = non_ascii or c >= 0x80;
    }
    return .{ .at = bytes.len, .non_ascii = non_ascii };
}

fn nextString(self: *@This()) Error!Token {
    const found = stringSpecial(self.input[self.cursor..]);
    const at = self.cursor + found.at;
    if (found.non_ascii and !std.unicode.utf8ValidateSlice(self.input[self.value_start..at])) {
        self.cursor = at;
        return error.SyntaxError;
    }
    self.cursor = at;
    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
    switch (self.input[self.cursor]) {
        0...0x1f => return error.SyntaxError,
        '"' => {
            const slice = self.input[self.value_start..self.cursor];
            self.cursor += 1;
            self.state = .post_value;
            return .{ .string = slice };
        },
        '\\' => {
            const slice = self.input[self.value_start..self.cursor];
            self.cursor += 1;
            self.state = .string_escape;
            if (slice.len != 0) return .{ .partial_string = slice };
            return self.nextStringEscape();
        },
        else => unreachable,
    }
}

fn nextStringEscape(self: *@This()) Error!Token {
    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
    switch (self.input[self.cursor]) {
        '"', '\\', '/' => {
            self.value_start = self.cursor;
            self.cursor += 1;
            self.state = .string;
            return self.nextString();
        },
        'b', 'f', 'n', 'r', 't' => |c| {
            const escaped: u8 = switch (c) {
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => unreachable,
            };
            self.cursor += 1;
            self.value_start = self.cursor;
            self.state = .string;
            return .{ .partial_string_escaped_1 = .{escaped} };
        },
        'u' => {
            const codepoint = try self.unicodeEscape();
            self.value_start = self.cursor;
            self.state = .string;
            return codepointToken(codepoint);
        },
        else => return error.SyntaxError,
    }
}

fn unicodeEscape(self: *@This()) Error!u21 {
    // `cursor` points at the u.
    self.cursor += 1;
    const first = try self.hexQuad();
    if (std.unicode.utf16IsLowSurrogate(first)) return error.SyntaxError;
    if (!std.unicode.utf16IsHighSurrogate(first)) return @intCast(first);
    if (self.input.len - self.cursor < 2) {
        self.cursor = self.input.len;
        return error.UnexpectedEndOfInput;
    }
    if (self.input[self.cursor] != '\\' or self.input[self.cursor + 1] != 'u') return error.SyntaxError;
    self.cursor += 2;
    const second = try self.hexQuad();
    if (!std.unicode.utf16IsLowSurrogate(second)) return error.SyntaxError;
    const pair = [2]u16{ first, second };
    return std.unicode.utf16DecodeSurrogatePair(&pair) catch return error.SyntaxError;
}

fn hexQuad(self: *@This()) Error!u16 {
    if (self.input.len - self.cursor < 4) {
        self.cursor = self.input.len;
        return error.UnexpectedEndOfInput;
    }
    var out: u16 = 0;
    for (0..4) |_| {
        const c = self.input[self.cursor];
        const nibble: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.SyntaxError,
        };
        out = (out << 4) | nibble;
        self.cursor += 1;
    }
    return out;
}

fn codepointToken(cp: u21) Token {
    var buf: [4]u8 = undefined;
    return switch (std.unicode.utf8Encode(cp, &buf) catch unreachable) {
        1 => .{ .partial_string_escaped_1 = buf[0..1].* },
        2 => .{ .partial_string_escaped_2 = buf[0..2].* },
        3 => .{ .partial_string_escaped_3 = buf[0..3].* },
        4 => .{ .partial_string_escaped_4 = buf[0..4].* },
        else => unreachable,
    };
}

pub fn nextAlloc(self: *@This(), allocator: Allocator, when: AllocWhen) AllocError!Token {
    return self.nextAllocMax(allocator, when, std.json.default_max_value_len);
}

pub fn nextAllocMax(self: *@This(), allocator: Allocator, when: AllocWhen, max: usize) AllocError!Token {
    const kind = self.peekNextTokenType() catch |err| switch (err) {
        error.BufferUnderrun => unreachable,
        else => |e| return e,
    };
    switch (kind) {
        .number, .string => {
            var list = std.array_list.Managed(u8).init(allocator);
            errdefer list.deinit();
            const borrowed = self.allocNextIntoArrayListMax(&list, when, max) catch |err| switch (err) {
                error.BufferUnderrun => unreachable,
                else => |e| return e,
            };
            if (borrowed) |slice| {
                return if (kind == .number) .{ .number = slice } else .{ .string = slice };
            }
            return if (kind == .number)
                .{ .allocated_number = try list.toOwnedSlice() }
            else
                .{ .allocated_string = try list.toOwnedSlice() };
        },
        else => return self.next() catch |err| switch (err) {
            error.BufferUnderrun => unreachable,
            else => |e| return e,
        },
    }
}

pub fn allocNextIntoArrayList(self: *@This(), list: *std.array_list.Managed(u8), when: AllocWhen) AllocIntoArrayListError!?[]const u8 {
    return self.allocNextIntoArrayListMax(list, when, std.json.default_max_value_len);
}

pub fn allocNextIntoArrayListMax(self: *@This(), list: *std.array_list.Managed(u8), when: AllocWhen, max: usize) AllocIntoArrayListError!?[]const u8 {
    while (true) switch (try self.next()) {
        .partial_number, .partial_string => |slice| try append(list, slice, max),
        .partial_string_escaped_1 => |buf| try append(list, &buf, max),
        .partial_string_escaped_2 => |buf| try append(list, &buf, max),
        .partial_string_escaped_3 => |buf| try append(list, &buf, max),
        .partial_string_escaped_4 => |buf| try append(list, &buf, max),
        .number, .string => |slice| {
            if (when == .alloc_if_needed and list.items.len == 0) return slice;
            try append(list, slice, max);
            return null;
        },
        else => unreachable,
    };
}

fn append(list: *std.array_list.Managed(u8), slice: []const u8, max: usize) AllocError!void {
    if (max -| list.items.len < slice.len) return error.ValueTooLong;
    try list.appendSlice(slice);
}

pub fn skipValue(self: *@This()) SkipError!void {
    switch (self.peekNextTokenType() catch |err| switch (err) {
        error.BufferUnderrun => unreachable,
        else => |e| return e,
    }) {
        .object_begin, .array_begin => self.skipUntilStackHeight(self.stackHeight()) catch |err| switch (err) {
            error.BufferUnderrun => unreachable,
            else => |e| return e,
        },
        .number, .string => while (true) switch (self.next() catch |err| switch (err) {
            error.BufferUnderrun => unreachable,
            else => |e| return e,
        }) {
            .partial_number, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
            .number, .string => break,
            else => unreachable,
        },
        .true, .false, .null => _ = self.next() catch |err| switch (err) {
            error.BufferUnderrun => unreachable,
            else => |e| return e,
        },
        .object_end, .array_end, .end_of_document => unreachable,
    }
}

pub fn skipUntilStackHeight(self: *@This(), terminal: usize) NextError!void {
    while (true) switch (try self.next()) {
        .object_end, .array_end => if (self.stackHeight() == terminal) return,
        .end_of_document => unreachable,
        else => {},
    };
}

test "string scan agrees with scalar positions" {
    const testing = std.testing;
    var buf: [259]u8 = undefined;
    for (0..buf.len) |len| {
        @memset(buf[0..len], 'x');
        try testing.expectEqual(len, stringSpecial(buf[0..len]).at);
        for (0..len) |at| {
            buf[at] = '"';
            try testing.expectEqual(at, stringSpecial(buf[0..len]).at);
            buf[at] = 'x';
        }
    }
}
