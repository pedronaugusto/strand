//! JSON read into a type as Go's `encoding/json` reads it into the Go type
//! that matches it, for a program that must take what a Go program takes and
//! make of it what that program makes.
//!
//! The types match as Go's do: `bool`, the integers (Go's of the same width
//! and sign), `f32` and `f64`, `[]const u8` as a Go `string`, `?T` as a
//! pointer, a struct, `[]const T` as a slice, `[N]T` as an array, and
//! `core.Pairs([]const u8, V)` as a `map[string]V`. A struct's members are
//! named as strand names them (`rename_all`, a field's `name` and `aliases`;
//! a `skip_decode` field is Go's `json:"-"`), every field has a default, which
//! stands for Go's zero value, and every name is ASCII. A type of its own
//! declares `strandGoDecode`, Go's `json.Unmarshaler`.
//!
//! What Go does, this does:
//! - a member is its field's by exact name, else by Go's case folding (the
//!   first field in order whose name folds to it): ASCII letters either case,
//!   and `ſ` and the Kelvin sign as `s` and `k`; `_` and `-` count;
//! - a member a struct does not name is passed over, and one given twice is
//!   read twice, into what the first left: a struct, an optional's value and
//!   a slice's elements are read into, a map's entries added to;
//! - `null` leaves a bool, a number, a string, a struct and an array as they
//!   are and empties an optional, a slice and a map;
//! - an integer is a number written as one and in range (`-0` is zero; `1.0`
//!   and `1e2` are not integers), a float one in range;
//! - in a string, a byte that is not UTF-8 and a `\u` escape of a surrogate
//!   half on its own each read as U+FFFD.
//!
//! What it does not: Go nests to 10 000, strand to `limits.depth`; a slice
//! read a third time reuses the elements of the second only, where Go's reuse
//! follows the capacity it grew to.
const std = @import("std");
const core = @import("../core.zig");
const descriptor = @import("../core/descriptor.zig");
const api = @import("api.zig");
const Value = @import("Value.zig").Value;
const Member = @import("Value.zig").Member;
const Allocator = std.mem.Allocator;

/// How the value is read.
pub const Options = struct {
    limits: core.Limits = .{},
    /// What may follow the value: white space alone, as `json.Unmarshal`
    /// wants, or anything, as a `json.Decoder` leaves what follows the value
    /// it read.
    rest: enum { space, any } = .space,
};

/// What reading into a type can fail with, a type's own `strandGoDecode`
/// included: Go's `UnmarshalTypeError` is `UnexpectedType` or, for a
/// number out of the type's range, `NumberOutOfRange`; `InvalidValue` is a
/// type's own refusal.
pub const MapError = error{ OutOfMemory, UnexpectedType, NumberOutOfRange, InvalidValue };

/// Everything `parseLeaky` can fail with.
pub const Error = api.ParseError(Value) || MapError;

/// `input` read into a `T` that starts as every field's default, as
/// `json.Unmarshal` reads into a zero value. Strings point into `arena` or
/// into `input`.
pub fn parseLeaky(comptime T: type, arena: Allocator, input: []const u8, options: Options) Error!T {
    var value: T = zero(T);
    try parseIntoLeaky(T, arena, input, &value, options);
    return value;
}

/// `input` read into `into` as it stands, as `json.Unmarshal` reads into a
/// value already set: members merge into it. On an error `into` is left
/// part-way, as Go leaves it.
pub fn parseIntoLeaky(comptime T: type, arena: Allocator, input: []const u8, into: *T, options: Options) Error!void {
    const text = try repaired(arena, input);
    const parse_options: api.ParseOptions = .{ .limits = options.limits, .reject_duplicates = false };
    const tree = switch (options.rest) {
        .space => try api.parseLeaky(Value, arena, text, parse_options),
        .any => (try api.parsePrefixLeaky(Value, arena, text, parse_options)).value,
    };
    try decodeInto(T, arena, tree, into);
}

/// `value` read into `into` as Go reads a JSON value into a Go value.
pub fn decodeInto(comptime T: type, arena: Allocator, value: Value, into: *T) MapError!void {
    if (comptime isPairs(T)) return decodeMap(T, arena, value, into);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "strandGoDecode")) return T.strandGoDecode(into, arena, value);
    switch (@typeInfo(T)) {
        .bool => switch (value) {
            .null_value => {},
            .boolean => |b| into.* = b,
            else => return error.UnexpectedType,
        },
        .int => switch (value) {
            .null_value => {},
            .number => |lexeme| into.* = try integer(T, lexeme),
            else => return error.UnexpectedType,
        },
        .float => switch (value) {
            .null_value => {},
            .number => |lexeme| {
                const f = std.fmt.parseFloat(T, lexeme) catch return error.UnexpectedType;
                if (!std.math.isFinite(f)) return error.NumberOutOfRange;
                into.* = f;
            },
            else => return error.UnexpectedType,
        },
        .optional => |o| switch (value) {
            .null_value => into.* = null,
            else => if (into.*) |*inner| {
                try decodeInto(o.child, arena, value, inner);
            } else {
                var fresh: o.child = zero(o.child);
                try decodeInto(o.child, arena, value, &fresh);
                into.* = fresh;
            },
        },
        .array => |a| switch (value) {
            .null_value => {},
            .array => |items| for (into, 0..) |*slot, k| {
                if (k < items.len) try decodeInto(a.child, arena, items[k], slot) else slot.* = zero(a.child);
            },
            else => return error.UnexpectedType,
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("strand.json.go reads no " ++ @typeName(T));
            if (p.child == u8) return switch (value) {
                .null_value => {},
                .string => |s| into.* = s,
                else => error.UnexpectedType,
            };
            try decodeSlice(T, arena, value, into);
        },
        .@"struct" => switch (value) {
            .null_value => {},
            .object => |members| for (members) |m| {
                try decodeMember(T, arena, m, into);
            },
            else => return error.UnexpectedType,
        },
        else => @compileError("strand.json.go reads no " ++ @typeName(T)),
    }
}

fn decodeSlice(comptime T: type, arena: Allocator, value: Value, into: *T) MapError!void {
    const E = @typeInfo(T).pointer.child;
    switch (value) {
        .null_value => into.* = &.{},
        .array => |items| {
            const old = into.*;
            const out = try arena.alloc(E, items.len);
            for (out, items, 0..) |*slot, item, k| {
                slot.* = if (k < old.len) old[k] else zero(E);
                try decodeInto(E, arena, item, slot);
            }
            into.* = out;
        },
        else => return error.UnexpectedType,
    }
}

fn decodeMap(comptime T: type, arena: Allocator, value: Value, into: *T) MapError!void {
    const Entry = @typeInfo(@FieldType(T, "items")).pointer.child;
    const V = @FieldType(Entry, "value");
    if (@FieldType(Entry, "key") != []const u8) @compileError("strand.json.go reads a map with string keys alone");
    switch (value) {
        .null_value => into.* = .{ .items = &.{} },
        .object => |members| {
            var entries: std.ArrayList(Entry) = .empty;
            try entries.appendSlice(arena, into.items);
            for (members) |m| {
                // A map's value is read into a zero value each time, as Go
                // reads it, and then set.
                var fresh: V = zero(V);
                try decodeInto(V, arena, m.value, &fresh);
                for (entries.items) |*e| {
                    if (std.mem.eql(u8, e.key, m.key)) {
                        e.value = fresh;
                        break;
                    }
                } else try entries.append(arena, .{ .key = m.key, .value = fresh });
            }
            into.* = .{ .items = entries.items };
        },
        else => return error.UnexpectedType,
    }
}

fn decodeMember(comptime T: type, arena: Allocator, member: Member, into: *T) MapError!void {
    const fields = @typeInfo(T).@"struct".field_names;
    const exact = comptime names(T, .exact);
    const folded = comptime names(T, .folded);
    inline for (fields, exact) |name, spellings| {
        inline for (spellings) |s| if (std.mem.eql(u8, member.key, s)) {
            return decodeInto(@FieldType(T, name), arena, member.value, &@field(into, name));
        };
    }
    var buffer: [256]u8 = undefined;
    const key = fold(member.key, &buffer) orelse return;
    inline for (fields, folded) |name, spellings| {
        inline for (spellings) |s| if (std.mem.eql(u8, key, s)) {
            return decodeInto(@FieldType(T, name), arena, member.value, &@field(into, name));
        };
    }
}

/// The names each field of `T` is read under, as written or folded; a field
/// never read has none.
fn names(comptime T: type, comptime how: enum { exact, folded }) [@typeInfo(T).@"struct".field_names.len][]const []const u8 {
    var out: [@typeInfo(T).@"struct".field_names.len][]const []const u8 = undefined;
    for (@typeInfo(T).@"struct".field_names, 0..) |name, k| {
        const f = descriptor.field(T, name);
        if (f.skip_decode) {
            out[k] = &.{};
            continue;
        }
        var list: []const []const u8 = &.{};
        for (.{f.name} ++ f.aliases) |spelling| {
            for (spelling) |c| if (c >= 0x80) @compileError("strand.json.go folds ASCII names alone: " ++ spelling);
            list = list ++ .{if (how == .exact) spelling else asciiUpper(spelling)};
        }
        out[k] = list;
    }
    return out;
}

fn asciiUpper(comptime text: []const u8) []const u8 {
    var out: [text.len]u8 = undefined;
    for (text, &out) |c, *o| o.* = std.ascii.toUpper(c);
    const final = out;
    return &final;
}

/// `key` folded as Go folds a name, as far as an ASCII name can fold to it:
/// ASCII letters to upper case, `ſ` (U+017F) to `S` and the Kelvin sign
/// (U+212A) to `K`. `null` for a key with any other non-ASCII letter, which no
/// ASCII name folds to, or one longer than `buffer`.
fn fold(key: []const u8, buffer: []u8) ?[]const u8 {
    var n: usize = 0;
    var at: usize = 0;
    while (at < key.len) {
        if (n == buffer.len) return null;
        const c = key[at];
        if (c < 0x80) {
            buffer[n] = std.ascii.toUpper(c);
            at += 1;
        } else if (std.mem.startsWith(u8, key[at..], "\u{17f}")) {
            buffer[n] = 'S';
            at += 2;
        } else if (std.mem.startsWith(u8, key[at..], "\u{212a}")) {
            buffer[n] = 'K';
            at += 3;
        } else return null;
        n += 1;
    }
    return buffer[0..n];
}

/// A number written as an integer and in `T`'s range, as Go's
/// `strconv.ParseInt` and `ParseUint` read it: an unsigned type takes no sign.
fn integer(comptime T: type, lexeme: []const u8) MapError!T {
    if (std.mem.findAny(u8, lexeme, ".eE") != null) return error.UnexpectedType;
    if (@typeInfo(T).int.signedness == .unsigned and lexeme.len != 0 and lexeme[0] == '-') return error.UnexpectedType;
    return std.fmt.parseInt(T, lexeme, 10) catch |err| switch (err) {
        error.Overflow => error.NumberOutOfRange,
        error.InvalidCharacter => error.UnexpectedType,
    };
}

/// The value Go starts a `T` from: every field's default.
pub fn zero(comptime T: type) T {
    if (comptime isPairs(T)) return .{ .items = &.{} };
    return switch (@typeInfo(T)) {
        .bool => false,
        .int, .float => 0,
        .optional => null,
        .array => |a| @splat(zero(a.child)),
        .pointer => &.{},
        .@"struct" => .{},
        else => @compileError("strand.json.go reads no " ++ @typeName(T)),
    };
}

fn isPairs(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "strandKeyType") and @hasField(T, "items");
}

/// `input` with its strings made UTF-8 as Go reads them: each byte that does
/// not begin a UTF-8 sequence, and each `\u` escape of a surrogate half not
/// paired, becomes U+FFFD. Nothing outside a string is touched, so what is
/// not JSON stays so. `input` itself when there is nothing to change.
pub fn repaired(arena: Allocator, input: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var changed = false;
    var in_string = false;
    var at: usize = 0;
    while (at < input.len) {
        const c = input[at];
        if (!in_string or c < 0x80) {
            if (c == '"') in_string = !in_string;
            const len = if (in_string and c == '\\') escapeLength(input[at..]) else 1;
            if (len == 6 and lone(input[at..][0..6])) {
                try out.appendSlice(arena, input[copied..at]);
                try out.appendSlice(arena, "\\ufffd");
                copied = at + 6;
                changed = true;
            }
            at += len;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (n != 0 and at + n <= input.len and validSequence(input[at..][0..n])) {
            at += n;
            continue;
        }
        try out.appendSlice(arena, input[copied..at]);
        try out.appendSlice(arena, "\u{fffd}");
        at += 1;
        copied = at;
        changed = true;
    }
    if (!changed) return input;
    try out.appendSlice(arena, input[copied..]);
    return out.items;
}

fn validSequence(bytes: []const u8) bool {
    return switch (bytes.len) {
        2 => if (std.unicode.utf8Decode2(bytes[0..2].*)) |_| true else |_| false,
        3 => if (std.unicode.utf8Decode3(bytes[0..3].*)) |_| true else |_| false,
        4 => if (std.unicode.utf8Decode4(bytes[0..4].*)) |_| true else |_| false,
        else => false,
    };
}

/// How many bytes the escape at the front of `bytes` takes: twelve for a
/// surrogate pair, six for any other `\u` escape, else the backslash and the
/// byte after it.
fn escapeLength(bytes: []const u8) usize {
    const first = if (bytes.len >= 6 and bytes[1] == 'u') quad(bytes[2..6]) else null;
    const high = first orelse return @min(bytes.len, 2);
    if (std.unicode.utf16IsHighSurrogate(high) and bytes.len >= 12 and bytes[6] == '\\' and bytes[7] == 'u') {
        if (quad(bytes[8..12])) |low| if (std.unicode.utf16IsLowSurrogate(low)) return 12;
    }
    return 6;
}

/// Whether `escape`, six bytes `escapeLength` took alone, is a `\u` escape of
/// a surrogate half, which Go reads as U+FFFD.
fn lone(escape: []const u8) bool {
    if (escape.len != 6 or escape[0] != '\\' or escape[1] != 'u') return false;
    const unit = quad(escape[2..6]) orelse return false;
    return std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit);
}

fn quad(bytes: []const u8) ?u16 {
    var out: u16 = 0;
    for (bytes[0..4]) |c| out = (out << 4) | @as(u16, switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return null,
    });
    return out;
}
