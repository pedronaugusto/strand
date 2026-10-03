//! One top-level member of a JSON object, found by name in bytes that go by
//! once and are not kept: what `LineReader` holds on to of a line too long
//! to hold, and where `memberOf` finds a member of a line it has whole.

const std = @import("std");
const stringSpecial = @import("scanner.zig").stringSpecial;

/// The longest value kept, in bytes. A member whose value is longer is not
/// kept, and nor is one whose value is an object or an array: what is wanted
/// from a line nobody read is a name for it — a request's id, a record's
/// kind — and those are short scalars.
pub const max_value_bytes = 128;

/// Fed a line's bytes in order, a chunk at a time, and asked once at the end.
///
/// The member is one of the outermost object's own: a member of the same name
/// inside a nested object or array is not it, and nor is a string that only
/// reads as the name once its escapes are decoded — the key is matched as it
/// is written, which is how every writer writes a plain name. When a line
/// has the member more than once, the last one is the answer, as it is for a
/// reader that keeps the last of a duplicate field. The value is kept as its
/// bytes, and only when they are one JSON scalar — a string, a number,
/// `true`, `false` or `null` — of at most `max_value_bytes`; nothing that
/// would make a line no reader takes back is handed on.
pub const MemberScan = struct {
    name: []const u8,
    depth: u32 = 0,
    /// The outermost value is an object, so a string at depth 1 after `{`
    /// or `,` is a key.
    object: bool = false,
    in_string: bool = false,
    escaped: bool = false,
    expect_key: bool = false,
    in_key: bool = false,
    key_len: usize = 0,
    key_same: bool = true,
    /// The key just read is the name; its value follows the colon.
    named: bool = false,
    value_next: bool = false,
    in_value: bool = false,
    value: [max_value_bytes]u8 = undefined,
    value_len: usize = 0,
    found: [max_value_bytes]u8 = undefined,
    found_len: ?u8 = null,
    /// Bytes fed so far: where the byte being looked at is.
    fed: usize = 0,
    /// Where the value being read began, counted as `fed` counts.
    value_start: usize = 0,
    /// Where the last value of the name began and ended, whatever its
    /// length, or `null` when it had none: `span` and `finishSpan`.
    found_span: ?Span = null,

    /// A stretch of the bytes fed, counted from the first of them.
    pub const Span = struct { start: usize, end: usize };

    pub fn init(name: []const u8) MemberScan {
        return .{ .name = name };
    }

    pub fn feed(s: *MemberScan, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (s.in_string and !s.in_key and !s.in_value and !s.escaped) {
                // A string that is neither a key nor the value: only where
                // it ends matters, and that is found a vector at a time.
                const at = stringSpecial(bytes[i..]).at;
                i += at;
                s.fed += at;
                if (i == bytes.len) return;
            }
            s.byte(bytes[i]);
            s.fed += 1;
            i += 1;
        }
    }

    /// The member's value as its bytes, borrowed from `s`, after the last
    /// byte of the line has been fed; `null` when the line had none that
    /// could be kept.
    pub fn finish(s: *MemberScan) ?[]const u8 {
        s.endValue(s.fed);
        const len = s.found_len orelse return null;
        return s.found[0..len];
    }

    /// Where the member's value lies in the bytes fed, after the last of
    /// them, whatever its length; `null` when the line had none, or when
    /// the last of the name's values is an object or an array. Not checked
    /// to be one JSON scalar: the caller holding the bytes does that.
    pub fn finishSpan(s: *MemberScan) ?Span {
        s.endValue(s.fed);
        return s.found_span;
    }

    fn byte(s: *MemberScan, b: u8) void {
        if (s.in_string) return s.stringByte(b);
        switch (b) {
            '"' => {
                s.in_string = true;
                if (s.depth == 1 and s.object and s.expect_key) {
                    s.expect_key = false;
                    s.in_key = true;
                    s.key_len = 0;
                    s.key_same = true;
                } else if (s.value_next) {
                    s.startValue(b);
                }
            },
            '{', '[' => {
                s.value_next = false;
                s.endValue(s.fed);
                s.depth +|= 1;
                if (s.depth == 1) s.object = b == '{';
                s.expect_key = s.depth == 1 and s.object;
            },
            '}', ']' => {
                s.endValue(s.fed);
                s.depth -|= 1;
            },
            ',' => {
                s.endValue(s.fed);
                s.expect_key = s.depth == 1 and s.object;
            },
            ':' => if (s.depth == 1 and s.named) {
                s.named = false;
                s.value_next = true;
                // The last member of the name is the answer, whatever it is.
                s.found_len = null;
                s.found_span = null;
            },
            ' ', '\t', '\r', '\n' => s.endValue(s.fed),
            else => if (s.value_next) s.startValue(b) else if (s.in_value) s.keep(b),
        }
    }

    fn stringByte(s: *MemberScan, b: u8) void {
        const closes = !s.escaped and b == '"';
        s.escaped = !s.escaped and b == '\\';
        if (s.in_key) {
            if (closes) {
                s.in_key = false;
                s.in_string = false;
                s.named = s.key_same and s.key_len == s.name.len;
            } else {
                if (s.key_len >= s.name.len or s.name[s.key_len] != b) s.key_same = false;
                s.key_len +|= 1;
            }
            return;
        }
        if (s.in_value) s.keep(b);
        if (closes) {
            s.in_string = false;
            s.endValue(s.fed + 1);
        }
    }

    fn startValue(s: *MemberScan, b: u8) void {
        s.value_next = false;
        s.in_value = true;
        s.value_len = 0;
        s.value_start = s.fed;
        s.keep(b);
    }

    fn keep(s: *MemberScan, b: u8) void {
        if (s.value_len < max_value_bytes) s.value[s.value_len] = b;
        s.value_len +|= 1;
    }

    /// A value ended just before `end`: placed, and kept when it fit and is
    /// one JSON scalar.
    fn endValue(s: *MemberScan, end: usize) void {
        if (!s.in_value) return;
        s.in_value = false;
        s.found_span = .{ .start = s.value_start, .end = end };
        if (s.value_len > max_value_bytes) return;
        const value = s.value[0..s.value_len];
        if (!scalar(value)) return;
        @memcpy(s.found[0..value.len], value);
        s.found_len = @intCast(value.len);
    }
};

/// Whether `bytes` are one JSON value with no structure in it. A scalar
/// nests nothing, so the check allocates nothing, and an allocator with no
/// room is enough: a value that asks for any is not a scalar.
pub fn scalar(bytes: []const u8) bool {
    var none: [0]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&none);
    return std.json.validate(fixed.allocator(), bytes) catch false;
}

fn expectFound(expected: ?[]const u8, name: []const u8, line: []const u8) !void {
    var s: MemberScan = .init(name);
    s.feed(line);
    const got = s.finish();
    if (expected) |e| {
        try std.testing.expectEqualStrings(e, got orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), got);
    }
}

test MemberScan {
    const pad = "x" ** 200;
    // Wherever the member sits, and whatever is around it.
    try expectFound("1", "id", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try expectFound("\"a\\\"b\"", "id", "{\"method\":\"tools/call\",\"params\":{\"id\":99,\"s\":\"" ++ pad ++ "\"},\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\"}");
    try expectFound("-12", "id", "{\"i\\\"d\":3,\"s\":\"" ++ pad ++ "\",\"id\" : -12 }");
    try expectFound("null", "id", "{\"id\":null}");
    try expectFound("true", "kind", "{ \"kind\"\t:\ttrue\r}");
    try expectFound("2.5e3", "id", "{\"id\":2.5e3}");
    // Only the outermost object's own member.
    try expectFound(null, "id", "{\"method\":\"n\",\"params\":{\"id\":5,\"s\":\"" ++ pad ++ "\"}}");
    try expectFound(null, "id", "[{\"id\":1}]");
    try expectFound(null, "id", "[1,\"id\":2]");
    try expectFound(null, "id", "{\"list\":[\"id\",{\"id\":4}]}");
    // A name as a value, or as a prefix of a longer key, is not the key.
    try expectFound(null, "id", "{\"s\":\"id\",\"ids\":1,\"i\":2}");
    try expectFound(null, "id", "{\"s\":\"x\",\"\\u0069d\":1}");
    // Structured, too long, or not a value at all: nothing kept.
    try expectFound(null, "id", "{\"id\":{\"n\":1}}");
    try expectFound(null, "id", "{\"id\":[1]}");
    try expectFound(null, "id", "{\"id\":\"" ++ "y" ** max_value_bytes ++ "\"}");
    try expectFound("\"" ++ "y" ** (max_value_bytes - 2) ++ "\"", "id", "{\"id\":\"" ++ "y" ** (max_value_bytes - 2) ++ "\"}");
    try expectFound(null, "id", "{\"id\":abc}");
    try expectFound(null, "id", "{\"id\":01}");
    try expectFound(null, "id", "{\"id\":\"bad\x01\"}");
    try expectFound(null, "id", "{\"id\":\"unclosed");
    // The last of a duplicate decides, even when it cannot be kept.
    try expectFound("2", "id", "{\"id\":1,\"id\":2}");
    try expectFound(null, "id", "{\"id\":1,\"id\":{}}");
    // A line cut short keeps what it reached.
    try expectFound("7", "id", "{\"id\":7,\"params\":{\"s\":\"xxxx");
    try expectFound("7", "id", "{\"id\":7");
}

test "a member split across chunks is the same member" {
    const line = "{\"params\":{\"id\":1},\"id\":\"call-42\",\"tail\":\"zz\"}";
    for (1..line.len) |cut| {
        var s: MemberScan = .init("id");
        s.feed(line[0..cut]);
        s.feed(line[cut..]);
        try std.testing.expectEqualStrings("\"call-42\"", s.finish().?);
    }
}
