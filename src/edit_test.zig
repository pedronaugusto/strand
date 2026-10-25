//! Comment-preserving editing: JSONC, TOML and YAML documents changed in
//! place by JSON Pointer, every byte the change does not replace kept,
//! members added at their siblings' indentation, removals taking their
//! lines, and every edit read back before it is kept.
const std = @import("std");
const json = @import("json.zig");
const toml = @import("toml.zig");

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
