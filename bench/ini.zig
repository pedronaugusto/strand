//! INI observations of strand's own: a configuration of about 64 KiB, a
//! section per service, read as a typed map of sections on a reset arena,
//! read as `ini.Value`, and written. Compilation and smoke are correctness
//! gates; timing is a manual run on a quiet machine. The comparisons with
//! other readers are in the private trials repository.
const std = @import("std");
const strand = @import("strand");
const ini = strand.ini;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Service = struct {
    host: []const u8,
    port: u16,
    enabled: bool,
    timeout: f64,
    tags: []const u8,
    note: ?[]const u8 = null,
    motd: []const u8 = "",
};
const Config = strand.core.Pairs([]const u8, Service);

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || error{ OutOfMemory, PolicyMismatch };
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Holds `value`, which the rows that reset `arena` must not disturb.
    fixture: std.heap.ArenaAllocator,
    document: []u8,
    value: Config,
    buffer: []u8,
};

fn document(gpa: std.mem.Allocator, services: usize) ![]u8 {
    const names = try gpa.alloc([8]u8, services);
    defer gpa.free(names);
    const list = try gpa.alloc(strand.core.Pair([]const u8, Service), services);
    defer gpa.free(list);
    for (list, names, 0..) |*entry, *name, i| {
        var w = std.Io.Writer.fixed(name);
        // unreachable: under 100,000 services, `svc99999` is eight bytes.
        w.print("svc{d:0>5}", .{i}) catch unreachable;
        entry.* = .{
            .key = w.buffered(),
            .value = .{
                .host = if (i % 3 == 0) "10.0.0.1" else "service.internal.example",
                .port = @intCast(8000 + i % 1000), // safe: under 9,000.
                .enabled = i % 4 != 0,
                .timeout = @as(f64, @floatFromInt(i % 60)) + 0.5,
                .tags = "web, api, primary",
                .note = if (i % 5 == 0) "kept for the migration" else null,
                .motd = if (i % 7 == 0) "Welcome\nto the service" else "",
            },
        };
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try ini.write(&out.writer, Config{ .items = list }, .{});
    return out.toOwnedSlice();
}

fn typed(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try ini.parseLeaky(Config, c.arena.allocator(), c.document, .{});
        sum +%= value.items.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn anyValue(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try ini.parseLeaky(ini.Value, c.arena.allocator(), c.document, .{});
        sum +%= value.members.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn write(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(c.buffer);
        try ini.write(&writer, c.value, .{});
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var c: Context = .{ .gpa = init.gpa, .arena = .init(init.gpa), .fixture = .init(init.gpa), .document = undefined, .value = undefined, .buffer = undefined };
    defer c.arena.deinit();
    defer c.fixture.deinit();
    c.document = try document(c.gpa, if (smoke) 4 else 560);
    defer c.gpa.free(c.document);
    c.buffer = try c.gpa.alloc(u8, c.document.len * 2);
    defer c.gpa.free(c.buffer);
    c.value = try ini.parseLeaky(Config, c.fixture.allocator(), c.document, .{});
    // What is read is written back as the same document.
    var again = std.Io.Writer.fixed(c.buffer);
    try ini.write(&again, c.value, .{});
    if (!std.mem.eql(u8, again.buffered(), c.document)) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "ini.typed.64k", .unit = "document", .initial = 1, .run = typed },
        .{ .name = "ini.value.64k", .unit = "document", .initial = 1, .run = anyValue },
        .{ .name = "ini.write.64k", .unit = "document", .initial = 1, .run = write },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
