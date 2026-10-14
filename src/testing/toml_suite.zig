//! toml-test (github.com/toml-lang/toml-test at ff49d109861c1ad25af53f687f2aef19ab650600,
//! MIT license beside the files) for TOML 1.0.0 and 1.1.0, each from its own
//! list of files. Decoder: every valid document reads as the value its JSON
//! says, every invalid one is refused. Encoder: every valid document's JSON,
//! as a `toml.Value`, is written and reads back, as TOML 1.0, as that value.
//! No file is skipped.
const std = @import("std");
const toml = @import("../toml.zig");
const json = @import("../json.zig");

const Case = struct { name: []const u8, toml: []const u8, json: ?[]const u8 };

/// The cases a list names: each `.toml` file, with its `.json` for a valid one.
fn listed(comptime list: []const u8) []const Case {
    @setEvalBranchQuota(10_000_000);
    comptime var found: []const Case = &.{};
    comptime var lines = std.mem.tokenizeScalar(u8, list, '\n');
    inline while (comptime lines.next()) |line| {
        if (comptime !std.mem.endsWith(u8, line, ".toml")) continue;
        const stem = line[0 .. line.len - ".toml".len];
        const valid = comptime std.mem.startsWith(u8, line, "valid/");
        found = found ++ &[_]Case{.{
            .name = line,
            .toml = @embedFile("../corpus/toml/" ++ line),
            .json = if (valid) @embedFile("../corpus/toml/" ++ stem ++ ".json") else null,
        }};
    }
    return found;
}
const v1_0 = listed(@embedFile("../corpus/toml/files-toml-1.0.0"));
const v1_1 = listed(@embedFile("../corpus/toml/files-toml-1.1.0"));

test "toml-test decoder, TOML 1.0.0 and 1.1.0" {
    // Every file each list names, as the pinned lists count them.
    try std.testing.expectEqual(.{ 208, 501 }, .{ try decoder(v1_0, .v1_0), v1_0.len - 208 });
    try std.testing.expectEqual(.{ 218, 494 }, .{ try decoder(v1_1, .v1_1), v1_1.len - 218 });
}
test "toml-test encoder, TOML 1.0.0 and 1.1.0" {
    try encoder(v1_0, .v1_0);
    try encoder(v1_1, .v1_1);
}

/// How many valid documents there were.
fn decoder(cases: []const Case, version: toml.Version) !usize {
    var failures: usize = 0;
    var valid: usize = 0;
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const read = toml.parseLeaky(toml.Value, a, case.toml, .{ .version = version });
        if (case.json) |expected_json| {
            valid += 1;
            const value = read catch |err| {
                std.debug.print("{t}: {s}: refused, {t}\n", .{ version, case.name, err });
                failures += 1;
                continue;
            };
            const expected = try json.parseLeaky(json.Value, a, expected_json, .{});
            if (!matches(value, expected)) {
                std.debug.print("{t}: {s}: read as another value\n", .{ version, case.name });
                failures += 1;
            }
        } else if (read) |_| {
            std.debug.print("{t}: {s}: invalid, and read\n", .{ version, case.name });
            failures += 1;
        } else |_| {}
    }
    try std.testing.expectEqual(0, failures);
    return valid;
}

fn encoder(cases: []const Case, version: toml.Version) !void {
    var failures: usize = 0;
    var count: usize = 0;
    for (cases) |case| {
        const expected_json = case.json orelse continue;
        count += 1;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const expected = try json.parseLeaky(json.Value, a, expected_json, .{});
        const value = try fromTagged(a, expected);
        var out: std.Io.Writer.Allocating = .init(a);
        toml.write(&out.writer, value, .{ .allocator = a }) catch |err| {
            std.debug.print("{t}: {s}: not written, {t}\n", .{ version, case.name, err });
            failures += 1;
            continue;
        };
        const again = toml.parseLeaky(toml.Value, a, out.written(), .{ .version = .v1_0 }) catch |err| {
            std.debug.print("{t}: {s}: written, and not read back as TOML 1.0, {t}:\n{s}\n", .{ version, case.name, err, out.written() });
            failures += 1;
            continue;
        };
        if (!matches(again, expected)) {
            std.debug.print("{t}: {s}: written, and read back as another value:\n{s}\n", .{ version, case.name, out.written() });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

/// toml-test's tagged scalar: `{"type": ..., "value": "..."}`.
fn tagged(expected: json.Value) ?struct { type: []const u8, value: []const u8 } {
    if (expected != .object or expected.object.len != 2) return null;
    var kind: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    for (expected.object) |member| {
        if (member.value != .string) return null;
        if (std.mem.eql(u8, member.key, "type")) kind = member.value.string;
        if (std.mem.eql(u8, member.key, "value")) text = member.value.string;
    }
    return .{ .type = kind orelse return null, .value = text orelse return null };
}

/// Whether `value` is the value toml-test's JSON says: dates by what they
/// mean (`.6` is `.600`), floats by value (any NaN is NaN), tables by keys.
fn matches(value: toml.Value, expected: json.Value) bool {
    if (tagged(expected)) |scalar| {
        const t = scalar.type;
        const v = scalar.value;
        if (std.mem.eql(u8, t, "string")) return value == .string and std.mem.eql(u8, value.string, v);
        if (std.mem.eql(u8, t, "integer")) return value == .integer and value.integer == (std.fmt.parseInt(i64, v, 10) catch return false);
        if (std.mem.eql(u8, t, "bool")) return value == .boolean and value.boolean == std.mem.eql(u8, v, "true");
        if (std.mem.eql(u8, t, "float")) {
            if (value != .float) return false;
            const f = parseFloat(v) orelse return false;
            if (std.math.isNan(f)) return std.math.isNan(value.float);
            return f == value.float and std.math.signbit(f) == std.math.signbit(value.float);
        }
        if (std.mem.eql(u8, t, "datetime")) return value == .offset_date_time and std.meta.eql(value.offset_date_time, toml.OffsetDateTime.parse(v) orelse return false);
        if (std.mem.eql(u8, t, "datetime-local")) return value == .local_date_time and std.meta.eql(value.local_date_time, toml.LocalDateTime.parse(v) orelse return false);
        if (std.mem.eql(u8, t, "date-local")) return value == .local_date and std.meta.eql(value.local_date, toml.LocalDate.parse(v) orelse return false);
        if (std.mem.eql(u8, t, "time-local")) return value == .local_time and std.meta.eql(value.local_time, toml.LocalTime.parse(v) orelse return false);
        return false;
    }
    switch (expected) {
        .array => |items| {
            if (value != .array or value.array.len != items.len) return false;
            for (value.array, items) |v, e| if (!matches(v, e)) return false;
            return true;
        },
        .object => |members| {
            if (value != .table or value.table.len != members.len) return false;
            for (members) |member| {
                const v = value.get(member.key) orelse return false;
                if (!matches(v, member.value)) return false;
            }
            return true;
        },
        else => return false,
    }
}
fn parseFloat(text: []const u8) ?f64 {
    const negative = text.len > 0 and text[0] == '-';
    const body = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    if (std.mem.eql(u8, body, "nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, body, "inf")) return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    return std.fmt.parseFloat(f64, text) catch null;
}

/// toml-test's JSON as the value it stands for.
fn fromTagged(a: std.mem.Allocator, expected: json.Value) !toml.Value {
    if (tagged(expected)) |scalar| {
        const t = scalar.type;
        const v = scalar.value;
        if (std.mem.eql(u8, t, "string")) return .{ .string = v };
        if (std.mem.eql(u8, t, "integer")) return .{ .integer = try std.fmt.parseInt(i64, v, 10) };
        if (std.mem.eql(u8, t, "bool")) return .{ .boolean = std.mem.eql(u8, v, "true") };
        if (std.mem.eql(u8, t, "float")) return .{ .float = parseFloat(v) orelse return error.TestUnexpectedResult };
        if (std.mem.eql(u8, t, "datetime")) return .{ .offset_date_time = toml.OffsetDateTime.parse(v) orelse return error.TestUnexpectedResult };
        if (std.mem.eql(u8, t, "datetime-local")) return .{ .local_date_time = toml.LocalDateTime.parse(v) orelse return error.TestUnexpectedResult };
        if (std.mem.eql(u8, t, "date-local")) return .{ .local_date = toml.LocalDate.parse(v) orelse return error.TestUnexpectedResult };
        if (std.mem.eql(u8, t, "time-local")) return .{ .local_time = toml.LocalTime.parse(v) orelse return error.TestUnexpectedResult };
        return error.TestUnexpectedResult;
    }
    switch (expected) {
        .array => |items| {
            const out = try a.alloc(toml.Value, items.len);
            for (out, items) |*o, item| o.* = try fromTagged(a, item);
            return .{ .array = out };
        },
        .object => |members| {
            const out = try a.alloc(toml.Entry, members.len);
            for (out, members) |*o, member| o.* = .{ .key = member.key, .value = try fromTagged(a, member.value) };
            return .{ .table = out };
        },
        else => return error.TestUnexpectedResult,
    }
}
