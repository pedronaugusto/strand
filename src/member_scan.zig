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

    /// Which of a repeated member is the answer. `last` by default, as for
    /// a reader that keeps the last of a duplicate field; `first` is a peek
    /// at a line in hand, which stops reading once it has one.
    which: enum { last, first } = .last,
    /// Under `first`, the name's value has been met: nothing more is read.
    done: bool = false,
    /// Whether the value is copied and checked for `finish`, or only placed
    /// for `finishSpan` by a caller that holds the bytes.
    copy: bool = true,

    /// A stretch of the bytes fed, counted from the first of them.
    pub const Span = struct { start: usize, end: usize };

    pub fn init(name: []const u8) MemberScan {
        return .{ .name = name };
    }

    pub fn feed(s: *MemberScan, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (s.done) {
                s.fed += bytes.len - i;
                return;
            }
            const skip = s.skippable(bytes[i..]);
            i += skip;
            s.fed += skip;
            if (i == bytes.len) return;
            s.byte(bytes[i]);
            s.fed += 1;
            i += 1;
        }
    }

    /// How many of `rest`'s leading bytes change nothing but `fed`, found a
    /// vector at a time: a string that is not the name's value up to its
    /// quote or escape, a key that is the name whole, and the inside of a
    /// nested value up to its next string or bracket.
    fn skippable(s: *MemberScan, rest: []const u8) usize {
        if (s.in_string) {
            if (s.escaped or s.in_value) return 0;
            if (s.in_key) {
                if (!s.key_same) return stringSpecial(rest).at;
                // The name and the quote after it, all in hand: compared at
                // once, and left on the quote that closes the key.
                if (s.key_len == 0 and rest.len > s.name.len) {
                    if (std.mem.eql(u8, rest[0..s.name.len], s.name) and rest[s.name.len] == '"') {
                        s.key_len = s.name.len;
                        return s.name.len;
                    }
                    s.key_same = false;
                    return stringSpecial(rest).at;
                }
                return 0;
            }
            return stringSpecial(rest).at;
        }
        if (s.depth > 1) return nextStructural(rest);
        // Another member's object or array, whole in hand: nothing in it
        // can be the name, and passing over it leaves every state as it was.
        if (s.depth == 1 and !s.value_next and rest.len != 0 and (rest[0] == '{' or rest[0] == '[')) {
            return closingAfter(rest) orelse 0;
        }
        return 0;
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
                // The name's value is an object or an array: not kept, and
                // under `first` the answer is that there is none.
                if (s.value_next and s.which == .first) s.done = true;
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
        if (s.copy and s.value_len < max_value_bytes) s.value[s.value_len] = b;
        s.value_len +|= 1;
    }

    /// A value ended just before `end`: placed, and kept when it fit and is
    /// one JSON scalar.
    fn endValue(s: *MemberScan, end: usize) void {
        if (!s.in_value) return;
        s.in_value = false;
        s.found_span = .{ .start = s.value_start, .end = end };
        if (s.which == .first) s.done = true;
        if (!s.copy) return;
        if (s.value_len > max_value_bytes) return;
        const value = s.value[0..s.value_len];
        if (!scalar(value)) return;
        @memcpy(s.found[0..value.len], value);
        s.found_len = @intCast(value.len);
    }
};

/// The index of the first byte of `bytes` that opens a string or opens or
/// closes an object or an array, or `bytes.len`: everything else inside a
/// nested value is passed over.
fn nextStructural(bytes: []const u8) usize {
    var i: usize = 0;
    if (!@inComptime()) if (std.simd.suggestVectorLength(u8)) |width| {
        const V = @Vector(width, u8);
        while (i + width <= bytes.len) : (i += width) {
            const v: V = bytes[i..][0..width].*;
            // `[` and `{`, and `]` and `}`, differ only in 0x20: set, an
            // opening bracket of either kind is one compare, and a closing
            // one another.
            const folded = v | @as(V, @splat(0x20));
            const hits = (v == @as(V, @splat('"'))) | (folded == @as(V, @splat('{'))) | (folded == @as(V, @splat('}')));
            if (@reduce(.Or, hits)) return i + std.simd.firstTrue(hits).?;
        }
    };
    while (i < bytes.len) : (i += 1) switch (bytes[i]) {
        '"', '{', '}', '[', ']' => return i,
        else => {},
    };
    return i;
}

/// The length of the object or array `bytes` opens with, up to and with its
/// closing bracket; `null` when it does not close in `bytes`. Not a check of
/// the value: brackets are counted outside strings, and that is all.
///
/// Sixty-four bytes at a time: a mask of the quotes, the strings they make
/// by a prefix XOR, and the brackets outside those, counted in order. A
/// block with a backslash in it, whose quotes may be escaped, is walked a
/// byte at a time.
fn closingAfter(bytes: []const u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    const V = @Vector(64, u8);
    while (i + 64 <= bytes.len) : (i += 64) {
        const block: V = bytes[i..][0..64].*;
        const slashes: u64 = @bitCast(block == @as(V, @splat('\\')));
        if (slashes != 0 or escaped) {
            for (bytes[i..][0..64], 0..) |b, at| {
                if (byteCloses(b, &depth, &in_string, &escaped)) return i + at + 1;
            }
            continue;
        }
        const quotes: u64 = @bitCast(block == @as(V, @splat('"')));
        var strings = prefixXor(quotes);
        if (in_string) strings = ~strings;
        in_string = strings >> 63 == 1;
        const folded = block | @as(V, @splat(0x20));
        const opens = @as(u64, @bitCast(folded == @as(V, @splat('{')))) & ~strings;
        const closes = @as(u64, @bitCast(folded == @as(V, @splat('}')))) & ~strings;
        var brackets = opens | closes;
        while (brackets != 0) : (brackets &= brackets - 1) {
            const bit: u6 = @intCast(@ctz(brackets));
            if (opens >> bit & 1 == 1) {
                depth += 1;
            } else {
                depth -= 1;
                if (depth == 0) return i + bit + 1;
            }
        }
    }
    for (bytes[i..], i..) |b, at| {
        if (byteCloses(b, &depth, &in_string, &escaped)) return at + 1;
    }
    return null;
}

/// `closingAfter` for one byte: whether it closes the outermost bracket.
inline fn byteCloses(b: u8, depth: *usize, in_string: *bool, escaped: *bool) bool {
    if (in_string.*) {
        if (escaped.*) {
            escaped.* = false;
        } else if (b == '\\') {
            escaped.* = true;
        } else if (b == '"') {
            in_string.* = false;
        }
        return false;
    }
    switch (b) {
        '"' => in_string.* = true,
        '{', '[' => depth.* += 1,
        '}', ']' => {
            depth.* -= 1;
            return depth.* == 0;
        },
        else => {},
    }
    return false;
}

/// Each bit set when an odd number of `bits` are set at or below it: the
/// bytes from an opening quote up to its closing one.
fn prefixXor(bits: u64) u64 {
    var x = bits;
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
}

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

test "a nested value is passed over to its own closing bracket, whatever is in its strings" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const pieces = [_][]const u8{ "{", "}", "[", "]", "\"a{b\"", "\"]\\\"[\"", "\"\\\\\"", "1", ",", ":", " ", "\"x\"", "\"" ++ "y" ** 70 ++ "\"" };
    var buffer: [2048]u8 = undefined;
    for (0..2000) |_| {
        var len: usize = 0;
        buffer[len] = '{';
        len += 1;
        for (0..random.uintLessThan(usize, 60)) |_| {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (len + piece.len > buffer.len) break;
            @memcpy(buffer[len..][0..piece.len], piece);
            len += piece.len;
        }
        const bytes = buffer[0..len];
        var depth: usize = 0;
        var in_string = false;
        var escaped = false;
        const want: ?usize = for (bytes, 0..) |b, at| {
            if (byteCloses(b, &depth, &in_string, &escaped)) break at + 1;
        } else null;
        try std.testing.expectEqual(want, closingAfter(bytes));
    }
}
