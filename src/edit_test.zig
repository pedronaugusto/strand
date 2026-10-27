//! Comment-preserving editing: JSONC, TOML and YAML documents changed in
//! place by JSON Pointer, every byte the change does not replace kept,
//! members added at their siblings' indentation, removals taking their
//! lines, and every edit read back before it is kept.
const std = @import("std");
const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");

const gpa = std.testing.allocator;

test "JSONC: a value set, a member added and removed, comments kept" {
    const text =
        \\// settings
        \\{
        \\  "editor.fontSize": 12, // points
        \\  /* the theme */
        \\  "workbench.colorTheme": "Default Dark+",
        \\  "files.exclude": {
        \\    "**/.git": true
        \\  },
        \\  "list": [1, 2, 3],
        \\}
        \\
    ;
    var e = try json.jsonc.Edit.init(gpa, text, .{});
    defer e.deinit();
    try e.set("/editor.fontSize", @as(u8, 14));
    try e.set("/files.exclude/**~1node_modules", true);
    try e.set("/list/-", @as(u8, 4));
    try e.insert("/list/0", @as(u8, 0));
    try e.remove("/workbench.colorTheme");
    try e.set("/new", .{ .a = @as(u8, 1) });
    try std.testing.expectEqualStrings(
        \\// settings
        \\{
        \\  "editor.fontSize": 14, // points
        \\  /* the theme */
        \\  "files.exclude": {
        \\    "**/.git": true,
        \\    "**/node_modules": true
        \\  },
        \\  "list": [0, 1, 2, 3, 4],
        \\  "new": {
        \\    "a": 1
        \\  },
        \\}
        \\
    , e.bytes());
    try std.testing.expectError(error.PathNotFound, e.set("/nope/x", true));
    try std.testing.expectError(error.PathNotFound, e.remove("/list/9"));
    try std.testing.expectError(error.InvalidPointer, e.set("x", true));
}

test "JSONC: removals take their separators and their lines" {
    var e = try json.jsonc.Edit.init(gpa, "{\"a\": 1, \"b\": 2, \"c\": [1, 2]}", .{});
    defer e.deinit();
    try e.remove("/b");
    try std.testing.expectEqualStrings("{\"a\": 1, \"c\": [1, 2]}", e.bytes());
    try e.remove("/c/1");
    try std.testing.expectEqualStrings("{\"a\": 1, \"c\": [1]}", e.bytes());
    try e.remove("/c");
    try std.testing.expectEqualStrings("{\"a\": 1}", e.bytes());
    try e.remove("/a");
    try std.testing.expectEqualStrings("{}", e.bytes());
    try e.set("/z", "q");
    try std.testing.expectEqualStrings("{\"z\": \"q\"}", e.bytes());
    try e.set("", @as([]const u8, "whole"));
    try std.testing.expectEqualStrings("\"whole\"", e.bytes());

    var lines = try json.jsonc.Edit.init(gpa, "{\n  \"a\": 1,\n  // about b\n  \"b\": 2 // two\n}\n", .{});
    defer lines.deinit();
    try lines.remove("/b");
    try std.testing.expectEqualStrings("{\n  \"a\": 1\n  // about b\n}\n", lines.bytes());
    try lines.set("/c", @as(u8, 3));
    try std.testing.expectEqualStrings("{\n  \"a\": 1,\n  \"c\": 3\n  // about b\n}\n", lines.bytes());
}

test "TOML: values set, keys added under their table, comments kept" {
    const text =
        \\# The service.
        \\title = "api"   # shown in the dashboard
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080 # the public port
        \\
        \\# Limits, per worker.
        \\[limits]
        \\memory = "512Mi"
        \\cpus = [1, 2]
        \\
    ;
    var e = try toml.Edit.init(gpa, text, .{});
    defer e.deinit();
    try e.set("/server/port", @as(u16, 9090));
    try e.set("/server/tls", true);
    try e.set("/limits/cpus/-", @as(u8, 4));
    try e.set("/owner", .{ .name = @as([]const u8, "ops"), .email = @as([]const u8, "ops@example.com") });
    try e.set("/title", @as([]const u8, "api v2"));
    try std.testing.expectEqualStrings(
        \\# The service.
        \\title = "api v2"   # shown in the dashboard
        \\
        \\[server]
        \\host = "localhost"
        \\port = 9090 # the public port
        \\tls = true
        \\
        \\# Limits, per worker.
        \\[limits]
        \\memory = "512Mi"
        \\cpus = [1, 2, 4]
        \\
        \\[owner]
        \\name = "ops"
        \\email = "ops@example.com"
        \\
    , e.bytes());
}

test "TOML: removals take their lines and their sections; dotted keys and inline tables" {
    const text =
        \\a = 1
        \\b.c = 2 # dotted
        \\b.d = 3
        \\inline = { x = 1, y = 2 }
        \\
        \\[t]
        \\k = "v"
        \\
        \\[t.sub]
        \\z = 0
        \\
        \\[u]
        \\w = 1
        \\
    ;
    var e = try toml.Edit.init(gpa, text, .{});
    defer e.deinit();
    try e.remove("/a");
    try e.set("/b/e", @as(u8, 4));
    try e.remove("/inline/x");
    try e.set("/inline/q", @as(u8, 9));
    try e.remove("/t");
    try std.testing.expectEqualStrings(
        \\b.c = 2 # dotted
        \\b.d = 3
        \\b.e = 4
        \\inline = { y = 2, q = 9 }
        \\
        \\[u]
        \\w = 1
        \\
    , e.bytes());
    try e.remove("/b");
    try std.testing.expectEqualStrings("inline = { y = 2, q = 9 }\n\n[u]\nw = 1\n", e.bytes());
    try std.testing.expectError(error.PathNotFound, e.remove("/nope"));
}

test "TOML: arrays of tables appended and removed" {
    const text =
        \\[[server]]
        \\name = "a"
        \\
        \\[[server]]
        \\name = "b"
        \\
    ;
    var e = try toml.Edit.init(gpa, text, .{});
    defer e.deinit();
    const Server = struct { name: []const u8 };
    try e.set("/server/-", Server{ .name = "c" });
    try e.remove("/server/0");
    try std.testing.expectEqualStrings("[[server]]\nname = \"b\"\n\n[[server]]\nname = \"c\"\n", e.bytes());
}

test "TOML: dotted keys inside braces and under an element of an array of tables" {
    var braces = try toml.Edit.init(gpa, "t = {a.b.c = 1, a.b.d = 2}\n", .{});
    defer braces.deinit();
    try braces.remove("/t/a/b/c");
    try std.testing.expectEqualStrings("t = {a.b.d = 2}\n", braces.bytes());
    try braces.remove("/t/a/b");
    try std.testing.expectEqualStrings("t = { a = {} }\n", braces.bytes());

    const text =
        \\[[arr]]
        \\a.b.c = 1
        \\
        \\[[arr]]
        \\a.b.c = 3
        \\
    ;
    var e = try toml.Edit.init(gpa, text, .{});
    defer e.deinit();
    // The table `a` stays, its section named in the first element's part.
    try e.remove("/arr/0/a/b");
    try std.testing.expectEqualStrings("[[arr]]\n\n[arr.a]\n\n[[arr]]\na.b.c = 3\n", e.bytes());
    try e.set("/arr/0/a/k", @as(u8, 1));
    try std.testing.expectEqualStrings("[[arr]]\n\n[arr.a]\nk = 1\n\n[[arr]]\na.b.c = 3\n", e.bytes());
}

test "YAML: values set, keys added at their column, comments kept" {
    const text =
        \\# The service.
        \\name: api   # shown in the dashboard
        \\server:
        \\  host: localhost
        \\  port: 8080 # the public port
        \\
        \\# Limits, per worker.
        \\limits:
        \\  memory: 512Mi
        \\  cpus: [1, 2]
        \\tags:
        \\- a
        \\- b
        \\
    ;
    var e = try yaml.Edit.init(gpa, text, .{});
    defer e.deinit();
    try e.set("/server/port", @as(u16, 9090));
    try e.set("/server/tls", true);
    try e.set("/limits/cpus/-", @as(u8, 4));
    try e.set("/tags/-", @as([]const u8, "c"));
    try e.insert("/tags/0", @as([]const u8, "z"));
    try e.set("/owner", .{ .name = @as([]const u8, "ops"), .email = @as([]const u8, "ops@example.com") });
    try e.set("/name", @as([]const u8, "api v2"));
    try std.testing.expectEqualStrings(
        \\# The service.
        \\name: api v2   # shown in the dashboard
        \\server:
        \\  host: localhost
        \\  port: 9090 # the public port
        \\  tls: true
        \\
        \\# Limits, per worker.
        \\limits:
        \\  memory: 512Mi
        \\  cpus: [1, 2, 4]
        \\tags:
        \\- z
        \\- a
        \\- b
        \\- c
        \\owner:
        \\  name: ops
        \\  email: ops@example.com
        \\
    , e.bytes());
    try std.testing.expectError(error.PathNotFound, e.set("/nope/x", true));
    try std.testing.expectError(error.PathNotFound, e.remove("/tags/9"));
}

test "YAML: values replaced by collections and back, entries of entries" {
    var e = try yaml.Edit.init(gpa, "a: 1\nlist:\n  - x: 1\n    y: 2\n  - 3\n", .{});
    defer e.deinit();
    try e.set("/a", .{ .b = @as(u8, 2), .c = [_]u8{ 1, 2 } });
    try std.testing.expectEqualStrings("a:\n  b: 2\n  c:\n    - 1\n    - 2\nlist:\n  - x: 1\n    y: 2\n  - 3\n", e.bytes());
    try e.set("/a", @as(u8, 5));
    try std.testing.expectEqualStrings("a: 5\nlist:\n  - x: 1\n    y: 2\n  - 3\n", e.bytes());
    try e.set("/list/1", .{ .p = @as(u8, 1), .q = @as(u8, 2) });
    try std.testing.expectEqualStrings("a: 5\nlist:\n  - x: 1\n    y: 2\n  - p: 1\n    q: 2\n", e.bytes());
    try e.set("/list/0/z", @as(u8, 3));
    try std.testing.expectEqualStrings("a: 5\nlist:\n  - x: 1\n    y: 2\n    z: 3\n  - p: 1\n    q: 2\n", e.bytes());
    try e.remove("/list/0/x");
    try std.testing.expectEqualStrings("a: 5\nlist:\n  - y: 2\n    z: 3\n  - p: 1\n    q: 2\n", e.bytes());
    try e.remove("/list/1");
    try std.testing.expectEqualStrings("a: 5\nlist:\n  - y: 2\n    z: 3\n", e.bytes());
    try e.remove("/list/0");
    try std.testing.expectEqualStrings("a: 5\nlist: []\n", e.bytes());
    try e.set("/list/-", @as(u8, 7));
    try std.testing.expectEqualStrings("a: 5\nlist: [7]\n", e.bytes());
}

test "YAML: removals take their lines; flow collections; empty values" {
    const text =
        \\a: 1
        \\# about b
        \\b: 2 # two
        \\c: {x: 1, y: 2}
        \\d:
        \\e: |
        \\  text
        \\
        \\f: [1, 2, 3]
        \\
    ;
    var e = try yaml.Edit.init(gpa, text, .{});
    defer e.deinit();
    try e.remove("/b");
    try e.remove("/c/x");
    try e.set("/c/q", @as(u8, 9));
    try e.set("/d", @as(u8, 4));
    try e.set("/e", @as([]const u8, "short"));
    try e.remove("/f/1");
    try e.insert("/f/0", @as(u8, 0));
    try std.testing.expectEqualStrings(
        \\a: 1
        \\# about b
        \\c: {y: 2, q: 9}
        \\d: 4
        \\e: short
        \\
        \\f: [0, 1, 3]
        \\
    , e.bytes());
    try e.set("", .{ .whole = true });
    try std.testing.expectEqualStrings("whole: true\n", e.bytes());
}

test "YAML: a carriage return alone ends a line, as the reader reads it" {
    // Found by the fuzzer: the comment after `a` ends at the carriage return,
    // and `b` is the next key, not part of `a`'s line.
    var e = try yaml.Edit.init(gpa, "# top\na: 1 # one\rb:\n  c: 2\n", .{});
    defer e.deinit();
    try e.remove("/a");
    try std.testing.expectEqualStrings("# top\nb:\n  c: 2\n", e.bytes());

    var lone = try yaml.Edit.init(gpa, "a: 1\rb: 2\r", .{});
    defer lone.deinit();
    try lone.remove("/b");
    try std.testing.expectEqualStrings("a: 1\r", lone.bytes());
    try lone.set("/c", @as(u8, 3));
    try std.testing.expectEqualStrings("a: 1\rc: 3\n", lone.bytes());

    var crlf = try yaml.Edit.init(gpa, "a: 1 # one\r\nb: [1,\r\n  2]\r\n", .{});
    defer crlf.deinit();
    try crlf.remove("/a");
    try crlf.remove("/b/0");
    try std.testing.expectEqualStrings("b: [\r\n  2]\r\n", crlf.bytes());
}

test "YAML: a node replaced takes its anchor; an alias left without one is refused" {
    var e = try yaml.Edit.init(gpa, "base: &b {x: 1}\nuse: *b\n", .{});
    defer e.deinit();
    try std.testing.expectError(error.SyntaxError, e.set("/base", @as(u8, 1)));
    try std.testing.expectEqualStrings("base: &b {x: 1}\nuse: *b\n", e.bytes());
    try e.set("/use", @as(u8, 2));
    try std.testing.expectEqualStrings("base: &b {x: 1}\nuse: 2\n", e.bytes());
    try std.testing.expectError(error.PathNotFound, e.set("/use/x", true));
}
