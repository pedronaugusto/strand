//! Direct decoding for ordinary Zig JSON types over a complete slice.
//!
//! Types with a custom `jsonParse` stay on the token-source path. This path
//! removes token construction between a contiguous JSON line and the same
//! reflected field rules. `Raw` has a `jsonParse` for that path and is read
//! here directly: skipping a value checks it, and what was skipped is kept.
const work_module = @import("work.zig");
const mapping = @import("mapping");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");
const int = @import("int.zig");
const tagging = @import("tagging.zig");

pub fn Decoder(comptime Raw: type) type {
    return struct {
        pub fn supports(comptime T: type) bool {
            // The walk visits every field of every type reachable from `T`, once
            // per path to it: a line protocol of sixty requests is thousands of
            // steps, past the compiler's default of a thousand. The ceiling is
            // for a schema's size, never a loop that does not end: the walk
            // stops at any type it is already inside.
            @setEvalBranchQuota(1_000_000);
            return supportsType(T, .{});
        }

        fn supportsType(comptime T: type, comptime ancestors: anytype) bool {
            if (T == Raw) return true;
            inline for (ancestors) |ancestor| if (T == ancestor) return false;
            if (std.meta.hasFn(T, "jsonParse")) return false;
            const next = ancestors ++ .{T};
            return switch (@typeInfo(T)) {
                .bool, .float, .comptime_float, .int, .comptime_int, .@"enum" => true,
                .optional => |i| supportsType(i.child, next),
                .array => |i| supportsType(i.child, next),
                .vector => |i| supportsType(i.child, next),
                .pointer => |i| switch (i.size) {
                    .one, .slice => supportsType(i.child, next),
                    else => false,
                },
                .@"struct" => |i| fields: {
                    for (i.field_types) |field_type| if (!supportsType(field_type, next)) break :fields false;
                    break :fields true;
                },
                .@"union" => |i| fields: {
                    if (i.tag_type == null) break :fields false;
                    for (i.field_types) |field_type| if (field_type != void and !supportsType(field_type, next)) break :fields false;
                    break :fields true;
                },
                else => false,
            };
        }

        /// Decodes `input` into `out`, where it lies: a struct is written a field
        /// at a time into the place it is going to be read from, rather than built
        /// somewhere else and copied there whole. On an error `out` holds whatever
        /// had been decoded before it, and nothing about that is promised.
        pub fn parseInto(
            comptime T: type,
            arena: Allocator,
            input: []const u8,
            options: std.json.ParseOptions,
            out: *T,
        ) std.json.ParseError(std.json.Scanner)!void {
            work_module.parse();
            var p: Parser = .{ .arena = arena, .input = input, .options = options };
            try p.valueInto(T, out);
            p.space();
            if (p.cursor != input.len) return error.SyntaxError;
        }

        /// A value at the start of `input`, decoded into `out` as `parseInto`
        /// decodes one, and how far into `input` it ran: what comes after it
        /// is the caller's. A `.pretty` reader parses a record this way out of
        /// the bytes buffered behind it, across the line breaks inside it.
        pub fn parsePrefixInto(
            comptime T: type,
            arena: Allocator,
            input: []const u8,
            options: std.json.ParseOptions,
            out: *T,
        ) std.json.ParseError(std.json.Scanner)!usize {
            work_module.parse();
            var p: Parser = .{ .arena = arena, .input = input, .options = options };
            try p.valueInto(T, out);
            std.debug.assert(p.cursor <= input.len);
            return p.cursor;
        }

        const keyLiteral = literalKey;
        const Parser = struct {
            pub const literalKey = keyLiteral;
            pub const RawType = Raw;
            pub const internal = tagging.internal;
            pub const integerSpelling = std.json.isNumberFormattedLikeAnInteger;
            pub const record_begin = '{';
            pub const record_end = '}';
            pub const sequence_begin = '[';
            pub const sequence_end = ']';
            pub const comma = ',';
            pub const colon = ':';
            pub const text_begin = '"';
            pub const true_word = "true";
            pub const false_word = "false";
            pub const null_word = "null";
            arena: Allocator,
            input: []const u8,
            options: std.json.ParseOptions,
            cursor: usize = 0,

            pub fn space(self: *Parser) void {
                std.debug.assert(self.cursor <= self.input.len);
                defer std.debug.assert(self.cursor <= self.input.len);
                while (self.cursor < self.input.len) : (self.cursor += 1) switch (self.input[self.cursor]) {
                    ' ', '\t', '\r', '\n' => {},
                    else => return,
                };
            }

            pub fn take(self: *Parser, want: u8) !void {
                self.space();
                if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.cursor] != want) return error.UnexpectedToken;
                self.cursor += 1;
            }

            /// `value`, into `out`. A struct is filled in place; anything else is
            /// decoded and stored.
            pub fn valueInto(self: *Parser, comptime T: type, out: *T) !void {
                return mapping.valueInto(T, self, out);
            }

            pub fn value(self: *Parser, comptime T: type) !T {
                return mapping.value(T, self);
            }

            pub fn object(self: *Parser, comptime T: type, result: *T) !void {
                try self.take('{');
                return self.members(T, result, null, .open);
            }

            /// Where `members` takes an object up.
            const From = enum {
                /// Just past its `{`.
                open,
                /// Just past the value of a member read already, which was the
                /// one named `skip`.
                after_skipped,
            };

            /// An object's members into `result`, from `from` to its `}`. A
            /// member named `skip` is passed over once and is a duplicate the
            /// second time: the tag of a union tagged inside its object, which
            /// is not one of the arm's fields.
            pub fn members(self: *Parser, comptime T: type, result: *T, comptime skip: ?[]const u8, comptime from: From) !void {
                return mapping.members(T, skip, from, self, result);
            }

            /// A union tagged inside its object. The tag is read where most
            /// writers put it, first, and the arm's members are read on from
            /// there; anywhere else, the object is looked through for it once
            /// and then read from the top, passing over it.
            pub fn tagged(self: *Parser, comptime T: type, comptime inside: anytype) !T {
                self.space();
                const start = self.cursor;
                try self.take('{');
                const key = comptime keyLiteral(inside.tag).?;
                self.space();
                var from: From = .open;
                const name = if (self.input.len - self.cursor >= key.len and
                    std.mem.eql(u8, self.input[self.cursor..][0..key.len], key))
                first: {
                    self.cursor += key.len;
                    try self.take(':');
                    from = .after_skipped;
                    break :first try self.tagName();
                } else elsewhere: {
                    const top = self.cursor;
                    const found = try self.findTag(inside.tag);
                    self.cursor = top;
                    break :elsewhere found;
                };
                const info = @typeInfo(T).@"union";
                inline for (info.field_names, info.field_types) |field_name, field_type| {
                    const is_other = comptime inside.other != null and
                        std.mem.eql(u8, field_name, @tagName(inside.other.?));
                    if (!is_other and std.mem.eql(u8, field_name, name)) {
                        if (field_type == void) {
                            var none: struct {} = .{};
                            switch (from) {
                                inline else => |at| try self.members(@TypeOf(none), &none, inside.tag, at),
                            }
                            return @unionInit(T, field_name, {});
                        }
                        var result: T = @unionInit(T, field_name, undefined);
                        switch (from) {
                            inline else => |at| try self.members(field_type, &@field(result, field_name), inside.tag, at),
                        }
                        return result;
                    }
                }
                if (comptime inside.other) |other| {
                    const payload_type = @FieldType(T, @tagName(other));
                    // Not this reader's to read: every member is passed over,
                    // and the record kept whole when there is a place for it.
                    try self.passOver(inside.tag, from);
                    if (payload_type == void) return @unionInit(T, @tagName(other), {});
                    const bytes = self.input[start..self.cursor];
                    return @unionInit(T, @tagName(other), .{
                        .bytes = if (self.options.allocate.? == .alloc_always) try self.arena.dupe(u8, bytes) else bytes,
                    });
                }
                return error.InvalidEnumTag;
            }

            /// The value of the tag member: a string, which is an arm's name.
            fn tagName(self: *Parser) ![]const u8 {
                self.space();
                if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.cursor] != '"') return error.UnexpectedToken;
                return self.string(false);
            }

            /// The tag's value in the object whose `{` is just behind the
            /// cursor, which is left anywhere: the caller puts it back.
            fn findTag(self: *Parser, comptime tag: []const u8) ![]const u8 {
                var found: ?[]const u8 = null;
                self.space();
                if (self.cursor < self.input.len and self.input[self.cursor] == '}') return error.MissingField;
                while (true) {
                    const name = try self.string(false);
                    try self.take(':');
                    if (std.mem.eql(u8, name, tag)) {
                        if (found != null) return error.DuplicateField;
                        found = try self.tagName();
                    } else try self.skipValue();
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == '}') break;
                }
                return found orelse error.MissingField;
            }

            /// Every member from `from` to the `}`, checked and not kept, the
            /// tag passed over once.
            fn passOver(self: *Parser, comptime tag: []const u8, from: From) !void {
                var skipped = from == .after_skipped;
                if (from == .open) {
                    self.space();
                    if (self.cursor < self.input.len and self.input[self.cursor] == '}') {
                        self.cursor += 1;
                        return;
                    }
                } else {
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == '}') return;
                }
                while (true) {
                    const name = try self.string(false);
                    try self.take(':');
                    if (std.mem.eql(u8, name, tag)) {
                        if (skipped) return error.DuplicateField;
                        skipped = true;
                    }
                    try self.skipValue();
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == '}') return;
                }
            }

            pub fn putField(self: *Parser, comptime T: type, result: *T, seen: anytype, comptime field_name: []const u8, comptime i: usize) !void {
                return mapping.putField(T, field_name, i, self, result, seen);
            }

            /// Consumes the comma or closing brace and leaves the consumed byte at
            /// `cursor - 1` for the object loop to distinguish.
            pub fn objectEnd(self: *Parser) !void {
                self.space();
                if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                switch (self.input[self.cursor]) {
                    ',', '}' => self.cursor += 1,
                    else => return error.UnexpectedToken,
                }
            }

            pub fn integer(self: *Parser, comptime T: type) !T {
                return int.fromSlice(T, try self.scalar());
            }

            pub fn scalar(self: *Parser) ![]const u8 {
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

            pub fn string(self: *Parser, always_allocate: bool) ![]const u8 {
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
                    if (found.non_ascii and !std.unicode.utf8ValidateSlice(self.input[self.cursor..at]))
                        return Scanner.invalidUtf8(self.input[self.cursor..at], at == self.input.len);
                    if (at == self.input.len) return error.UnexpectedEndOfInput;
                    if (self.input[at] < 0x20) return error.SyntaxError;
                    if (self.input[at] == '"') {
                        if (!allocated) {
                            self.cursor = at + 1;
                            return self.input[start..at];
                        }
                        try list.appendSlice(self.arena, self.input[self.cursor..at]);
                        self.cursor = at + 1;
                        return try list.toOwnedSlice(self.arena);
                    }
                    if (!allocated) allocated = true;
                    try list.appendSlice(self.arena, self.input[self.cursor..at]);
                    self.cursor = at + 1;
                    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                    switch (self.input[self.cursor]) {
                        '"', '\\', '/' => |c| {
                            try list.append(self.arena, c);
                            self.cursor += 1;
                        },
                        'b', 'f', 'n', 'r', 't' => |c| {
                            try list.append(self.arena, switch (c) {
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
                            std.debug.assert(cp <= 0x10FFFF);
                            std.debug.assert(cp < 0xD800 or cp > 0xDFFF);
                            // unreachable: unicodeEscape rejects lone surrogates and combines valid pairs into scalars at most U+10FFFF; four bytes suffice.
                            const len = std.unicode.utf8Encode(cp, &encoded) catch unreachable;
                            try list.appendSlice(self.arena, encoded[0..len]);
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

            pub fn word(self: *Parser, comptime word_bytes: []const u8) bool {
                if (self.input.len - self.cursor < word_bytes.len) return false;
                if (!std.mem.eql(u8, self.input[self.cursor..][0..word_bytes.len], word_bytes)) return false;
                self.cursor += word_bytes.len;
                return true;
            }

            /// A value, checked and kept as its bytes. They borrow from the input
            /// under the rule a string follows: a view unless every string is to be
            /// copied.
            pub fn raw(self: *Parser) !Raw {
                self.space();
                const start = self.cursor;
                try self.skipValue();
                const bytes = self.input[start..self.cursor];
                if (self.options.allocate.? == .alloc_always) return .{ .bytes = try self.arena.dupe(u8, bytes) };
                return .{ .bytes = bytes };
            }

            /// Steps over one value, checking it as the scanner would, without a
            /// token or an allocation: what an unknown field and a `Raw` cost. The
            /// nesting is a bit a level in one word, so a value deeper than that
            /// goes to the scanner, whose stack is on the heap, from its start.
            pub fn skipValue(self: *Parser) !void {
                self.space();
                const start = self.cursor;
                // One bit a level, set for an object.
                var objects: u64 = 0;
                var depth: u8 = 0;
                values: while (true) {
                    self.space();
                    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                    switch (self.input[self.cursor]) {
                        '{', '[' => |open| {
                            if (depth == 64) {
                                self.cursor = start;
                                return self.skipDeep();
                            }
                            const in_object = open == '{';
                            objects = (objects << 1) | @intFromBool(in_object);
                            depth += 1;
                            self.cursor += 1;
                            self.space();
                            if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                            if (self.input[self.cursor] == @as(u8, if (in_object) '}' else ']')) {
                                self.cursor += 1;
                                objects >>= 1;
                                depth -= 1;
                            } else {
                                if (in_object) try self.skipKey();
                                continue :values;
                            }
                        },
                        '"' => try self.skipString(),
                        't' => if (!self.word("true")) return error.SyntaxError,
                        'f' => if (!self.word("false")) return error.SyntaxError,
                        'n' => if (!self.word("null")) return error.SyntaxError,
                        '-', '0'...'9' => _ = try self.scalar(),
                        else => return error.SyntaxError,
                    }
                    // A value is done: close what it closes, until a comma says
                    // another value follows or nothing is left open.
                    while (depth > 0) {
                        self.space();
                        if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                        const in_object = objects & 1 == 1;
                        const byte = self.input[self.cursor];
                        self.cursor += 1;
                        if (byte == ',') {
                            if (in_object) try self.skipKey();
                            continue :values;
                        }
                        if (byte != @as(u8, if (in_object) '}' else ']')) return error.SyntaxError;
                        objects >>= 1;
                        depth -= 1;
                    }
                    return;
                }
            }

            /// A key and its colon, checked and passed over.
            fn skipKey(self: *Parser) !void {
                self.space();
                if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.cursor] != '"') return error.SyntaxError;
                try self.skipString();
                try self.take(':');
            }

            /// A string, checked as `string` checks it and not copied anywhere.
            /// The cursor is on its opening quote.
            fn skipString(self: *Parser) !void {
                self.cursor += 1;
                while (true) {
                    const found = Scanner.stringSpecial(self.input[self.cursor..]);
                    const at = self.cursor + found.at;
                    if (found.non_ascii and !std.unicode.utf8ValidateSlice(self.input[self.cursor..at]))
                        return Scanner.invalidUtf8(self.input[self.cursor..at], at == self.input.len);
                    if (at == self.input.len) return error.UnexpectedEndOfInput;
                    if (self.input[at] < 0x20) return error.SyntaxError;
                    self.cursor = at + 1;
                    if (self.input[at] == '"') return;
                    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                    switch (self.input[self.cursor]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,
                        'u' => {
                            self.cursor += 1;
                            _ = try self.unicodeEscape();
                        },
                        else => return error.SyntaxError,
                    }
                }
            }

            /// `skipValue` past the depth it tracks itself.
            fn skipDeep(self: *Parser) !void {
                var scanner: Scanner = .initCompleteInput(self.arena, self.input[self.cursor..]);
                defer scanner.deinit();
                try scanner.skipValue();
                self.cursor += scanner.cursor;
            }
        };

        /// A field's name as a key spelled with no escape in it, quotes included;
        /// null for a name that would need one, or that is not UTF-8, which the
        /// key's own reading decides.
        pub fn literalKey(comptime name: []const u8) ?[]const u8 {
            comptime {
                if (!std.unicode.utf8ValidateSlice(name)) return null;
                for (name) |b| if (b < 0x20 or b == '"' or b == '\\') return null;
                return "\"" ++ name ++ "\"";
            }
        }

        inline fn digit(c: u8) bool {
            return c >= '0' and c <= '9';
        }
    };
}
