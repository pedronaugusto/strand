//! Ten distinct 100-field checked JSON encoders, derived versus separate typed code.
const std = @import("std");
const core = @import("strand.core");
const Encoder = @import("json").Encoder_module;
const options = @import("schema_options");
fn Schema(comptime index: usize) type {
    @setEvalBranchQuota(1_000_000);
    var names: [100][]const u8 = undefined;
    var types: [100]type = @splat(u64);
    for (0..100) |i| names[i] = std.fmt.comptimePrint("s{d}_f{d}", .{ index, i });
    return @Struct(.auto, null, &names, &types, &@as([100]std.builtin.Type.Struct.FieldAttributes, @splat(.{})));
}
fn node(c: *core.Context) core.EncodeError!void {
    try c.node();
    try c.chargeWork(1);
}
fn separate(value: anytype, out: *Encoder, c: *core.Context) Encoder.Error!void {
    try node(c);
    try c.enter();
    defer c.leave();
    try c.count(100);
    try out.begin(.record, "", 100, c);
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        try c.node();
        try c.span(name.len, true);
        try c.chargeWork(name.len);
        try out.key(name, c);
        try node(c);
        try out.integer(@field(value, name), c);
    }
    try out.end(c);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seed = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 17;
    var memory: [16384]u8 = undefined;
    inline for (0..10) |i| {
        const T = Schema(i);
        var value: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names) |name| @field(value, name) = seed +% name.len;
        var writer = std.Io.Writer.fixed(&memory);
        var out: Encoder = .{ .writer = &writer };
        var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
        if (options.common) try core.serialize(value, &out, &c) else try separate(value, &out, &c);
        if (c.allocationRequested() != 0) return error.UnexpectedAllocation;
        std.mem.doNotOptimizeAway(writer.buffered());
    }
}
