//! XML's tokens, read off a document's bytes one at a time and checked for
//! well-formedness as they are read: the declaration, the doctype (its
//! internal subset handed over whole, for `dtd.zig`), start and end tags
//! (each end matching its start, each attribute named once), character data,
//! CDATA sections, comments and processing instructions, every character one
//! XML allows. References stay as written in text and attribute values; what
//! they stand for is the document's to say, since its doctype may declare
//! them. Every typed read, `xml.Value` and `xml.Raw` reads through this; it
//! is public for a reader of a document too large to read whole.
//!
//! The input is UTF-8 with no byte-order mark (the caller takes one off, and
//! transcodes UTF-16 first). A scanner is made in place and not moved.
const std = @import("std");
const core = @import("../core.zig");
const text = @import("text.zig");

pub const Error = error{ SyntaxError, InvalidUtf8, DepthLimit, ItemLimit, LengthLimit, WorkLimit, AllocationLimit, OutOfMemory };

/// What is read: a document (a prolog, one root element, then only
/// comments, processing instructions and white space), or content (what an
/// element or an internal entity holds: elements balanced, no prolog).
pub const Mode = enum { document, content };

pub const Declaration = struct {
    version: []const u8,
    encoding: ?[]const u8,
    standalone: ?bool,
};
pub const Doctype = struct {
    name: []const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    /// The internal subset, between its brackets, unread.
    internal: ?[]const u8,
    /// Where the internal subset starts in the input.
    internal_at: usize,
};
pub const Start = struct {
    name: []const u8,
    /// The tag's attributes as written: read them with `attributes`.
    raw: []const u8,
    /// `<name/>`: an end follows at once, which `next` gives too.
    empty: bool,
    pub fn attributes(self: Start) Attributes {
        return .{ .raw = self.raw };
    }
};
pub const Attribute = struct {
    name: []const u8,
    /// The value between its quotes, references unexpanded and white space
    /// not yet normalized.
    value: []const u8,
};
/// A tag's attributes, which the scanner has checked as it read the tag.
pub const Attributes = struct {
    raw: []const u8,
    at: usize = 0,
    pub fn next(self: *Attributes) ?Attribute {
        while (self.at < self.raw.len and text.isSpace(self.raw[self.at])) self.at += 1;
        if (self.at == self.raw.len) return null;
        const name_start = self.at;
        while (self.raw[self.at] != '=' and !text.isSpace(self.raw[self.at])) self.at += 1;
        const name = self.raw[name_start..self.at];
        while (self.raw[self.at] != '"' and self.raw[self.at] != '\'') self.at += 1;
        const quote = self.raw[self.at];
        const value_start = self.at + 1;
        const value_end = std.mem.findScalarPos(u8, self.raw, value_start, quote).?;
        self.at = value_end + 1;
        return .{ .name = name, .value = self.raw[value_start..value_end] };
    }
};
pub const Pi = struct { target: []const u8, data: []const u8 };
pub const Token = union(enum) {
    declaration: Declaration,
    doctype: Doctype,
    start: Start,
    end: []const u8,
    /// Character data as written: references unexpanded, line ends as they
    /// are (a carriage return is the reader's to make a line feed).
    text: []const u8,
    cdata: []const u8,
    comment: []const u8,
    pi: Pi,
};

const Span32 = struct { start: u32, len: u32 };
const Place = enum { prolog, after_doctype, inside, epilog };

input: []const u8,
at: usize,
mode: Mode,
place: Place,
context: *core.Context,
/// The open elements' names, for each end tag to match.
open: std.ArrayList(Span32),
allocator: std.mem.Allocator,
/// An empty element's end, given after its start.
pending_end: ?[]const u8,
/// Where the input was found not well-formed.
failed_at: usize,
own_context: core.Context,
const Self = @This();

pub const Options = struct {
    limits: core.Limits = .{},
    mode: Mode = .document,
};

/// Starts a scanner over `input` for a reader of its tokens: its limits are
/// its own, the open elements held on `gpa`. Made in place, never moved.
pub fn init(self: *Self, gpa: std.mem.Allocator, input: []const u8, options: Options) void {
    self.own_context = .init(gpa, options.limits, .borrowed);
    self.start(&self.own_context, gpa, input, options.mode);
}
/// Starts a scanner charged to an operation's context.
pub fn start(self: *Self, c: *core.Context, allocator: std.mem.Allocator, input: []const u8, mode: Mode) void {
    self.input = input;
    self.at = 0;
    self.mode = mode;
    self.place = if (mode == .document) .prolog else .inside;
    self.context = c;
    self.open = .empty;
    self.allocator = allocator;
    self.pending_end = null;
    self.failed_at = 0;
}
pub fn deinit(self: *Self) void {
    self.open.deinit(self.allocator);
}
/// How deep in elements the scanner is.
pub fn depth(self: *const Self) usize {
    return self.open.items.len;
}

fn fail(self: *Self, at: usize) error{SyntaxError} {
    self.failed_at = at;
    return error.SyntaxError;
}
fn failUtf8(self: *Self, at: usize) error{InvalidUtf8} {
    self.failed_at = at;
    return error.InvalidUtf8;
}
fn startsWith(self: *const Self, at: usize, comptime s: []const u8) bool {
    return std.mem.startsWith(u8, self.input[at..], s);
}

/// The next token, or null at the end of the input, which is checked to end
/// where a document or content may.
pub fn next(self: *Self) Error!?Token {
    if (self.pending_end) |name| {
        self.pending_end = null;
        return .{ .end = name };
    }
    const input = self.input;
    if (self.at >= input.len) {
        if (self.open.items.len != 0) return self.fail(input.len);
        if (self.mode == .document and self.place != .epilog) return self.fail(input.len);
        return null;
    }
    if (input[self.at] != '<') return try self.charData();
    const at = self.at;
    if (at + 1 >= input.len) return self.fail(at);
    switch (input[at + 1]) {
        '/' => return try self.endTag(),
        '?' => return try self.instruction(),
        '!' => {
            if (self.startsWith(at, "<!--")) return try self.comment();
            if (self.startsWith(at, "<![CDATA[")) {
                if (self.place != .inside) return self.fail(at);
                return try self.cdata();
            }
            if (self.startsWith(at, "<!DOCTYPE")) {
                if (self.place != .prolog) return self.fail(at);
                return try self.doctype();
            }
            return self.fail(at);
        },
        else => return try self.startTag(),
    }
}

/// Checks that `bytes` (from `at`) holds only characters XML allows.
fn chars(self: *Self, bytes: []const u8, at: usize) Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b >= 0x20 and b < 0x80) {
            i += 1;
            continue;
        }
        if (b < 0x20) {
            if (b != '\t' and b != '\n' and b != '\r') return self.fail(at + i);
            i += 1;
            continue;
        }
        const d = text.decode(bytes, i) orelse return self.failUtf8(at + i);
        if (!text.isChar(d.c)) return self.fail(at + i);
        i += d.len;
    }
}
/// The name at `at`, checked; its end is the caller's to check.
fn nameAt(self: *Self, at: usize) Error![]const u8 {
    const n = text.nameLength(self.input[at..]) orelse return self.failUtf8(at);
    if (n == 0) return self.fail(at);
    try self.context.span(n, true);
    return self.input[at..][0..n];
}
fn spaces(self: *Self, at: usize) usize {
    var i = at;
    while (i < self.input.len and text.isSpace(self.input[i])) i += 1;
    return i;
}
/// Checks a reference at `at` (`&name;`, `&#n;`, `&#xh;`), returning its end.
fn reference(self: *Self, at: usize) Error!usize {
    const input = self.input;
    var i = at + 1;
    if (i < input.len and input[i] == '#') {
        i += 1;
        const hex = i < input.len and input[i] == 'x';
        if (hex) i += 1;
        const digits_start = i;
        var value: u32 = 0;
        while (i < input.len and input[i] != ';') : (i += 1) {
            const d = std.fmt.charToDigit(input[i], if (hex) 16 else 10) catch return self.fail(i);
            value = value * (if (hex) @as(u32, 16) else 10) + d;
            if (value > 0x10FFFF) return self.fail(at);
        }
        if (i == digits_start or i >= input.len) return self.fail(at);
        if (!text.isChar(@intCast(value))) return self.fail(at);
        return i + 1;
    }
    const n = try self.nameAt(i);
    i += n.len;
    if (i >= input.len or input[i] != ';') return self.fail(i);
    return i + 1;
}

fn charData(self: *Self) Error!Token {
    const input = self.input;
    const start_at = self.at;
    const end = std.mem.findScalarPos(u8, input, start_at, '<') orelse input.len;
    const bytes = input[start_at..end];
    if (self.place != .inside) {
        // Outside the root: white space only.
        if (!text.allSpace(bytes)) return self.fail(start_at + (std.mem.findNone(u8, bytes, " \t\r\n") orelse 0));
    } else {
        try self.chars(bytes, start_at);
        var i: usize = 0;
        while (std.mem.findAnyPos(u8, bytes, i, "&]")) |k| {
            if (bytes[k] == '&') {
                i = try self.reference(start_at + k) - start_at;
                if (i > bytes.len) return self.fail(start_at + k);
            } else {
                if (std.mem.startsWith(u8, bytes[k..], "]]>")) return self.fail(start_at + k);
                i = k + 1;
            }
        }
    }
    try self.context.chargeWork(bytes.len);
    self.at = end;
    return .{ .text = bytes };
}

fn startTag(self: *Self) Error!Token {
    const input = self.input;
    const at = self.at;
    if (self.place == .epilog or (self.place != .inside and self.mode == .content)) return self.fail(at);
    const tag_name = try self.nameAt(at + 1);
    var i = at + 1 + tag_name.len;
    const raw_start = i;
    var count: usize = 0;
    while (true) {
        const before = i;
        i = self.spaces(i);
        if (i >= input.len) return self.fail(i);
        if (input[i] == '>' or input[i] == '/') break;
        if (i == before) return self.fail(i);
        const attribute_name = try self.nameAt(i);
        i += attribute_name.len;
        i = self.spaces(i);
        if (i >= input.len or input[i] != '=') return self.fail(i);
        i = self.spaces(i + 1);
        if (i >= input.len or (input[i] != '"' and input[i] != '\'')) return self.fail(i);
        const quote = input[i];
        const value_start = i + 1;
        const value_end = std.mem.findScalarPos(u8, input, value_start, quote) orelse return self.fail(i);
        const value = input[value_start..value_end];
        try self.attributeValue(value, value_start);
        // Each attribute named once: compared with those before it.
        var others: Attributes = .{ .raw = input[raw_start..before] };
        while (others.next()) |other| {
            try self.context.chargeWork(other.name.len + 1);
            if (std.mem.eql(u8, other.name, attribute_name)) return self.fail(i - attribute_name.len);
        }
        count += 1;
        if (count > self.context.limits.container_items) return error.ItemLimit;
        i = value_end + 1;
    }
    const raw = input[raw_start..i];
    var empty = false;
    if (input[i] == '/') {
        if (i + 1 >= input.len or input[i + 1] != '>') return self.fail(i);
        empty = true;
        i += 1;
    }
    try self.context.chargeWork(i + 1 - at);
    self.at = i + 1;
    if (self.place != .inside) self.place = .inside;
    if (empty) {
        self.pending_end = tag_name;
        if (self.open.items.len == 0 and self.mode == .document) self.place = .epilog;
    } else {
        if (self.open.items.len >= self.context.limits.depth) return error.DepthLimit;
        try self.open.append(self.allocator, .{ .start = @intCast(at + 1), .len = @intCast(tag_name.len) });
    }
    return .{ .start = .{ .name = tag_name, .raw = raw, .empty = empty } };
}
fn attributeValue(self: *Self, value: []const u8, at: usize) Error!void {
    try self.chars(value, at);
    var i: usize = 0;
    while (std.mem.findAnyPos(u8, value, i, "&<")) |k| {
        if (value[k] == '<') return self.fail(at + k);
        const end = try self.reference(at + k) - at;
        if (end > value.len) return self.fail(at + k);
        i = end;
    }
}

fn endTag(self: *Self) Error!Token {
    const input = self.input;
    const at = self.at;
    if (self.open.items.len == 0) return self.fail(at);
    const tag_name = try self.nameAt(at + 2);
    const i = self.spaces(at + 2 + tag_name.len);
    if (i >= input.len or input[i] != '>') return self.fail(i);
    const top = self.open.pop().?;
    if (!std.mem.eql(u8, tag_name, input[top.start..][0..top.len])) return self.fail(at);
    try self.context.chargeWork(i + 1 - at);
    self.at = i + 1;
    if (self.open.items.len == 0 and self.mode == .document) self.place = .epilog;
    return .{ .end = tag_name };
}

fn comment(self: *Self) Error!Token {
    const at = self.at;
    const body_start = at + 4;
    const end = std.mem.findPos(u8, self.input, body_start, "--") orelse return self.fail(at);
    if (end + 2 >= self.input.len or self.input[end + 2] != '>') return self.fail(end);
    const body = self.input[body_start..end];
    try self.chars(body, body_start);
    try self.context.chargeWork(end + 3 - at);
    self.at = end + 3;
    return .{ .comment = body };
}

fn cdata(self: *Self) Error!Token {
    const at = self.at;
    const body_start = at + 9;
    const end = std.mem.findPos(u8, self.input, body_start, "]]>") orelse return self.fail(at);
    const body = self.input[body_start..end];
    try self.chars(body, body_start);
    try self.context.chargeWork(end + 3 - at);
    self.at = end + 3;
    return .{ .cdata = body };
}

fn instruction(self: *Self) Error!Token {
    const input = self.input;
    const at = self.at;
    const target = try self.nameAt(at + 2);
    var i = at + 2 + target.len;
    const is_xml = std.ascii.eqlIgnoreCase(target, "xml");
    if (is_xml) {
        if (at != 0 or self.mode != .document or !std.mem.eql(u8, target, "xml")) return self.fail(at);
        return try self.declaration(i);
    }
    const end = std.mem.findPos(u8, input, i, "?>") orelse return self.fail(at);
    var data: []const u8 = "";
    if (end != i) {
        if (!text.isSpace(input[i])) return self.fail(i);
        i = self.spaces(i);
        data = input[@min(i, end)..end];
        try self.chars(data, i);
    }
    try self.context.chargeWork(end + 2 - at);
    self.at = end + 2;
    return .{ .pi = .{ .target = target, .data = data } };
}

/// One pseudo-attribute of the declaration: ` name="value"`.
fn pseudo(self: *Self, at: usize, comptime label: []const u8) Error!?struct { value: []const u8, end: usize } {
    const input = self.input;
    const i = self.spaces(at);
    if (i == at or !self.startsWith(i, label)) return null;
    var k = self.spaces(i + label.len);
    if (k >= input.len or input[k] != '=') return self.fail(k);
    k = self.spaces(k + 1);
    if (k >= input.len or (input[k] != '"' and input[k] != '\'')) return self.fail(k);
    const close = std.mem.findScalarPos(u8, input, k + 1, input[k]) orelse return self.fail(k);
    return .{ .value = input[k + 1 .. close], .end = close + 1 };
}
fn declaration(self: *Self, after_target: usize) Error!Token {
    var i = after_target;
    const version = (try self.pseudo(i, "version")) orelse return self.fail(i);
    // `1.` and digits: a 1.x document is read as 1.0, as the fifth edition asks.
    const v = version.value;
    if (v.len < 3 or !std.mem.startsWith(u8, v, "1.")) return self.fail(i);
    for (v[2..]) |b| if (!std.ascii.isDigit(b)) return self.fail(i);
    i = version.end;
    var encoding: ?[]const u8 = null;
    if (try self.pseudo(i, "encoding")) |e| {
        const name_ = e.value;
        if (name_.len == 0 or !std.ascii.isAlphabetic(name_[0])) return self.fail(i);
        for (name_) |b| if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '_' or b == '-')) return self.fail(i);
        encoding = name_;
        i = e.end;
    }
    var standalone: ?bool = null;
    if (try self.pseudo(i, "standalone")) |s| {
        if (std.mem.eql(u8, s.value, "yes")) standalone = true else if (std.mem.eql(u8, s.value, "no")) standalone = false else return self.fail(i);
        i = s.end;
    }
    i = self.spaces(i);
    if (!self.startsWith(i, "?>")) return self.fail(i);
    try self.context.chargeWork(i + 2);
    self.at = i + 2;
    return .{ .declaration = .{ .version = v, .encoding = encoding, .standalone = standalone } };
}

/// A quoted literal at `at`: its contents and the position after it.
fn literal(self: *Self, at: usize) Error!struct { value: []const u8, end: usize } {
    const input = self.input;
    if (at >= input.len or (input[at] != '"' and input[at] != '\'')) return self.fail(at);
    const close = std.mem.findScalarPos(u8, input, at + 1, input[at]) orelse return self.fail(at);
    try self.chars(input[at + 1 .. close], at + 1);
    return .{ .value = input[at + 1 .. close], .end = close + 1 };
}
pub fn isPubidChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or std.mem.findScalar(u8, " \r\n-'()+,./:=?;!*#@$_%", b) != null;
}
fn doctype(self: *Self) Error!Token {
    const input = self.input;
    const at = self.at;
    var i = at + 9;
    if (i >= input.len or !text.isSpace(input[i])) return self.fail(i);
    i = self.spaces(i);
    const root = try self.nameAt(i);
    i += root.len;
    var public_id: ?[]const u8 = null;
    var system_id: ?[]const u8 = null;
    const after_name = i;
    i = self.spaces(i);
    if (i != after_name and (self.startsWith(i, "SYSTEM") or self.startsWith(i, "PUBLIC"))) {
        const public = self.startsWith(i, "PUBLIC");
        i += 6;
        if (i >= input.len or !text.isSpace(input[i])) return self.fail(i);
        i = self.spaces(i);
        if (public) {
            const p = try self.literal(i);
            for (p.value) |b| if (!isPubidChar(b)) return self.fail(i);
            public_id = p.value;
            i = p.end;
            if (i >= input.len or !text.isSpace(input[i])) return self.fail(i);
            i = self.spaces(i);
        }
        const s = try self.literal(i);
        system_id = s.value;
        i = self.spaces(s.end);
    }
    var internal: ?[]const u8 = null;
    var internal_at: usize = 0;
    if (i < input.len and input[i] == '[') {
        internal_at = i + 1;
        const end = try self.subsetEnd(internal_at);
        internal = input[internal_at..end];
        i = self.spaces(end + 1);
    }
    if (i >= input.len or input[i] != '>') return self.fail(i);
    try self.context.chargeWork(i + 1 - at);
    self.at = i + 1;
    self.place = .after_doctype;
    return .{ .doctype = .{ .name = root, .public_id = public_id, .system_id = system_id, .internal = internal, .internal_at = internal_at } };
}
/// Where the internal subset starting at `at` ends (its `]`): found past its
/// declarations' literals, comments and processing instructions, which may
/// hold one. Its grammar is `dtd.zig`'s to check.
fn subsetEnd(self: *Self, at: usize) Error!usize {
    const input = self.input;
    var i = at;
    while (i < input.len) {
        switch (input[i]) {
            ']' => return i,
            '<' => {
                if (self.startsWith(i, "<!--")) {
                    i = (std.mem.findPos(u8, input, i + 4, "-->") orelse return self.fail(i)) + 3;
                } else if (self.startsWith(i, "<?")) {
                    i = (std.mem.findPos(u8, input, i + 2, "?>") orelse return self.fail(i)) + 2;
                } else {
                    // A declaration: to its `>`, past its quoted literals.
                    i += 1;
                    while (i < input.len and input[i] != '>') {
                        if (input[i] == '"' or input[i] == '\'') {
                            i = (std.mem.findScalarPos(u8, input, i + 1, input[i]) orelse return self.fail(i)) + 1;
                        } else i += 1;
                    }
                    if (i >= input.len) return self.fail(at);
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
    return self.fail(at);
}

test "tokens of a small document" {
    var s: Self = undefined;
    s.init(std.testing.allocator, "<?xml version=\"1.0\"?>\n<a x='1' y=\"&amp;\"><b/>t&#65;<![CDATA[<]]><!--c--><?p d?></a>\n", .{});
    defer s.deinit();
    try std.testing.expectEqualStrings("1.0", (try s.next()).?.declaration.version);
    try std.testing.expectEqualStrings("\n", (try s.next()).?.text);
    const a = (try s.next()).?.start;
    try std.testing.expectEqualStrings("a", a.name);
    var attributes = a.attributes();
    try std.testing.expectEqualStrings("x", attributes.next().?.name);
    try std.testing.expectEqualStrings("&amp;", attributes.next().?.value);
    try std.testing.expectEqual(null, attributes.next());
    try std.testing.expect((try s.next()).?.start.empty);
    try std.testing.expectEqualStrings("b", (try s.next()).?.end);
    try std.testing.expectEqualStrings("t&#65;", (try s.next()).?.text);
    try std.testing.expectEqualStrings("<", (try s.next()).?.cdata);
    try std.testing.expectEqualStrings("c", (try s.next()).?.comment);
    try std.testing.expectEqualStrings("p", (try s.next()).?.pi.target);
    try std.testing.expectEqualStrings("a", (try s.next()).?.end);
    try std.testing.expectEqualStrings("\n", (try s.next()).?.text);
    try std.testing.expectEqual(null, try s.next());
}

test "what is not well-formed is refused" {
    const bad = [_][]const u8{
        "<a></b>",                   "<a>",                        "<a x='1' x='2'/>", "<a/><b/>",           "text<a/>",    "<a>]]></a>",
        "<a>&#0;</a>",               "<a>&;</a>",                  "<a x='<'/>",       "<a><!-- -- --></a>", "<a>\x01</a>", "",
        "<?xml version='2.0'?><a/>", " <?xml version='1.0'?><a/>", "<a/><!DOCTYPE a>", "<a x=1/>",
    };
    for (bad) |input| {
        var s: Self = undefined;
        s.init(std.testing.allocator, input, .{});
        defer s.deinit();
        const result = while (true) {
            const token = s.next() catch |err| break err;
            if (token == null) break error.Accepted;
        };
        std.testing.expect(result == error.SyntaxError) catch |err| {
            std.debug.print("accepted or wrong error for {s}: {}\n", .{ input, result });
            return err;
        };
    }
}
