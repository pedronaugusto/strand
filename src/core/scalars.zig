//! The aegis scalars, read and written as what they hold. Each publishes the
//! parameters it was made from (its `Representation`, and a `Scale`,
//! `Domain`, `Clock` or range where it has one), so a type is recognized by
//! rebuilding it from them: a type that only looks like one, or another
//! revision of aegis, is not taken for it.
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

/// What `T` is as an aegis scalar, or null when it is none.
pub fn kind(comptime T: type) ?Kind {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum" => {},
        else => return null,
    }
    if (!@hasDecl(T, "Representation") or @TypeOf(T.Representation) != type) return null;
    const R = T.Representation;
    if (@typeInfo(R) != .int) return null;
    if (@hasDecl(T, "minimum") and @hasDecl(T, "maximum")) {
        return if (T == aegis.int.Ranged(R, T.minimum, T.maximum)) .ranged else null;
    }
    if (@hasDecl(T, "Scale")) {
        if (@hasDecl(T, "Clock")) return if (T == aegis.units.Instant(T.Clock, T.Scale, R)) .integer else null;
        return if (T == aegis.units.Duration(T.Scale, R)) .text else null;
    }
    if (@hasDecl(T, "Domain")) {
        const D = T.Domain;
        if (T == aegis.units.Count(D, R) or T == aegis.id.Id(D, R)) return .integer;
        if (T == aegis.id.NonZero(D, R)) return .nonzero;
        if (T == aegis.id.Counter(D, R)) return .counter;
        return null;
    }
    if (T == aegis.units.Bytes(R)) return .text;
    if (T == aegis.units.Bits(R) or T == aegis.int.Checked(R) or T == aegis.int.Saturating(R)) return .integer;
    return null;
}

/// The integer a scalar of an integer kind holds.
pub fn integer(value: anytype) @TypeOf(value).Representation {
    const T = @TypeOf(value);
    if (comptime kind(T) == .counter) return if (value.last()) |id| id.raw() else 0;
    return value.raw();
}

/// The scalar of an integer kind that holds `n`.
pub fn fromInteger(comptime T: type, n: T.Representation) error{NumberOutOfRange}!T {
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
