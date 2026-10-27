//! JSON on strand's shared type mapping and ownership core.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const aegis = @import("aegis");
const std_value = @import("std_value.zig");
const decoding = @import("Decoder.zig");
const encoding = @import("Encoder.zig");
const WireEncoder = encoding.Dialect(false);
const indent = @import("indent.zig");
const route = @import("route.zig");
const object_members = @import("members.zig");
const control = @import("control.zig");
const work = @import("work.zig");
pub const Format = decoding.Format;
pub const capabilities = decoding.capabilities;
/// One JSON value kept as its bytes: checked when it is read, written back as
/// it came, and parsed when it is wanted. A carried payload, a request handed
/// on, the part of a record a reader only routes.
pub const Raw = struct {
    /// One complete JSON value, with nothing before or after it.
    bytes: []const u8,

    pub const StrandRawFormat = Format;
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
        _ = emitOn(false, gpa, &out.writer, value, options, false) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
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
/// How JSON is read. The defaults read it strictly; the rest are the choices
/// a reader that must take what a more lenient one takes may want (Go's
/// `encoding/json` reads as `.duplicates = .merge, .names = .fold_case,
/// .nulls = .keep, .integers = .digits, .invalid_unicode = .replace` with
/// unknown fields ignored).
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    ignore_unknown_fields: bool = false,
    /// A record's member, or an object's key read as a map's, given twice:
    /// refused (the default); kept `.first`, `.last`, or `.merge`d, the later
    /// read into what the earlier left, for every record and map
    /// (`core.Duplicates`); `null` as each record's type declares
    /// (`strand.duplicates`), a map's keys all kept.
    duplicates: ?core.Duplicates = .reject,
    /// A member's name matched to a field `.exact`ly, or exactly first and
    /// then by case folding (`.fold_case`, `core.Names`).
    names: core.Names = .exact,
    /// `null` where the type has none: refused, or `.keep` the value as it is
    /// (`core.Nulls`).
    nulls: core.Nulls = .refuse,
    /// An integer: any number whose value is whole (`1.0`, `1e2`), or
    /// `.digits` alone, a minus only for a signed type.
    integers: core.Integers = .whole,
    /// A string with a byte that is not UTF-8 or a surrogate escape without
    /// its pair: refused, or read with each as U+FFFD (`.replace`). Map keys
    /// and member names are read so too; a `Raw` keeps its bytes as written.
    invalid_unicode: core.InvalidUnicode = .refuse,
    diagnostics: ?*core.Diagnostics = null,
};
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{
        .reject_unknown_fields = !options.ignore_unknown_fields,
        .duplicates = options.duplicates,
        .names = options.names,
        .nulls = options.nulls,
        .integers = options.integers,
        .invalid_unicode = options.invalid_unicode,
    };
}
fn Decode(comptime T: type) type {
    return Dialect(T, .json);
}
fn Dialect(comptime T: type, comptime grammar: decoding.Grammar) type {
    const Wire = decoding.Dialect(grammar);
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*Wire, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        /// The parse's value in a type of its own, as aegis's boundary marker
        /// asks of what it refines, whatever `T` is.
        const Refined = struct { value: T };
        const RefinedPrefix = struct { value: Prefix(T) };
        /// Where bytes enter the JSON reader: through aegis's boundary marker
        /// (`input.Untrusted`), its one checked boundary, past which what it
        /// reads is the parse's.
        fn run(c: *core.Context, input: []const u8) Error!T {
            // aegis: design: `descriptor.same` and the decoder's `zero` recurse over T's own fields and children, as deep as T nests when strand compiles, never as deep as the input
            return (try aegis.input.Untrusted([]const u8).init(input).parse(c, checked)).value;
        }
        fn checked(c: *core.Context, input: []const u8) Error!Refined {
            return .{ .value = try parsed(c, input) };
        }
        fn parsed(c: *core.Context, input: []const u8) Error!T {
            work.parse();
            try c.input(input.len);
            var decoder: Wire = undefined;
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
            return (try aegis.input.Untrusted([]const u8).init(input).parse(c, checkedFront)).value;
        }
        fn checkedFront(c: *core.Context, input: []const u8) Error!RefinedPrefix {
            return .{ .value = try parsedFront(c, input) };
        }
        fn parsedFront(c: *core.Context, input: []const u8) Error!Prefix(T) {
            work.parse();
            try c.input(input.len);
            var decoder: Wire = undefined;
            decoder.init(c, input);
            defer decoder.deinit();
            var cursor: core.Cursor(Wire) = .{ .backend = &decoder, .context = c };
            const value = cursor.readFresh(T, .{}) catch |err| {
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
fn context(arena: std.mem.Allocator, options: ParseOptions, grammar: decoding.Grammar) core.Context {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = formatName(grammar);
    }
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return c;
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).run))).error_union.error_set!Parsed(T) {
    return parseDialect(T, .json, ownership, gpa, input, options);
}
/// What diagnostics call the format read: JSONC is JSON with comments.
fn formatName(grammar: decoding.Grammar) []const u8 {
    return if (grammar == .json5) "json5" else "json";
}
fn parseDialect(comptime T: type, comptime grammar: decoding.Grammar, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Dialect(T, grammar).run))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = formatName(grammar);
    }
    const acquisition: core.AcquisitionOptions = .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    };
    return core.acquireWith(T, ownership, gpa, input, acquisition, Dialect(T, grammar).run);
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
    return parseLeakyDialect(T, .json, arena, input, options);
}
fn parseLeakyDialect(comptime T: type, comptime grammar: decoding.Grammar, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(Dialect(T, grammar).run(@as(*core.Context, undefined), input))).error_union.error_set!T {
    var c = context(arena, options, grammar);
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    return Dialect(T, grammar).run(&c, input);
}
/// JSONC, the JSON of editors' settings and `tsconfig.json`: `//` and
/// `/* */` comments wherever whitespace may be, and a comma after a
/// container's last member or element, read with JSON's options and promises.
/// A `Raw` read from JSONC keeps its comments, so it is JSONC too. There is no
/// JSONC writer: what is written is JSON.
pub const jsonc = struct {
    /// `json.parse` of JSONC.
    pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseDialect(T, .jsonc, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
        return parseDialect(T, .jsonc, .borrowed, gpa, input, options);
    }
    /// `json.parseOwned` of JSONC.
    pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseDialect(T, .jsonc, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
        return parseDialect(T, .jsonc, .owned, gpa, input, options);
    }
    /// `json.parseLeaky` of JSONC.
    pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseLeakyDialect(T, .jsonc, arena, input, options))).error_union.error_set!T {
        return parseLeakyDialect(T, .jsonc, arena, input, options);
    }
};
/// JSON5 (json5.org), JSON for people to write: JSONC's comments and final
/// commas, and keys as ECMAScript identifier names, strings in single quotes
/// and continued across lines, ECMAScript's escapes (`\v`, `\0`, `\xHH`, any
/// other character as itself), numbers in hexadecimal, with a plus, with a
/// point and no digits on one side of it, `Infinity` and `NaN`, and Unicode's
/// space separators as white space. Read with JSON's options and promises:
/// a key given twice is refused unless `duplicates` says otherwise, and a
/// string that is not Unicode refused unless `invalid_unicode` does. A number
/// stays its lexeme in a `Value`, so a JSON5 spelling of one writes as JSON5
/// and not as JSON. A `Raw` read from JSON5 keeps its text, so it is JSON5.
pub const json5 = struct {
    /// `json.parse` of JSON5.
    pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseDialect(T, .json5, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
        return parseDialect(T, .json5, .borrowed, gpa, input, options);
    }
    /// `json.parseOwned` of JSON5.
    pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseDialect(T, .json5, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
        return parseDialect(T, .json5, .owned, gpa, input, options);
    }
    /// `json.parseLeaky` of JSON5.
    pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseLeakyDialect(T, .json5, arena, input, options))).error_union.error_set!T {
        return parseLeakyDialect(T, .json5, arena, input, options);
    }
    /// Everything writing a `T` as JSON5 can fail with.
    pub fn WriteError(comptime T: type) type {
        return WriteErrorOf(T, true);
    }
    /// `json.write` as JSON5: the same text, but that a float JSON has no
    /// spelling for is written `Infinity`, `-Infinity` or `NaN` and not
    /// refused, and a `Value`'s number or a `Raw` is checked as JSON5.
    pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteErrorOf(@TypeOf(value), true)!void {
        return writeDialect(true, output, value, options);
    }
};
/// A value read from the front of some bytes, and where it ended.
pub fn Prefix(comptime T: type) type {
    return struct { value: T, end: usize };
}
/// `parseLeaky` of the value at the front of `input`, where what follows it is
/// the caller's, as a stream decoder reads one value and leaves the rest: a
/// pretty JSON Lines record is read this way out of the bytes buffered behind
/// it, across the line breaks inside it.
pub fn parsePrefixLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError(T)!Prefix(T) {
    var c = context(arena, options, .json);
    if (limit.exceeds(input.len, options.limits.input_bytes)) return error.InputLimit;
    return Dialect(T, .json).front(&c, input);
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
    /// What a null optional field is: written as `null`, or left out of its
    /// record. A log that is read by a reader with defaults is smaller left out,
    /// and a field can say the same for itself with `.omit = .null_value`.
    nulls: Nulls = .write,
    pub const Nulls = enum { write, omit };
};
/// Everything writing a `T` can fail with.
pub fn WriteError(comptime T: type) type {
    return WriteErrorOf(T, false);
}
fn WriteErrorOf(comptime T: type, comptime json5_text: bool) type {
    return @typeInfo(@TypeOf(core.serialize(if (T == std.json.Value) @as(Value, undefined) else @as(T, undefined), @as(*encoding.Dialect(json5_text), undefined), @as(*core.Context, undefined)))).error_union.error_set || std.Io.Writer.Error;
}
/// Writes `value` as checked JSON. Output is published a stage at a time, so a
/// failure can leave a prefix in `output`; encode into a fixed or allocating
/// writer first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteError(@TypeOf(value))!void {
    return writeDialect(false, output, value, options);
}
fn writeDialect(comptime json5_text: bool, output: *std.Io.Writer, value: anytype, options: WriteOptions) WriteErrorOf(@TypeOf(value), json5_text)!void {
    if (options.whitespace != .minified) {
        var buffer: [256]u8 = undefined;
        var laid: indent.Indent = .init(output, unit(options.whitespace), &buffer);
        _ = try emit(json5_text, &laid.interface, value, options, false);
        return laid.interface.flush();
    }
    _ = try emit(json5_text, output, value, options, false);
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
/// Writes `value`, as JSON5 where `json5_text`; with `open`, an object at the
/// top is left without its closing brace, and whether it has members is
/// returned.
fn emit(comptime json5_text: bool, output: *std.Io.Writer, value: anytype, options: WriteOptions, open: bool) WriteErrorOf(@TypeOf(value), json5_text)!bool {
    var fixed: std.heap.FixedBufferAllocator = .init(options.scratch);
    return emitOn(json5_text, fixed.allocator(), output, value, options, open);
}
/// `emit` with `storage` for what writing needs beyond the stack.
fn emitOn(comptime json5_text: bool, storage: std.mem.Allocator, output: *std.Io.Writer, value: anytype, options: WriteOptions, open: bool) WriteErrorOf(@TypeOf(value), json5_text)!bool {
    var c = core.Context.init(storage, options.limits, .borrowed);
    c.acceptance.duplicates = .reject;
    c.omit_nulls = options.nulls == .omit;
    var encoder: encoding.Dialect(json5_text) = undefined;
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
    const members = try emit(false, output, value, minified, true);
    return .{ .output = output, .options = minified, .empty = !members };
}

pub const kindOf = route.kindOf;
pub const tagOf = route.tagOf;
pub const memberOf = route.memberOf;
pub const memberStringOf = route.memberStringOf;
pub const Members = object_members.Members;
pub const Member = object_members.Member;
pub const MembersOptions = object_members.MembersOptions;
pub const MembersError = object_members.MembersError;
pub const intOf = object_members.intOf;
pub const indexOfControl = control.indexOfControl;

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = control;
    _ = indent;
    _ = object_members;
    _ = route;
    _ = @import("member_scan.zig");
    _ = @import("text.zig");
    _ = @import("json5.zig");
}
