//! Editing observations of strand's own: a commented TOML manifest, YAML
//! stack and JSONC settings file of about 4 KiB and 256 KiB, each opened,
//! one value set and the text taken, and a session of three edits (a value
//! set, a key added, an entry removed) and the text taken. Compilation and
//! smoke are correctness gates; timing is a manual run. `--inputs DIR`
//! writes the documents for the rivals' harnesses (bench/rivals/edit:
//! toml_edit, ruamel.yaml, jsonc-parser), which make the same edits to the
//! same bytes and write what they make; `--check DIR` reads what they wrote
//! as the value strand's session makes. The entries the edits change and
//! remove are named `mid` and `old` in every document, so a harness needs no
//! more than the file.
const std = @import("std");
const strand = @import("strand");
const toml = strand.toml;
const yaml = strand.yaml;
const jsonc = strand.json.jsonc;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const EditError = @typeInfo(@typeInfo(@TypeOf(toml.Edit.init)).@"fn".return_type.?).error_union.error_set;
const WorkError = EditError || error{ OutOfMemory, PolicyMismatch };

const Format = enum { toml, yaml, jsonc };
const sizes = [_]struct { name: []const u8, bytes: usize }{ .{ .name = "4k", .bytes = 4 << 10 }, .{ .name = "256k", .bytes = 256 << 10 } };
/// Each format's documents, by size.
const Context = struct {
    gpa: std.mem.Allocator,
    docs: [3][sizes.len][]u8,
};

/// Entry `i` of `count`'s key: the two the edits name, else `e` and its number.
fn key(buffer: *[6]u8, i: usize, count: usize) []const u8 {
    if (i == count / 2) return "mid";
    if (i == count / 2 + 1) return "old";
    var w = std.Io.Writer.fixed(buffer);
    // unreachable: under 100,000 entries, `e99999` is six bytes.
    w.print("e{d}", .{i}) catch unreachable;
    return w.buffered();
}

fn write(format: Format, w: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
    var b: [6]u8 = undefined;
    switch (format) {
        .toml => {
            try w.writeAll("# The service's manifest.\n[package]\nname = \"relay\"\nversion = \"0.1.0\" # bumped by the release\nedition = \"2024\"\n\n[dependencies]\n# Pinned for the wire format.\n");
            for (0..count) |i| {
                if (i % 3 == 0) {
                    try w.print("{s} = {{ version = \"1.{d}.0\", features = [\"std\", \"serde\"] }} # with features\n", .{ key(&b, i, count), i });
                } else {
                    try w.print("{s} = \"0.{d}.{d}\"\n", .{ key(&b, i, count), i, i % 7 });
                }
            }
            try w.writeAll("\n[profile.release]\n# Smaller and slower to build.\nlto = true\ncodegen-units = 1\n");
        },
        .yaml => {
            try w.writeAll("# The stack's services.\nversion: \"3.9\"\nservices:\n");
            for (0..count) |i| {
                const k = key(&b, i, count);
                try w.print("  {s}:\n    image: registry.example/{s}:1.{d} # pinned\n    replicas: {d}\n    ports: [{d}, {d}]\n    env:\n      LEVEL: info\n", .{ k, k, i, i % 4 + 1, 8000 + i % 1000, 9000 + i % 1000 });
            }
            try w.writeAll("# The end.\n");
        },
        .jsonc => {
            try w.writeAll("// The editor's settings.\n{\n  \"editor.fontSize\": 14, // points\n  \"items\": {\n");
            for (0..count) |i| {
                if (i > 0) try w.writeAll(",\n");
                if (i % 10 == 0) try w.writeAll("    // A group of ten.\n");
                try w.print("    \"{s}\": {{ \"enabled\": {}, \"level\": {d}, \"tags\": [\"a\", \"b\"] }}", .{ key(&b, i, count), i % 2 == 0, i % 5 });
            }
            try w.writeAll("\n  }\n}\n");
        },
    }
}
/// A document of `format` of about `bytes`.
fn document(gpa: std.mem.Allocator, format: Format, bytes: usize) ![]u8 {
    var empty: std.Io.Writer.Discarding = .init(&.{});
    try write(format, &empty.writer, 0);
    const frame = empty.fullCount();
    var hundred: std.Io.Writer.Discarding = .init(&.{});
    try write(format, &hundred.writer, 100);
    const each = (hundred.fullCount() - frame) / 100;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(format, &out.writer, @max(4, (bytes -| frame) / each));
    return out.toOwnedSlice();
}

fn EditOf(comptime format: Format) type {
    return switch (format) {
        .toml => toml.Edit,
        .yaml => yaml.Edit,
        .jsonc => jsonc.Edit,
    };
}
/// The one value set: the version, the middle service's replicas, the
/// middle item's level.
fn setOne(comptime format: Format, e: *EditOf(format)) WorkError!void {
    switch (format) {
        .toml => try e.set("/package/version", "0.2.0"),
        .yaml => try e.set("/services/mid/replicas", @as(u8, 5)),
        .jsonc => try e.set("/items/mid/level", @as(u8, 5)),
    }
}
/// The session: that set, a key added, an entry removed.
fn session(comptime format: Format, e: *EditOf(format)) WorkError!void {
    try setOne(format, e);
    switch (format) {
        .toml => {
            try e.set("/dependencies/zeta", "2.0.0");
            try e.remove("/dependencies/old");
        },
        .yaml => {
            try e.set("/services/mid/env/TRACE", "on");
            try e.remove("/services/old");
        },
        .jsonc => {
            try e.set("/items/mid/note", "new");
            try e.remove("/items/old");
        },
    }
}

fn Rows(comptime format: Format, comptime size: usize) type {
    const E = EditOf(format);
    return struct {
        const suffix = sizes[size].name ++ "." ++ @tagName(format);
        fn source(c: *Context) []const u8 {
            return c.docs[@backingInt(format)][size];
        }
        fn open(c: *Context, units: u64) WorkError!void {
            var sum: usize = 0;
            for (0..units) |_| {
                var e = try E.init(c.gpa, source(c), .{});
                defer e.deinit();
                sum +%= e.bytes().len;
            }
            std.mem.doNotOptimizeAway(sum);
        }
        fn set(c: *Context, units: u64) WorkError!void {
            var sum: usize = 0;
            for (0..units) |_| {
                var e = try E.init(c.gpa, source(c), .{});
                defer e.deinit();
                try setOne(format, &e);
                sum +%= e.bytes().len;
            }
            std.mem.doNotOptimizeAway(sum);
        }
        fn edits(c: *Context, units: u64) WorkError!void {
            var sum: usize = 0;
            for (0..units) |_| {
                var e = try E.init(c.gpa, source(c), .{});
                defer e.deinit();
                try session(format, &e);
                sum +%= e.bytes().len;
            }
            std.mem.doNotOptimizeAway(sum);
        }
        /// The session's text, on `gpa`.
        fn made(c: *Context) WorkError![]u8 {
            var e = try E.init(c.gpa, source(c), .{});
            defer e.deinit();
            try session(format, &e);
            return c.gpa.dupe(u8, e.bytes());
        }
        const rows = [_]shakedown.bench.Row(Context, WorkError){
            .{ .name = "edit." ++ @tagName(format) ++ ".open." ++ sizes[size].name, .unit = "document", .initial = 1, .run = open },
            .{ .name = "edit." ++ @tagName(format) ++ ".set." ++ sizes[size].name, .unit = "document", .initial = 1, .run = set },
            .{ .name = "edit." ++ @tagName(format) ++ ".session." ++ sizes[size].name, .unit = "document", .initial = 1, .run = edits },
        };
    };
}
const all = .{ Rows(.toml, 0), Rows(.toml, 1), Rows(.yaml, 0), Rows(.yaml, 1), Rows(.jsonc, 0), Rows(.jsonc, 1) };

/// Whether `other` reads as the value `made` reads as, in `format`.
fn same(format: Format, a: std.mem.Allocator, made: []const u8, other: []const u8) !bool {
    return switch (format) {
        .toml => (try toml.parseLeaky(toml.Value, a, made, .{})).eql(try toml.parseLeaky(toml.Value, a, other, .{})),
        .yaml => (try yaml.parseLeaky(yaml.Value, a, made, .{})).eql(try yaml.parseLeaky(yaml.Value, a, other, .{})),
        .jsonc => jsonEql(try jsonc.parseLeaky(strand.json.Value, a, made, .{}), try jsonc.parseLeaky(strand.json.Value, a, other, .{})),
    };
}
/// JSON values equal, an object's members in any order.
fn jsonEql(x: strand.json.Value, y: strand.json.Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null_value => true,
        .boolean => |b| b == y.boolean,
        .number => |n| std.mem.eql(u8, n, y.number),
        .string => |t| std.mem.eql(u8, t, y.string),
        .array => |items| items.len == y.array.len and for (items, y.array) |i, j| {
            if (!jsonEql(i, j)) break false;
        } else true,
        .object => |members| members.len == y.object.len and for (members) |m| {
            const found = for (y.object) |n| {
                if (std.mem.eql(u8, m.key, n.key)) break jsonEql(m.value, n.value);
            } else false;
            if (!found) break false;
        } else true,
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var c: Context = .{ .gpa = init.gpa, .docs = undefined };
    for (&c.docs, 0..) |*by_size, f| for (by_size, sizes) |*doc, size| {
        doc.* = try document(c.gpa, @fromBackingInt(@intCast(f)), if (smoke) 256 else size.bytes);
    };
    defer for (c.docs) |by_size| for (by_size) |doc| c.gpa.free(doc);

    if (args.len > 2 and std.mem.eql(u8, args[1], "--inputs")) {
        var dir = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
        defer dir.close(init.io);
        inline for (all) |R| {
            try dir.writeFile(init.io, .{ .sub_path = "input-" ++ R.suffix, .data = R.source(&c) });
            // What strand's session makes, for comparing by eye.
            const made = try R.made(&c);
            defer c.gpa.free(made);
            try dir.writeFile(init.io, .{ .sub_path = "strand-" ++ R.suffix, .data = made });
        }
        return;
    }
    if (args.len > 2 and std.mem.eql(u8, args[1], "--check")) {
        // Each rival's session (`NAME-SIZE.FORMAT`) read as the value
        // strand's makes.
        var dir = try std.Io.Dir.cwd().openDir(init.io, args[2], .{ .iterate = true });
        defer dir.close(init.io);
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var it = dir.iterate();
        var checked: usize = 0;
        while (try it.next(init.io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "input-") or std.mem.startsWith(u8, entry.name, "strand-")) continue;
            inline for (all, 0..) |R, i| if (std.mem.endsWith(u8, entry.name, "-" ++ R.suffix)) {
                const made = try R.made(&c);
                defer c.gpa.free(made);
                const other = try dir.readFileAlloc(init.io, entry.name, arena.allocator(), .limited(16 << 20));
                if (!try same(@fromBackingInt(@intCast(i / sizes.len)), arena.allocator(), made, other)) {
                    std.log.err("{s}: not the value strand's session makes", .{entry.name});
                    return error.PolicyMismatch;
                }
                std.log.info("{s}: read as the value strand's session makes", .{entry.name});
                checked += 1;
            };
        }
        if (checked == 0) return error.PolicyMismatch;
        return;
    }
    // Each session changes its document.
    inline for (all) |R| {
        const made = try R.made(&c);
        defer c.gpa.free(made);
        if (std.mem.eql(u8, made, R.source(&c))) return error.PolicyMismatch;
    }
    const rows = Rows(.toml, 0).rows ++ Rows(.toml, 1).rows ++ Rows(.yaml, 0).rows ++ Rows(.yaml, 1).rows ++ Rows(.jsonc, 0).rows ++ Rows(.jsonc, 1).rows;
    // `--row NAME` runs that row alone, for a profiler.
    var chosen: []const shakedown.bench.Row(Context, WorkError) = &rows;
    if (args.len > 2 and std.mem.eql(u8, args[1], "--row")) {
        for (&rows) |*r| if (std.mem.eql(u8, r.name, args[2])) {
            chosen = r[0..1];
        };
    }
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, chosen, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
