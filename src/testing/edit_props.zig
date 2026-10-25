//! Editing held to each format's suite: in every valid document of
//! toml-test (1.1.0), yaml-test-suite and JSONTestSuite (and the
//! yaml-test-suite's JSON, as JSONC), each leaf set to 7 reads back as the
//! document's value with that leaf 7, and each member removed as the value
//! without it; and the text a set changes holds no comment line, so the
//! comments around a value stay (a quoted or block scalar replaced may
//! hold lines like comments, and is not held to this). In YAML a value an alias repeats changes
//! where the alias is too, and a node replaced takes its anchor: there an
//! edit may be refused, and what it makes is held only to reading back.
const std = @import("std");
const json = @import("../json.zig");
const toml = @import("../toml.zig");
const yaml = @import("../yaml.zig");
const toml_suite = @import("toml_suite.zig");
const yaml_suite = @import("yaml_suite.zig");
const json_suite = @import("json_suite.zig");
const shakedown = @import("shakedown");

const gpa = std.testing.allocator;
/// Paths tried in one document, of each kind.
const per_document = 64;

/// Paths into and changes to values of type `V`, whose sequences are its
/// `seq` arm and mappings its `map` arm.
fn Model(comptime V: type, comptime seq: []const u8, comptime map: []const u8) type {
    return struct {
        const Tag = std.meta.Tag(V);
        const Entry = @typeInfo(@FieldType(V, map)).pointer.child;

        fn isSeq(v: V) bool {
            return std.meta.activeTag(v) == @field(Tag, seq);
        }
        fn isMap(v: V) bool {
            return std.meta.activeTag(v) == @field(Tag, map);
        }
        fn keyText(e: Entry) ?[]const u8 {
            if (@TypeOf(e.key) == []const u8) return e.key;
            return switch (e.key) {
                .string => |s| s,
                else => null,
            };
        }
        /// Whether a pointer token names entry `e` of `entries` alone: its
        /// key is a string no other key is spelled as.
        fn addressable(entries: []const Entry, e: Entry) bool {
            const k = keyText(e) orelse return false;
            var seen: usize = 0;
            for (entries) |other| {
                const o = keyText(other) orelse return false;
                if (std.mem.eql(u8, o, k)) seen += 1;
            }
            return seen == 1;
        }
        /// Every path to a leaf, and to a member of a collection.
        fn paths(a: std.mem.Allocator, v: V, prefix: []const u8, leaves: *std.ArrayList([]const u8), members: *std.ArrayList([]const u8)) !void {
            if (isSeq(v)) {
                for (@field(v, seq), 0..) |x, i| {
                    var buffer: [24]u8 = undefined;
                    const p = try std.mem.concat(a, u8, &.{ prefix, "/", try std.mem.print(&buffer, "{d}", .{i}) });
                    try members.append(a, p);
                    try paths(a, x, p, leaves, members);
                }
            } else if (isMap(v)) {
                const entries = @field(v, map);
                for (entries) |e| {
                    if (!addressable(entries, e)) continue;
                    const p = try std.mem.concat(a, u8, &.{ prefix, "/", try escape(a, keyText(e).?) });
                    try members.append(a, p);
                    try paths(a, @field(e, "value"), p, leaves, members);
                }
            } else try leaves.append(a, prefix);
        }
        /// `v` with the value at `tokens` made `new`, or taken out for null.
        fn changed(a: std.mem.Allocator, v: V, tokens: []const []const u8, new: ?V) !V {
            if (tokens.len == 0) return new.?;
            if (isSeq(v)) {
                const items = @field(v, seq);
                const i = try std.fmt.parseInt(usize, tokens[0], 10);
                if (tokens.len == 1 and new == null) return @unionInit(V, seq, try std.mem.concat(a, V, &.{ items[0..i], items[i + 1 ..] }));
                const copy = try a.dupe(V, items);
                copy[i] = try changed(a, items[i], tokens[1..], new);
                return @unionInit(V, seq, copy);
            }
            const entries = @field(v, map);
            const i = for (entries, 0..) |e, k| {
                if (keyText(e)) |text| if (std.mem.eql(u8, text, tokens[0])) break k;
            } else return error.TestUnexpectedResult;
            if (tokens.len == 1 and new == null) return @unionInit(V, map, try std.mem.concat(a, Entry, &.{ entries[0..i], entries[i + 1 ..] }));
            const copy = try a.dupe(Entry, entries);
            @field(copy[i], "value") = try changed(a, @field(entries[i], "value"), tokens[1..], new);
            return @unionInit(V, map, copy);
        }
    };
}

/// The value `x` is the value `y` is: floats by value, NaN as NaN.
fn eql(x: anytype, y: @TypeOf(x)) bool {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .@"union" => {
            if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
            switch (x) {
                inline else => |payload, tag| return eql(payload, @field(y, @tagName(tag))),
            }
        },
        .@"struct" => |s| {
            inline for (s.field_names) |f| if (!eql(@field(x, f), @field(y, f))) return false;
            return true;
        },
        .pointer => |p| {
            if (p.size != .slice) return eql(x.*, y.*);
            if (x.len != y.len) return false;
            if (comptime @typeInfo(p.child) == .@"struct" and @hasField(p.child, "key")) {
                // A mapping's entries, in any order: a re-made TOML table
                // goes at its parent's end.
                for (x) |a| {
                    for (y) |b| {
                        if (eql(a.key, b.key)) {
                            if (!eql(a.value, b.value)) return false;
                            break;
                        }
                    } else return false;
                }
                return true;
            }
            for (x, y) |a, b| if (!eql(a, b)) return false;
            return true;
        },
        .float => return x == y or (std.math.isNan(x) and std.math.isNan(y)),
        .void => return true,
        else => return x == y,
    }
}

fn escape(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key) |b| switch (b) {
        '~' => try out.appendSlice(a, "~0"),
        '/' => try out.appendSlice(a, "~1"),
        else => try out.append(a, b),
    };
    return out.items;
}
fn tokensOf(a: std.mem.Allocator, pointer: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (pointer.len == 0) return list.items;
    var parts = std.mem.splitScalar(u8, pointer[1..], '/');
    while (parts.next()) |part| {
        const out = try a.alloc(u8, part.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < part.len) : (n += 1) {
            if (part[i] == '~') {
                out[n] = if (part[i + 1] == '0') '~' else '/';
                i += 2;
            } else {
                out[n] = part[i];
                i += 1;
            }
        }
        try list.append(a, out[0..n]);
    }
    return list.items;
}

/// Whether the bytes a change replaced in `before` hold a line that is a
/// comment: none where they hold a quoted or block scalar.
fn commentChanged(before: []const u8, after: []const u8, marker: []const u8) bool {
    var p: usize = 0;
    while (p < before.len and p < after.len and before[p] == after[p]) p += 1;
    var q: usize = 0;
    while (q < before.len - p and q < after.len - p and before[before.len - 1 - q] == after[after.len - 1 - q]) q += 1;
    const region = before[p .. before.len - q];
    // A quoted or block scalar may hold a line like a comment.
    if (std.mem.findAny(u8, region, "\"'|>") != null) return false;
    var lines = std.mem.splitScalar(u8, region, '\n');
    _ = lines.next(); // The first is the changed value's own line.
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), marker)) return true;
    }
    return false;
}

const Tally = struct { documents: usize = 0, sets: usize = 0, removes: usize = 0, refused: usize = 0, failures: usize = 0 };

/// The property over one document of format `F`. An edit refused leaves
/// the text as it was.
fn property(comptime F: type, name: []const u8, text: []const u8, tally: *Tally) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const old = F.read(a, text) catch return;
    var editor = F.Edit.init(gpa, text, .{}) catch |err| {
        std.log.err("{s}: {s} not edited: {t}", .{ F.name, name, err });
        tally.failures += 1;
        return;
    };
    editor.deinit();
    tally.documents += 1;
    var leaves: std.ArrayList([]const u8) = .empty;
    var members: std.ArrayList([]const u8) = .empty;
    try F.M.paths(a, old, "", &leaves, &members);
    const aliases = F.aliases(text);
    for (leaves.items[0..@min(leaves.items.len, per_document)]) |path| {
        var e = try F.Edit.init(gpa, text, .{});
        defer e.deinit();
        e.set(path, @as(u8, 7)) catch |err| {
            if (!std.mem.eql(u8, e.bytes(), text)) {
                std.log.err("{s}: {s} set {s}: refused ({t}), the text changed", .{ F.name, name, path, err });
                tally.failures += 1;
                continue;
            }
            if (aliases and (err == error.SyntaxError or err == error.PathNotFound)) {
                tally.refused += 1;
                continue;
            }
            std.log.err("{s}: {s} set {s}: {t}", .{ F.name, name, path, err });
            tally.failures += 1;
            continue;
        };
        tally.sets += 1;
        const now = F.read(a, e.bytes()) catch |err| {
            std.log.err("{s}: {s} set {s}: reads back {t}:\n{s}", .{ F.name, name, path, err, e.bytes() });
            tally.failures += 1;
            continue;
        };
        if (aliases) continue;
        const expected = try F.M.changed(a, old, try tokensOf(a, path), F.seven);
        if (!eql(expected, now) or commentChanged(text, e.bytes(), F.comment)) {
            std.log.err("{s}: {s} set {s}:\n{s}\n---\n{s}", .{ F.name, name, path, text, e.bytes() });
            tally.failures += 1;
        }
    }
    for (members.items[0..@min(members.items.len, per_document)]) |path| {
        var e = try F.Edit.init(gpa, text, .{});
        defer e.deinit();
        e.remove(path) catch |err| {
            if (!std.mem.eql(u8, e.bytes(), text)) {
                std.log.err("{s}: {s} remove {s}: refused ({t}), the text changed", .{ F.name, name, path, err });
                tally.failures += 1;
                continue;
            }
            if (aliases and (err == error.SyntaxError or err == error.PathNotFound)) {
                tally.refused += 1;
                continue;
            }
            std.log.err("{s}: {s} remove {s}: {t}", .{ F.name, name, path, err });
            tally.failures += 1;
            continue;
        };
        tally.removes += 1;
        const now = F.read(a, e.bytes()) catch |err| {
            std.log.err("{s}: {s} remove {s}: reads back {t}:\n{s}", .{ F.name, name, path, err, e.bytes() });
            tally.failures += 1;
            continue;
        };
        if (aliases) continue;
        const expected = try F.M.changed(a, old, try tokensOf(a, path), null);
        if (!eql(expected, now)) {
            std.log.err("{s}: {s} remove {s}:\n{s}\n---\n{s}", .{ F.name, name, path, text, e.bytes() });
            tally.failures += 1;
        }
    }
}

const Toml = struct {
    const name = "TOML";
    const Edit = toml.Edit;
    const M = Model(toml.Value, "array", "table");
    const seven: toml.Value = .{ .integer = 7 };
    const comment = "#";
    fn read(a: std.mem.Allocator, text: []const u8) !toml.Value {
        return toml.parseLeaky(toml.Value, a, text, .{});
    }
    fn aliases(_: []const u8) bool {
        return false;
    }
    const examples = [_][]const u8{
        "# top\na = 1 # one\nb.c = [1, 2] # dotted\n\n[t]\nk = \"v\"\n\n[t.sub]\nz = { x = 1, y.w = 2 }\n",
        "[[arr]]\n# first\nn = 1\na.b.c = 2\n\n[[arr]]\nn = 3\n[arr.s]\nq = [\n  1, # one\n  2,\n]\n",
        "s = \"\"\"\nx\"\"\"\nl = 'raw'\nt = { a = { b = [true, 07:32:00] } }\n",
    };
};
const Yaml = struct {
    const name = "YAML";
    const Edit = yaml.Edit;
    const M = Model(yaml.Value, "sequence", "mapping");
    const seven: yaml.Value = .{ .integer = 7 };
    const comment = "#";
    fn read(a: std.mem.Allocator, text: []const u8) !yaml.Value {
        return yaml.parseLeaky(yaml.Value, a, text, .{});
    }
    fn aliases(text: []const u8) bool {
        return std.mem.findScalar(u8, text, '*') != null;
    }
    const examples = [_][]const u8{
        "# top\na: 1 # one\nb:\n  c: [1, 2] # flow\n  d:\n    - x\n    # between\n    - y\n",
        "- name: a\n  tags: {k: v, w: [1]}\n- ? complex\n  : value\n-\n  - nested\n",
        "s: |\n  block\n  text\nq: 'quoted'\nanchor: &a {x: 1}\nalias: *a\n---\nsecond: 2\n",
    };
};
const Jsonc = struct {
    const name = "JSONC";
    const Edit = json.jsonc.Edit;
    const M = Model(json.Value, "array", "object");
    const seven: json.Value = .{ .number = "7" };
    const comment = "//";
    fn read(a: std.mem.Allocator, text: []const u8) !json.Value {
        return json.jsonc.parseLeaky(json.Value, a, text, .{});
    }
    fn aliases(_: []const u8) bool {
        return false;
    }
    const examples = [_][]const u8{
        "{\n  // top\n  \"a\": 1, // one\n  \"b\": {\"c\": [1, 2,], /* inline */ \"d\": null},\n}\n",
        "[\n  {\"n\": 1},\n  // between\n  [true, \"s\\\"q\"],\n  {}\n]\n",
        "/* head */ {\"x\": {\"y\": {\"z\": []}}, \"e\": \"\"}",
    };
};

fn expectNone(comptime F: type, tally: Tally) !void {
    if (tally.failures != 0) {
        std.log.err("{s}: {d} failures ({d} documents, {d} sets, {d} removals)", .{ F.name, tally.failures, tally.documents, tally.sets, tally.removes });
        return error.TestUnexpectedResult;
    }
}

test "TOML editing over toml-test: each leaf set, each member removed" {
    var tally: Tally = .{};
    for (toml_suite.v1_1) |case| if (case.json != null) try property(Toml, case.name, case.toml, &tally);
    try expectNone(Toml, tally);
    try std.testing.expect(tally.documents > 200 and tally.sets > 800 and tally.removes > 1300);
}
test "YAML editing over yaml-test-suite: each leaf set, each member removed" {
    var tally: Tally = .{};
    for (yaml_suite.cases) |case| if (!case.invalid) try property(Yaml, case.path, case.yaml, &tally);
    try expectNone(Yaml, tally);
    try std.testing.expect(tally.documents > 200 and tally.sets > 500 and tally.removes > 500);
}
test "JSONC editing over JSONTestSuite and yaml-test-suite's JSON: each leaf set, each member removed" {
    var tally: Tally = .{};
    for (json_suite.cases) |case| if (case.accept) try property(Jsonc, case.name, case.input, &tally);
    for (yaml_suite.cases) |case| if (case.json) |text| try property(Jsonc, case.path, text, &tally);
    try expectNone(Jsonc, tally);
    try std.testing.expect(tally.documents > 200 and tally.sets > 500 and tally.removes > 500);
}

/// Documents mutated from each format's examples, commented and nested, are
/// held to the property: whatever reads is edited without a crash, a leak or
/// a change the property refuses.
fn anyDocument(comptime F: type) fn (void, *shakedown.Case) anyerror!void {
    return struct {
        fn run(_: void, case: *shakedown.Case) anyerror!void {
            var buffer: [160]u8 = undefined;
            const input = shakedown.gen.mutated(case.source, &buffer, &F.examples);
            case.note("input: {s}", .{input});
            var tally: Tally = .{};
            try property(F, "a mutated document", input, &tally);
            try std.testing.expectEqual(0, tally.failures);
        }
    }.run;
}

test "fuzz: TOML editing of any document read" {
    try shakedown.check(gpa, {}, anyDocument(Toml), .{ .cases = 600 });
}
test "fuzz: YAML editing of any document read" {
    try shakedown.check(gpa, {}, anyDocument(Yaml), .{ .cases = 600 });
}
test "fuzz: JSONC editing of any document read" {
    try shakedown.check(gpa, {}, anyDocument(Jsonc), .{ .cases = 600 });
}
