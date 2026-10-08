//! Semantic events, consumed immediately. This is not a format DOM or token tape.
const context = @import("context.zig");
pub const Kind = enum { sequence, tuple, named_tuple, map, record, variant, newtype, some, named_unit };
pub const Span = struct { bytes: []const u8, lifetime: context.Lifetime };
pub const Compound = struct { kind: Kind, len: ?usize = null, name: []const u8 = "" };
/// Unsigned little-endian magnitude. Formats can supply any Zig integer width.
/// Textual decimal/exponent normalization belongs to the format's checked kernel.
pub const Integer = struct { negative: bool = false, magnitude: []const u8 };
pub const Event = union(enum) {
    boolean: bool,
    scalar: u21,
    integer: Integer,
    floating: f128,
    text: Span,
    bytes: Span,
    none,
    unit,
    begin: Compound,
    end,
};

/// Format-branded raw input. Strict acquisition validates the entire value;
/// emission validates again and refuses an unnormalized canonical raw value.
pub fn Raw(comptime Format: type) type {
    return struct {
        bytes: []const u8,
        const Self = @This();
        pub const strandRawFormat = Format;
        pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Self {
            return .{ .bytes = try access.raw(Format) };
        }
        pub fn strandSerialize(self: Self, access: anytype) @TypeOf(access.*).Error!void {
            try access.raw(Format, self.bytes);
        }
    };
}

/// Zig has no distinct character primitive; this wrapper carries Unicode meaning.
pub const Scalar = struct {
    value: u21,
    pub const Self = Scalar;
    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Self {
        return .{ .value = try access.scalar() };
    }
    pub fn strandSerialize(self: Self, access: anytype) @TypeOf(access.*).Error!void {
        try access.scalar(self.value);
    }
};
pub fn Pair(comptime K: type, comptime V: type) type {
    return struct { key: K, value: V };
}
/// Ordered entries retain arbitrary key types and duplicates explicitly.
pub fn Pairs(comptime K: type, comptime V: type) type {
    return struct {
        items: []const Pair(K, V),
        pub const strandKeyType = K;
        pub const Self = @This();
        pub fn strandDeserialize(access: anytype) @typeInfo(@TypeOf(access.readPairs(K, V))).error_union.error_set!Self {
            return .{ .items = try access.readPairs(K, V) };
        }
        pub fn strandSerialize(self: Self, access: anytype) @typeInfo(@TypeOf(access.writePairs(self.items))).error_union.error_set!void {
            try access.writePairs(self.items);
        }
    };
}
