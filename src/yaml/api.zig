//! YAML on Strand's shared type mapping and ownership core.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Parsed = core.Parsed;
pub const Value = @import("Value.zig").Value;
pub const Entry = @import("Value.zig").Entry;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    /// A key the type does not have is refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    diagnostics: ?*core.Diagnostics = null,
};
/// A stream read as a `T`: one document, or every document as a `T` each.
fn Decode(comptime T: type, comptime root: WireDecoder.Root) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        /// Where the stream's working storage comes from: the caller's
        /// allocator, given back once the value is read, or the caller's
        /// arena in a leaky parse.
        backing: std.mem.Allocator,
        pub fn run(self: @This(), c: *core.Context, input: []const u8) Error!T {
            try c.input(input.len);
            var scratch = c.scratch(self.backing);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input, root, scratch.allocator());
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c) catch |err| {
                if (c.diagnostics) |d| {
                    d.offset = decoder.place(d.offset);
                    d.locate(input);
                }
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
        }
    };
}
fn parseWith(comptime T: type, comptime root: WireDecoder.Root, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T, root){ .backing = gpa }))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "yaml";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields },
        .diagnostics = options.diagnostics,
    }, Decode(T, root){ .backing = gpa });
}
fn leaky(comptime T: type, comptime root: WireDecoder.Root, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T, root).Error!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "yaml";
    }
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields };
    c.diagnostics = options.diagnostics;
    return (Decode(T, root){ .backing = arena }).run(&c, input);
}

/// The one document of `input` as a `T` (no document is an empty one,
/// null), its strings borrowed from `input` where they hold no escape and
/// no folded line. `input` outlives the result; the result's `deinit`
/// releases only what it allocated. A second document is refused.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .document, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .document, .borrowed, gpa, input, options);
}
/// The document, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .document, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .document, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T, .document).Error!T {
    return leaky(T, .document, arena, input, options);
}
/// Every document of `input`, each a `T`, borrowed as `parse` borrows.
pub fn parseStream(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith([]const T, .stream, .borrowed, gpa, input, options))).error_union.error_set!Parsed([]const T) {
    return parseWith([]const T, .stream, .borrowed, gpa, input, options);
}
/// Every document, independent of `input`.
pub fn parseStreamOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith([]const T, .stream, .owned, gpa, input, options))).error_union.error_set!Parsed([]const T) {
    return parseWith([]const T, .stream, .owned, gpa, input, options);
}
/// Every document, on the caller's arena.
pub fn parseStreamLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode([]const T, .stream).Error![]const T {
    return leaky([]const T, .stream, arena, input, options);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Where what a write holds past its own storage is held: collections
    /// nested past 64 levels, and a map's keys past 128 (kept to refuse one
    /// given twice). With none, a value that needs it is refused.
    allocator: ?std.mem.Allocator = null,
    /// What a null optional field is: written as `null`, or left out of its
    /// mapping.
    nulls: Nulls = .write,
    pub const Nulls = enum { write, omit };
};
/// The error set of a write of `T`.
fn WriteError(comptime T: type) type {
    return @typeInfo(@TypeOf(core.serialize(@as(T, undefined), @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
}
/// Writes `value` as a YAML document. A sink failure may publish a prefix;
/// write into a fixed or allocating writer first where nothing must reach
/// the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteError(@TypeOf(value))!void {
    // Writing allocates nothing through the core.
    var fixed: std.heap.FixedBufferAllocator = .init(&.{});
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    c.omit_nulls = options.nulls == .omit;
    try document(output, value, options, &c);
}
/// Writes each of `values` as a document of one stream, `---` before each
/// but the first.
pub fn writeStream(output: *std.Io.Writer, values: anytype, options: WriteOptions) WriteError(@TypeOf(values[0]))!void {
    var fixed: std.heap.FixedBufferAllocator = .init(&.{});
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    c.omit_nulls = options.nulls == .omit;
    for (values, 0..) |value, i| {
        if (i > 0) {
            try c.output(4);
            try output.writeAll("---\n");
        }
        try document(output, value, options, &c);
    }
}
fn document(output: *std.Io.Writer, value: anytype, options: WriteOptions, c: *core.Context) WriteError(@TypeOf(value))!void {
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.allocator);
    defer encoder.deinit();
    try core.serialize(value, &encoder, c);
    try encoder.finish();
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;

test {
    _ = @import("schema.zig");
    _ = @import("document.zig");
}
