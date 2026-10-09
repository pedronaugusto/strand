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
    const layout = comptime layout: {
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".is_tuple or info.@"struct".field_names.len == 0)
            @compileError("leadingIntMembers takes a struct of integer fields, not '" ++ @typeName(T) ++ "'");
        for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
            if (@typeInfo(field_type) != .int)
                @compileError("leadingIntMembers reads integers; '" ++ field_name ++ "' is a '" ++ @typeName(field_type) ++ "'");
            for (field_name) |b| if (b < 0x20 or b == '"' or b == '\\' or b >= 0x7f)
                @compileError("leadingIntMembers reads a name as written plain; '" ++ field_name ++ "' is not one");
        }
        break :layout info.@"struct";
    };
    var result: T = undefined;
    var at: usize = 0;
    inline for (layout.field_names, layout.field_types, 0..) |field_name, field_type, i| {
        const opening = comptime (if (i == 0) "{" else ",") ++ "\"" ++ field_name ++ "\":";
        if (!std.mem.startsWith(u8, line[at..], opening)) return null;
        at += opening.len;
        const from = at;
        if (at < line.len and line[at] == '-') at += 1;
        const digits = at;
        while (at < line.len and std.ascii.isDigit(line[at])) at += 1;
        // JSON's integer: at least one digit, and no zero in front of others.
        if (at == digits or (line[digits] == '0' and at - digits > 1)) return null;
        @field(result, field_name) = std.fmt.parseInt(field_type, line[from..at], 10) catch return null;
    }
    if (at >= line.len or (line[at] != ',' and line[at] != '}')) return null;
    return .{ .value = result, .end = at };
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
