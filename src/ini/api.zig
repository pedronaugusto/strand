//! INI on Strand's shared type mapping and ownership core, in Python
//! configparser's dialect unless another is given.
const std = @import("std");
const limit = @import("../core/limit.zig");
const aegis = @import("aegis");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
const syntax = @import("text.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Dialect = syntax.Dialect;
pub const Value = @import("Value.zig").Value;
pub const Member = @import("Value.zig").Member;
pub const Part = @import("Value.zig").Part;
pub const Parsed = core.Parsed;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    dialect: Dialect = .{},
    /// A key or section the type does not have is refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    diagnostics: ?*core.Diagnostics = null,
};
const valid_dialect = "a delimiter, each an ASCII byte that is not white space or `[`, and comment prefixes of some bytes and no line break";
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        fn run(c: *core.Context, input: []const u8, dialect: Dialect) Error!T {
            aegis.assert.pre(dialect.valid(), valid_dialect);
            try c.input(input.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input, dialect);
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
        /// The decoder with its dialect, as acquisition calls it.
        pub const Runner = struct {
            dialect: Dialect,
            pub fn run(self: Runner, c: *core.Context, input: []const u8) Error!T {
                return Decode(T).run(c, input, self.dialect);
            }
        };
    };
}
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{ .reject_unknown_fields = !options.ignore_unknown_fields };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).Runner{ .dialect = .{} }))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "ini";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    }, Decode(T).Runner{ .dialect = options.dialect });
}
/// An INI document as a `T`, a struct or a map: the keys before its first
/// section are its members, and each section a member that is a struct or a
/// map of its keys. A value on one line is borrowed from `input`, which
/// outlives the result; the result's `deinit` releases only what it allocated.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The document, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T).Error!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "ini";
    }
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input, options.dialect);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    dialect: Dialect = .{},
};
/// Streams `value`, a struct or a map, as an INI document: its members that
/// hold a value first, then each struct or map member as a section. A sink
/// failure may publish a prefix; write into a fixed or allocating writer
/// first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    aegis.assert.pre(options.dialect.valid(), valid_dialect);
    var no_scratch: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.dialect);
    defer encoder.deinit();
    try core.serialize(value, &encoder, &c);
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;

test {
    _ = syntax;
}
