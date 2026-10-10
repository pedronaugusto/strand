//! Explicit paired S2 observations; compilation and smoke are correctness gates.
const std = @import("std");
const strand = @import("strand");
const core = strand.core;
const json = strand.json;
const jsonl = strand.jsonl;
const Encoder = @import("json").Encoder_module;
const shakedown = @import("shakedown");
const paired = @import("paired.zig");
const Record = struct { id: u64, label: []const u8, data: [2]u8 };
const prefix = "{\"id\":18446744073709551615,\"label\":\"";
const suffix = "\",\"data\":[1,2]}";
const input = prefix ++ @as([512 - prefix.len - suffix.len]u8, @splat('a')) ++ suffix;
const Text = struct { text: []const u8 };
const text_input = "{\"text\":\"" ++ @as([8192]u8, @splat('a')) ++ "\"}";
const WorkError = core.DecodeError || core.EncodeError || std.json.ParseError(std.json.Scanner) || std.Io.Writer.Error || jsonl.Decoder(Record).Error;
const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    decoder: jsonl.Decoder(Record),
    value: Record,
    buffer: [16384]u8 = undefined,
};
fn parseRow(comptime strict: bool, c: *Context, units: u64) WorkError!void {
    var sum: u64 = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const v = if (strict) try json.parseLeaky(Record, c.arena.allocator(), input, .{}) else try std.json.parseFromSliceLeaky(Record, c.arena.allocator(), input, .{});
        sum +%= v.id +% v.label.len +% v.data[0] +% v.data[1];
    }
    std.mem.doNotOptimizeAway(sum);
}
fn strictParse(c: *Context, units: u64) WorkError!void {
    return parseRow(true, c, units);
}
fn stdParse(c: *Context, units: u64) WorkError!void {
    return parseRow(false, c, units);
}
fn owned(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var v = try json.parseOwned(Record, c.gpa, input, .{});
        sum +%= v.value.label.len;
        v.deinit();
    }
    std.mem.doNotOptimizeAway(sum);
}
fn push(c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        const result = c.decoder.push(input ++ "\n");
        switch (result.status) {
            .record => |v| sum +%= v.value.label.len,
            .failure => |err| return err,
            .need_input => return error.CustomRejected,
        }
    }
    std.mem.doNotOptimizeAway(sum);
}
fn textRow(comptime strict: bool, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        _ = c.arena.reset(.retain_capacity);
        const v = if (strict) try json.parseLeaky(Text, c.arena.allocator(), text_input, .{}) else try std.json.parseFromSliceLeaky(Text, c.arena.allocator(), text_input, .{});
        sum +%= v.text.len;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn strictText(c: *Context, units: u64) WorkError!void {
    return textRow(true, c, units);
}
fn stdText(c: *Context, units: u64) WorkError!void {
    return textRow(false, c, units);
}
fn node(c: *core.Context) core.EncodeError!void {
    try c.node();
    try c.chargeWork(1);
}
fn key(out: *Encoder, c: *core.Context, name: []const u8) WorkError!void {
    try c.node();
    try c.span(name.len, true);
    try c.chargeWork(name.len);
    try out.key(name, c);
}
fn hand(value: Record, out: *Encoder, c: *core.Context) WorkError!void {
    try node(c);
    try c.enter();
    defer c.leave();
    try c.count(3);
    try out.begin(.record, "", 3, c);
    try key(out, c, "id");
    try node(c);
    try out.integer(value.id, c);
    try key(out, c, "label");
    try node(c);
    try c.span(value.label.len, false);
    try c.chargeWork(value.label.len);
    if (!std.unicode.utf8ValidateSlice(value.label)) return error.InvalidUtf8;
    try out.text(value.label, c);
    try key(out, c, "data");
    try node(c);
    try c.enter();
    try c.count(2);
    try out.begin(.tuple, "", 2, c);
    for (value.data) |v| {
        try node(c);
        try out.integer(v, c);
    }
    try out.end(c);
    c.leave();
    try out.end(c);
}
fn writeRow(comptime common: bool, c: *Context, units: u64) WorkError!void {
    var sum: usize = 0;
    for (0..units) |_| {
        var writer = std.Io.Writer.fixed(&c.buffer);
        var out: Encoder = .{ .writer = &writer };
        var budget: core.Context = .init(c.gpa, .{}, .borrowed);
        if (common) try core.serialize(c.value, &out, &budget) else try hand(c.value, &out, &budget);
        sum +%= writer.buffered().len;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
    std.mem.doNotOptimizeAway(sum);
}
fn commonWrite(c: *Context, units: u64) WorkError!void {
    return writeRow(true, c, units);
}
fn handWrite(c: *Context, units: u64) WorkError!void {
    return writeRow(false, c, units);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var c: Context = .{ .gpa = init.gpa, .arena = .init(init.gpa), .decoder = .init(init.gpa, .{}), .value = undefined };
    defer c.arena.deinit();
    defer c.decoder.deinit();
    c.value = try json.parseLeaky(Record, c.arena.allocator(), input, .{});
    const expected = try std.json.parseFromSliceLeaky(Record, c.arena.allocator(), input, .{});
    if (!std.meta.eql(c.value.data, expected.data) or c.value.id != expected.id or !std.mem.eql(u8, c.value.label, expected.label)) return error.PolicyMismatch;
    var writer = std.Io.Writer.fixed(&c.buffer);
    var out: Encoder = .{ .writer = &writer };
    var budget: core.Context = .init(c.gpa, .{}, .borrowed);
    try hand(c.value, &out, &budget);
    if (!std.mem.eql(u8, input, writer.buffered()) or budget.allocationRequested() != 0) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context, WorkError){
        .{ .name = "json.strict.borrowed.512", .unit = "record", .initial = 1024, .run = strictParse },
        .{ .name = "json.std.borrowed.512", .unit = "record", .initial = 1024, .run = stdParse },
        .{ .name = "json.strict.owned.512", .unit = "record", .initial = 1024, .run = owned },
        .{ .name = "jsonl.push.512", .unit = "record", .initial = 1024, .run = push },
        .{ .name = "json.strict.text.8192", .unit = "record", .initial = 1024, .run = strictText },
        .{ .name = "json.std.text.8192", .unit = "record", .initial = 1024, .run = stdText },
        .{ .name = "json.write.core.512", .unit = "record", .initial = 1024, .run = commonWrite },
        .{ .name = "json.write.hand.512", .unit = "record", .initial = 1024, .run = handWrite },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(WorkError, init.gpa, init.io, &output.interface, &c, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 31, .minimum = .fromMilliseconds(100), .smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke") });
    try output.interface.flush();
}
