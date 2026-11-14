//! The JSON-Schema-Test-Suite's validation tests for draft-07, 2019-09 and
//! 2020-12: every case whose `compatibility` admits the draft, its schema
//! compiled in that draft with its `externalSchemas` served by a loader, and
//! each instance's verdict checked; once with formats annotated (cases
//! tagged `format-assertion` aside) and once with them asserted (the cases
//! so tagged). Every required case must pass, and no schema the suite gives
//! may fail to compile (a `ReferenceCycle` among them would be the compiler
//! refusing a schema the suite calls valid). A pattern spectra cannot run
//! in linear time is refused under `.refuse` only where `unrunnable` names
//! the case, and under `.downgrade` its validations say they passed a
//! downgraded keyword. `optional/` runs too; the optional cases strand does
//! not pass are named in `skipped` with their reasons. The suite is fetched by
//! the build, for the tests alone.
const std = @import("std");
const strand = @import("strand");
const suite = @import("json_schema_suite");
const Schema = @import("Schema.zig");
const Loader = @import("Loader.zig");
const Dialect = @import("dialect.zig").Dialect;

const Value = strand.json.Value;
const Member = strand.core.Pair([]const u8, Value);

/// The release number the suite's `compatibility` gives each draft.
fn release(d: Dialect) u32 {
    return switch (d) {
        .draft7 => 7,
        .draft2019_09 => 2019,
        .draft2020_12 => 2020,
    };
}

/// The suite's own matching: each constraint read in order, the last one at
/// or above the release deciding.
fn compatible(spec: []const u8, version: u32) bool {
    var valid = true;
    var constraints = std.mem.splitScalar(u8, spec, ',');
    while (constraints.next()) |raw| {
        const c = std.mem.trim(u8, raw, " ");
        const op: enum { at_least, at_most, exactly }, const number = if (std.mem.startsWith(u8, c, "<="))
            .{ .at_most, c[2..] }
        else if (std.mem.startsWith(u8, c, "="))
            .{ .exactly, c[1..] }
        else
            .{ .at_least, c };
        const n = std.fmt.parseInt(u32, number, 10) catch return false;
        valid = switch (op) {
            .at_least => version >= n,
            .at_most => version <= n,
            .exactly => version == n,
        };
        if (version <= n) break;
    }
    return valid;
}

test "the suite's compatibility matching" {
    try std.testing.expect(compatible("7", 2020));
    try std.testing.expect(!compatible("2019", 7));
    try std.testing.expect(compatible("<=2019", 7));
    try std.testing.expect(!compatible("<=2019", 2020));
    try std.testing.expect(compatible("6,<=7", 7));
    try std.testing.expect(!compatible("6,<=7", 2019));
    try std.testing.expect(compatible("=3,7,<=2020", 2019));
    try std.testing.expect(!compatible("=2020", 2019));
    try std.testing.expect(compatible("<=3,7", 2020));
    try std.testing.expect(!compatible("9999", 2020));
}

/// A loader over one case's `externalSchemas`.
const CaseLoader = struct {
    loader: Loader = .{ .vtable = &.{ .load = load } },
    schemas: []const Member = &.{},
    arena: std.mem.Allocator,

    fn load(l: *Loader, gpa: std.mem.Allocator, io: std.Io, uri: []const u8) Loader.LoadError![]const u8 {
        _ = io;
        const self: *CaseLoader = @fieldParentPtr("loader", l);
        for (self.schemas) |m| if (std.mem.eql(u8, m.key, uri)) {
            return text(gpa, m.value) catch return error.OutOfMemory;
        };
        return error.NotFound;
    }
};

fn text(gpa: std.mem.Allocator, value: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try strand.json.write(&out.writer, value, .{});
    return out.toOwnedSlice();
}

fn member(members: []const Member, name: []const u8) ?Value {
    for (members) |m| if (std.mem.eql(u8, m.key, name)) return m.value;
    return null;
}

const Tally = struct {
    passed: usize = 0,
    refused: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    /// Instances rewritten as YAML and as TOML, each giving the verdict JSON
    /// gives; those TOML cannot spell (a null, a root that is no table, a
    /// number past its range) are not rewritten.
    yaml: usize = 0,
    toml: usize = 0,
};

/// `value` as a YAML document in block style, its strings and keys double
/// quoted with JSON's escapes, which YAML's double-quoted style reads.
fn yamlText(gpa: std.mem.Allocator, value: Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try yamlValue(&out.writer, value, 0);
    try out.writer.writeByte('\n');
    return out.written();
}

fn yamlValue(w: *std.Io.Writer, value: Value, indent: usize) !void {
    switch (value) {
        .array => |items| {
            if (items.len == 0) return w.writeAll("[]");
            for (items, 0..) |item, i| {
                if (i > 0 or indent > 0) {
                    try w.writeByte('\n');
                    try w.splatByteAll(' ', indent);
                }
                try w.writeAll("- ");
                try yamlValue(w, item, indent + 2);
            }
        },
        .object => |members| {
            if (members.len == 0) return w.writeAll("{}");
            for (members, 0..) |m, i| {
                if (i > 0 or indent > 0) {
                    try w.writeByte('\n');
                    try w.splatByteAll(' ', indent);
                }
                try strand.json.write(w, Value{ .string = m.key }, .{});
                try w.writeAll(": ");
                try yamlValue(w, m.value, indent + 2);
            }
        },
        else => try strand.json.write(w, value, .{}),
    }
}

/// `value` as a TOML document: a table, its tables inline, its strings
/// basic. Null where TOML cannot spell it: a null, a root that is no table,
/// an integer past 64 bits, a number past a double's range.
fn tomlText(gpa: std.mem.Allocator, value: Value) !?[]const u8 {
    if (value != .object) return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    for (value.object) |m| {
        try strand.json.write(&out.writer, Value{ .string = m.key }, .{});
        try out.writer.writeAll(" = ");
        if (!try tomlValue(&out.writer, m.value)) return null;
        try out.writer.writeByte('\n');
    }
    return out.written();
}

fn tomlValue(w: *std.Io.Writer, value: Value) !bool {
    switch (value) {
        .null_value => return false,
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| {
            const integer = std.mem.findAny(u8, n, ".eE") == null;
            if (integer) {
                _ = std.fmt.parseInt(i64, n, 10) catch return false;
                try w.writeAll(if (std.mem.eql(u8, n, "-0")) "0" else n);
            } else {
                const f = std.fmt.parseFloat(f64, n) catch return false;
                if (!std.math.isFinite(f)) return false;
                // TOML's float wants a digit each side of a point.
                try w.print("{e}", .{f});
            }
        },
        .string => |t| {
            // TOML's basic strings take JSON's escapes but `\/`.
            try w.writeByte('"');
            for (t) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                0...0x1F, 0x7F => try w.print("\\u{X:0>4}", .{c}),
                else => try w.writeByte(c),
            };
            try w.writeByte('"');
        },
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                if (!try tomlValue(w, item)) return false;
            }
            try w.writeByte(']');
        },
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeAll(", ");
                try strand.json.write(w, Value{ .string = m.key }, .{});
                try w.writeAll(" = ");
                if (!try tomlValue(w, m.value)) return false;
            }
            try w.writeByte('}');
        },
    }
    return true;
}

/// Patterns spectra refuses to run, by file and case: a backreference or a
/// lookbehind ECMA-262 has and linear time does not.
const unrunnable = [_][2][]const u8{};

/// Cases strand does not pass, each optional (an `optional/` file, or a
/// format asserted, which no draft here requires): the file, the case (empty
/// for every case in it), the drafts by release (empty for all), and why.
const skipped = [_][4][]const u8{
    .{ "optional/dependencies-compatibility.json", "", "2019,2020", "`dependencies` is draft-07's: 2019-09 and 2020-12 replaced it with `dependentRequired` and `dependentSchemas`, which strand reads" },
    .{ "optional/content.json", "", "7", "`contentEncoding` and `contentMediaType` are annotations: strand decodes no content" },
} ++ uts46;

/// Asserted `idn-hostname` and `idn-email` cases that map a name by UTS #46
/// (width, zero width characters, normalization) before IDNA2008's checks:
/// strand checks IDNA2008 as written, mapping nothing.
const uts46 = [_][4][]const u8{
    .{ "format-idn-hostname.json", "fullwidth digits are mapped to ASCII digits", "", uts46_reason },
    .{ "format-idn-hostname.json", "an ACE prefix produced by the mapping step is decoded as an A-label", "", uts46_reason },
    .{ "format-idn-hostname.json", "a zero width space is ignored by the mapping", "", uts46_reason },
    .{ "format-idn-hostname.json", "a non-NFC U-label is valid after UTS 46 normalisation", "", uts46_reason },
    .{ "format-idn-hostname.json", "a label of 63 fullwidth characters is valid after mapping", "", uts46_reason },
    .{ "format-idn-email.json", "a domain label that is not in Unicode NFC is valid", "", uts46_reason },
};
const uts46_reason = "UTS #46 maps user input to a candidate name; whether a string is a valid name is IDNA2008's question (RFC 5890 to 5893, which 2019-09 and 2020-12 cite), and fullwidth digits and labels not in NFC are not valid U-labels";

fn listed(list: anytype, file: []const u8, description: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry[0], file) and std.mem.eql(u8, entry[1], description)) return true;
    return false;
}

/// Whether `skipped` names the case, or the test in it, in draft `d`.
fn skippedIn(d: Dialect, file: []const u8, case: []const u8, test_description: []const u8) bool {
    for (skipped) |entry| {
        if (!std.mem.eql(u8, entry[0], file)) continue;
        if (entry[1].len > 0 and !std.mem.eql(u8, entry[1], case) and !std.mem.eql(u8, entry[1], test_description)) continue;
        if (entry[2].len == 0) return true;
        var drafts = std.mem.splitScalar(u8, entry[2], ',');
        while (drafts.next()) |r| if ((std.fmt.parseInt(u32, r, 10) catch 0) == release(d)) return true;
    }
    return false;
}

const Mode = enum { annotate, assert };

fn runDraft(d: Dialect, mode: Mode, files: []const suite.File, tally: *Tally) !void {
    const gpa = std.testing.allocator;
    for (files) |file| {
        var state: std.heap.ArenaAllocator = .init(gpa);
        defer state.deinit();
        const a = state.allocator();
        const document = try strand.json.parseLeaky(Value, a, file.text, .{ .limits = .sized(file.text.len) });
        const cases = member(document.object, "tests").?.array;
        for (cases) |case| {
            const fields = case.object;
            if (member(fields, "compatibility")) |c| if (!compatible(c.string, release(d))) continue;
            const asserting = if (member(fields, "tags")) |tags| for (tags.array) |t| {
                if (std.mem.eql(u8, t.string, "format-assertion")) break true;
            } else false else false;
            if (asserting != (mode == .assert)) continue;
            const description = member(fields, "description").?.string;
            if (skippedIn(d, file.name, description, "")) {
                tally.skipped += 1;
                continue;
            }
            var loader: CaseLoader = .{ .arena = a };
            if (member(fields, "externalSchemas")) |external| loader.schemas = external.object;
            var diagnostic: Schema.Diagnostic = .{};
            const schema_text = try text(a, member(fields, "schema").?);
            const formats: @FieldType(Schema.Options, "formats") = if (mode == .assert) .assert else .annotate;
            var downgrading = false;
            var schema = Schema.compile(gpa, std.testing.io, strand.json, .init(schema_text), .{ .dialect = d, .loader = &loader.loader, .diagnostics = &diagnostic, .formats = formats }) catch |err| retry: {
                if (err == error.UnsupportedPattern and listed(unrunnable, file.name, description)) {
                    // Refused, as named; under `.downgrade` it compiles and
                    // says so.
                    tally.refused += 1;
                    downgrading = true;
                    break :retry try Schema.compile(gpa, std.testing.io, strand.json, .init(schema_text), .{ .dialect = d, .loader = &loader.loader, .formats = formats, .unsupported_pattern = .downgrade });
                }
                std.debug.print("{s} {s} \"{s}\": compile {s} at {s}\n", .{ @tagName(d), file.name, description, @errorName(err), diagnostic.location() });
                tally.failed += 1;
                continue;
            };
            defer schema.deinit();
            if (downgrading) {
                for (member(fields, "tests").?.array) |t| {
                    const instance = try text(a, member(t.object, "data").?);
                    var scratch: std.heap.ArenaAllocator = .init(gpa);
                    defer scratch.deinit();
                    var report: Schema.Report = .{};
                    _ = try schema.validate(std.testing.io, scratch.allocator(), strand.json, .init(instance), .{ .flag = &report });
                    if (report.downgraded.len == 0) {
                        std.debug.print("{s} {s} \"{s}\": a downgraded pattern's validation did not say so\n", .{ @tagName(d), file.name, description });
                        tally.failed += 1;
                    }
                }
                continue;
            }
            for (member(fields, "tests").?.array) |t| {
                if (skippedIn(d, file.name, "\x00", member(t.object, "description").?.string)) {
                    tally.skipped += 1;
                    continue;
                }
                const instance = try text(a, member(t.object, "data").?);
                const expected = member(t.object, "valid").?.boolean;
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                const valid = schema.validate(std.testing.io, scratch.allocator(), strand.json, .init(instance), .{ .flag = null }) catch |err| {
                    std.debug.print("{s} {s} \"{s}\" / \"{s}\": {s}\n", .{ @tagName(d), file.name, description, member(t.object, "description").?.string, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                // The same instance as YAML and as TOML: the same verdict.
                if (mode == .annotate) inline for (.{ strand.yaml, strand.toml }, .{ "yaml", "toml" }) |Format, name| {
                    const data = member(t.object, "data").?;
                    const spelled: ?[]const u8 = if (Format == strand.yaml) try yamlText(scratch.allocator(), data) else try tomlText(scratch.allocator(), data);
                    if (spelled) |other| {
                        const again = schema.validate(std.testing.io, scratch.allocator(), Format, .init(other), .{ .flag = null }) catch |err| blk: {
                            std.debug.print("{s} {s} \"{s}\" / \"{s}\" as {s}: {s}\n{s}\n", .{ @tagName(d), file.name, description, member(t.object, "description").?.string, name, @errorName(err), other });
                            tally.failed += 1;
                            break :blk expected;
                        };
                        if (again != expected) {
                            std.debug.print("{s} {s} \"{s}\" / \"{s}\" as {s}: expected {}, got {}\n{s}\n", .{ @tagName(d), file.name, description, member(t.object, "description").?.string, name, expected, again, other });
                            tally.failed += 1;
                        } else @field(tally, name) += 1;
                    }
                };
                if (valid == expected) {
                    tally.passed += 1;
                } else {
                    std.debug.print("{s} {s} \"{s}\" / \"{s}\": expected {}, got {}\n", .{ @tagName(d), file.name, description, member(t.object, "description").?.string, expected, valid });
                    tally.failed += 1;
                }
            }
        }
    }
}

test "the JSON-Schema-Test-Suite, draft-07, 2019-09 and 2020-12" {
    // The build fetches the suite unless it runs without its lazy
    // dependencies.
    const files = suite.files orelse return error.SkipZigTest;
    var failed: usize = 0;
    for ([_]Dialect{ .draft7, .draft2019_09, .draft2020_12 }) |d| for ([_]Mode{ .annotate, .assert }) |mode| {
        var tally: Tally = .{};
        try runDraft(d, mode, files, &tally);
        std.debug.print("{s} formats {s}: {d} passed, {d} refused as named, {d} skipped as named, {d} failed; {d} as YAML, {d} as TOML\n", .{ @tagName(d), @tagName(mode), tally.passed, tally.refused, tally.skipped, tally.failed, tally.yaml, tally.toml });
        failed += tally.failed;
    };
    try std.testing.expectEqual(0, failed);
}
