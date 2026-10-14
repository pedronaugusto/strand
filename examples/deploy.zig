//! A deployment as YAML: a stream of services read into structs, defaults
//! shared through an anchor, plain scalars read as the fields ask, and
//! written back.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- yaml`
//! extracts the region between the yaml markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Resources = struct { cpu: f32, memory: []const u8 };
const Service = struct {
    name: []const u8,
    image: []const u8,
    version: []const u8,
    replicas: u8 = 1,
    requests: Resources,
    limits: Resources,
    ports: []const u16 = &.{},
    debug: bool = false,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:yaml ---

    const text =
        \\name: api
        \\image: registry.example/api
        \\version: 1.10        # a string field: read as written
        \\replicas: 3
        \\requests: {cpu: 0.25, memory: 128Mi}
        \\limits: {cpu: 1, memory: 512Mi}
        \\ports: [8080, 9090]
        \\---
        \\name: worker
        \\image: registry.example/worker
        \\version: 2.0
        \\requests: &small {cpu: 0.5, memory: 256Mi}
        \\limits: *small       # the anchor's mapping again
        \\debug: true
    ;
    var services = try strand.yaml.parseStream(Service, gpa, text, .{});
    defer services.deinit();
    std.debug.assert(services.value.len == 2);
    std.debug.assert(std.mem.eql(u8, services.value[0].version, "1.10"));
    std.debug.assert(services.value[1].limits.cpu == 0.5);
    std.debug.assert(services.value[1].replicas == 1);

    // Written back, one document after another: a string that would read
    // as something else is quoted.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.yaml.writeStream(&out.writer, services.value, .{});
    std.debug.assert(std.mem.startsWith(u8, out.written(), "name: api\nimage: registry.example/api\nversion: \"1.10\"\n"));

    // Any document as a value, by the core schema: no YAML 1.1 booleans.
    var value = try strand.yaml.parse(strand.yaml.Value, gpa, "on: yes\nretries: 0x10\nratio: .5", .{});
    defer value.deinit();
    std.debug.assert(std.mem.eql(u8, value.value.field("on").?.string, "yes"));
    std.debug.assert(value.value.field("retries").?.integer == 16);
    // --- README:yaml ---

    std.log.info("yaml:\n{s}", .{out.written()});
}
