//! JSON on strand's shared type mapping and ownership core.
const std = @import("std");
const core = @import("../core.zig");
const std_value = @import("std_value.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
const indent = @import("indent.zig");
const route = @import("route.zig");
const leading = @import("leading.zig");
const control = @import("control.zig");
const work = @import("work.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
/// One JSON value kept as its bytes: checked when it is read, written back as
/// it came, and parsed when it is wanted. A carried payload, a request handed
/// on, the part of a record a reader only routes.
pub const Raw = struct {
    /// One complete JSON value, with nothing before or after it.
    bytes: []const u8,

    pub const strandRawFormat = Format;
    pub const strand = .{ .fields = .{ .bytes = .{ .as = .bytes } } };
    /// JSON `null`, as a default: `data: strand.json.Raw = .null`.
    pub const @"null": Raw = .{ .bytes = "null" };

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Raw {
        return .{ .bytes = try access.raw(Format) };
    }
    pub fn strandSerialize(self: Raw, access: anytype) @TypeOf(access.*).Error!void {
        try access.raw(Format, self.bytes);
    }

    /// `value` written by `write`, as a `Raw` on `gpa`. The bytes are one
    /// allocation of exactly their length: `gpa.free(raw.bytes)` returns it.
    pub fn encode(gpa: std.mem.Allocator, value: anytype, options: WriteOptions) (WriteError(@TypeOf(value)) || std.mem.Allocator.Error)!Raw {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = emitOn(gpa, &out.writer, value, options, false) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        return .{ .bytes = try out.toOwnedSlice() };
    }

    /// The value, as a `T`: `parseLeaky` over the bytes, with its options and its
    /// ownership. Strings with no escape point into `raw.bytes`, so they live as
    /// long as those do.
    pub fn parse(raw: Raw, comptime T: type, arena: std.mem.Allocator, options: ParseOptions) ParseError(T)!T {
        return parseLeaky(T, arena, raw.bytes, options);
    }
};
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
            work.parse();
            try c.input(input.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input);
            defer decoder.deinit();
            const result = core.deserialize(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
            return result;
        }
        /// A value at the front of `input`, and where it ended: what comes
        /// after it is the caller's.
        fn front(c: *core.Context, input: []const u8) Error!Prefix(T) {
            work.parse();
            try c.input(input.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input);
            defer decoder.deinit();
            var cursor: core.Cursor(WireDecoder) = .{ .backend = &decoder, .context = c };
            const value = cursor.read(T, .{}) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
            return .{ .value = value, .end = decoder.rootEnd() orelse return error.SyntaxError };
        }
    };
}
/// Everything parsing a `T` can fail with.
pub fn ParseError(comptime T: type) type {
    return @typeInfo(@TypeOf(parseLeaky(T, @as(std.mem.Allocator, undefined), "", .{}))).error_union.error_set;
}
fn context(arena: std.mem.Allocator, options: ParseOptions) core.Context {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "json";
    }
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields, .reject_duplicates = options.reject_duplicates };
    c.diagnostics = options.diagnostics;
    return c;
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
/// `input` as a `T`, owned by the returned `Parsed`. Strings with nothing to
/// unescape point into `input`, which must outlive the result.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// `parse`, with every string copied: the result is independent of `input`.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Decode(T).run(@as(*core.Context, undefined), input))).error_union.error_set!T {
    var c = context(arena, options);
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    return Decode(T).run(&c, input);
}
/// A value read from the front of some bytes, and where it ended.
pub fn Prefix(comptime T: type) type {
    return struct { value: T, end: usize };
}
/// `parseLeaky` of the value at the front of `input`, where what follows it is
/// the caller's: a pretty JSON Lines record is read this way out of the bytes
/// buffered behind it, across the line breaks inside it.
pub fn parsePrefixLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError(T)!Prefix(T) {
    var c = context(arena, options);
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    return Decode(T).front(&c, input);
}
/// Bounded bridge with standard dynamic numeric alternatives and standard owner.
/// Transfers one arena; the stable standard owner permits managed Array mutation.
pub fn parseStdValue(gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) core.DecodeError!std.json.Parsed(std.json.Value) {
    var owner = try parseOwned(Value, gpa, input, options);
    defer if (owner.isLive()) owner.deinit();
    return std_value.take(&owner, options.limits);
}

/// How written JSON is laid out: on one line, or indented as `std.json`
/// indents it, a member or an item to a line.
pub const Whitespace = enum { minified, indent_1, indent_2, indent_3, indent_4, indent_8, indent_tab };
pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Scratch for checking a `Raw` and converting a `std.json.Value`; a
    /// fixed schema needs none.
    scratch: []u8 = &.{},
    whitespace: Whitespace = .minified,
};
/// Everything writing a `T` can fail with.
pub fn WriteError(comptime T: type) type {
    return @typeInfo(@TypeOf(core.serialize(if (T == std.json.Value) @as(Value, undefined) else @as(T, undefined), @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set || std.Io.Writer.Error;
}
/// Writes `value` as checked JSON. Output is published a stage at a time, so a
/// failure can leave a prefix in `output`; encode into a fixed or allocating
/// writer first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteError(@TypeOf(value))!void {
    if (options.whitespace != .minified) {
        var buffer: [256]u8 = undefined;
        var laid: indent.Indent = .init(output, unit(options.whitespace), &buffer);
        _ = try emit(&laid.interface, value, options, false);
        return laid.interface.flush();
    }
    _ = try emit(output, value, options, false);
}
fn unit(whitespace: Whitespace) []const u8 {
    return switch (whitespace) {
        .minified => "",
        .indent_1 => " ",
        .indent_2 => "  ",
        .indent_3 => "   ",
        .indent_4 => "    ",
        .indent_8 => "        ",
        .indent_tab => "\t",
    };
}
/// Writes `value`; with `open`, an object at the top is left without its
/// closing brace, and whether it has members is returned.
fn emit(output: *std.Io.Writer, value: anytype, options: WriteOptions, open: bool) WriteError(@TypeOf(value))!bool {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    return emitOn(fixed.allocator(), output, value, options, open);
}
/// `emit` with `storage` for what writing needs beyond the stack.
fn emitOn(storage: std.mem.Allocator, output: *std.Io.Writer, value: anytype, options: WriteOptions, open: bool) WriteError(@TypeOf(value))!bool {
    var c = core.Context.init(storage, options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    var encoder: WireEncoder = undefined;
    encoder.init(output);
    encoder.open_root = open;
    defer encoder.deinit(&c);
    const data = if (@TypeOf(value) == std.json.Value) try std_value.toNative(value, &c) else value;
    try core.serialize(data, &encoder, &c);
    try encoder.flush(&c);
    return encoder.root_members;
}

/// An object `writeObjectOpen` began: the members written so far, and no
/// closing brace yet.
pub const OpenObject = struct {
    output: *std.Io.Writer,
    options: WriteOptions,
    /// Whether no member has been written, so the next needs no comma.
    empty: bool,

    /// Writes one more member: `name` and `value` as `write` writes a struct's
    /// field, after a comma where a member came before it. Nothing checks that
    /// `name` is not one already written.
    pub fn member(object: *OpenObject, comptime name: []const u8, value: anytype) WriteError(@TypeOf(value))!void {
        const key = comptime "\"" ++ WireEncoder.escapedName(name) ++ "\":";
        try object.output.writeAll(if (object.empty) key else "," ++ key);
        object.empty = false;
        try write(object.output, value, object.options);
    }

    /// Writes the closing brace. The object is finished.
    pub fn close(object: OpenObject) std.Io.Writer.Error!void {
        try object.output.writeByte('}');
    }
};

/// Writes a struct as `write` writes it but for the closing brace, and hands
/// back the object to go on with: members the struct does not have, such as
/// a checksum over the bytes before it, written by `OpenObject.member`, then
/// `close`. What `output` holds after this is exactly the object so far, so a
/// checksum taken over it covers what a reader sees in front of the member
/// that carries it. Written minified, whatever `options.whitespace` says.
pub fn writeObjectOpen(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteError(@TypeOf(value))!OpenObject {
    const T = @TypeOf(value);
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".is_tuple or @hasDecl(T, "strandSerialize"))
            @compileError("writeObjectOpen takes a struct that writes as its fields, not '" ++ @typeName(T) ++ "'");
    }
    var minified = options;
    minified.whitespace = .minified;
    const members = try emit(output, value, minified, true);
    return .{ .output = output, .options = minified, .empty = !members };
}

pub const kindOf = route.kindOf;
pub const tagOf = route.tagOf;
pub const memberOf = route.memberOf;
pub const memberStringOf = route.memberStringOf;
pub const leadingIntMembers = leading.leadingIntMembers;
pub const IntMembers = leading.IntMembers;
pub const indexOfControl = control.indexOfControl;

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = control;
    _ = indent;
    _ = leading;
    _ = route;
    _ = @import("member_scan.zig");
    _ = @import("text.zig");
}
