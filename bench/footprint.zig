//! Identical frozen legacy call sites for separate cold-build/code-size trials.
const std = @import("std");
const api = @import("api");
const Record = struct { id: u64, label: []const u8, data: [2]u8 };
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "{\"id\":1,\"label\":\"hello\",\"data\":[1,2]}";
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const value = try api.parseLine(Record, arena.allocator(), input, .{});
    var memory: [16384]u8 = undefined;
    var output = std.Io.Writer.fixed(&memory);
    try api.writeLine(&output, value);
    std.mem.doNotOptimizeAway(output.buffered());
}
