//! .env observations of strand's own: a service's environment of about
//! 16 KiB (comments, `export`, unquoted, single- and double-quoted values, a
//! value across lines), read as a map of its keys on a reset arena, read as
//! a struct of the few keys an application wants with the rest ignored, and
//! written. Compilation and smoke are correctness gates; timing is a manual
//! run on a quiet machine. The comparisons with other readers are in the
//! private trials repository.
const std = @import("std");
const strand = @import("strand");
const dotenv = strand.dotenv;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Env = strand.core.Pairs([]const u8, ?[]const u8);
const App = struct { APP_NAME: []const u8, APP_PORT: u16, APP_DEBUG: bool, APP_GREETING: []const u8 };

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || error{ OutOfMemory, PolicyMismatch };
const Context = struct {
    arena: std.heap.ArenaAllocator,
    document: []const u8,
    value: Env,
    buffer: []u8,
    scratch: []u8,
};

/// A service's environment of `groups` groups of settings.
fn document(gpa: std.mem.Allocator, groups: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# The service's environment.\nAPP_NAME=relay\nAPP_PORT=8443\nAPP_DEBUG=false\nAPP_GREETING=\"Welcome,\\nfriend\"\n");
    for (0..groups) |i| try w.print(
        \\
        \\# Worker {d}
        \\export WORKER_{d}_HOST=worker-{d}.internal.example
        \\WORKER_{d}_PORT = {d}
        \\WORKER_{d}_TOKEN='s3cr3t-{d}-$keep'  # not expanded
        \\WORKER_{d}_MOTD="Hello from worker {d}, \"{d}\""
        \\WORKER_{d}_CERT='-----BEGIN-----
        \\abc{d}
        \\-----END-----'
        \\
    , .{ i, i, i, i, 9000 + i, i, i, i, i, i, i, i });
    return out.toOwnedSlice();
}

fn pairs(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try dotenv.parseLeaky(Env, c.arena.allocator(), c.document, .{});
        sum +%= value.items.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn typed(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try dotenv.parseLeaky(App, c.arena.allocator(), c.document, .{ .ignore_unknown_fields = true });
        sum +%= value.APP_PORT;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn write(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(c.buffer);
        try dotenv.write(&writer, c.value, .{ .scratch = c.scratch });
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const gpa = init.gpa;
    var fixture: std.heap.ArenaAllocator = .init(gpa);
    defer fixture.deinit();
    const text = try document(gpa, if (smoke) 4 else 70);
    defer gpa.free(text);
    const value = try dotenv.parseLeaky(Env, fixture.allocator(), text, .{});
    const buffer = try gpa.alloc(u8, text.len * 2);
    defer gpa.free(buffer);
    const scratch = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(scratch);
    // What is written reads back as the same keys and values.
    var again = std.Io.Writer.fixed(buffer);
    try dotenv.write(&again, value, .{ .scratch = scratch });
    const back = try dotenv.parseLeaky(Env, fixture.allocator(), again.buffered(), .{});
    if (back.items.len != value.items.len) return error.PolicyMismatch;
    for (back.items, value.items) |b, v| if (!std.mem.eql(u8, b.key, v.key) or !std.mem.eql(u8, b.value.?, v.value.?)) return error.PolicyMismatch;
    var c: Context = .{ .arena = .init(gpa), .document = text, .value = value, .buffer = buffer, .scratch = scratch };
    defer c.arena.deinit();
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "dotenv.pairs.16k", .unit = "document", .initial = 1, .run = pairs },
        .{ .name = "dotenv.typed.16k", .unit = "document", .initial = 1, .run = typed },
        .{ .name = "dotenv.write.16k", .unit = "document", .initial = 1, .run = write },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = smoke });
    try output.interface.flush();
}
