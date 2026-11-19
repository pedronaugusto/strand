//! A type's text form (`core/text_form.zig`), through every format: a type
//! of this test's own and aegis's duration and size, each written as its
//! text and read back, in JSON, TOML, YAML, INI, dotenv, URL-encoded, XML,
//! ZON and CSV; text past `max_len` refused unread; a parse error
//! `InvalidValue` with the type's own error name and the field path; the
//! JSON Schema `format` a type names.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand.zig");
const core = strand.core;

/// A calendar date as RFC 3339's `full-date` spells it.
const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    pub const text_form = .{ .max_len = 10, .schema_format = "date" };
    pub const ParseError = error{ Malformed, OutOfRange };

    pub fn parse(text: []const u8) ParseError!Date {
        if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.Malformed;
        const year = std.fmt.parseInt(u16, text[0..4], 10) catch return error.Malformed;
        const month = std.fmt.parseInt(u8, text[5..7], 10) catch return error.Malformed;
        const day = std.fmt.parseInt(u8, text[8..10], 10) catch return error.Malformed;
        if (month < 1 or month > 12 or day < 1 or day > 31) return error.OutOfRange;
        return .{ .year = year, .month = month, .day = day };
    }

    pub fn format(self: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

const Record = struct {
    born: Date,
    wait: aegis.units.Duration(.millisecond, u32),
    size: aegis.units.Bytes(u64),
};

const sample: Record = .{ .born = .{ .year = 1987, .month = 6, .day = 5 }, .wait = .literal("1m30s"), .size = .literal("64KiB") };

fn expectSample(got: Record) !void {
    try std.testing.expectEqual(sample.born, got.born);
    try std.testing.expect(sample.wait.eql(got.wait));
    try std.testing.expect(sample.size.eql(got.size));
}

/// Writes `value` with `format` and reads it back, the texts in the output.
fn roundTrip(comptime format: type, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    // TOML's writer orders a table's keys, in memory it is given; XML's
    // names its root element.
    if (comptime format == strand.toml)
        try format.write(&w, value, .{ .allocator = std.testing.allocator })
    else if (comptime format == strand.xml)
        try format.write(&w, value, .{ .root = "record" })
    else
        try format.write(&w, value, .{});
    const text = w.buffered();
    for ([_][]const u8{ "1987-06-05", "1m30s", "64KiB" }) |spelled| {
        if (std.mem.find(u8, text, spelled) == null) {
            std.debug.print("{s}: no {s} in\n{s}\n", .{ @typeName(format), spelled, text });
            return error.TestUnexpectedResult;
        }
    }
    var parsed = try format.parse(@TypeOf(value), std.testing.allocator, text, .{});
    defer parsed.deinit();
    if (@typeInfo(@TypeOf(value)) == .pointer) {
        try std.testing.expectEqual(value.len, parsed.value.len);
        for (parsed.value) |row| try expectSample(row);
    } else try expectSample(parsed.value);
}

test "a text form is the value's text in every format, read back to the same value" {
    inline for (.{ strand.json, strand.toml, strand.yaml, strand.ini, strand.dotenv, strand.urlencoded, strand.xml, strand.zon }) |format| try roundTrip(format, sample);
    try roundTrip(strand.csv, @as([]const Record, &.{ sample, sample }));
}

test "format then parse is the identity, and a text form's documented examples read as documented" {
    const dates = [_]Date{ .{ .year = 1, .month = 1, .day = 1 }, .{ .year = 9999, .month = 12, .day = 31 }, sample.born };
    for (dates) |date| {
        var buffer: [Date.text_form.max_len]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try date.format(&w);
        try std.testing.expectEqual(date, try Date.parse(w.buffered()));
    }
    try std.testing.expectEqual(Date{ .year = 2026, .month = 11, .day = 19 }, try Date.parse("2026-11-19"));
    // std's {f} prints the same text strand writes.
    var buffer: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{sample.born});
    try std.testing.expectEqualStrings("1987-06-05", w.buffered());
}

test "text past max_len is refused before parse sees it" {
    try std.testing.expectError(error.LengthLimit, strand.json.parse(Record, std.testing.allocator,
        \\{"born":"1987-06-05T00:00","wait":"1s","size":"1B"}
    , .{}));
    // A duration's text is at most what its format writes.
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    const long = "{\"born\":\"1987-06-05\",\"wait\":\"" ++ zeros ++ "1s\",\"size\":\"1B\"}";
    try std.testing.expectError(error.LengthLimit, strand.json.parse(Record, std.testing.allocator, long, .{}));
}

test "a parse error is InvalidValue, the type's own error name and the field path in the diagnostics" {
    const cases = [_]struct { input: []const u8, name: []const u8, field: []const u8 }{
        .{ .input = "{\"born\":\"1987-13-05\",\"wait\":\"1s\",\"size\":\"1B\"}", .name = "OutOfRange", .field = "born" },
        .{ .input = "{\"born\":\"1987/06/05\",\"wait\":\"1s\",\"size\":\"1B\"}", .name = "Malformed", .field = "born" },
        // aegis's own errors, never mapped to strand's number errors.
        .{ .input = "{\"born\":\"1987-06-05\",\"wait\":\"1.5ms\",\"size\":\"1B\"}", .name = "Inexact", .field = "wait" },
        .{ .input = "{\"born\":\"1987-06-05\",\"wait\":\"60d\",\"size\":\"1B\"}", .name = "Overflow", .field = "wait" },
        .{ .input = "{\"born\":\"1987-06-05\",\"wait\":\"1s\",\"size\":\"64KB\"}", .name = "Malformed", .field = "size" },
    };
    for (cases) |case| {
        var diagnostics: core.Diagnostics = .{};
        try std.testing.expectError(error.InvalidValue, strand.json.parse(Record, std.testing.allocator, case.input, .{ .diagnostics = &diagnostics }));
        try std.testing.expectEqualStrings(case.name, diagnostics.value_error);
        try std.testing.expectEqualStrings(case.field, diagnostics.path.frames()[0].name.view());
    }
    // A duration is text, never a bare number of an unstated unit.
    try std.testing.expectError(error.UnexpectedType, strand.json.parse(Record, std.testing.allocator, "{\"born\":\"1987-06-05\",\"wait\":30,\"size\":\"1B\"}", .{}));
}

test "the JSON Schema of a text form: a string, with the format the type names" {
    try std.testing.expectEqualStrings("{\"type\":\"string\",\"format\":\"date\"}", comptime strand.json.schema.of(Date, .{ .dialect = false }));
    try std.testing.expectEqualStrings("{\"type\":\"string\"}", comptime strand.json.schema.of(aegis.units.Duration(.millisecond, u32), .{ .dialect = false }));
}
