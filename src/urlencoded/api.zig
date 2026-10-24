//! Forms and query strings (application/x-www-form-urlencoded) on Strand's
//! shared type mapping and ownership core.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Parsed = core.Parsed;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    /// A field the type does not have is refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    diagnostics: ?*core.Diagnostics = null,
};
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        fn run(c: *core.Context, input: []const u8) Error!T {
            try c.input(input.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input);
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
        }
    };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "urlencoded";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields },
        .diagnostics = options.diagnostics,
    }, Decode(T).run);
}
/// The value of a form or query string (`a=1&b=x`, without the `?`), its
/// text borrowed from `input` where decoding changes nothing. `input`
/// outlives the result; the result's `deinit` releases only what it allocated.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The value, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Decode(T).run(@as(*core.Context, undefined), input))).error_union.error_set!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "urlencoded";
    }
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields };
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input);
}
pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Scratch for a name's path past 4 KiB encoded or nesting past 128
    /// levels, a fixed budget of bytes. None is enough for ordinary values.
    scratch: []u8 = &.{},
};
/// Streams a form. A sink failure may publish a prefix. For transactional
/// publication write into a fixed or allocating writer before the sink.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    var encoder: WireEncoder = undefined;
    encoder.init(output, c.allocator());
    defer encoder.deinit();
    try core.serialize(value, &encoder, &c);
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;
pub const text_module = @import("text.zig");

test {
    _ = text_module;
}
