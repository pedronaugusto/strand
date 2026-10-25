//! XML observations of strand's own: an S3 `ListBucketResult` of 1,000
//! objects (about 300 KB) and of 10 (about 3 KB) read as types on a reset
//! arena, the large one as `xml.Element` and as the scanner's tokens alone,
//! and the large one written. Compilation and smoke are correctness gates;
//! timing is a manual run. `--inputs DIR` writes the documents for the
//! rivals' harnesses (bench/rivals/xml: quick-xml with serde, Go's
//! encoding/xml), which read the same bytes.
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
    if (args.len > 2 and std.mem.eql(u8, args[1], "--inputs")) {
        var dir = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
        defer dir.close(init.io);
        try dir.writeFile(init.io, .{ .sub_path = "s3-small.xml", .data = c.small });
        try dir.writeFile(init.io, .{ .sub_path = "s3-large.xml", .data = c.large });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--dump")) return dump(init);
    if (args.len > 2 and std.mem.eql(u8, args[1], "--check")) {
        // A listing another library wrote from what strand wrote: read back
        // as the value strand wrote it from.
        const expected = try xml.parseLeaky(Listing, c.fixture.allocator(), c.large, .{});
        const other = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], c.gpa, .limited(64 << 20));
        defer c.gpa.free(other);
        const value = xml.parseLeaky(Listing, c.fixture.allocator(), other, .{}) catch |err| {
            std.log.err("{s}: refused: {t}", .{ args[2], err });
            return err;
        };
        if (!deepEql(Listing, value, expected)) return error.PolicyMismatch;
        std.log.info("{s}: read as the listing strand wrote ({d} objects)", .{ args[2], value.Contents.len });
        return;
    }
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

/// `--dump`: documents on stdin, each after its length (eight bytes, little
/// endian), each read as
/// `xml.Element` (namespaces off, as a reader that does not process them)
/// and printed as one line of JSON: `["name", [["attribute", "value"], ...],
/// [child, "text", ...]]`, or `{"refused": "Error"}`. For comparing what
/// strand reads with what another reader reads (bench/rivals/xml/infoset.py).
fn dump(init: std.process.Init) !void {
    var input_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var all: std.Io.Writer.Allocating = .init(init.gpa);
    defer all.deinit();
    _ = try stdin.interface.streamRemaining(&all.writer);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const out = &output.interface;
    var rest = all.written();
    while (rest.len >= 8) {
        const len: usize = @intCast(std.mem.readInt(u64, rest[0..8], .little));
        const each = rest[8..][0..len];
        rest = rest[8 + len ..];
        var parsed = xml.parse(xml.Element, init.gpa, each, .{ .namespaces = false }) catch |err| {
            try out.print("{{\"refused\":\"{t}\"}}\n", .{err});
            continue;
        };
        defer parsed.deinit();
        try tree(out, parsed.value.name, parsed.value.content);
        try out.writeAll("\n");
    }
    try out.flush();
}
fn tree(out: *std.Io.Writer, name: []const u8, content: []const xml.Entry) !void {
    try out.writeAll("[");
    try strand.json.write(out, name, .{});
    try out.writeAll(",[");
    var first = true;
    for (content) |e| if (e.key[0] == '@') {
        if (!first) try out.writeAll(",");
        first = false;
        try out.writeAll("[");
        try strand.json.write(out, e.key[1..], .{});
        try out.writeAll(",");
        try strand.json.write(out, e.value.text, .{});
        try out.writeAll("]");
    };
    try out.writeAll("],[");
    first = true;
    for (content) |e| if (e.key[0] != '@') {
        if (!first) try out.writeAll(",");
        first = false;
        if (std.mem.eql(u8, e.key, "$text")) {
            try strand.json.write(out, e.value.text, .{});
        } else switch (e.value) {
            .text => |t| if (t.len == 0) try tree(out, e.key, &.{}) else try tree(out, e.key, &.{.{ .key = "$text", .value = .{ .text = t } }}),
            .content => |inner| try tree(out, e.key, inner),
        }
    };
    try out.writeAll("]]");
}

fn deepEql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |i| {
            inline for (i.field_names) |name| if (!deepEql(@FieldType(T, name), @field(a, name), @field(b, name))) return false;
            return true;
        },
        .pointer => |i| {
            if (a.len != b.len) return false;
            if (i.child == u8) return std.mem.eql(u8, a, b);
            for (a, b) |x, y| if (!deepEql(i.child, x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}
