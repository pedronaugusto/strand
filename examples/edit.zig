//! Configuration edited in place: a TOML manifest's version bumped and a
//! dependency added and removed, a YAML service scaled, a JSONC setting
//! changed, each by JSON Pointer, every comment and byte around the change
//! kept, and an edit that would leave a broken document refused.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- edit`
//! extracts the region between the edit markers into README.md.

const std = @import("std");
const strand = @import("strand");

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:edit ---

    const manifest =
        \\# The service's manifest.
        \\[package]
        \\name = "relay"
        \\version = "0.1.0" # bumped by the release
        \\
        \\[dependencies]
        \\wire = "1.4"     # pinned for the wire format
        \\legacy = "0.9"
        \\
    ;
    var toml = try strand.toml.Edit.init(gpa, manifest, .{});
    defer toml.deinit();
    try toml.set("/package/version", "0.2.0");
    try toml.set("/dependencies/trace", "0.3");
    try toml.remove("/dependencies/legacy");
    std.debug.assert(std.mem.eql(u8, toml.bytes(),
        \\# The service's manifest.
        \\[package]
        \\name = "relay"
        \\version = "0.2.0" # bumped by the release
        \\
        \\[dependencies]
        \\wire = "1.4"     # pinned for the wire format
        \\trace = "0.3"
        \\
    ));

    // YAML: a value set where it is written, a key added at its column.
    var yaml = try strand.yaml.Edit.init(gpa, "api:\n  replicas: 2 # scaled by hand\n  ports: [8080]\n", .{});
    defer yaml.deinit();
    try yaml.set("/api/replicas", @as(u8, 5));
    try yaml.insert("/api/ports/-", @as(u16, 9090));
    try yaml.set("/api/debug", true);
    std.debug.assert(std.mem.eql(u8, yaml.bytes(), "api:\n  replicas: 5 # scaled by hand\n  ports: [8080, 9090]\n  debug: true\n"));

    // JSONC: comments and a trailing comma kept; an edit read back before it
    // is kept, so a key that cannot be reached is refused, the text as it was.
    var jsonc = try strand.json.jsonc.Edit.init(gpa, "{\n  // points\n  \"editor.fontSize\": 14,\n}\n", .{});
    defer jsonc.deinit();
    try jsonc.set("/editor.fontSize", @as(u8, 16));
    std.debug.assert(std.mem.eql(u8, jsonc.bytes(), "{\n  // points\n  \"editor.fontSize\": 16,\n}\n"));
    std.debug.assert(jsonc.set("/editor.fontSize/size", @as(u8, 1)) == error.PathNotFound);
    std.debug.assert(std.mem.eql(u8, jsonc.bytes(), "{\n  // points\n  \"editor.fontSize\": 16,\n}\n"));
    // --- README:edit ---

    std.log.info("edit:\n{s}", .{toml.bytes()});
}
