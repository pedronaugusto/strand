//! JSON5 observations of strand's own: a configuration of about 64 KiB in
//! JSON5 as people write it (comments, unquoted keys, single quotes,
//! hexadecimal, trailing commas), read as a typed record on a reset arena,
//! read as `json.Value`, written, and the same configuration as plain JSON
//! read as JSON5, the dialect's cost over JSON's reading of one text.
//! Compilation and smoke are correctness gates; timing is a manual run on a
//! quiet machine. The comparisons with other readers are in the private
//! trials repository.
const std = @import("std");
const strand = @import("strand");
const json = strand.json;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Service = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    mask: u32,
    enabled: bool,
    timeout: f64,
    tags: []const []const u8,
    motd: []const u8,
};
const Config = struct { version: u32, services: []const Service };

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || error{ OutOfMemory, PolicyMismatch };
const Context = struct {
    arena: std.heap.ArenaAllocator,
    document: []const u8,
    plain: []const u8,
    value: Config,
    buffer: []u8,
};

/// The configuration of `services` services in JSON5, as a person keeps one.
fn document(gpa: std.mem.Allocator, services: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("// The relay's services.\n{\n  version: 3,\n  services: [\n");
    for (0..services) |i| {
        try w.print(
            \\    {{
            \\      /* service {d} */
            \\      name: 'svc{d:0>5}',
            \\      host: '{s}',
            \\      port: {d},
            \\      mask: 0x{X:0>8},
            \\      enabled: {},
            \\      timeout: {d}.5,
            \\      tags: ['web', "api", 'primary',],
            \\      motd: 'Welcome \
            \\to the service',
            \\    }},
            \\
        , .{ i, i, if (i % 3 == 0) "10.0.0.1" else "service.internal.example", 8000 + i % 1000, (i *% 2654435761) & 0xffffffff, i % 4 != 0, i % 60 });
    }
    try w.writeAll("  ],\n}\n");
    return out.toOwnedSlice();
}

fn typed(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try json.json5.parseLeaky(Config, c.arena.allocator(), c.document, .{});
        sum +%= value.services.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn anyValue(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try json.json5.parseLeaky(json.Value, c.arena.allocator(), c.document, .{});
        sum +%= value.object.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn write(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(c.buffer);
        try json.json5.write(&writer, c.value, .{});
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}
fn plainJson(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try json.json5.parseLeaky(Config, c.arena.allocator(), c.plain, .{});
        sum +%= value.services.len;
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const gpa = init.gpa;
    var fixture: std.heap.ArenaAllocator = .init(gpa);
    defer fixture.deinit();
    const text = try document(gpa, if (smoke) 4 else 250);
    defer gpa.free(text);
    const value = try json.json5.parseLeaky(Config, fixture.allocator(), text, .{});
    const buffer = try gpa.alloc(u8, text.len * 2);
    defer gpa.free(buffer);
    // The same configuration as JSON, which JSON reads as JSON5 reads it.
    var plain = std.Io.Writer.fixed(buffer[0..text.len]);
    try json.write(&plain, value, .{});
    const plain_text = try gpa.dupe(u8, plain.buffered());
    defer gpa.free(plain_text);
    const again = try json.parseLeaky(Config, fixture.allocator(), plain_text, .{});
    if (again.services.len != value.services.len or !std.mem.eql(u8, again.services[0].motd, "Welcome to the service")) return error.PolicyMismatch;
    var c: Context = .{ .arena = .init(gpa), .document = text, .plain = plain_text, .value = value, .buffer = buffer };
    defer c.arena.deinit();
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "json5.typed.64k", .unit = "document", .initial = 1, .run = typed },
        .{ .name = "json5.value.64k", .unit = "document", .initial = 1, .run = anyValue },
        .{ .name = "json5.write.64k", .unit = "document", .initial = 1, .run = write },
        .{ .name = "json5.plain-json.64k", .unit = "document", .initial = 1, .run = plainJson },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
