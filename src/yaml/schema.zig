//! YAML 1.2's core schema: what a plain scalar is (null, a boolean, an
//! integer, a float or a string) by its spelling, and the conversion of a
//! number's spelling into a Zig number. No YAML 1.1 forms: `yes`, `on`, `0b1`,
//! `1_000` and sexagesimals are strings.
const std = @import("std");
const core = @import("../core.zig");
const json = @import("../json/number.zig");

pub const Kind = enum { null, boolean, integer, float, string };

/// What the core schema resolves a plain scalar's text to.
pub fn resolve(text: []const u8) Kind {
    if (text.len == 0) return .null;
    switch (text[0]) {
        'n', 'N', '~' => if (isNull(text)) return .null,
        't', 'T', 'f', 'F' => if (boolean(text) != null) return .boolean,
        '-', '+', '.', '0'...'9' => if (number(text)) |kind| return kind,
        else => {},
    }
    return .string;
}

pub fn isNull(text: []const u8) bool {
    return text.len == 0 or eqlAny(text, &.{ "~", "null", "Null", "NULL" });
}
pub fn boolean(text: []const u8) ?bool {
    if (eqlAny(text, &.{ "true", "True", "TRUE" })) return true;
    if (eqlAny(text, &.{ "false", "False", "FALSE" })) return false;
    return null;
}
fn eqlAny(text: []const u8, comptime spellings: []const []const u8) bool {
    inline for (spellings) |s| if (std.mem.eql(u8, text, s)) return true;
    return false;
}

/// Whether `text` is a number of the core schema, and which kind.
pub fn number(text: []const u8) ?Kind {
    if (text.len == 0) return null;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'o')) {
        const radix: u8 = if (text[1] == 'x') 16 else 8;
        for (text[2..]) |b| _ = std.fmt.charToDigit(b, radix) catch return null;
        return .integer;
    }
    const body = if (text[0] == '-' or text[0] == '+') text[1..] else text;
    if (body.len == 0) return null;
    if (eqlAny(body, &.{ ".inf", ".Inf", ".INF" })) return .float;
    if (eqlAny(text, &.{ ".nan", ".NaN", ".NAN" })) return .float;
    // [0-9]+ ( . [0-9]* )? | . [0-9]+, then an optional exponent.
    var at: usize = 0;
    while (at < body.len and std.ascii.isDigit(body[at])) at += 1;
    const whole = at;
    if (at == body.len) return .integer;
    var fraction: usize = 0;
    if (body[at] == '.') {
        at += 1;
        const from = at;
        while (at < body.len and std.ascii.isDigit(body[at])) at += 1;
        fraction = at - from;
    }
    if (whole == 0 and fraction == 0) return null;
    if (at < body.len) {
        if (body[at] != 'e' and body[at] != 'E') return null;
        at += 1;
        if (at < body.len and (body[at] == '+' or body[at] == '-')) at += 1;
        const from = at;
        while (at < body.len and std.ascii.isDigit(body[at])) at += 1;
        if (at == from or at != body.len) return null;
    }
    return .float;
}

/// An integer's spelling as a `T`.
pub fn parseInteger(comptime T: type, spelling: []const u8, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    const kind = number(spelling) orelse return error.SyntaxError;
    if (kind != .integer) return error.UnexpectedType;
    return integer(T, spelling) orelse error.NumberOutOfRange;
}
/// An integer's spelling as a `T`, or null where it does not fit.
pub fn integer(comptime T: type, spelling: []const u8) ?T {
    if (spelling.len > 2 and spelling[0] == '0' and (spelling[1] == 'x' or spelling[1] == 'o'))
        return std.fmt.parseInt(T, spelling[2..], if (spelling[1] == 'x') 16 else 8) catch null;
    return std.fmt.parseInt(T, spelling, 10) catch null;
}

/// A number's spelling as the nearest `f64`, null past its range.
pub fn float(spelling: []const u8) ?f64 {
    const negative = spelling[0] == '-';
    const body = if (negative or spelling[0] == '+') spelling[1..] else spelling;
    if (body.len == 4 and body[0] == '.' and std.ascii.toLower(body[1]) == 'i') return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    if (body.len == 4 and body[0] == '.' and std.ascii.toLower(body[1]) == 'n') return std.math.nan(f64);
    if (integer(u128, spelling)) |n| return @floatFromInt(n);
    const v = std.fmt.parseFloat(f64, body) catch return null;
    if (!std.math.isFinite(v)) return null;
    return if (negative) -v else v;
}

/// A number's spelling as a `T`: a float's rounded once from its decimal
/// digits, an integer's exact or refused when `exact` asks.
pub fn parseFloat(comptime T: type, spelling: []const u8, exact: bool, c: *core.Context) core.DecodeError!T {
    try c.chargeWork(spelling.len);
    const kind = number(spelling) orelse return error.SyntaxError;
    const negative = spelling[0] == '-';
    const body = if (negative or spelling[0] == '+') spelling[1..] else spelling;
    if (body.len == 4 and body[0] == '.' and std.ascii.toLower(body[1]) == 'i') return if (negative) -std.math.inf(T) else std.math.inf(T);
    if (body.len == 4 and body[0] == '.' and std.ascii.toLower(body[1]) == 'n') return std.math.nan(T);
    if (kind == .integer and spelling.len > 2 and spelling[0] == '0' and (spelling[1] == 'x' or spelling[1] == 'o')) {
        const value = integer(u128, spelling) orelse return error.NumberOutOfRange;
        const result: T = @floatFromInt(value);
        if (!std.math.isFinite(result)) return error.NumberOutOfRange;
        if (exact and (result >= 0x1p128 or @as(u128, @intFromFloat(result)) != value)) return error.InexactNumber;
        return result;
    }
    // A decimal spelling, signed by `-` alone, is what JSON's kernel reads.
    return json.floating(T, if (spelling[0] == '+') spelling[1..] else spelling, exact, c);
}

test "the core schema's resolution" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "", .null },        .{ "~", .null },        .{ "Null", .null },    .{ "nULL", .string },
        .{ "true", .boolean }, .{ "FALSE", .boolean }, .{ "yes", .string },   .{ "on", .string },
        .{ "0", .integer },    .{ "-19", .integer },   .{ "+12", .integer },  .{ "007", .integer },
        .{ "0o14", .integer }, .{ "0x3A", .integer },  .{ "0b1", .string },   .{ "1_000", .string },
        .{ "0.", .float },     .{ "-0.0", .float },    .{ ".5", .float },     .{ "+12e03", .float },
        .{ "-2E+05", .float }, .{ ".inf", .float },    .{ "-.Inf", .float },  .{ ".NaN", .float },
        .{ "-.nan", .string }, .{ ".", .string },      .{ "1e", .string },    .{ "1.2.3", .string },
        .{ "0x", .string },    .{ "-0x1", .string },   .{ "12:30", .string }, .{ "1e5", .float },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], resolve(case[0]));
}

test "a spelling as an integer and as a float" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c: core.Context = .init(arena.allocator(), .{}, .borrowed);
    try std.testing.expectEqual(@as(i64, 0x3A), try parseInteger(i64, "0x3A", &c));
    try std.testing.expectEqual(@as(i64, 12), try parseInteger(i64, "0o14", &c));
    try std.testing.expectEqual(@as(i64, 7), try parseInteger(i64, "007", &c));
    try std.testing.expectEqual(@as(i64, 12), try parseInteger(i64, "+12", &c));
    try std.testing.expectEqual(std.math.minInt(i64), try parseInteger(i64, "-9223372036854775808", &c));
    try std.testing.expectError(error.NumberOutOfRange, parseInteger(u8, "256", &c));
    try std.testing.expectError(error.UnexpectedType, parseInteger(i64, "1.5", &c));
    try std.testing.expectEqual(@as(f64, 0.5), try parseFloat(f64, ".5", false, &c));
    try std.testing.expectEqual(@as(f64, 1), try parseFloat(f64, "1.", false, &c));
    try std.testing.expectEqual(@as(f64, 12e3), try parseFloat(f64, "+12e03", false, &c));
    try std.testing.expectEqual(@as(f64, 58), try parseFloat(f64, "0x3A", true, &c));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-.inf", false, &c)));
    try std.testing.expect(std.math.isNan(try parseFloat(f32, ".NaN", false, &c)));
    try std.testing.expectError(error.InexactNumber, parseFloat(f32, "16777217", true, &c));
}
