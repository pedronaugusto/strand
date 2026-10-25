//! .env files on Strand's shared type mapping and ownership core, read as
//! python-dotenv reads them, with nothing interpolated.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
const syntax = @import("text.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Parsed = core.Parsed;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    /// A key the type does not have is refused unless this says to skip it.
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
                if (c.diagnostics) |d| {
                    d.offset = decoder.offset();
                    d.locate(input);
                }
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
        }
    };
}
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{ .reject_unknown_fields = !options.ignore_unknown_fields };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "dotenv";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    }, Decode(T).run);
}
/// A .env file as a `T`, a struct or a map of its keys. A value with no
/// escape read is borrowed from `input`, which outlives the result; the
/// result's `deinit` releases only what it allocated.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The file, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T).Error!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "dotenv";
    }
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Scratch for a map's keys past its 128th, remembered to refuse one
    /// given twice (`OutOfMemory` where it runs out); a struct needs none.
    scratch: []u8 = &.{},
};
/// Streams `value`, a struct or a map, as a .env file: a `KEY=value` line
/// for each member, quoted only where it must be. A sink failure may publish
/// a prefix; write into a fixed or allocating writer first where nothing
/// must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    var encoder: WireEncoder = undefined;
    encoder.init(output);
    defer encoder.deinit(&c);
    try core.serialize(value, &encoder, &c);
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;

test {
    _ = syntax;
}
