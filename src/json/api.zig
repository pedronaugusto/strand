//! JSON on Strand's shared type mapping and ownership core.
const std = @import("std");
const core = @import("../core.zig");
const std_value = @import("std_value.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Raw = core.Raw(Format);
pub const Parsed = core.Parsed;
pub const Value = @import("Value.zig").Value;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    ignore_unknown_fields: bool = false,
    reject_duplicates: bool = true,
    diagnostics: ?*core.Diagnostics = null,
};
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        fn run(c: *core.Context, input: []const u8) Error!T {
            var decoder = try WireDecoder.init(c, input);
            defer decoder.deinit();
            const result = core.deserialize(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
            return result;
        }
    };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "json";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields, .reject_duplicates = options.reject_duplicates },
        .diagnostics = options.diagnostics,
    }, Decode(T).run);
}
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Decode(T).run(@as(*core.Context, undefined), input))).error_union.error_set!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "json";
    }
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields, .reject_duplicates = options.reject_duplicates };
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input);
}
/// Bounded bridge with standard dynamic numeric alternatives and standard owner.
/// Transfers one arena; the stable standard owner permits managed Array mutation.
pub fn parseStdValue(gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) core.DecodeError!std.json.Parsed(std.json.Value) {
    var owner = try parseOwned(Value, gpa, input, options);
    defer if (owner.isLive()) owner.deinit();
    return std_value.take(&owner, options.limits);
}
pub const WriteOptions = struct { limits: core.Limits = .{}, scratch: []u8 = &.{} };
/// Streams checked JSON. A sink failure may publish a prefix. For transactional
/// publication encode into a fixed/allocating writer before writing to the sink.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(if (@TypeOf(value) == std.json.Value) @as(Value, undefined) else value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    var encoder: WireEncoder = .{ .writer = output };
    defer encoder.extra.deinit(c.allocator());
    defer encoder.extra_keys.deinit(c.allocator());
    const data = if (@TypeOf(value) == std.json.Value) try std_value.toNative(value, &c) else value;
    return core.serialize(data, &encoder, &c);
}
// The historical JSON contract remains one implementation and is explicitly
// separate from finite strict entry points.
const legacy = codec_module;
pub const parseLine = legacy.parseLine;
pub const LegacyParseOptions = legacy.ParseOptions;
pub const LegacyParseError = legacy.ParseLineError;
pub const LegacyRaw = legacy.Raw;
pub const writeValue = legacy.writeValue;
pub const writeObjectOpen = legacy.writeObjectOpen;
pub const OpenObject = legacy.OpenObject;
pub const ValueOptions = legacy.ValueOptions;

pub const Encoder_module = WireEncoder;
pub const codec_module = @import("codec.zig");
pub const Scanner_module = @import("Scanner.zig");
pub const parse_module = @import("parse.zig");
pub const from_value_module = @import("from_value.zig");
pub const tagging_module = @import("tagging.zig");
pub const leading_module = @import("leading.zig");
pub const route_module = @import("route.zig");
pub const member_scan_module = @import("member_scan.zig");
pub const control_module = @import("control.zig");
pub const output_module = @import("output.zig");
pub const int_module = @import("int.zig");
pub const indent_module = @import("indent.zig");
pub const work_module = @import("work.zig");
pub const decode_module = @import("decode.zig");
pub const encode_module = @import("encode.zig");
pub const raw_module = @import("raw.zig");
pub const line_parser_module = @import("parse/line.zig");
pub const EncodeBuffer_module = @import("encode/Buffer.zig");

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = Scanner_module;
    _ = control_module;
    _ = indent_module;
    _ = int_module;
    _ = leading_module;
    _ = member_scan_module;
    _ = route_module;
    _ = tagging_module;
    _ = line_parser_module;
}
