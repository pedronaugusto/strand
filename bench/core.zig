//! Paired manual S1 observations against equivalent checked field emission.
const std = @import("std");
const core = proof.core;
const proof = @import("proof");
const shakedown = @import("shakedown");
const paired = @import("paired.zig");
const Record = struct { id: u8, label: []const u8 };
const Context = struct { value: Record = .{ .id = 42, .label = "plain" }, memory: [128]u8 = undefined };
fn key(out: *proof.Reference.Encoder, c: *core.Context, name: []const u8) core.EncodeError!void {
    try c.node();
    try c.span(name.len, true);
    try c.chargeWork(name.len);
    try out.key(name, c);
}
fn hand(value: Record, out: *proof.Reference.Encoder, c: *core.Context) core.EncodeError!void {
    try c.node();
    try c.chargeWork(1);
    try c.enter();
    defer c.leave();
    try c.count(2);
    try out.begin(.record, @typeName(Record), 2, c);
    try key(out, c, "id");
    try c.node();
    try c.chargeWork(1);
    try out.integer(value.id, c);
    try key(out, c, "label");
    try c.node();
    try c.chargeWork(1);
    try c.span(value.label.len, false);
    try c.chargeWork(value.label.len);
    if (!std.unicode.utf8ValidateSlice(value.label)) return error.InvalidUtf8;
    try out.text(value.label, c);
    try out.end(c);
}
fn handRow(context: *Context, units: u64) !void {
    var sum: usize = 0;
    for (0..units) |_| {
        var out: proof.Reference.Encoder = .{ .buffer = &context.memory };
        var c: core.Context = .init(std.heap.smp_allocator, .{}, .borrowed);
        try hand(context.value, &out, &c);
        sum +%= out.used;
        std.mem.doNotOptimizeAway(out.buffer[0..out.used]);
    }
    std.mem.doNotOptimizeAway(sum);
}
fn coreRow(context: *Context, units: u64) !void {
    var sum: usize = 0;
    for (0..units) |_| {
        var out: proof.Reference.Encoder = .{ .buffer = &context.memory };
        var c: core.Context = .init(std.heap.smp_allocator, .{}, .borrowed);
        try core.serialize(context.value, &out, &c);
        sum +%= out.used;
        std.mem.doNotOptimizeAway(out.buffer[0..out.used]);
    }
    std.mem.doNotOptimizeAway(sum);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var context: Context = .{};
    var hand_bytes: [128]u8 = undefined;
    var expected: proof.Reference.Encoder = .{ .buffer = &hand_bytes };
    var hc: core.Context = .init(std.heap.smp_allocator, .{}, .borrowed);
    try hand(context.value, &expected, &hc);
    var actual: proof.Reference.Encoder = .{ .buffer = &context.memory };
    var cc: core.Context = .init(std.heap.smp_allocator, .{}, .borrowed);
    try core.serialize(context.value, &actual, &cc);
    if (!std.mem.eql(u8, expected.buffer[0..expected.used], actual.buffer[0..actual.used]) or hc.items != cc.items or hc.work != cc.work) return error.PolicyMismatch;
    const rows = [_]shakedown.bench.Row(Context){
        .{ .name = "reference.hand.a", .unit = "record", .initial = 1024, .run = handRow },
        .{ .name = "reference.core.a", .unit = "record", .initial = 1024, .run = coreRow },
        .{ .name = "reference.hand.b", .unit = "record", .initial = 1024, .run = handRow },
        .{ .name = "reference.core.b", .unit = "record", .initial = 1024, .run = coreRow },
    };
    var output = std.Io.File.stdout().writerStreaming(init.io, &.{});
    try paired.run(init.gpa, init.io, &output.interface, &context, &rows, .{ .commit = if (args.len > 1) args[1] else "working-tree" }, .{ .samples = 7, .minimum = .fromMilliseconds(100) });
    try output.interface.flush();
}
