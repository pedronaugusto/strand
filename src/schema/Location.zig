//! A JSON Pointer (RFC 6901): where in an instance or a schema a result
//! belongs. `Location` is the path an evaluation builds as it descends, a
//! bounded stack of steps written as a pointer; `tokens` reads a pointer
//! written in a schema (a `$ref` fragment).
const Location = @This();
const std = @import("std");
const aegis = @import("aegis");

/// One step: a member's name, borrowed from the document, or an item's
/// position.
pub const Step = union(enum) { name: []const u8, index: usize };

pub const max_steps = 256;

steps: aegis.bounded.Array(Step, max_steps) = .init,

/// Descend one step; `error.TooDeep` past `max_steps`.
pub fn push(l: *Location, step: Step) error{TooDeep}!void {
    var s = step;
    l.steps.append(&s) catch return error.TooDeep;
}

/// Back up one step.
pub fn pop(l: *Location) void {
    var last: Step = undefined;
    l.steps.pop(&last) catch aegis.assert.never("a step is popped only after one is pushed");
}

/// The pointer: `` for the whole document, `/a/0/b~1c` for a step under it.
pub fn format(l: Location, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (l.steps.constItems()) |step| {
        try w.writeByte('/');
        switch (step) {
            .name => |n| try writeToken(w, n),
            .index => |i| try w.print("{d}", .{i}),
        }
    }
}

/// A reference token, `~` written `~0` and `/` written `~1`.
pub fn writeToken(w: *std.Io.Writer, token: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (token, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '~' => "~0",
            '/' => "~1",
            else => null,
        };
        if (escape) |e| {
            try w.writeAll(token[start..i]);
            try w.writeAll(e);
            start = i + 1;
        }
    }
    try w.writeAll(token[start..]);
}

pub const PointerError = error{
    /// Not empty and not beginning with `/`, or a `~` not followed by `0` or `1`.
    InvalidPointer,
};

/// The reference tokens of `pointer`, each unescaped into the iterator's
/// buffer as it is read.
pub fn tokens(pointer: []const u8) PointerError!Tokens {
    if (pointer.len != 0 and pointer[0] != '/') return error.InvalidPointer;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, pointer, i, '~')) |t| : (i = t + 1) {
        if (t + 1 >= pointer.len or (pointer[t + 1] != '0' and pointer[t + 1] != '1')) return error.InvalidPointer;
    }
    return .{ .rest = if (pointer.len == 0) null else pointer[1..] };
}

pub const Tokens = struct {
    rest: ?[]const u8,

    /// The next token unescaped into `buffer`, which must be at least as
    /// long as the pointer; null after the last.
    pub fn next(t: *Tokens, buffer: []u8) ?[]const u8 {
        const rest = t.rest orelse return null;
        const end = std.mem.findScalar(u8, rest, '/') orelse rest.len;
        const raw = rest[0..end];
        t.rest = if (end == rest.len) null else rest[end + 1 ..];
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (n += 1) {
            if (raw[i] == '~') {
                buffer[n] = if (raw[i + 1] == '0') '~' else '/';
                i += 2;
            } else {
                buffer[n] = raw[i];
                i += 1;
            }
        }
        return buffer[0..n];
    }
};

/// An array index token (RFC 6901 §4): `0` or digits without a leading zero.
pub fn arrayIndex(token: []const u8) ?usize {
    if (token.len == 0 or (token.len > 1 and token[0] == '0')) return null;
    for (token) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, token, 10) catch null;
}

const testing = std.testing;

test "a location writes as RFC 6901's pointer, escapes and all" {
    var l: Location = .{};
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.format(&w);
    try testing.expectEqualStrings("", w.buffered());
    try l.push(.{ .name = "a/b" });
    try l.push(.{ .index = 0 });
    try l.push(.{ .name = "m~n" });
    w = .fixed(&buf);
    try l.format(&w);
    try testing.expectEqualStrings("/a~1b/0/m~0n", w.buffered());
    l.pop();
    w = .fixed(&buf);
    try l.format(&w);
    try testing.expectEqualStrings("/a~1b/0", w.buffered());
}

test "RFC 6901's examples read as their tokens" {
    // §5's document keys, each pointer and the token it names.
    const cases = [_][2][]const u8{
        .{ "/foo", "foo" },   .{ "/foo/0", "0" }, .{ "/", "" },        .{ "/a~1b", "a/b" },
        .{ "/c%d", "c%d" },   .{ "/e^f", "e^f" }, .{ "/g|h", "g|h" },  .{ "/i\\j", "i\\j" },
        .{ "/k\"l", "k\"l" }, .{ "/ ", " " },     .{ "/m~0n", "m~n" }, .{ "/~01", "~1" },
    };
    var buf: [16]u8 = undefined;
    for (cases) |c| {
        var t = try tokens(c[0]);
        var last: []const u8 = undefined;
        while (t.next(&buf)) |token| last = token;
        try testing.expectEqualStrings(c[1], last);
    }
    var whole = try tokens("");
    try testing.expectEqual(null, whole.next(&buf));
    for ([_][]const u8{ "foo", "/a~", "/a~2", "/~" }) |bad| try testing.expectError(error.InvalidPointer, tokens(bad));
    try testing.expectEqual(@as(?usize, 0), arrayIndex("0"));
    try testing.expectEqual(@as(?usize, 12), arrayIndex("12"));
    try testing.expectEqual(@as(?usize, null), arrayIndex("01"));
    try testing.expectEqual(@as(?usize, null), arrayIndex("-1"));
}
