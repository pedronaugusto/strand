//! Semantic events, consumed immediately. This is not a format DOM or token tape.
const context = @import("context.zig");
pub const Kind = enum { sequence, tuple, map, record, variant };
pub const Span = struct { bytes: []const u8, lifetime: context.Lifetime };
pub const Compound = struct { kind: Kind, len: ?usize = null, name: []const u8 = "" };
/// Unsigned little-endian magnitude. Formats can supply any Zig integer width.
/// Textual decimal/exponent normalization belongs to the format's checked kernel.
pub const Integer = struct { negative: bool = false, magnitude: []const u8 };
pub const Event = union(enum) {
    boolean: bool,
    integer: Integer,
    floating: f128,
    text: Span,
    bytes: Span,
    none,
    unit,
    begin: Compound,
    end,
};
