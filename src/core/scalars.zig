//! The aegis scalars, read and written as what they hold. Each says which it
//! is in its `aegis_scalar` declaration (aegis 0.1.18, contract 1), by which a
//! type is recognized and its integer and range read, never by its name or its
//! shape: a program pinning another aegis version than strand's builds another
//! copy of aegis, whose types are never equal to the ones strand's copy makes
//! but declare the same. A value is made only through its own checked
//! functions, as the contract names them.
const std = @import("std");
const aegis = @import("aegis");

pub const Kind = enum {
    /// Its representation's integer: `int.Checked`, `int.Saturating`,
    /// `units.Count`, `units.Bits`, `units.Instant` and `id.Id`.
    integer,
    /// `int.Ranged`: an integer the range admits, `NumberOutOfRange` otherwise.
    ranged,
    /// `id.NonZero`: an integer other than zero.
    nonzero,
    /// `id.Counter`: the last id it issued, 0 before the first.
    counter,
    /// `units.Duration` and `units.Bytes`: their text form (`1m30s`,
    /// `64MiB`), which is exact both ways.
    text,
};

/// What `T` is as an aegis scalar, or null when it is none. A contract other
/// than 1, the one this strand reads, does not compile: its fields or the
/// functions a value is made with may have changed.
pub fn kind(comptime T: type) ?Kind {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum" => {},
        else => return null,
    }
    if (!@hasDecl(T, "aegis_scalar")) return null;
    const declared = T.aegis_scalar;
    if (@typeInfo(@TypeOf(declared)) != .@"struct" or !@hasField(@TypeOf(declared), "contract")) return null;
    if (declared.contract != 1) @compileError(std.fmt.comptimePrint("strand: {s} is an aegis scalar of contract {d}; this strand reads contract 1", .{ @typeName(T), declared.contract }));
    const scalar = declared.kind;
    if (scalar == .ranged) return .ranged;
    if (scalar == .nonzero) return .nonzero;
    if (scalar == .counter) return .counter;
    if (scalar == .duration or scalar == .bytes) return .text;
    if (scalar == .checked or scalar == .saturating or scalar == .count or scalar == .bits or scalar == .instant or scalar == .id) return .integer;
    return null;
}

/// The integer an aegis scalar is held in, as its declaration states it.
pub fn Representation(comptime T: type) type {
    return T.aegis_scalar.representation;
}

/// The integer a scalar of an integer kind holds.
pub fn integer(value: anytype) Representation(@TypeOf(value)) {
    const T = @TypeOf(value);
    if (comptime kind(T) == .counter) return if (value.last()) |id| id.raw() else 0;
    return value.raw();
}

/// The scalar of an integer kind that holds `n`.
pub fn fromInteger(comptime T: type, n: Representation(T)) error{NumberOutOfRange}!T {
    return switch (comptime kind(T).?) {
        .ranged => T.init(n) catch error.NumberOutOfRange,
        .nonzero => T.fromRaw(n) catch error.NumberOutOfRange,
        .counter => T.init(n),
        .integer => if (@typeInfo(T) == .@"struct") T.init(n) else T.fromRaw(n),
        .text => comptime unreachable, // unreachable: a text kind is read as text
    };
}

/// The text form of a scalar of the text kind, in `buffer`.
pub fn text(value: anytype, buffer: *[@TypeOf(value).max_text_len]u8) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    value.format(&w) catch aegis.assert.never("max_text_len holds every value's text");
    return w.buffered();
}

/// The scalar of the text kind that `bytes` spells.
pub fn parse(comptime T: type, bytes: []const u8) error{ SyntaxError, NumberOutOfRange, InexactNumber }!T {
    return T.parse(bytes) catch |err| switch (err) {
        error.Malformed => error.SyntaxError,
        error.Overflow => error.NumberOutOfRange,
        error.Inexact => error.InexactNumber,
    };
}
