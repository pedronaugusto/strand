//! What kind of line this is, read from its first key or from a member
//! named for it, without parsing it.
const std = @import("std");
const member_scan = @import("member_scan.zig");
const strings = @import("text.zig");
const descriptor = @import("../core/descriptor.zig");

/// The first key of the object on `line`, or `null` when there is not one to
/// read cheaply.
///
/// This is the "what kind of line is this" question, answered without parsing
/// the value: a dispatcher can compare the result against the kinds it knows
/// and only then parse into the matching type. It scans the first few bytes
/// and allocates nothing.
///
/// Ownership: the result points into `line`.
///
/// `null` means: not an object, an object with no keys, or a first key
/// containing a `\` escape, which this function does not decode (`json.parseLeaky`
/// decodes it correctly; this is a peek, not a parser). The rest of the line
/// is not looked at, so a `kindOf` that answers is not a claim that the line
/// is valid JSON.
pub fn kindOf(line: []const u8) ?[]const u8 {
    var i = skipSpace(line, 0);
    if (i == line.len or line[i] != '{') return null;
    i = skipSpace(line, i + 1);
    if (i == line.len or line[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '\\' => return null,
        '"' => {
            const key = line[start..i];
            // A string this early can only be a key, and a key is followed by
            // a colon; anything else means the line is not shaped as assumed.
            const after = skipSpace(line, i + 1);
            if (after == line.len or line[after] != ':') return null;
            return key;
        },
        else => {},
    };
    return null;
}

/// The index of the first byte at or after `i` that is not JSON whitespace.
fn skipSpace(bytes: []const u8, i: usize) usize {
    var j = i;
    while (j < bytes.len) : (j += 1) switch (bytes[j]) {
        ' ', '\t', '\r', '\n' => {},
        else => return j,
    };
    return j;
}

test kindOf {
    try std.testing.expectEqualStrings("kind", kindOf("{\"kind\":\"open\",\"at\":17}").?);
    try std.testing.expectEqualStrings("at", kindOf("  { \"at\" : 17 }").?);
    try std.testing.expectEqual(@as(?[]const u8, null), kindOf("[1,2,3]"));
    try std.testing.expectEqual(@as(?[]const u8, null), kindOf("{}"));
}

/// The value of the member `name` of the object on `line`, as its bytes:
/// a string with its quotes and escapes as written, a number, `true`,
/// `false` or `null`. `null` when there is not one to read cheaply.
///
/// This is `kindOf` for a line whose kind is in a member rather than in its
/// first key — `{"type":"assistant",...}` — wherever in the object the
/// member is. It reads the line once, a vector at a time through strings
/// it is not looking for, and allocates nothing.
///
/// Ownership: the result points into `line`.
///
/// The member is one of the outermost object's own, matched by its name as
/// written: a key spelled with a `\` escape is not decoded, as `kindOf`
/// does not decode one. When the name is there more than once, the first
/// is the answer, and nothing after it is read: a parse refuses the line
/// anyway, or keeps the one its `duplicate_fields` says. `null` means: not
/// an object, no such member, or a member whose value is an object or an
/// array, which is not something to route on. Only the value is checked,
/// so an answer is not a claim that the line is valid JSON.
pub fn memberOf(line: []const u8, name: []const u8) ?[]const u8 {
    var scan: member_scan.MemberScan = .init(name);
    scan.which = .first;
    scan.copy = false;
    scan.feed(line);
    const span = scan.finishSpan() orelse return null;
    const value = line[span.start..span.end];
    if (!scalar(value)) return null;
    return value;
}

/// Whether `value`, which `MemberScan` found to run from a value's first
/// byte to where it ended, is one JSON scalar. A string with no escape is
/// one when it holds no raw control byte and is UTF-8, which is a vector
/// at a time; anything else is asked of `std.json`.
fn scalar(value: []const u8) bool {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        const text = value[1 .. value.len - 1];
        const special = strings.special(text);
        if (special.at == text.len) return !special.non_ascii or std.unicode.utf8ValidateSlice(text);
    }
    return member_scan.scalar(value);
}

/// The member `name` of the object on `line` as the text of its string:
/// `memberOf` without the quotes. `null` for anything `memberOf` answers
/// `null` for, for a value that is not a string, and for a string written
/// with a `\` escape, which this does not decode (`json.parseLeaky` does).
///
/// Ownership: the result points into `line`.
pub fn memberStringOf(line: []const u8, name: []const u8) ?[]const u8 {
    const value = memberOf(line, name) orelse return null;
    if (value[0] != '"') return null;
    const text = value[1 .. value.len - 1];
    if (std.mem.findScalar(u8, text, '\\') != null) return null;
    return text;
}

/// The arm of the tagged union `U` that `line` names, or `null`.
///
/// A union is written as a one-key object whose key is the active arm,
/// `{"open":{...}}`, so the first key is the arm, and reading it is enough to
/// route a line without parsing its payload. A union whose `strand`
/// declaration names a `tag` member is written with the arm's name in that
/// member, `{"type":"open",...}`, and its arm is the string there, read as
/// `memberStringOf` reads it. Names are the arms' as the declaration spells
/// them, aliases included. A name that is no arm's is the `other` arm, when
/// the union declares one, as a parse takes it.
///
/// `null` means the line is not shaped that way, its key or tag is escaped
/// (see `kindOf`), or the name is no arm's and there is no `other` to take it.
pub fn tagOf(comptime U: type, line: []const u8) ?std.meta.Tag(U) {
    comptime {
        const info = @typeInfo(U);
        if (info != .@"union" or info.@"union".tag_type == null) {
            @compileError("tagOf expects a tagged union, got " ++ @typeName(U));
        }
    }
    const opt = comptime descriptor.options(U);
    const name = if (comptime @hasField(@TypeOf(opt), "tag")) memberStringOf(line, opt.tag) else kindOf(line);
    const found = name orelse return null;
    inline for (@typeInfo(U).@"union".field_names) |arm| {
        const v = comptime descriptor.variant(U, arm);
        if (std.mem.eql(u8, found, v.name)) return @field(std.meta.Tag(U), arm);
        inline for (v.aliases) |alias| if (std.mem.eql(u8, found, alias)) return @field(std.meta.Tag(U), arm);
    }
    if (comptime @hasField(@TypeOf(opt), "other")) return @field(std.meta.Tag(U), opt.other);
    return null;
}

test memberOf {
    const line = "{\"session\":{\"type\":\"inner\"},\"type\":\"assistant\",\"n\":17,\"s\":\"a\\\"b\"}";
    try std.testing.expectEqualStrings("\"assistant\"", memberOf(line, "type").?);
    try std.testing.expectEqualStrings("17", memberOf(line, "n").?);
    try std.testing.expectEqualStrings("\"a\\\"b\"", memberOf(line, "s").?);
    try std.testing.expectEqual(@as(?[]const u8, null), memberOf(line, "session"));
    try std.testing.expectEqual(@as(?[]const u8, null), memberOf(line, "missing"));
    try std.testing.expectEqual(@as(?[]const u8, null), memberOf("[{\"type\":1}]", "type"));
    try std.testing.expectEqualStrings("assistant", memberStringOf(line, "type").?);
    try std.testing.expectEqual(@as(?[]const u8, null), memberStringOf(line, "n"));
    try std.testing.expectEqual(@as(?[]const u8, null), memberStringOf(line, "s"));
}

test tagOf {
    const Message = union(enum) {
        open: struct { path: []const u8 },
        close: struct { code: u8 },
    };

    try std.testing.expectEqual(.open, tagOf(Message, "{\"open\":{\"path\":\"/tmp\"}}").?);
    try std.testing.expectEqual(.close, tagOf(Message, "{\"close\":{\"code\":0}}").?);
    try std.testing.expectEqual(@as(?std.meta.Tag(Message), null), tagOf(Message, "{\"other\":1}"));
}
