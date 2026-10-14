//! The integer members a line in a known shape opens with, read off its
//! bytes rather than parsed.

const std = @import("std");

/// What `leadingIntMembers` read: the members, and where the line goes on.
pub fn IntMembers(comptime T: type) type {
    return struct {
        value: T,
        /// The offset just past the last integer: a `,` that begins the next
        /// member, or the `}` that closes the object.
        end: usize,
    };
}

/// `T`'s fields, in order, as the members `line` opens with — `{"a":1,"b":-2`
/// — each one a JSON integer that fits its field: the bytes `writeValue`
/// writes for a struct that begins with those fields. A record whose envelope
/// is a run of integers is read this way at the cost of the digits, which is
/// what a log replayed at every open needs from every line.
///
/// Null whenever the line is not in exactly that shape: whitespace, another
/// order, an escape in a name, a number with a fraction or an exponent or a
/// leading zero, a value that does not fit its field, or a last integer
/// followed by anything but `,` or `}`. The same members spelled any other
/// way are still JSON, and are the parser's to read; null says only that this
/// is not the shape to take them off the bytes.
pub fn leadingIntMembers(comptime T: type, line: []const u8) ?IntMembers(T) {
    return intMembersAt(T, line, 0);
}

/// `T`'s fields as the integer members `line` holds from `at`, as
/// `leadingIntMembers` reads them: from the start of the line when `at` is 0,
/// the first member opening the object; otherwise each member after a `,`
/// (`,"bf":3,"bl":5`), so that a run of integers further along a known shape
/// is read off the bytes as well. Null when the bytes from `at` are not
/// exactly that.
pub fn intMembersAt(comptime T: type, line: []const u8, at_: usize) ?IntMembers(T) {
    const layout = comptime layout: {
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".is_tuple or info.@"struct".field_names.len == 0)
            @compileError("intMembersAt takes a struct of integer fields, not '" ++ @typeName(T) ++ "'");
        for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
            if (@typeInfo(field_type) != .int)
                @compileError("intMembersAt reads integers; '" ++ field_name ++ "' is a '" ++ @typeName(field_type) ++ "'");
            plainName(field_name);
        }
        break :layout info.@"struct";
    };
    if (at_ > line.len) return null;
    var result: T = undefined;
    var at = at_;
    inline for (layout.field_names, layout.field_types, 0..) |field_name, field_type, i| {
        const opening = comptime "\"" ++ field_name ++ "\":";
        const first: u8 = if (i == 0 and at_ == 0) '{' else ',';
        if (at >= line.len or line[at] != first or !std.mem.startsWith(u8, line[at + 1 ..], opening)) return null;
        at += 1 + opening.len;
        const from = at;
        at = integerEnd(line, at) orelse return null;
        @field(result, field_name) = std.fmt.parseInt(field_type, line[from..at], 10) catch return null;
    }
    if (at >= line.len or (line[at] != ',' and line[at] != '}')) return null;
    return .{ .value = result, .end = at };
}

/// What `trailingIntMember` read: the member's value, and where it begins.
pub fn TrailingInt(comptime T: type) type {
    return struct {
        value: T,
        /// The offset of the `,` before the member: the line up to it is
        /// everything the object holds before its last member.
        start: usize,
    };
}

/// The member `name` that `line` closes with, `,"name":<integer>}` and
/// nothing after it, read off the bytes from the end: a checksum written as
/// a record's last member, found without reading what it covers. Null when
/// the line does not end in exactly that, an integer as JSON writes one that
/// fits `T`.
pub fn trailingIntMember(comptime T: type, comptime name: []const u8, line: []const u8) ?TrailingInt(T) {
    comptime plainName(name);
    const opening = ",\"" ++ name ++ "\":";
    if (line.len < opening.len + 2 or line[line.len - 1] != '}') return null;
    var from = line.len - 1;
    while (from > 0 and std.ascii.isDigit(line[from - 1])) from -= 1;
    if (from > 0 and line[from - 1] == '-') from -= 1;
    if (from < opening.len or !std.mem.eql(u8, line[from - opening.len .. from], opening)) return null;
    if (integerEnd(line, from) != line.len - 1) return null;
    const value = std.fmt.parseInt(T, line[from .. line.len - 1], 10) catch return null;
    return .{ .value = value, .start = from - opening.len };
}

/// A JSON value's bytes as a `T` when they are an integer written as one: an
/// optional `-`, then digits with no zero in front of others, and nothing
/// else, which `T` holds. Null for anything else, a number with a fraction or
/// an exponent among it: a member kept as `json.Raw` and read as an integer
/// only where it was written as one.
pub fn intOf(comptime T: type, bytes: []const u8) ?T {
    if (integerEnd(bytes, 0) != bytes.len) return null;
    return std.fmt.parseInt(T, bytes, 10) catch null;
}

/// Where the JSON integer at `at` ends, or null when none starts there.
fn integerEnd(bytes: []const u8, from: usize) ?usize {
    var at = from;
    if (at < bytes.len and bytes[at] == '-') at += 1;
    const digits = at;
    while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
    // JSON's integer: at least one digit, and no zero in front of others.
    if (at == digits or (bytes[digits] == '0' and at - digits > 1)) return null;
    return at;
}

fn plainName(comptime name: []const u8) void {
    for (name) |b| if (b < 0x20 or b == '"' or b == '\\' or b >= 0x7f)
        @compileError("a name is read as written plain; '" ++ name ++ "' is not one");
}

const testing = std.testing;

test leadingIntMembers {
    const Envelope = struct { seq: i64, at: i64, v: u32 };
    const line = "{\"seq\":7,\"at\":-3,\"v\":2,\"ev\":{\"x\":1}}";
    const read = leadingIntMembers(Envelope, line).?;
    try testing.expectEqual(Envelope{ .seq = 7, .at = -3, .v = 2 }, read.value);
    try testing.expectEqualStrings(",\"ev\":{\"x\":1}}", line[read.end..]);
    // The whole object, closed after its integers.
    const Header = struct { chronicle: u32, base: u64, root: u32 };
    const header = "{\"chronicle\":1,\"base\":18446744073709551615,\"root\":0}";
    const h = leadingIntMembers(Header, header).?;
    try testing.expectEqual(Header{ .chronicle = 1, .base = std.math.maxInt(u64), .root = 0 }, h.value);
    try testing.expectEqual(header.len - 1, h.end);

    // Any other spelling is the parser's.
    for ([_][]const u8{
        "{ \"seq\":7,\"at\":1,\"v\":1}",
        "{\"seq\": 7,\"at\":1,\"v\":1}",
        "{\"at\":1,\"seq\":7,\"v\":1}",
        "{\"s\\u0065q\":7,\"at\":1,\"v\":1}",
        "{\"seq\":7.0,\"at\":1,\"v\":1}",
        "{\"seq\":7e0,\"at\":1,\"v\":1}",
        "{\"seq\":07,\"at\":1,\"v\":1}",
        "{\"seq\":-,\"at\":1,\"v\":1}",
        "{\"seq\":\"7\",\"at\":1,\"v\":1}",
        "{\"seq\":7,\"at\":1,\"v\":-1}",
        "{\"seq\":7,\"at\":1,\"v\":4294967296}",
        "{\"seq\":9223372036854775808,\"at\":1,\"v\":1}",
        "{\"seq\":7,\"at\":1,\"v\":1",
        "{\"seq\":7,\"at\":1,\"v\":1 }",
        "{\"seq\":7,\"at\":1}",
        "[7,1,1]",
        "",
    }) |other| try testing.expectEqual(@as(?IntMembers(Envelope), null), leadingIntMembers(Envelope, other));
    // Zero, and a negative zero, are integers.
    try testing.expectEqual(Envelope{ .seq = 0, .at = 0, .v = 0 }, leadingIntMembers(Envelope, "{\"seq\":0,\"at\":-0,\"v\":0}").?.value);
}

test intMembersAt {
    const line = "{\"seq\":4,\"at\":1,\"bf\":3,\"bl\":5,\"ev\":{}}";
    const head = leadingIntMembers(struct { seq: i64, at: i64 }, line).?;
    const batch = intMembersAt(struct { bf: i64, bl: i64 }, line, head.end).?;
    try testing.expectEqual(@as(i64, 3), batch.value.bf);
    try testing.expectEqual(@as(i64, 5), batch.value.bl);
    try testing.expectEqualStrings(",\"ev\":{}}", line[batch.end..]);
    // Each member after a comma, and nothing else, from where it is asked.
    try testing.expectEqual(null, intMembersAt(struct { bf: i64 }, line, head.end + 1));
    try testing.expectEqual(null, intMembersAt(struct { bf: i64, ev: i64 }, line, head.end));
    try testing.expectEqual(null, intMembersAt(struct { bf: i64 }, line, line.len + 1));
}

test trailingIntMember {
    const line = "{\"seq\":1,\"ev\":{\"c\":9},\"c\":42}";
    const read = trailingIntMember(u32, "c", line).?;
    try testing.expectEqual(@as(u32, 42), read.value);
    try testing.expectEqualStrings("{\"seq\":1,\"ev\":{\"c\":9}", line[0..read.start]);
    try testing.expectEqual(@as(i32, -7), trailingIntMember(i32, "c", "{\"a\":1,\"c\":-7}").?.value);
    for ([_][]const u8{
        "{\"seq\":1,\"c\":}",
        "{\"seq\":1,\"c\":07}",
        "{\"seq\":1,\"c\":4294967296}",
        "{\"seq\":1,\"c\":1.0}",
        "{\"seq\":1,\"c\":1 }",
        "{\"seq\":1,\"c\":1}\n",
        "{\"seq\":1, \"c\":1}",
        "{\"c\":1}",
        "}",
        "",
    }) |other| try testing.expectEqual(null, trailingIntMember(u32, "c", other));
}

test intOf {
    try testing.expectEqual(@as(?i64, -12), intOf(i64, "-12"));
    try testing.expectEqual(@as(?u32, 0), intOf(u32, "0"));
    for ([_][]const u8{ "7.0", "7e0", "07", "\"7\"", "", "-", " 7", "7 ", "null", "4294967296" }) |other|
        try testing.expectEqual(@as(?u32, null), intOf(u32, other));
}
