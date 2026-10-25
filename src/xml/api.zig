//! XML on Strand's shared type mapping and ownership core.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Parsed = core.Parsed;
pub const Element = @import("Value.zig").Element;
pub const Entry = @import("Value.zig").Entry;
pub const Part = @import("Value.zig").Part;
pub const Scanner = @import("Scanner.zig");
pub const Whitespace = WireEncoder.Whitespace;
pub const Namespace = WireEncoder.Namespace;

pub const ParseOptions = struct {
    limits: core.Limits = .{},
    /// A member the type does not have (an attribute or a child element) is
    /// refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    /// The name the root element must have; any name when null.
    root: ?[]const u8 = null,
    /// Check names against Namespaces in XML 1.0: qualified names, every
    /// prefix bound. Off for a document that is well-formed XML and not
    /// namespace-well-formed.
    namespaces: bool = true,
    diagnostics: ?*core.Diagnostics = null,
};
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        /// Where the document's working storage comes from: the caller's
        /// allocator, given back once the value is read, or the caller's
        /// arena in a leaky parse.
        backing: std.mem.Allocator,
        options: ParseOptions,
        pub fn run(self: @This(), c: *core.Context, input: []const u8) Error!T {
            try c.input(input.len);
            var scratch = c.scratch(self.backing);
            var decoder: WireDecoder = undefined;
            decoder.init(input, .{ .namespaces = self.options.namespaces }, self.options.root, scratch.allocator());
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
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{ .reject_unknown_fields = !options.ignore_unknown_fields };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T){ .backing = gpa, .options = options }))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "xml";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    }, Decode(T){ .backing = gpa, .options = options });
}

/// The document's root element as a `T`, its text borrowed from `input`
/// where it needs no decoding (no reference, no carriage return). `input`
/// outlives the result; the result's `deinit` releases only what it
/// allocated.
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
        d.format = "xml";
    }
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return (Decode(T){ .backing = arena, .options = options }).run(&c, input);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// The root element's name. A union written at the root is its arm's
    /// element instead, as a union's root is read.
    root: []const u8,
    /// `<?xml version="1.0" encoding="UTF-8"?>` before the root.
    declaration: bool = true,
    whitespace: Whitespace = .minified,
    /// Namespace declarations on the root's start tag.
    namespaces: []const Namespace = &.{},
    /// Where what a write holds past its own storage is held: elements nested
    /// past 64 levels, and the attribute names of open tags past 32 (kept to
    /// refuse one given twice). With none, a value that needs it is refused.
    allocator: ?std.mem.Allocator = null,
};
/// The error set of a write of `T`.
fn WriteError(comptime T: type) type {
    return @typeInfo(@TypeOf(core.serialize(@as(T, undefined), @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
}
/// Writes `value` as an XML document. A null optional field is left out. A
/// sink failure may publish a prefix; write into a fixed or allocating
/// writer first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteError(@TypeOf(value))!void {
    // Writing allocates nothing through the core.
    var fixed: std.heap.FixedBufferAllocator = .init(&.{});
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    c.omit_nulls = true;
    if (options.declaration) {
        const declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
        try c.output(declaration.len);
        try output.writeAll(declaration);
        if (options.whitespace != .minified) {
            try c.output(1);
            try output.writeAll("\n");
        }
    }
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.root, options.whitespace, options.namespaces, options.allocator);
    defer encoder.deinit();
    try core.serialize(value, &encoder, &c);
    try encoder.finish();
}

pub const Decoder_module = WireDecoder;
pub const Encoder_module = WireEncoder;
pub const text_module = @import("text.zig");
pub const dtd_module = @import("dtd.zig");
pub const document_module = @import("document.zig");

test {
    _ = text_module;
    _ = dtd_module;
    _ = Scanner;
}
