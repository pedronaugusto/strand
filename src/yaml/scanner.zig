//! YAML 1.2's tokens from its text: indentation turned into the starts and
//! ends of block collections, an implicit key found when the `:` after it is,
//! scalars of every style decoded. The shape is libyaml's scanner, held to
//! YAML 1.2: anchors of any characters but white space and flow indicators,
//! `:` inside plain scalars in flow collections, a `:` right after a JSON-like
//! key, tabs only where white space may be and never as indentation, a block
//! collection only where one may start, and the indentation rules of quoted,
//! plain and block scalars.
//!
//! A token refers to its bytes by position: in the input where its value is
//! those bytes, in the decoded bytes where it is not (a folded line, an
//! escape). The decoded bytes are working storage the caller gives back.
const std = @import("std");

pub const Error = error{ SyntaxError, OutOfMemory, InputLimit };

/// The character `bytes` start with, and its length, if they start with one.
pub fn decodeChar(bytes: []const u8) ?struct { cp: u21, len: u3 } {
    if (bytes.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < len) return null;
    const cp: u21 = switch (len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return null,
        else => std.unicode.utf8Decode4(bytes[0..4].*) catch return null,
    };
    return .{ .cp = cp, .len = len };
}

/// A place in the text.
pub const Mark = struct {
    index: u32 = 0,
    line: u32 = 0,
    /// In characters, not bytes.
    column: u32 = 0,
};

pub const Style = enum(u3) { plain, single_quoted, double_quoted, literal, folded };

/// Bytes of the input, or of the decoded bytes.
pub const Ref = struct {
    start: u32 = 0,
    len: u32 = 0,
    decoded: bool = false,
};

pub const Kind = enum(u8) {
    stream_start,
    stream_end,
    version_directive,
    tag_directive,
    /// A directive YAML reserves: read past.
    reserved_directive,
    document_start,
    document_end,
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end,
    flow_mapping_start,
    flow_mapping_end,
    block_entry,
    flow_entry,
    key,
    value,
    alias,
    anchor,
    tag,
    scalar,
};

pub const Token = struct {
    kind: Kind,
    start: Mark,
    end: Mark,
    style: Style = .plain,
    /// A scalar's value; an anchor's or an alias's name; a tag's suffix; a
    /// tag directive's prefix; a version directive's version.
    value: Ref = .{},
    /// A tag's handle (empty for a verbatim tag); a tag directive's handle.
    handle: Ref = .{},
};

/// What came before on a line: nothing, an indicator after which a compact
/// block collection may start (`- `, `? `, a `: ` that starts its line), or
/// anything else, after which no block collection starts on the line.
const Prefix = enum { none, compact, other };

/// A key that may be implicit: found as such when a `:` follows it on its line.
const SimpleKey = struct {
    possible: bool = false,
    required: bool = false,
    number: usize = 0,
    mark: Mark = .{},
    /// What came before it on its line.
    prefix: Prefix = .none,
    /// A tab is in the white space before it, which starts its line.
    tabbed: bool = false,
};

/// A scalar's bytes as they are found: a span of the input while they are
/// one, copied into the decoded bytes once they are not.
const Builder = struct {
    scanner: *Scanner,
    start: u32,
    end: u32,
    decoded: bool = false,

    fn init(scanner: *Scanner, at: u32) Builder {
        return .{ .scanner = scanner, .start = at, .end = at };
    }
    /// The input from `from` to `to`.
    fn input(self: *Builder, from: u32, to: u32) Error!void {
        if (!self.decoded) {
            if (self.start == self.end) {
                self.start = from;
                self.end = to;
                return;
            }
            if (from == self.end) {
                self.end = to;
                return;
            }
            try self.spill();
        }
        try self.scanner.decoded.appendSlice(self.scanner.allocator, self.scanner.input[from..to]);
    }
    fn bytes(self: *Builder, b: []const u8) Error!void {
        if (b.len == 0) return;
        if (!self.decoded) try self.spill();
        try self.scanner.decoded.appendSlice(self.scanner.allocator, b);
    }
    fn byte(self: *Builder, b: u8) Error!void {
        try self.bytes(&.{b});
    }
    fn spill(self: *Builder) Error!void {
        const s = self.scanner;
        const from = s.input[self.start..self.end];
        self.start = std.math.cast(u32, s.decoded.items.len) orelse return error.InputLimit;
        try s.decoded.appendSlice(s.allocator, from);
        self.decoded = true;
    }
    fn ref(self: *const Builder) Error!Ref {
        if (!self.decoded) return .{ .start = self.start, .len = self.end - self.start };
        const len = std.math.cast(u32, self.scanner.decoded.items.len - self.start) orelse return error.InputLimit;
        return .{ .start = self.start, .len = len, .decoded = true };
    }
};

pub const Scanner = struct {
    input: []const u8,
    allocator: std.mem.Allocator,
    /// Where the bytes no span of the input holds are kept.
    decoded: *std.ArrayList(u8),
    at: Mark = .{},
    /// The tokens found and not yet taken, from `head`.
    tokens: std.ArrayList(Token) = .empty,
    head: usize = 0,
    /// How many tokens have been taken.
    taken: usize = 0,
    started: bool = false,
    ended: bool = false,
    /// The block indentation: the column of the innermost block collection.
    indent: i64 = -1,
    indents: std.ArrayList(i64) = .empty,
    flow_level: u32 = 0,
    simple_key_allowed: bool = false,
    simple_keys: std.ArrayList(SimpleKey) = .empty,
    /// The last token ends a JSON-like node (a quoted scalar, a flow
    /// collection): a `:` after it is a value indicator in a flow collection
    /// even with no space after it.
    json_last: bool = false,
    /// What came before on this line.
    prefix: Prefix = .none,
    /// A tab is in the white space before the next token, on its line.
    tabbed: bool = false,
    /// Where the scanner stopped, when it refused the text.
    failed_at: u32 = 0,

    pub fn init(input: []const u8, allocator: std.mem.Allocator, decoded: *std.ArrayList(u8)) Scanner {
        return .{ .input = input, .allocator = allocator, .decoded = decoded };
    }
    pub fn deinit(self: *Scanner) void {
        self.tokens.deinit(self.allocator);
        self.indents.deinit(self.allocator);
        self.simple_keys.deinit(self.allocator);
    }

    fn fail(self: *Scanner) Error {
        self.failed_at = self.at.index;
        return error.SyntaxError;
    }
    fn failAt(self: *Scanner, mark: Mark) Error {
        self.failed_at = mark.index;
        return error.SyntaxError;
    }

    /// The next token, not taken.
    pub fn peek(self: *Scanner) Error!*const Token {
        try self.fetchMore();
        return &self.tokens.items[self.head];
    }
    /// Takes the token `peek` gave.
    pub fn skip(self: *Scanner) void {
        self.head += 1;
        self.taken += 1;
        if (self.head == self.tokens.items.len) {
            self.tokens.clearRetainingCapacity();
            self.head = 0;
        }
    }

    // Characters.

    fn byteAt(self: *const Scanner, offset: usize) u8 {
        const i = self.at.index + offset;
        return if (i < self.input.len) self.input[i] else 0;
    }
    fn cur(self: *const Scanner) u8 {
        return self.byteAt(0);
    }
    fn eof(self: *const Scanner) bool {
        return self.at.index >= self.input.len;
    }
    fn isBlank(b: u8) bool {
        return b == ' ' or b == '\t';
    }
    fn isBreakAt(self: *const Scanner, offset: usize) bool {
        const b = self.byteAt(offset);
        return b == '\n' or b == '\r';
    }
    fn isBlankzAt(self: *const Scanner, offset: usize) bool {
        const i = self.at.index + offset;
        if (i >= self.input.len) return true;
        const b = self.input[i];
        return b == ' ' or b == '\t' or b == '\n' or b == '\r';
    }
    fn isFlowIndicator(b: u8) bool {
        return b == ',' or b == '[' or b == ']' or b == '{' or b == '}';
    }
    /// Advances one character on the same line.
    fn advance(self: *Scanner) void {
        const b = self.input[self.at.index];
        const len: u32 = if (b < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(b) catch 1);
        self.at.index += len;
        self.at.column += 1;
    }
    /// Advances `n` ASCII characters.
    fn advanceAscii(self: *Scanner, n: u32) void {
        self.at.index += n;
        self.at.column += n;
    }
    /// Advances over a line break: `\n`, `\r\n` or `\r`.
    fn advanceBreak(self: *Scanner) void {
        if (self.cur() == '\r' and self.byteAt(1) == '\n') self.at.index += 2 else self.at.index += 1;
        self.at.line += 1;
        self.at.column = 0;
    }
    /// Whether a printable character starts here (YAML's c-printable, less
    /// the line breaks).
    fn printableAt(self: *const Scanner) bool {
        const b = self.cur();
        if (b == 0x09 or (b >= 0x20 and b < 0x7f)) return true;
        if (b < 0x80) return false;
        const cp = (decodeChar(self.input[self.at.index..]) orelse return false).cp;
        return switch (cp) {
            0x85, 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
            else => false,
        };
    }
    /// How many spaces start the line the scanner is on, which nothing but
    /// white space has been read on.
    fn lineSpaces(self: *const Scanner) u32 {
        const line_start = self.at.index - self.at.column;
        var n: u32 = 0;
        while (line_start + n < self.input.len and self.input[line_start + n] == ' ') n += 1;
        return n;
    }

    // Tokens.

    fn append(self: *Scanner, token: Token) Error!void {
        try self.tokens.append(self.allocator, token);
        self.json_last = false;
        self.prefix = switch (token.kind) {
            .block_entry, .key => .compact,
            .value => if (self.prefix == .none) .compact else .other,
            else => .other,
        };
    }
    fn simple(self: *Scanner, kind: Kind, start: Mark) Error!void {
        try self.append(.{ .kind = kind, .start = start, .end = self.at });
    }

    fn fetchMore(self: *Scanner) Error!void {
        while (true) {
            var need = self.head == self.tokens.items.len;
            if (!need) {
                if (self.ended) return;
                try self.staleSimpleKeys();
                for (self.simple_keys.items) |candidate| {
                    if (candidate.possible and candidate.number == self.taken) {
                        need = true;
                        break;
                    }
                }
            }
            if (!need) return;
            try self.fetchNext();
        }
    }

    fn fetchNext(self: *Scanner) Error!void {
        if (!self.started) return self.streamStart();
        if (self.ended) return self.fail();
        try self.toNextToken();
        try self.staleSimpleKeys();
        try self.unrollIndent(self.at.column);
        if (self.eof()) return self.streamEnd();
        const c = self.cur();
        if (self.at.column == 0) {
            const marker = self.documentIndicator("---") or self.documentIndicator("...");
            if ((c == '%' or marker) and self.flow_level > 0) return self.fail();
            if (c == '%') return self.directive();
            if (self.documentIndicator("---")) return self.documentMarker(.document_start);
            if (self.documentIndicator("...")) return self.documentMarker(.document_end);
        }
        if (self.prefix == .none) {
            // The first token on a line inside a flow collection is indented
            // past the block it is in, by spaces.
            if (self.flow_level > 0 and self.lineSpaces() <= self.indent) return self.fail();
            if (self.tabbed and self.flow_level == 0) {
                // A tab is no indentation: no block indicator follows one,
                // and what does is indented past its block by spaces alone.
                switch (c) {
                    '-', '?', ':' => if (self.isBlankzAt(1)) return self.fail(),
                    else => {},
                }
                if (self.lineSpaces() <= self.indent) return self.fail();
            }
        }
        switch (c) {
            '[' => return self.flowCollectionStart(.flow_sequence_start),
            '{' => return self.flowCollectionStart(.flow_mapping_start),
            ']' => return self.flowCollectionEnd(.flow_sequence_end),
            '}' => return self.flowCollectionEnd(.flow_mapping_end),
            ',' => return self.flowEntry(),
            '-' => if (self.isBlankzAt(1)) return self.blockEntry(),
            '?' => if (self.isBlankzAt(1)) return self.key(),
            ':' => if (self.isBlankzAt(1) or (self.flow_level > 0 and (isFlowIndicator(self.byteAt(1)) or self.json_last))) return self.value(),
            '*' => return self.anchor(.alias),
            '&' => return self.anchor(.anchor),
            '!' => return self.tag(),
            '|', '>' => if (self.flow_level == 0) return self.blockScalar(c == '|'),
            '\'' => return self.flowScalar(false),
            '"' => return self.flowScalar(true),
            else => {},
        }
        // A plain scalar, unless this is an indicator that starts nothing.
        const starts_plain = switch (c) {
            '-' => !self.isBlankzAt(1) and !(self.flow_level > 0 and isFlowIndicator(self.byteAt(1))),
            '?', ':' => !self.isBlankzAt(1) and !(self.flow_level > 0 and isFlowIndicator(self.byteAt(1))),
            ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => false,
            else => true,
        };
        if (!starts_plain) return self.fail();
        return self.plainScalar();
    }

    fn documentIndicator(self: *const Scanner, comptime marker: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.at.index..], marker) and self.isBlankzAt(3);
    }

    /// White space, comments and line breaks before the next token.
    fn toNextToken(self: *Scanner) Error!void {
        while (true) {
            // A byte-order mark may start the stream and any document.
            if (self.at.column == 0 and std.mem.startsWith(u8, self.input[self.at.index..], "\xEF\xBB\xBF")) self.at.index += 3;
            while (!self.eof() and isBlank(self.cur())) {
                self.advanceAscii(1);
            }
            if (!self.eof() and self.cur() == '#') {
                // A comment is set apart from what comes before it.
                if (self.at.column > 0 and !isBlank(self.input[self.at.index - 1])) return self.fail();
                while (!self.eof() and !self.isBreakAt(0)) {
                    if (!self.printableAt()) return self.fail();
                    self.advance();
                }
            }
            if (!self.eof() and self.isBreakAt(0)) {
                self.newLine();
                continue;
            }
            break;
        }
        // Whether a tab is in the white space just before the token.
        self.tabbed = false;
        var i = self.at.index;
        while (i > 0 and isBlank(self.input[i - 1])) {
            i -= 1;
            if (self.input[i] == '\t') self.tabbed = true;
        }
    }
    fn newLine(self: *Scanner) void {
        self.advanceBreak();
        self.prefix = .none;
        if (self.flow_level == 0) self.simple_key_allowed = true;
    }

    fn staleSimpleKeys(self: *Scanner) Error!void {
        for (self.simple_keys.items) |*candidate| {
            if (candidate.possible and (candidate.mark.line < self.at.line or self.at.index > candidate.mark.index + 1024)) {
                if (candidate.required) return self.failAt(candidate.mark);
                candidate.possible = false;
            }
        }
    }
    fn saveSimpleKey(self: *Scanner) Error!void {
        const required = self.flow_level == 0 and self.indent == self.at.column;
        if (!self.simple_key_allowed) return;
        try self.removeSimpleKey();
        self.simple_keys.items[self.simple_keys.items.len - 1] = .{
            .possible = true,
            .required = required,
            .number = self.taken + self.tokens.items.len - self.head,
            .mark = self.at,
            .prefix = self.prefix,
            .tabbed = self.tabbed,
        };
    }
    fn removeSimpleKey(self: *Scanner) Error!void {
        const last = &self.simple_keys.items[self.simple_keys.items.len - 1];
        if (last.possible and last.required) return self.failAt(last.mark);
        last.possible = false;
    }

    /// Opens a block collection at `column` when it is deeper than the one
    /// open; `prefix` is what came before it on its line.
    /// `tabbed`, that a tab is in the white space before it on its line.
    fn rollIndent(self: *Scanner, column: u32, number: ?usize, kind: Kind, mark: Mark, prefix: Prefix, tabbed: bool) Error!void {
        if (self.flow_level > 0) return;
        if (self.indent >= column) return;
        if (prefix == .other or tabbed) return self.failAt(mark);
        try self.indents.append(self.allocator, self.indent);
        self.indent = column;
        const token: Token = .{ .kind = kind, .start = mark, .end = mark };
        if (number) |n| {
            try self.tokens.insert(self.allocator, n - self.taken + self.head, token);
        } else try self.tokens.append(self.allocator, token);
    }
    fn unrollIndent(self: *Scanner, column: i64) Error!void {
        if (self.flow_level > 0) return;
        while (self.indent > column) {
            try self.tokens.append(self.allocator, .{ .kind = .block_end, .start = self.at, .end = self.at });
            self.indent = self.indents.pop().?;
        }
    }

    fn streamStart(self: *Scanner) Error!void {
        self.started = true;
        self.indent = -1;
        self.simple_key_allowed = true;
        try self.simple_keys.append(self.allocator, .{});
        try self.simple(.stream_start, self.at);
        self.prefix = .none;
    }
    fn streamEnd(self: *Scanner) Error!void {
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        self.ended = true;
        try self.simple(.stream_end, self.at);
    }

    fn directive(self: *Scanner) Error!void {
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        self.advanceAscii(1);
        const name_start = self.at.index;
        while (!self.isBlankzAt(0)) {
            if (!self.printableAt()) return self.fail();
            self.advance();
        }
        const name = self.input[name_start..self.at.index];
        if (name.len == 0) return self.fail();
        var token: Token = .{ .kind = .reserved_directive, .start = start, .end = start };
        if (std.mem.eql(u8, name, "YAML")) {
            token.kind = .version_directive;
            try self.separation();
            const v = self.at.index;
            try self.digits();
            if (self.cur() != '.') return self.fail();
            self.advanceAscii(1);
            try self.digits();
            token.value = .{ .start = v, .len = self.at.index - v };
        } else if (std.mem.eql(u8, name, "TAG")) {
            token.kind = .tag_directive;
            try self.separation();
            token.handle = try self.tagHandle(true);
            try self.separation();
            // The prefix: a local one starts with `!`, a global one with a
            // URI character that is no flow indicator.
            var builder: Builder = .init(self, self.at.index);
            if (self.cur() == '!') {
                const from = self.at.index;
                self.advanceAscii(1);
                try builder.input(from, self.at.index);
            } else if (isFlowIndicator(self.cur())) return self.fail();
            try self.uri(&builder, false);
            token.value = try builder.ref();
            if (token.value.len == 0) return self.fail();
        } else {
            // A reserved directive's parameters are read past.
            while (!self.eof() and isBlank(self.cur())) {
                while (!self.eof() and isBlank(self.cur())) self.advanceAscii(1);
                if (self.cur() == '#' or self.eof() or self.isBreakAt(0)) break;
                while (!self.isBlankzAt(0)) {
                    if (!self.printableAt()) return self.fail();
                    self.advance();
                }
            }
        }
        // The rest of the line: white space and a comment.
        try self.lineEnd();
        token.end = self.at;
        try self.append(token);
    }
    /// White space and a comment to the end of the line.
    fn lineEnd(self: *Scanner) Error!void {
        while (!self.eof() and isBlank(self.cur())) self.advanceAscii(1);
        if (!self.eof() and self.cur() == '#') {
            if (!isBlank(self.input[self.at.index - 1])) return self.fail();
            while (!self.eof() and !self.isBreakAt(0)) {
                if (!self.printableAt()) return self.fail();
                self.advance();
            }
        }
        if (!self.eof() and !self.isBreakAt(0)) return self.fail();
    }
    fn separation(self: *Scanner) Error!void {
        if (self.eof() or !isBlank(self.cur())) return self.fail();
        while (!self.eof() and isBlank(self.cur())) self.advanceAscii(1);
    }
    fn digits(self: *Scanner) Error!void {
        const start = self.at.index;
        while (!self.eof() and std.ascii.isDigit(self.cur())) self.advanceAscii(1);
        if (self.at.index == start) return self.fail();
    }

    fn documentMarker(self: *Scanner, kind: Kind) Error!void {
        try self.unrollIndent(-1);
        try self.removeSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        self.advanceAscii(3);
        try self.simple(kind, start);
        // Only a comment may follow `...` on its line.
        if (kind == .document_end) try self.lineEnd();
    }

    fn flowCollectionStart(self: *Scanner, kind: Kind) Error!void {
        try self.saveSimpleKey();
        try self.simple_keys.append(self.allocator, .{});
        self.flow_level = std.math.add(u32, self.flow_level, 1) catch return self.fail();
        self.simple_key_allowed = true;
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(kind, start);
    }
    fn flowCollectionEnd(self: *Scanner, kind: Kind) Error!void {
        if (self.flow_level == 0) return self.fail();
        try self.removeSimpleKey();
        self.flow_level -= 1;
        _ = self.simple_keys.pop();
        self.simple_key_allowed = false;
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(kind, start);
        self.json_last = true;
    }
    fn flowEntry(self: *Scanner) Error!void {
        if (self.flow_level == 0) return self.fail();
        try self.removeSimpleKey();
        self.simple_key_allowed = true;
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(.flow_entry, start);
    }
    fn blockEntry(self: *Scanner) Error!void {
        if (self.flow_level > 0) return self.fail();
        if (!self.simple_key_allowed) return self.fail();
        try self.rollIndent(self.at.column, null, .block_sequence_start, self.at, self.prefix, self.tabbed);
        try self.removeSimpleKey();
        self.simple_key_allowed = true;
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(.block_entry, start);
    }
    fn key(self: *Scanner) Error!void {
        if (self.flow_level == 0) {
            if (!self.simple_key_allowed) return self.fail();
            try self.rollIndent(self.at.column, null, .block_mapping_start, self.at, self.prefix, self.tabbed);
        }
        try self.removeSimpleKey();
        self.simple_key_allowed = self.flow_level == 0;
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(.key, start);
    }
    fn value(self: *Scanner) Error!void {
        const sk = &self.simple_keys.items[self.simple_keys.items.len - 1];
        if (sk.possible) {
            const found = sk.*;
            sk.possible = false;
            try self.tokens.insert(self.allocator, found.number - self.taken + self.head, .{ .kind = .key, .start = found.mark, .end = found.mark });
            try self.rollIndent(found.mark.column, found.number, .block_mapping_start, found.mark, found.prefix, found.tabbed);
            self.simple_key_allowed = false;
        } else {
            if (self.flow_level == 0) {
                if (!self.simple_key_allowed) return self.fail();
                // A node that could not be an implicit key (on more than one
                // line, or too long) is not followed by `:` on its line.
                if (self.prefix == .other) return self.fail();
                try self.rollIndent(self.at.column, null, .block_mapping_start, self.at, self.prefix, self.tabbed);
            }
            self.simple_key_allowed = self.flow_level == 0;
        }
        const start = self.at;
        self.advanceAscii(1);
        try self.simple(.value, start);
    }

    /// `&name` or `*name`: any characters but white space and flow indicators.
    fn anchor(self: *Scanner, kind: Kind) Error!void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        self.advanceAscii(1);
        const name_start = self.at.index;
        while (!self.isBlankzAt(0) and !isFlowIndicator(self.cur())) {
            if (!self.printableAt()) return self.fail();
            self.advance();
        }
        if (self.at.index == name_start) return self.fail();
        try self.append(.{ .kind = kind, .start = start, .end = self.at, .value = .{ .start = name_start, .len = self.at.index - name_start } });
    }

    /// A tag handle: `!`, `!!` or `!word!`. In a TAG directive it is one of
    /// those whole; on a node, `!word` is the primary handle and a suffix.
    fn tagHandle(self: *Scanner, in_directive: bool) Error!Ref {
        const start = self.at.index;
        if (self.cur() != '!') return self.fail();
        self.advanceAscii(1);
        while (!self.eof() and (std.ascii.isAlphanumeric(self.cur()) or self.cur() == '-')) self.advanceAscii(1);
        if (!self.eof() and self.cur() == '!') {
            self.advanceAscii(1);
        } else if (self.at.index - start > 1) {
            if (in_directive) return self.fail();
            // The word is the suffix: read it again as one.
            self.at.column -= self.at.index - start - 1;
            self.at.index = start + 1;
        }
        return .{ .start = start, .len = self.at.index - start };
    }

    /// URI characters into `builder`, `%xx` escapes decoded. A tag's
    /// shorthand suffix takes no `!` and no flow indicators.
    fn uri(self: *Scanner, builder: *Builder, comptime shorthand: bool) Error!void {
        while (!self.eof()) {
            const c = self.cur();
            const ok = std.ascii.isAlphanumeric(c) or switch (c) {
                '-', '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', '_', '.', '~', '*', '\'', '(', ')', '%' => true,
                ',', '[', ']', '!' => !shorthand,
                else => false,
            };
            if (!ok) break;
            if (c == '%') {
                const hi = std.fmt.charToDigit(self.byteAt(1), 16) catch return self.fail();
                const lo = std.fmt.charToDigit(self.byteAt(2), 16) catch return self.fail();
                try builder.byte(hi << 4 | lo);
                self.advanceAscii(3);
                continue;
            }
            const from = self.at.index;
            self.advanceAscii(1);
            try builder.input(from, self.at.index);
        }
    }

    fn tag(self: *Scanner) Error!void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        var token: Token = .{ .kind = .tag, .start = start, .end = start };
        if (self.byteAt(1) == '<') {
            // `!<uri>`, verbatim.
            self.advanceAscii(2);
            var builder: Builder = .init(self, self.at.index);
            try self.uri(&builder, false);
            if (self.eof() or self.cur() != '>') return self.fail();
            token.value = try builder.ref();
            if (token.value.len == 0) return self.fail();
            self.advanceAscii(1);
        } else {
            token.handle = try self.tagHandle(false);
            var builder: Builder = .init(self, self.at.index);
            try self.uri(&builder, true);
            token.value = try builder.ref();
            // `!!` and `!name!` need a suffix; `!` alone is the non-specific tag.
            if (token.value.len == 0 and token.handle.len > 1) return self.fail();
        }
        if (!self.isBlankzAt(0) and !(self.flow_level > 0 and isFlowIndicator(self.cur()))) return self.fail();
        token.end = self.at;
        try self.append(token);
    }

    fn blockScalar(self: *Scanner, literal: bool) Error!void {
        try self.removeSimpleKey();
        self.simple_key_allowed = true;
        const start = self.at;
        self.advanceAscii(1);
        const Chomp = enum { strip, clip, keep };
        var chomp: Chomp = .clip;
        var increment: u32 = 0;
        for (0..2) |_| {
            if (self.eof()) break;
            const c = self.cur();
            if ((c == '+' or c == '-') and chomp == .clip) {
                chomp = if (c == '+') .keep else .strip;
                self.advanceAscii(1);
            } else if (c >= '1' and c <= '9' and increment == 0) {
                increment = c - '0';
                self.advanceAscii(1);
            }
        }
        try self.lineEnd();
        if (!self.eof()) self.advanceBreak();

        var builder: Builder = .init(self, self.at.index);
        try builder.spill();
        const parent = self.indent;
        var trailing: usize = 0;
        var leading_break = false;
        var leading_blank = false;
        const n = try self.blockBreaks(if (increment > 0) parent + increment else null, &trailing, parent);
        while (self.at.column == n and !self.eof()) {
            // A document marker ends the scalar.
            if (self.at.column == 0 and (self.documentIndicator("---") or self.documentIndicator("..."))) break;
            const trailing_blank = isBlank(self.cur());
            if (!literal and leading_break and !leading_blank and !trailing_blank) {
                if (trailing == 0) try builder.byte(' ');
            } else if (leading_break) try builder.byte('\n');
            leading_break = false;
            for (0..trailing) |_| try builder.byte('\n');
            trailing = 0;
            leading_blank = isBlank(self.cur());
            const from = self.at.index;
            while (!self.eof() and !self.isBreakAt(0)) {
                if (!self.printableAt()) return self.fail();
                self.advance();
            }
            try builder.input(from, self.at.index);
            // The last line ends with the input as with a line break.
            leading_break = true;
            if (self.eof()) break;
            self.advanceBreak();
            _ = try self.blockBreaks(n, &trailing, parent);
        }
        if (chomp != .strip and leading_break) try builder.byte('\n');
        if (chomp == .keep) for (0..trailing) |_| try builder.byte('\n');
        try self.append(.{ .kind = .scalar, .start = start, .end = self.at, .style = if (literal) .literal else .folded, .value = try builder.ref() });
        // The scalar ends at the start of a line.
        self.prefix = .none;
    }
    /// Empty lines inside a block scalar, counted into `trailing`, up to a
    /// line with content at its indentation or less; that indentation, found
    /// from the first line with content when `indent` is null.
    fn blockBreaks(self: *Scanner, indent: ?i64, trailing: *usize, parent: i64) Error!i64 {
        var max_spaces: i64 = 0;
        while (true) {
            const line_from = self.at.index;
            while (!self.eof() and self.cur() == ' ' and (indent == null or self.at.column < indent.?)) self.advanceAscii(1);
            if (self.at.column > max_spaces) max_spaces = self.at.column;
            if (self.eof()) {
                // A last line of spaces ends with the input as with a break.
                if (self.at.index > line_from) trailing.* += 1;
                break;
            }
            if (!self.isBreakAt(0)) {
                if (self.cur() != '\t') break;
                const known = indent orelse {
                    // The first line with something on it: a tab where its
                    // indentation would be is refused.
                    if (self.at.column <= parent) return self.fail();
                    break;
                };
                if (self.at.column >= known) break;
                // A tab inside the indentation: an empty line if nothing
                // else is on it; otherwise a less indented line, which ends
                // the scalar.
                var probe = self.at.index;
                while (probe < self.input.len and isBlank(self.input[probe])) probe += 1;
                if (probe < self.input.len and self.input[probe] != '\n' and self.input[probe] != '\r') break;
                self.at.column += @intCast(probe - self.at.index);
                self.at.index = @intCast(probe);
                if (self.eof()) {
                    trailing.* += 1;
                    break;
                }
            }
            trailing.* += 1;
            self.advanceBreak();
        }
        if (indent) |n| return n;
        // The first line of content sets the indentation; an empty line
        // before it may not be indented further.
        if (!self.eof() and self.at.column > parent) {
            if (max_spaces > self.at.column) return self.fail();
            return self.at.column;
        }
        return @max(max_spaces, parent + 1);
    }

    fn flowScalar(self: *Scanner, double: bool) Error!void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        self.advanceAscii(1);
        var builder: Builder = .init(self, self.at.index);
        const quote: u8 = if (double) '"' else '\'';
        while (true) {
            if (self.eof()) return self.fail();
            // A run of characters.
            while (!self.isBlankzAt(0)) {
                const c = self.cur();
                if (c == quote) {
                    if (!double and self.byteAt(1) == '\'') {
                        try builder.byte('\'');
                        self.advanceAscii(2);
                        continue;
                    }
                    break;
                }
                if (double and c == '\\') {
                    if (self.isBreakAt(1)) {
                        // An escaped line break: the lines join with no space.
                        self.advanceAscii(1);
                        self.advanceBreak();
                        try self.quotedLine();
                        while (!self.eof() and isBlank(self.cur())) self.advanceAscii(1);
                        continue;
                    }
                    try self.escape(&builder);
                    continue;
                }
                if (!self.printableAt()) return self.fail();
                const from = self.at.index;
                self.advance();
                try builder.input(from, self.at.index);
            }
            if (!self.eof() and self.cur() == quote) break;
            // White space and line breaks.
            const whitespace_start = self.at.index;
            var whitespace_end = self.at.index;
            var breaks: usize = 0;
            while (!self.eof() and (isBlank(self.cur()) or self.isBreakAt(0))) {
                if (isBlank(self.cur())) {
                    self.advanceAscii(1);
                    if (breaks == 0) whitespace_end = self.at.index;
                } else {
                    breaks += 1;
                    self.advanceBreak();
                    try self.quotedLine();
                }
            }
            if (self.eof()) return self.fail();
            if (breaks == 0) {
                try builder.input(whitespace_start, whitespace_end);
            } else if (breaks == 1) {
                try builder.byte(' ');
            } else {
                for (0..breaks - 1) |_| try builder.byte('\n');
            }
        }
        self.advanceAscii(1);
        try self.append(.{ .kind = .scalar, .start = start, .end = self.at, .style = if (double) .double_quoted else .single_quoted, .value = try builder.ref() });
        self.json_last = true;
    }
    /// A new line inside a quoted scalar: not a document marker, and in a
    /// block collection indented past it by spaces.
    fn quotedLine(self: *Scanner) Error!void {
        if (self.documentIndicator("---") or self.documentIndicator("...")) return self.fail();
        var probe = self.at.index;
        var spaces: i64 = 0;
        while (probe < self.input.len and self.input[probe] == ' ') : (probe += 1) spaces += 1;
        while (probe < self.input.len and isBlank(self.input[probe])) probe += 1;
        if (probe >= self.input.len) return;
        const b = self.input[probe];
        if (b == '\n' or b == '\r') return;
        if (spaces <= self.indent) return self.fail();
    }
    fn escape(self: *Scanner, builder: *Builder) Error!void {
        const e = self.byteAt(1);
        const simple_escape: ?u8 = switch (e) {
            '0' => 0,
            'a' => 7,
            'b' => 8,
            't', '\t' => '\t',
            'n' => '\n',
            'v' => 11,
            'f' => 12,
            'r' => '\r',
            'e' => 0x1b,
            ' ' => ' ',
            '"' => '"',
            '/' => '/',
            '\\' => '\\',
            else => null,
        };
        if (simple_escape) |b| {
            try builder.byte(b);
            self.advanceAscii(2);
            return;
        }
        var cp: u21 = switch (e) {
            'N' => 0x85,
            '_' => 0xA0,
            'L' => 0x2028,
            'P' => 0x2029,
            else => 0,
        };
        if (cp != 0) {
            self.advanceAscii(2);
        } else {
            const width: u32 = switch (e) {
                'x' => 2,
                'u' => 4,
                'U' => 8,
                else => return self.fail(),
            };
            var v: u32 = 0;
            for (0..width) |i| {
                const d = std.fmt.charToDigit(self.byteAt(2 + i), 16) catch return self.fail();
                v = v << 4 | d;
            }
            if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return self.fail();
            cp = @intCast(v);
            self.advanceAscii(2 + width);
        }
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buffer) catch return self.fail();
        try builder.bytes(buffer[0..len]);
    }

    fn plainScalar(self: *Scanner) Error!void {
        try self.saveSimpleKey();
        self.simple_key_allowed = false;
        const start = self.at;
        var end = start;
        const indent: i64 = self.indent + 1;
        var builder: Builder = .init(self, self.at.index);
        var leading_blanks = false;
        var whitespace_start: u32 = 0;
        var breaks: usize = 0;
        var pending = false;
        while (true) {
            if (self.at.column == 0 and (self.documentIndicator("---") or self.documentIndicator("..."))) break;
            if (self.cur() == '#') break;
            var any = false;
            while (!self.isBlankzAt(0)) {
                const c = self.cur();
                if (c == ':') {
                    if (self.isBlankzAt(1)) break;
                    if (self.flow_level > 0 and isFlowIndicator(self.byteAt(1))) break;
                }
                if (self.flow_level > 0 and isFlowIndicator(c)) break;
                if (!self.printableAt()) return self.fail();
                if (pending) {
                    if (leading_blanks) {
                        if (breaks == 1) try builder.byte(' ') else for (0..breaks - 1) |_| try builder.byte('\n');
                    } else {
                        try builder.input(whitespace_start, self.at.index);
                    }
                    pending = false;
                    leading_blanks = false;
                }
                const from = self.at.index;
                self.advance();
                try builder.input(from, self.at.index);
                any = true;
            }
            if (any) end = self.at;
            if (self.eof() or !(isBlank(self.cur()) or self.isBreakAt(0))) break;
            // White space and line breaks.
            if (!pending) {
                whitespace_start = self.at.index;
                breaks = 0;
            }
            while (!self.eof() and (isBlank(self.cur()) or self.isBreakAt(0))) {
                if (isBlank(self.cur())) {
                    self.advanceAscii(1);
                } else {
                    breaks += 1;
                    leading_blanks = true;
                    self.advanceBreak();
                }
            }
            pending = true;
            if (leading_blanks and !self.eof() and self.cur() != '#') {
                // The next line: a line less indented than the scalar ends
                // it in a block, and the indentation is spaces alone.
                if (self.flow_level == 0 and self.at.column < indent) break;
                if (self.lineSpaces() < indent) return self.fail();
            }
        }
        try self.append(.{ .kind = .scalar, .start = start, .end = end, .style = .plain, .value = try builder.ref() });
        if (leading_blanks) {
            // The scalar left off at the start of a line.
            self.simple_key_allowed = true;
            self.prefix = .none;
        }
    }
};
