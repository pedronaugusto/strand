//! The JSON-Schema-Test-Suite's validation tests for draft-07, 2019-09 and
//! 2020-12: every case whose `compatibility` admits the draft, its schema
//! compiled in that draft with its `externalSchemas` served by a loader, and
//! each instance's verdict checked. Cases tagged `format-assertion` wait for
//! formats. A case whose schema uses a keyword this build does not evaluate
//! yet is counted as pending, never passed; every other case must pass, and
//! no schema the suite gives may fail to compile (a `ReferenceCycle` among
//! them would be the compiler refusing a schema the suite calls valid). The
//! suite is fetched by the build, for the tests alone.
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

const Tally = struct { passed: usize = 0, pending: usize = 0, failed: usize = 0 };

fn runDraft(d: Dialect, files: []const suite.File, tally: *Tally) !void {
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
            if (member(fields, "tags")) |tags| if (for (tags.array) |t| {
                if (std.mem.eql(u8, t.string, "format-assertion")) break true;
            } else false) continue;
            const description = member(fields, "description").?.string;
            var loader: CaseLoader = .{ .arena = a };
            if (member(fields, "externalSchemas")) |external| loader.schemas = external.object;
            var diagnostic: Schema.Diagnostic = .{};
            const schema_text = try text(a, member(fields, "schema").?);
            var schema = Schema.compile(gpa, std.testing.io, strand.json, .init(schema_text), .{ .dialect = d, .loader = &loader.loader, .diagnostics = &diagnostic }) catch |err| {
                std.debug.print("{s} {s} \"{s}\": compile {s} at {s}\n", .{ @tagName(d), file.name, description, @errorName(err), diagnostic.location() });
                tally.failed += 1;
                continue;
            };
            defer schema.deinit();
            for (member(fields, "tests").?.array) |t| {
                const instance = try text(a, member(t.object, "data").?);
                const expected = member(t.object, "valid").?.boolean;
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                const valid = schema.validate(std.testing.io, scratch.allocator(), strand.json, .init(instance), .flag) catch |err| {
                    if (err == error.Unsupported) {
                        tally.pending += 1;
                        continue;
                    }
                    std.debug.print("{s} {s} \"{s}\" / \"{s}\": {s}\n", .{ @tagName(d), file.name, description, member(t.object, "description").?.string, @errorName(err) });
                    tally.failed += 1;
                    continue;
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
    for ([_]Dialect{ .draft7, .draft2019_09, .draft2020_12 }) |d| {
        var tally: Tally = .{};
        try runDraft(d, files, &tally);
        std.debug.print("{s}: {d} passed, {d} pending, {d} failed\n", .{ @tagName(d), tally.passed, tally.pending, tally.failed });
        failed += tally.failed;
    }
    try std.testing.expectEqual(0, failed);
}
