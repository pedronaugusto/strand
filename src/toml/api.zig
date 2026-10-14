//! TOML on Strand's shared type mapping and ownership core.
const std = @import("std");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Version = WireDecoder.Version;
pub const Parsed = core.Parsed;
pub const Value = @import("Value.zig").Value;
pub const Entry = @import("Value.zig").Entry;
pub const OffsetDateTime = @import("codecs.zig").OffsetDateTime;
pub const LocalDateTime = @import("codecs.zig").LocalDateTime;
pub const LocalDate = @import("codecs.zig").LocalDate;
pub const LocalTime = @import("codecs.zig").LocalTime;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    /// A key the type does not have is refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    diagnostics: ?*core.Diagnostics = null,
    /// TOML 1.1.0 by default; `.v1_0` reads as an older peer would.
    version: Version = .v1_1,
};
/// A document read as a `T`, in the TOML it is read as.
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        version: Version,
        /// Where the document's working storage comes from: the caller's
        /// allocator, given back once the value is read, or the caller's
        /// arena in a leaky parse.
        backing: std.mem.Allocator,
        pub fn run(self: @This(), c: *core.Context, input: []const u8) Error!T {
            try c.input(input.len);
            var scratch = c.scratch(self.backing);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input, self.version, scratch.allocator());
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c) catch |err| {
                if (c.diagnostics) |d| {
                    d.offset = decoder.place(d.offset);
                    locate(d, input);
                }
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
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T){ .version = .v1_1, .backing = gpa }))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "toml";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields },
        .diagnostics = options.diagnostics,
    }, Decode(T){ .version = options.version, .backing = gpa });
}
/// The document as a `T`, its strings borrowed from `input` where they hold
/// no escape. `input` outlives the result; the result's `deinit` releases
/// only what it allocated.
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
        d.format = "toml";
    }
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields };
    c.diagnostics = options.diagnostics;
    return (Decode(T){ .version = options.version, .backing = arena }).run(&c, input);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// What the document is held on until its root closes.
    allocator: std.mem.Allocator,
    /// TOML has no null: one is refused, unless optional fields that are
    /// null are left out of their tables.
    nulls: Nulls = .refuse,
    pub const Nulls = enum { refuse, omit };
};
/// Writes `value`, a struct, a map or a union, as a TOML document. A sink
/// failure may publish a prefix; write into a fixed or allocating writer
/// first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(value, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    var no_scratch: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    c.omit_nulls = options.nulls == .omit;
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.allocator);
    defer encoder.deinit();
    try core.serialize(value, &encoder, &c);
    try encoder.finish();
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;

test {
    _ = @import("temporal.zig");
    _ = @import("number.zig");
    _ = @import("text.zig");
    _ = @import("codecs.zig");
    _ = @import("syntax.zig");
}
