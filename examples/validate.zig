//! A tool's result checked against its output schema, as an MCP client does:
//! the schema compiled once, each result validated by streaming it, a failure
//! read as a result and the reasons with it.
//!
//! `zig build examples` builds AND runs this, against strand built with
//! `.schema = true`; `zig build docs -- validate` extracts the region between
//! the validate markers into README.md.

const std = @import("std");
const strand = @import("strand");
const strand_schema = @import("strand_schema");

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = init.io;

    // --- README:validate ---

    var schema = try strand_schema.Schema.compile(gpa, io, strand.json, .init(
        \\{"type": "object", "required": ["city", "celsius"],
        \\ "properties": {"city": {"type": "string", "minLength": 1},
        \\   "celsius": {"type": "number", "minimum": -273.15},
        \\   "observed": {"type": "string", "format": "date-time"}},
        \\ "additionalProperties": false}
    ), .{ .formats = .assert });
    defer schema.deinit();

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const good = "{\"city\": \"Lisbon\", \"celsius\": 21.5, \"observed\": \"2026-10-14T09:30:00Z\"}";
    std.debug.assert(try schema.validate(io, scratch.allocator(), strand.json, .init(good), .{ .flag = null }));

    // An invalid result is `false`, never an error; `basic` says where and why.
    var errors: strand_schema.Schema.Errors = .{};
    const bad = "{\"city\": \"\", \"celsius\": -300, \"observed\": \"yesterday\"}";
    std.debug.assert(!try schema.validate(io, scratch.allocator(), strand.json, .init(bad), .{ .basic = &errors }));
    std.debug.assert(errors.records.len == 3);
    std.debug.assert(std.mem.eql(u8, errors.records[0].instance_location, "/city"));

    // The same schema reads the same result from YAML.
    const yaml = "city: Porto\ncelsius: 18\n";
    std.debug.assert(try schema.validate(io, scratch.allocator(), strand.yaml, .init(yaml), .{ .flag = null }));

    // --- README:validate ---
}
