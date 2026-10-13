//! MessagePack on Strand's shared type mapping and ownership core.
const std = @import("std");
const aegis = @import("aegis");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
/// One MessagePack value kept as its bytes: checked when it is read, written
/// back as it came.
pub const Raw = core.Raw(Format);
pub const Parsed = core.Parsed;
pub const Value = @import("Value.zig").Value;
pub const Entry = @import("Value.zig").Entry;
pub const Ext = @import("codecs.zig").Ext;
pub const Timestamp = @import("codecs.zig").Timestamp;
pub const Profile = WireEncoder.Profile;
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
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{ .reject_unknown_fields = !options.ignore_unknown_fields };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "msgpack";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    }, Decode(T).run);
}
/// One MessagePack value as a `T`, its strings, binaries and extension data
/// borrowed from `input`, which outlives the result; the result's `deinit`
/// releases only what it allocated.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The value, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T).Error!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "msgpack";
    }
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// How maps are ordered. `.deterministic` holds each map until it
    /// closes, on `allocator`.
    profile: Profile = .compact,
    allocator: ?std.mem.Allocator = null,
};
/// Streams one MessagePack value, each part in its smallest format: the
/// shortest integer family, float 32 where it holds a float's bits, the
/// shortest length. A sink failure may publish a prefix; write into a fixed
/// or allocating writer first where nothing must reach the sink unless all
/// of it does. Writing allocates nothing in the compact profile.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    aegis.assert.pre(options.profile == .compact or options.allocator != null, "the deterministic profile sorts each map on an allocator");
    var no_scratch: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.profile, options.allocator);
    defer encoder.deinit();
    try core.serialize(value, &encoder, &c);
    try encoder.finish();
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;
pub const wire_module = @import("wire.zig");
pub const codecs_module = @import("codecs.zig");

test {
    _ = wire_module;
    _ = codecs_module;
}
