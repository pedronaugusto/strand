//! JSON on Strand's shared type mapping and ownership core.
const std = @import("std");
const core = @import("../core.zig");
const std_value = @import("std_value.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
const Indent = @import("indent.zig").Indent;
const route = @import("route.zig");
const work = @import("work.zig");
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
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
            var decoder = try WireDecoder.init(c, input);
            defer decoder.deinit();
            const result = core.deserialize(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
            return result;
        }
        const Prefix = struct { value: T, len: usize };
        fn front(c: *core.Context, input: []const u8) Error!Prefix {
            work.parse();
            var decoder = try WireDecoder.init(c, input);
            defer decoder.deinit();
            const result = core.deserializePrefix(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
            return .{ .value = result, .len = decoder.offset() };
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
/// Strict by default: unknown fields and repeated keys are refused. Strings with
/// no escape point into `input`, which must outlive the result.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The value, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
fn leaky(arena: std.mem.Allocator, options: ParseOptions) core.Context {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "json";
    }
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = .{ .reject_unknown_fields = !options.ignore_unknown_fields, .reject_duplicates = options.reject_duplicates };
    c.diagnostics = options.diagnostics;
    return c;
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Decode(T).run(@as(*core.Context, undefined), input))).error_union.error_set!T {
    var c = leaky(arena, options);
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    return Decode(T).run(&c, input);
}
/// `parseLeaky` for a value at the front of `input`: what follows it is the
/// caller's, and `len` is how many bytes the value took, whitespace after it
/// not counted. The limit on input bytes applies to the whole of `input`.
pub fn parsePrefix(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Decode(T).front(@as(*core.Context, undefined), input))).error_union.error_set!struct { value: T, len: usize } {
    var c = leaky(arena, options);
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    const front = try Decode(T).front(&c, input);
    return .{ .value = front.value, .len = front.len };
}
/// Bounded bridge with standard dynamic numeric alternatives and standard owner.
/// Transfers one arena; the stable standard owner permits managed Array mutation.
pub fn parseStdValue(gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) core.DecodeError!std.json.Parsed(std.json.Value) {
    var owner = try parseOwned(Value, gpa, input, options);
    defer if (owner.isLive()) owner.deinit();
    return std_value.take(&owner, options.limits);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    /// Memory for what writing needs beyond the stack: nesting past 128 levels
    /// and the keys of a map past 128, a fixed budget of bytes. A value of
    /// ordinary shape needs none.
    scratch: []u8 = &.{},
    /// What a null optional field is: written as `null`, or left out of its
    /// record. A log that is read by a reader with defaults is smaller left out.
    nulls: Nulls = .write,
    /// Every byte out is ASCII: text past it is written as `\u` escapes.
    ascii: bool = false,
    /// One line, or the value laid out over several, two spaces to a level, as
    /// `std.json` lays it out. A reader of JSON Lines in pretty mode reads it back.
    layout: Layout = .compact,
    pub const Nulls = enum { write, omit };
    pub const Layout = enum { compact, indented };
};

fn WriteError(comptime V: type) type {
    return @typeInfo(@TypeOf(core.serialize(if (V == std.json.Value) @as(Value, undefined) else @as(V, undefined), @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
}

/// Writing on `storage` for what a value needs beyond the stack. `leave_open`
/// leaves the root record without its closing brace and says whether it held
/// any member.
fn writeOn(storage: std.mem.Allocator, output: *std.Io.Writer, value: anytype, options: WriteOptions, leave_open: ?*bool) (WriteError(@TypeOf(value)) || std.Io.Writer.Error)!void {
    var c = core.Context.init(storage, options.limits, .borrowed);
    c.acceptance.reject_duplicates = true;
    c.omit_nulls = options.nulls == .omit;
    var sink = output;
    var buffer: [256]u8 = undefined;
    var indent: Indent = undefined;
    if (options.layout == .indented) {
        indent = .init(output, .indent_2, &buffer);
        sink = &indent.interface;
    }
    var encoder: WireEncoder = .{ .writer = sink, .ascii = options.ascii, .leave_open = leave_open != null };
    defer encoder.extra.deinit(c.allocator());
    defer encoder.extra_keys.deinit(c.allocator());
    const data = if (@TypeOf(value) == std.json.Value) try std_value.toNative(value, &c) else value;
    try core.serialize(data, &encoder, &c);
    try encoder.flush(&c);
    if (options.layout == .indented) try sink.flush();
    if (leave_open) |empty| empty.* = encoder.left_empty;
}

/// Streams checked JSON. A sink failure may publish a prefix. For transactional
/// publication encode into a fixed/allocating writer before writing to the sink.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) (WriteError(@TypeOf(value)) || std.Io.Writer.Error)!void {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    return writeOn(fixed.allocator(), output, value, options, null);
}

/// An object written up to but not including its closing brace, for a caller
/// that adds members of its own: a checksum over the bytes before it, a length,
/// a signature, an envelope around a value. What `output` holds after `begin`
/// is exactly the object so far.
pub const Object = struct {
    output: *std.Io.Writer,
    options: WriteOptions,
    /// Whether no member has been written, so the next needs no comma.
    empty: bool,

    /// Writes `value`, a record, as `write` does but for its closing brace.
    pub fn begin(output: *std.Io.Writer, value: anytype, options: WriteOptions) (WriteError(@TypeOf(value)) || std.Io.Writer.Error)!Object {
        comptime {
            const info = @typeInfo(@TypeOf(value));
            if (info != .@"struct" or info.@"struct".is_tuple) @compileError("json.Object.begin takes a struct that writes as its fields, not '" ++ @typeName(@TypeOf(value)) ++ "'");
        }
        std.debug.assert(options.layout == .compact);
        var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
        var empty = true;
        try writeOn(fixed.allocator(), output, value, options, &empty);
        return .{ .output = output, .options = options, .empty = empty };
    }

    /// Writes one more member, `name` and `value` spelled as `write` spells a
    /// record's field, after a comma where a member came before it. Nothing
    /// checks that `name` is not one already written.
    pub fn member(object: *Object, comptime name: []const u8, value: anytype) (WriteError(@TypeOf(value)) || std.Io.Writer.Error)!void {
        if (!object.empty) try object.output.writeByte(',');
        object.empty = false;
        try object.output.writeAll("\"" ++ comptime escapedName(name) ++ "\":");
        try write(object.output, value, object.options);
    }

    /// Writes the closing brace. The object is finished.
    pub fn close(object: Object) std.Io.Writer.Error!void {
        try object.output.writeByte('}');
    }
};
fn escapedName(comptime name: []const u8) []const u8 {
    comptime var result: []const u8 = "";
    inline for (name) |byte| result = result ++ switch (byte) {
        '"' => "\\\"",
        '\\' => "\\\\",
        0...31 => std.fmt.comptimePrint("\\u00{x:0>2}", .{byte}),
        else => &[_]u8{byte},
    };
    return result;
}

/// One JSON value kept as the bytes it was written in: checked when read,
/// written back as it came, decoded when it is wanted. A carried payload, a
/// request handed on, the part of a record a reader only routes.
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
    pub fn encode(gpa: std.mem.Allocator, value: anytype, options: WriteOptions) (WriteError(@TypeOf(value)) || std.Io.Writer.Error || std.mem.Allocator.Error)!Raw {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        writeOn(gpa, &out.writer, value, options, null) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        return .{ .bytes = try out.toOwnedSlice() };
    }

    /// The value, as a `T`: `parseLeaky` over the bytes, with its options and its
    /// ownership. Strings with no escape point into `raw.bytes`, so they live as
    /// long as those do.
    pub fn parse(raw: Raw, comptime T: type, arena: std.mem.Allocator, options: ParseOptions) @typeInfo(@TypeOf(parseLeaky(T, arena, raw.bytes, options))).error_union.error_set!T {
        return parseLeaky(T, arena, raw.bytes, options);
    }
};

pub const kindOf = route.kindOf;
pub const tagOf = route.tagOf;
pub const memberOf = route.memberOf;
pub const memberStringOf = route.memberStringOf;
pub const leadingIntMembers = @import("leading.zig").leadingIntMembers;
pub const IntMembers = @import("leading.zig").IntMembers;
pub const indexOfControl = @import("control.zig").indexOfControl;

pub const Encoder_module = WireEncoder;
pub const Decoder_module = WireDecoder;
pub const Scanner_module = @import("Scanner.zig");
pub const leading_module = @import("leading.zig");
pub const route_module = route;
pub const member_scan_module = @import("member_scan.zig");
pub const control_module = @import("control.zig");
pub const indent_module = @import("indent.zig");
pub const work_module = @import("work.zig");
pub const EncodeBuffer_module = @import("encode/Buffer.zig");

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = Scanner_module;
    _ = control_module;
    _ = indent_module;
    _ = leading_module;
    _ = member_scan_module;
    _ = route_module;
}
