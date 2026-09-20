//! Direct decoding for ordinary Zig JSON types over a complete slice.
//!
//! Types with a custom `jsonParse` stay on the token-source path. This path
//! removes token construction between a contiguous JSON line and the same
//! reflected field rules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("scanner.zig");

pub fn supports(comptime T: type) bool {
    if (std.meta.hasFn(T, "jsonParse")) return false;
    return switch (@typeInfo(T)) {
        .bool, .float, .comptime_float, .int, .comptime_int, .@"enum" => true,
        .optional => |i| supports(i.child),
        .array => |i| supports(i.child),
        .vector => |i| supports(i.child),
        .pointer => |i| switch (i.size) {
            .one, .slice => supports(i.child),
            else => false,
        },
        .@"struct" => |i| fields: {
            for (i.fields) |field| if (!supports(field.type)) break :fields false;
            break :fields true;
        },
        .@"union" => |i| fields: {
            if (i.tag_type == null) break :fields false;
            for (i.fields) |field| if (field.type != void and !supports(field.type)) break :fields false;
            break :fields true;
        },
        else => false,
    };
}

pub fn parse(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!T {
    var p: Parser = .{ .allocator = allocator, .input = input, .options = options };
    const value = try p.value(T);
    p.space();
    if (p.cursor != input.len) return error.SyntaxError;
    return value;
}

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    options: std.json.ParseOptions,
    cursor: usize = 0,

    fn space(self: *Parser) void {
        while (self.cursor < self.input.len) : (self.cursor += 1) switch (self.input[self.cursor]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        };
    }

    fn take(self: *Parser, want: u8) !void {
        self.space();
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] != want) return error.UnexpectedToken;
        self.cursor += 1;
    }

    fn value(self: *Parser, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .bool => {
                self.space();
                if (self.word("true")) return true;
                if (self.word("false")) return false;
                return error.UnexpectedToken;
            },
            .float, .comptime_float => {
                const slice = try self.scalar();
                return std.fmt.parseFloat(T, slice);
            },
            .int, .comptime_int => return self.integer(T),
            .optional => |i| {
                self.space();
                if (self.word("null")) return null;
                return try self.value(i.child);
            },
            .@"enum" => {
                const slice = try self.scalar();
                if (std.meta.stringToEnum(T, slice)) |tag| return tag;
                if (!std.json.isNumberFormattedLikeAnInteger(slice)) return error.InvalidEnumTag;
                const Tag = @typeInfo(T).@"enum".tag_type;
                const n = std.fmt.parseInt(Tag, slice, 10) catch return error.InvalidEnumTag;
                return std.enums.fromInt(T, n) orelse error.InvalidEnumTag;
            },
            .@"struct" => |i| {
                if (i.is_tuple) {
                    try self.take('[');
                    var result: T = undefined;
                    inline for (i.fields, 0..) |field, n| {
                        if (n != 0) try self.take(',');
                        result[n] = try self.value(field.type);
                    }
                    try self.take(']');
                    return result;
                }
                return self.object(T);
            },
            .array => |i| {
                self.space();
                if (i.child == u8 and self.cursor < self.input.len and self.input[self.cursor] == '"') {
                    const text = try self.string(false);
                    if (text.len != i.len) return error.LengthMismatch;
                    var result: T = undefined;
                    @memcpy(&result, text);
                    return result;
                }
                try self.take('[');
                var result: T = undefined;
                for (&result, 0..) |*item, n| {
                    if (n != 0) try self.take(',');
                    item.* = try self.value(i.child);
                }
                try self.take(']');
                return result;
            },
            .vector => |i| {
                const A = [i.len]i.child;
                return @bitCast(try self.value(A));
            },
            .pointer => |i| switch (i.size) {
                .one => {
                    const result = try self.allocator.create(i.child);
                    result.* = try self.value(i.child);
                    return result;
                },
                .slice => {
                    self.space();
                    if (i.child == u8 and self.cursor < self.input.len and self.input[self.cursor] == '"') {
                        const always = !i.is_const or self.options.allocate.? == .alloc_always;
                        const result = try self.string(always);
                        if (i.sentinel()) |sentinel| {
                            const copy = try self.allocator.allocSentinel(u8, result.len, sentinel);
                            @memcpy(copy, result);
                            return copy;
                        }
                        if (!i.is_const and !always) unreachable;
                        return @constCast(result);
                    }
                    try self.take('[');
                    var list: std.ArrayList(i.child) = .empty;
                    self.space();
                    if (self.cursor < self.input.len and self.input[self.cursor] == ']') {
                        self.cursor += 1;
                    } else {
                        while (true) {
                            try list.append(self.allocator, try self.value(i.child));
                            self.space();
                            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                            if (self.input[self.cursor] == ']') {
                                self.cursor += 1;
                                break;
                            }
                            if (self.input[self.cursor] != ',') return error.UnexpectedToken;
                            self.cursor += 1;
                        }
                    }
                    if (i.sentinel()) |sentinel| return try list.toOwnedSliceSentinel(self.allocator, sentinel);
                    return try list.toOwnedSlice(self.allocator);
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            },
            .@"union" => |i| {
                try self.take('{');
                const name = try self.string(false);
                try self.take(':');
                var result: ?T = null;
                inline for (i.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        result = if (field.type == void) payload: {
                            try self.take('{');
                            try self.take('}');
                            break :payload @unionInit(T, field.name, {});
                        } else @unionInit(T, field.name, try self.value(field.type));
                        break;
                    }
                } else return error.UnknownField;
                try self.take('}');
                return result.?;
            },
            else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
        }
    }

    fn object(self: *Parser, comptime T: type) !T {
        const fields = @typeInfo(T).@"struct".fields;
        try self.take('{');
        var result: T = undefined;
        var seen = [_]bool{false} ** fields.len;
        var hint: usize = 0;
        self.space();
        if (self.cursor < self.input.len and self.input[self.cursor] == '}') {
            self.cursor += 1;
        } else fields_loop: while (true) {
            const name = try self.string(false);
            try self.take(':');

            inline for (fields, 0..) |field, i| {
                if (i == hint and std.mem.eql(u8, field.name, name)) {
                    try self.putField(T, &result, &seen, field, i);
                    hint = (i + 1) % fields.len;
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == '}') break :fields_loop;
                    continue :fields_loop;
                }
            }
            inline for (fields, 0..) |field, i| {
                if (field.is_comptime)
                    @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                if (std.mem.eql(u8, field.name, name)) {
                    try self.putField(T, &result, &seen, field, i);
                    hint = (i + 1) % fields.len;
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == '}') break :fields_loop;
                    continue :fields_loop;
                }
            }
            if (!self.options.ignore_unknown_fields) return error.UnknownField;
            try self.skipValue();
            try self.objectEnd();
            if (self.input[self.cursor - 1] == '}') break;
        }

        inline for (fields, 0..) |field, i| if (!seen[i]) {
            if (field.defaultValue()) |default| @field(result, field.name) = default else return error.MissingField;
        };
        return result;
    }

    fn putField(self: *Parser, comptime T: type, result: *T, seen: anytype, comptime field: std.builtin.Type.StructField, comptime i: usize) !void {
        if (seen[i]) switch (self.options.duplicate_field_behavior) {
            .use_first => {
                _ = try self.value(field.type);
                return;
            },
            .@"error" => return error.DuplicateField,
            .use_last => {},
        };
        @field(result, field.name) = try self.value(field.type);
        seen[i] = true;
    }

    /// Consumes the comma or closing brace and leaves the consumed byte at
    /// `cursor - 1` for the object loop to distinguish.
    fn objectEnd(self: *Parser) !void {
        self.space();
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        switch (self.input[self.cursor]) {
            ',', '}' => self.cursor += 1,
            else => return error.UnexpectedToken,
        }
    }

    fn integer(self: *Parser, comptime T: type) !T {
        const slice = try self.scalar();
        if (comptime @typeInfo(T).int.bits <= 64) {
            if (slice.len != 0 and slice[0] != '-') {
                var result: u64 = 0;
                const limit: u64 = @intCast(std.math.maxInt(T));
                for (slice) |c| {
                    if (c < '0' or c > '9') break;
                    const decimal = c - '0';
                    if (result > limit / 10 or
                        (result == limit / 10 and decimal > limit % 10)) return error.Overflow;
                    result = result * 10 + decimal;
                } else return @intCast(result);
            }
        }
        if (std.json.isNumberFormattedLikeAnInteger(slice)) return std.fmt.parseInt(T, slice, 10);
        const float = try std.fmt.parseFloat(f128, slice);
        if (@round(float) != float) return error.InvalidNumber;
        if (float > @as(f128, @floatFromInt(std.math.maxInt(T))) or
            float < @as(f128, @floatFromInt(std.math.minInt(T)))) return error.Overflow;
        return @as(T, @intFromFloat(float));
    }

    fn scalar(self: *Parser) ![]const u8 {
        self.space();
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] == '"') return self.string(false);
        const start = self.cursor;
        if (self.input[self.cursor] == '-') self.cursor += 1;
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] == '0') {
            self.cursor += 1;
        } else if (self.input[self.cursor] >= '1' and self.input[self.cursor] <= '9') {
            self.cursor += 1;
            while (self.cursor < self.input.len and digit(self.input[self.cursor])) self.cursor += 1;
        } else return error.UnexpectedToken;
        if (self.cursor < self.input.len and self.input[self.cursor] == '.') {
            self.cursor += 1;
            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
            if (!digit(self.input[self.cursor])) return error.SyntaxError;
            while (self.cursor < self.input.len and digit(self.input[self.cursor])) self.cursor += 1;
        }
        if (self.cursor < self.input.len and (self.input[self.cursor] == 'e' or self.input[self.cursor] == 'E')) {
            self.cursor += 1;
            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
            if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') self.cursor += 1;
            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
            if (!digit(self.input[self.cursor])) return error.SyntaxError;
            while (self.cursor < self.input.len and digit(self.input[self.cursor])) self.cursor += 1;
        }
        return self.input[start..self.cursor];
    }

    fn string(self: *Parser, always_allocate: bool) ![]const u8 {
        self.space();
        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] != '"') return error.UnexpectedToken;
        self.cursor += 1;
        const start = self.cursor;
        var list: std.ArrayList(u8) = .empty;
        var allocated = always_allocate;
        while (true) {
            const found = Scanner.stringSpecial(self.input[self.cursor..]);
            const at = self.cursor + found.at;
            if (found.non_ascii and !std.unicode.utf8ValidateSlice(self.input[self.cursor..at])) return error.SyntaxError;
            if (at == self.input.len) return error.UnexpectedEndOfInput;
            if (self.input[at] < 0x20) return error.SyntaxError;
            if (self.input[at] == '"') {
                if (!allocated) {
                    self.cursor = at + 1;
                    return self.input[start..at];
                }
                try list.appendSlice(self.allocator, self.input[self.cursor..at]);
                self.cursor = at + 1;
                return try list.toOwnedSlice(self.allocator);
            }
            if (!allocated) allocated = true;
            try list.appendSlice(self.allocator, self.input[self.cursor..at]);
            self.cursor = at + 1;
            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
            switch (self.input[self.cursor]) {
                '"', '\\', '/' => |c| {
                    try list.append(self.allocator, c);
                    self.cursor += 1;
                },
                'b', 'f', 'n', 'r', 't' => |c| {
                    try list.append(self.allocator, switch (c) {
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => unreachable,
                    });
                    self.cursor += 1;
                },
                'u' => {
                    self.cursor += 1;
                    const cp = try self.unicodeEscape();
                    var encoded: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &encoded) catch unreachable;
                    try list.appendSlice(self.allocator, encoded[0..len]);
                },
                else => return error.SyntaxError,
            }
        }
    }

    fn unicodeEscape(self: *Parser) !u21 {
        const first = try self.hexQuad();
        if (std.unicode.utf16IsLowSurrogate(first)) return error.SyntaxError;
        if (!std.unicode.utf16IsHighSurrogate(first)) return @intCast(first);
        if (self.input.len - self.cursor < 2) return error.UnexpectedEndOfInput;
        if (self.input[self.cursor] != '\\' or self.input[self.cursor + 1] != 'u') return error.SyntaxError;
        self.cursor += 2;
        const second = try self.hexQuad();
        if (!std.unicode.utf16IsLowSurrogate(second)) return error.SyntaxError;
        const pair = [2]u16{ first, second };
        return std.unicode.utf16DecodeSurrogatePair(&pair) catch return error.SyntaxError;
    }

    fn hexQuad(self: *Parser) !u16 {
        if (self.input.len - self.cursor < 4) return error.UnexpectedEndOfInput;
        var result: u16 = 0;
        for (0..4) |_| {
            const c = self.input[self.cursor];
            const nibble: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.SyntaxError,
            };
            result = (result << 4) | nibble;
            self.cursor += 1;
        }
        return result;
    }

    fn word(self: *Parser, comptime word_bytes: []const u8) bool {
        if (self.input.len - self.cursor < word_bytes.len) return false;
        if (!std.mem.eql(u8, self.input[self.cursor..][0..word_bytes.len], word_bytes)) return false;
        self.cursor += word_bytes.len;
        return true;
    }

    fn skipValue(self: *Parser) !void {
        self.space();
        var scanner: Scanner = .initCompleteInput(self.allocator, self.input[self.cursor..]);
        defer scanner.deinit();
        try scanner.skipValue();
        self.cursor += scanner.cursor;
    }
};

inline fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}
