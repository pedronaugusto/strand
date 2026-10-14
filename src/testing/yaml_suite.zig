//! yaml-test-suite (github.com/yaml/yaml-test-suite, data-2022-01-17 at
//! 6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f, MIT license beside the files):
//! every case its list names. Events: each valid stream's events are the ones
//! its `test.event` gives, each invalid one is refused.
const std = @import("std");
const parser = @import("../yaml/parser.zig");
const yaml = @import("../yaml.zig");
const json = @import("../json.zig");

pub const Case = struct { path: []const u8, name: []const u8, yaml: []const u8, events: []const u8, json: ?[]const u8, invalid: bool };

/// The cases the list names: `path`, flags (`e` invalid, `j` with JSON), name.
fn listed(comptime list: []const u8) []const Case {
    @setEvalBranchQuota(10_000_000);
    comptime var found: []const Case = &.{};
    comptime var lines = std.mem.tokenizeScalar(u8, list, '\n');
    inline while (comptime lines.next()) |line| {
        comptime var fields = std.mem.splitScalar(u8, line, '\t');
        const path = comptime fields.next().?;
        const flags = comptime fields.next().?;
        const name = comptime fields.rest();
        const dir = "../corpus/yaml/" ++ path ++ "/";
        found = found ++ &[_]Case{.{
            .path = path,
            .name = name,
            .yaml = @embedFile(dir ++ "in.yaml"),
            .events = @embedFile(dir ++ "test.event"),
            .json = if (comptime std.mem.findScalar(u8, flags, 'j') != null) @embedFile(dir ++ "in.json") else null,
            .invalid = comptime std.mem.findScalar(u8, flags, 'e') != null,
        }};
    }
    return found;
}
pub const cases = listed(@embedFile("../corpus/yaml/cases"));

/// The events of `input` in the suite's notation, or the refusal.
pub fn events(gpa: std.mem.Allocator, input: []const u8, out: *std.Io.Writer) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    var p: parser.Parser = .init(input, gpa, &decoded);
    defer p.deinit();
    while (true) {
        const e = try p.next();
        switch (e.kind) {
            .stream_start => try out.writeAll("+STR\n"),
            .stream_end => {
                try out.writeAll("-STR\n");
                return;
            },
            .document_start => try out.writeAll(if (e.explicit) "+DOC ---\n" else "+DOC\n"),
            .document_end => try out.writeAll(if (e.explicit) "-DOC ...\n" else "-DOC\n"),
            .sequence_start, .mapping_start => {
                try out.writeAll(if (e.kind == .sequence_start) "+SEQ" else "+MAP");
                if (e.flow) try out.writeAll(if (e.kind == .sequence_start) " []" else " {}");
                try properties(&p, e, out);
                try out.writeAll("\n");
            },
            .sequence_end => try out.writeAll("-SEQ\n"),
            .mapping_end => try out.writeAll("-MAP\n"),
            .alias => try out.print("=ALI *{s}\n", .{p.text(e.anchor)}),
            .scalar => {
                try out.writeAll("=VAL");
                try properties(&p, e, out);
                try out.writeAll(switch (e.style) {
                    .plain => " :",
                    .single_quoted => " '",
                    .double_quoted => " \"",
                    .literal => " |",
                    .folded => " >",
                });
                for (p.text(e.value)) |b| switch (b) {
                    '\\' => try out.writeAll("\\\\"),
                    8 => try out.writeAll("\\b"),
                    '\t' => try out.writeAll("\\t"),
                    '\n' => try out.writeAll("\\n"),
                    '\r' => try out.writeAll("\\r"),
                    else => try out.writeByte(b),
                };
                try out.writeAll("\n");
            },
        }
    }
}
fn properties(p: *const parser.Parser, e: parser.Event, out: *std.Io.Writer) !void {
    if (e.anchor.len > 0) try out.print(" &{s}", .{p.text(e.anchor)});
    if (e.tagged) try out.print(" <{s}>", .{p.text(e.tag)});
}

test "yaml-test-suite events" {
    const gpa = std.testing.allocator;
    // Every case the pinned data names: 308 valid, 94 invalid.
    try std.testing.expectEqual(402, cases.len);
    var failures: usize = 0;
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const result = events(gpa, case.yaml, &out.writer);
        if (case.invalid) {
            if (result) |_| {
                std.debug.print("{s} ({s}): invalid, and read\n", .{ case.path, case.name });
                failures += 1;
            } else |_| {}
            continue;
        }
        result catch |err| {
            std.debug.print("{s} ({s}): refused, {t}\n", .{ case.path, case.name, err });
            failures += 1;
            continue;
        };
        if (!std.mem.eql(u8, out.written(), case.events)) {
            std.debug.print("{s} ({s}): other events\n--- expected\n{s}--- read\n{s}", .{ case.path, case.name, case.events, out.written() });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

/// The JSON documents of a case: values one after another.
fn jsonDocuments(a: std.mem.Allocator, text: []const u8) ![]const json.Value {
    var found: std.ArrayList(json.Value) = .empty;
    var rest = text;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        if (rest.len == 0) break;
        const read = try @import("../json/api.zig").parsePrefixLeaky(json.Value, a, rest, .{});
        try found.append(a, read.value);
        rest = rest[read.end..];
    }
    return found.items;
}
/// Whether a YAML value is the value the case's JSON says.
fn matches(value: yaml.Value, expected: json.Value) bool {
    return switch (expected) {
        .null_value => value == .null,
        .boolean => |b| value == .boolean and value.boolean == b,
        .number => |lexeme| blk: {
            const want = std.fmt.parseFloat(f64, lexeme) catch break :blk false;
            break :blk switch (value) {
                .integer => |n| @as(f64, @floatFromInt(n)) == want,
                .float => |f| f == want,
                else => false,
            };
        },
        .string => |s| value == .string and std.mem.eql(u8, value.string, s),
        .array => |items| value == .sequence and value.sequence.len == items.len and for (items, value.sequence) |e, v| {
            if (!matches(v, e)) break false;
        } else true,
        .object => |members| value == .mapping and value.mapping.len == members.len and for (members) |m| {
            const v = value.field(m.key) orelse break false;
            if (!matches(v, m.value)) break false;
        } else true,
    };
}

/// The valid cases with JSON that hold a tag the core schema lacks: local
/// tags (`!foo`, `!e!foo`, `!<...>`) and YAML 1.1's `!!binary`, `!!set`,
/// `!!omap`. strand reads no application type from a tag (designs/strand.md
/// §9, S6c), so each is refused, as `UnsupportedValue`, rather than read with
/// its tag dropped; their events are read above like every other case's.
const tagged = [_][]const u8{ "2XXW", "565N", "5TYM", "6CK3", "6WLZ", "7FWL", "9WXW", "C4HZ", "CC74", "CUP7", "J7PZ", "M5C3", "P76L", "UGM3", "Z67P", "Z9M4" };

test "yaml-test-suite values and writing" {
    var failures: usize = 0;
    var read: usize = 0;
    var refused: usize = 0;
    for (cases) |case| {
        // An invalid case's JSON is what an older reading gave; the case is
        // refused above.
        if (case.invalid) continue;
        const expected_json = case.json orelse continue;
        const is_tagged = for (tagged) |path| {
            if (std.mem.eql(u8, path, case.path)) break true;
        } else false;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const expected = try jsonDocuments(a, expected_json);
        const documents = yaml.parseStreamLeaky(yaml.Value, a, case.yaml, .{}) catch |err| {
            if (is_tagged and err == error.UnsupportedValue) {
                refused += 1;
                continue;
            }
            std.debug.print("{s} ({s}): not read as values, {t}\n", .{ case.path, case.name, err });
            failures += 1;
            continue;
        };
        if (is_tagged) {
            std.debug.print("{s} ({s}): a tag the core schema lacks, and read\n", .{ case.path, case.name });
            failures += 1;
            continue;
        }
        read += 1;
        const same = documents.len == expected.len and for (documents, expected) |d, e| {
            if (!matches(d, e)) break false;
        } else true;
        if (!same) {
            std.debug.print("{s} ({s}): read as other values\n", .{ case.path, case.name });
            failures += 1;
            continue;
        }
        var out: std.Io.Writer.Allocating = .init(a);
        yaml.writeStream(&out.writer, documents, .{}) catch |err| {
            std.debug.print("{s} ({s}): not written, {t}\n", .{ case.path, case.name, err });
            failures += 1;
            continue;
        };
        const again = yaml.parseStreamLeaky(yaml.Value, a, out.written(), .{}) catch |err| {
            std.debug.print("{s} ({s}): written, and not read back, {t}:\n{s}\n", .{ case.path, case.name, err, out.written() });
            failures += 1;
            continue;
        };
        const back = again.len == documents.len and for (again, documents) |x, y| {
            if (!x.eql(y)) break false;
        } else true;
        if (!back) {
            std.debug.print("{s} ({s}): written, and read back as other values:\n{s}\n", .{ case.path, case.name, out.written() });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
    try std.testing.expectEqual(.{ 263, tagged.len }, .{ read, refused });
}
