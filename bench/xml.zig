//! XML observations of strand's own: an S3 `ListBucketResult` of 1,000
//! objects (about 300 KB) and of 10 (about 3 KB) read as types on a reset
//! arena, the large one as `xml.Element` and as the scanner's tokens alone,
//! and the large one written. Compilation and smoke are correctness gates;
//! timing is a manual run on a quiet machine. The comparisons with other
//! readers are in the private trials repository.
const std = @import("std");
const strand = @import("strand");
const xml = strand.xml;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");

const Owner = struct { ID: []const u8, DisplayName: []const u8 };
const Object = struct {
    Key: []const u8,
    LastModified: []const u8,
    ETag: []const u8,
    Size: u64,
    StorageClass: []const u8,
    Owner: Owner,
};
const Listing = struct {
    Name: []const u8,
    Prefix: []const u8,
    KeyCount: u32,
    MaxKeys: u32,
    IsTruncated: bool,
    Contents: []const Object,
};

const WorkError = strand.core.DecodeError || strand.core.EncodeError || std.Io.Writer.Error || xml.Scanner.Error || error{ OutOfMemory, PolicyMismatch };
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    fixture: std.heap.ArenaAllocator,
    small: []u8,
    large: []u8,
    value: Listing,
    buffer: []u8,
};

fn document(gpa: std.mem.Allocator, objects: usize) ![]u8 {
    const keys = [_][]const u8{ "photos/2026/10/beach.jpg", "logs/app & worker.log", "backups/db-\u{e9}t\u{e9}.tar.gz", "index.html", "a/b/c/d/e/f/g.txt" };
    const list = try gpa.alloc(Object, objects);
    defer gpa.free(list);
    var etags: std.ArrayList(u8) = .empty;
    defer etags.deinit(gpa);
    try etags.ensureTotalCapacity(gpa, objects * 34);
    for (list, 0..) |*o, i| {
        const start = etags.items.len;
        etags.printAssumeCapacity("\"{x:0>32}\"", .{i *% 0x9E3779B97F4A7C15});
        o.* = .{
            .Key = keys[i % keys.len],
            .LastModified = "2026-10-25T12:30:45.000Z",
            .ETag = etags.items[start..],
            .Size = i * 7919 % 10_000_000,
            .StorageClass = if (i % 7 == 0) "GLACIER" else "STANDARD",
            .Owner = .{ .ID = "75aa57f09aa0c8caeab4f8c24e99d10f8e7faeebf76c078efc7c6caea54ba06a", .DisplayName = "mtd@amazon.com" },
        };
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const listing: Listing = .{ .Name = "example-bucket", .Prefix = "", .KeyCount = @intCast(objects), .MaxKeys = 1000, .IsTruncated = false, .Contents = list };
    try xml.write(&out.writer, listing, .{ .root = "ListBucketResult", .whitespace = .indent_2, .namespaces = &.{.{ .uri = "http://s3.amazonaws.com/doc/2006-03-01/" }} });
    return out.toOwnedSlice();
}

fn typedRow(source: []const u8, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try xml.parseLeaky(Listing, c.arena.allocator(), source, .{});
        sum +%= value.Contents.len +% value.Name.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn typedSmall(c: *Context, units: u64) WorkError!void {
    return typedRow(c.small, c, units);
}
fn typedLarge(c: *Context, units: u64) WorkError!void {
    return typedRow(c.large, c, units);
}
fn elementLarge(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const value = try xml.parseLeaky(xml.Element, c.arena.allocator(), c.large, .{});
        sum +%= value.content.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn scanLarge(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        var scanner: xml.Scanner = undefined;
        scanner.init(c.arena.allocator(), c.large, .{});
        while (try scanner.next()) |token| sum +%= @backingInt(token);
    }
    std.mem.doNotOptimizeAway(sum);
}
fn writeLarge(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(c.buffer);
        try xml.write(&writer, c.value, .{ .root = "ListBucketResult", .whitespace = .indent_2, .namespaces = &.{.{ .uri = "http://s3.amazonaws.com/doc/2006-03-01/" }} });
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    var c: Context = .{ .gpa = init.gpa, .arena = .init(init.gpa), .fixture = .init(init.gpa), .small = undefined, .large = undefined, .value = undefined, .buffer = undefined };
    defer c.arena.deinit();
    defer c.fixture.deinit();
    c.small = try document(c.gpa, if (smoke) 2 else 10);
    defer c.gpa.free(c.small);
    c.large = try document(c.gpa, if (smoke) 4 else 1000);
    defer c.gpa.free(c.large);
    c.buffer = try c.gpa.alloc(u8, c.large.len * 2);
    defer c.gpa.free(c.buffer);
    c.value = try xml.parseLeaky(Listing, c.fixture.allocator(), c.large, .{});
    // What is read is written back as the same document.
    var again = std.Io.Writer.fixed(c.buffer);
    try xml.write(&again, c.value, .{ .root = "ListBucketResult", .whitespace = .indent_2, .namespaces = &.{.{ .uri = "http://s3.amazonaws.com/doc/2006-03-01/" }} });
    if (!std.mem.eql(u8, again.buffered(), c.large)) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "xml.typed.s3-10", .unit = "document", .initial = 64, .run = typedSmall },
        .{ .name = "xml.typed.s3-1000", .unit = "document", .initial = 1, .run = typedLarge },
        .{ .name = "xml.element.s3-1000", .unit = "document", .initial = 1, .run = elementLarge },
        .{ .name = "xml.scan.s3-1000", .unit = "document", .initial = 1, .run = scanLarge },
        .{ .name = "xml.write.s3-1000", .unit = "document", .initial = 1, .run = writeLarge },
    };
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
