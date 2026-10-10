//! ZON on Strand's shared type mapping and ownership core.
const std = @import("std");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
/// A value kept as the ZON text it was written as, checked as a whole.
pub const Raw = core.Raw(Format);
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
            var decoder = try WireDecoder.init(c, input);
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c) catch |err| {
                if (c.diagnostics) |d| locate(d, input);
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
        }
    };
}
/// Where in the text a failure is: the line and column of its offset.
fn locate(d: *core.Diagnostics, input: []const u8) void {
    const at = @min(d.offset, input.len);
    var line: usize = 1;
    var column: usize = 1;
    for (input[0..at]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    d.line = line;
    d.column = column;
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "zon";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields },
        .diagnostics = options.diagnostics,
    }, Decode(T).run);
}
/// The value, with its text borrowed from `input` where a string has no escape.
/// `input` outlives the result; the result's `deinit` releases only what it allocated.
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
        d.format = "zon";
    }
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields };
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input);
}
pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Scratch for what writing needs beyond the stack: nesting past 128 levels
    /// and map keys, a fixed budget of bytes. None is enough for ordinary values.
    scratch: []u8 = &.{},
    /// std's layout, or only the whitespace the syntax needs.
    whitespace: bool = true,
};
/// Streams ZON. A sink failure may publish a prefix. For transactional
/// publication write into a fixed or allocating writer before the sink.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    var encoder: WireEncoder = .{ .writer = output, .whitespace = options.whitespace };
    defer encoder.extra.deinit(c.allocator());
    defer encoder.extra_keys.deinit(c.allocator());
    try core.serialize(value, &encoder, &c);
    try encoder.flush(&c);
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;
pub const number_module = @import("number.zig");
pub const text_module = @import("text.zig");

test {
    _ = number_module;
    _ = text_module;
}
