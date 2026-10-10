//! Pure JSON consumer: names strand.json and strand.core and nothing else, so
//! no jsonl or airlock code is analysed and none reaches the executable.
const std = @import("std");
const strand = @import("strand");
const json = strand.json;
const core = strand.core;
const Event = struct { n: u8, text: []const u8 };
comptime {
    std.debug.assert(json.Parsed(Event) == core.Parsed(Event));
}
pub fn main() !void {
    var no_storage: [0]u8 = .{};
    var no_alloc: std.heap.FixedBufferAllocator = .init(&no_storage);
    var parsed = try json.parse(Event, no_alloc.allocator(), "{\"n\":1,\"text\":\"hello\"}", .{});
    defer parsed.deinit();
    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    try json.write(&output, parsed.value, .{});
    std.debug.assert(std.mem.eql(u8, output.buffered(), "{\"n\":1,\"text\":\"hello\"}"));
}
