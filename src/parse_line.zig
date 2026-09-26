//! One line's bytes, already in memory, as a `T`: `parseLine`, the options
//! it takes and what it reports. Every reader here parses through this, and
//! so does `Raw.parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("scanner.zig");
const typed_parse = @import("parse.zig");
const decode = @import("decode.zig");

/// How a line's bytes are turned into a `T`.
///
/// The defaults are the ones a log or a protocol wants: a reader that is
/// older than the writer ignores fields it does not know, and a field the
/// writer omitted takes the Zig default declared on the struct. A field with
/// no default that is absent from the line is `error.MissingField`.
pub const ParseOptions = struct {
    /// When true, a key with no matching field is skipped. When false, it is
    /// `error.UnknownField`.
    ignore_unknown_fields: bool = true,
    /// When false, a string field that needs no unescaping points into the
    /// line's own bytes and nothing is allocated for it. When true, every
    /// string is copied out of the line, so the value borrows nothing from
    /// it.
    copy_strings: bool = false,
    /// What a line that names the same field twice does. `std.json`'s
    /// default, kept here, is to refuse it; the other two are what a log
    /// written by a language whose own encoder allows duplicates needs, since
    /// those encoders resolve a repeat by keeping one of the two.
    duplicate_fields: DuplicateFields = .@"error",
    /// Where to put what `std.json` can say about where it got to. Filled in
    /// whether the parse succeeded or not; see `Diagnostics`.
    ///
    /// Asking costs the scan a little bookkeeping per line, which is why the
    /// readers ask only about a line that has already failed.
    diagnostics: ?*Diagnostics = null,
};

/// How far into a line `std.json` got.
///
/// On a line that did not parse, this is where it gave up — which is not
/// always the byte that is wrong, but is always at or after it, and is what
/// turns "line 402 is malformed" into something a person can look at.
pub const Diagnostics = struct {
    /// The 0-based byte offset in the line. `line.len` means the parse ran
    /// off the end, which is what a truncated line does.
    offset: usize = 0,
    /// The 1-based line within what was parsed, which is 1 for every
    /// minified line and counts within the record in `.pretty` mode.
    line: u64 = 1,
    /// The 1-based column within that line.
    column: u64 = 1,
};

/// What a repeated key in one line means. The names are `std.json`'s.
pub const DuplicateFields = enum {
    /// `error.DuplicateField`, which through a `Reader` is
    /// `error.MalformedLine`.
    @"error",
    /// The first value wins and the rest are skipped.
    use_first,
    /// The last value wins, which is what most JSON encoders do.
    use_last,
};

/// Everything `std.json` can report about a line whose bytes are already in
/// memory. `error.OutOfMemory` is the allocator's; every other member means
/// the line did not describe a `T`.
pub const ParseLineError = std.json.ParseError(std.json.Scanner);

/// Parses one line's bytes as a `T`.
///
/// `line` is one JSON value with no line terminator; a trailing `\n` is
/// `error.SyntaxError`, because a JSON Lines line does not contain one.
///
/// Ownership: allocations are made on `allocator` and are not individually
/// tracked, so `allocator` should be an arena you can drop as a whole (this
/// is `std.json.parseFromSliceLeaky`'s contract). With the default
/// `copy_strings = false`, string fields that need no unescaping point into
/// `line` and are valid exactly as long as it is; with `copy_strings = true`
/// the returned value borrows nothing from `line`.
pub fn parseLine(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: ParseOptions,
) ParseLineError!T {
    var value: T = undefined;
    try parseLineInto(T, allocator, line, options, &value);
    return value;
}

/// `parseLine`, with the value decoded into `out` where it lies. `Reader`
/// calls this with the `value` of the `Line` it is about to hand back.
///
/// A value decoded somewhere else and then copied is a value whose fields
/// were just stored one at a time and are loaded straight back a register
/// at a time. On x86_64 a load that spans two stores still in flight is not
/// forwarded from them; it waits for both to reach the cache. The decoder
/// copied its value out once, which every parse paid, and the reader copied
/// it again into its `Line`, which was the gap between a line and its parse
/// there. Decoded in place, a field is stored once, where it is read from.
pub fn parseLineInto(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: ParseOptions,
    out: *T,
) ParseLineError!void {
    if (line.len != 0 and line[line.len - 1] == '\n') return error.SyntaxError;
    if (options.diagnostics) |where| {
        out.* = try parseDiagnosed(T, allocator, line, options, where);
        return;
    }
    if (comptime decode.supports(T)) {
        return decode.parseInto(T, allocator, line, jsonOptions(options, line.len), out) catch {
            // The direct path is for good lines. On a refusal, the token
            // source remains the oracle for the precise public error.
            var oracle: Scanner = .initCompleteInput(allocator, line);
            defer oracle.deinit();
            out.* = try typed_parse.parse(T, allocator, &oracle, jsonOptions(options, line.len));
        };
    }

    var scanner: Scanner = .initCompleteInput(allocator, line);
    defer scanner.deinit();
    out.* = try typed_parse.parse(T, allocator, &scanner, jsonOptions(options, line.len));
}

/// `parseLine` for the caller who asked where a line gave up.
///
/// It is a function of its own rather than a branch inside `parseLine`
/// because a scanner that has been handed a `Diagnostics` counts lines and
/// columns as it goes, and a scanner that has not is free of that. Split
/// here, the compiler sees a `null` it can fold away on the path every good
/// line takes, and the counting lives only on the path that asked for it.
fn parseDiagnosed(
    comptime T: type,
    allocator: Allocator,
    line: []const u8,
    options: ParseOptions,
    out: *Diagnostics,
) ParseLineError!T {
    var scanner: Scanner = .initCompleteInput(allocator, line);
    defer scanner.deinit();

    var where: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&where);

    const parsed = typed_parse.parse(T, allocator, &scanner, jsonOptions(options, line.len));
    // Read out before the scanner goes: what the diagnostics point at is the
    // scanner's own cursor.
    out.* = .{
        .offset = @min(@as(usize, @intCast(where.getByteOffset())), line.len),
        .line = where.getLine(),
        .column = where.getColumn(),
    };
    return parsed;
}

/// This package's parse options as `std.json`'s.
fn jsonOptions(options: ParseOptions, max_value_len: usize) std.json.ParseOptions {
    return .{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .allocate = if (options.copy_strings) .alloc_always else .alloc_if_needed,
        .duplicate_field_behavior = switch (options.duplicate_fields) {
            .@"error" => .@"error",
            .use_first => .use_first,
            .use_last => .use_last,
        },
        .max_value_len = max_value_len,
    };
}

test parseLine {
    const Event = struct {
        kind: []const u8,
        at: u64,
        note: ?[]const u8 = null,
        level: enum { info, warn } = .info,
    };

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"kind\":\"open\",\"at\":17,\"extra\":[1,2,3]}";
    const event = try parseLine(Event, arena.allocator(), line, .{});

    try std.testing.expectEqualStrings("open", event.kind);
    try std.testing.expectEqual(@as(u64, 17), event.at);
    // Absent fields take their declared defaults, and `extra` is ignored.
    try std.testing.expectEqual(@as(?[]const u8, null), event.note);
    try std.testing.expectEqual(.info, event.level);
    // "open" needed no unescaping, so it is a view into `line`.
    try std.testing.expect(event.kind.ptr == line.ptr + std.mem.indexOf(u8, line, "open").?);
}
