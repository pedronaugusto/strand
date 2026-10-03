//! A union tagged inside its object: what the union declares, read once and
//! checked at compile time, for every codec that writes or reads one.
//!
//! `std.json` writes a tagged union as an object with one key, the arm:
//! `{"assistant":{"text":"hi"}}`. Most producers of JSON Lines write the arm
//! as a member of the record itself instead — `{"type":"assistant","text":"hi"}`
//! — which is serde's `#[serde(tag = "type")]`. A union says it is written
//! that way with two declarations:
//!
//! ```zig
//! const Message = union(enum) {
//!     assistant: struct { text: []const u8 },
//!     ping,
//!     unknown: strand.Raw,
//!     pub const jsonl_tag = "type";
//!     pub const jsonl_other = .unknown;
//! };
//! ```
//!
//! `jsonl_tag` names the member that holds the arm; every arm's payload is a
//! struct, whose fields are the record's other members, or `void`.
//! `jsonl_other`, optional, names the arm a tag naming no other arm is read
//! as; its payload is `void`, or a `Raw` holding the whole record as written.

const std = @import("std");

/// What `U` declares, or `null` for a union written as `std.json` writes
/// one. Every rule is checked here, so a codec that gets an answer can rely
/// on it.
pub fn internal(comptime U: type) ?Internal(U) {
    comptime {
        if (@typeInfo(U) != .@"union") return null;
        if (!@hasDecl(U, "jsonl_tag")) {
            if (@hasDecl(U, "jsonl_other"))
                @compileError(@typeName(U) ++ " declares jsonl_other without jsonl_tag");
            return null;
        }
        const info = @typeInfo(U).@"union";
        if (info.tag_type == null)
            @compileError(@typeName(U) ++ " declares jsonl_tag but is not a tagged union");
        if (std.meta.hasFn(U, "jsonParse") or std.meta.hasFn(U, "jsonStringify"))
            @compileError(@typeName(U) ++ " declares jsonl_tag and its own jsonParse or jsonStringify; keep one");
        const tag: []const u8 = U.jsonl_tag;
        if (tag.len == 0) @compileError(@typeName(U) ++ ".jsonl_tag is empty");
        for (tag) |b| if (b < 0x20 or b == '"' or b == '\\' or b >= 0x80)
            @compileError(@typeName(U) ++ ".jsonl_tag must be written without an escape");
        const Tag = info.tag_type.?;
        const other: ?Tag = if (@hasDecl(U, "jsonl_other")) @as(Tag, U.jsonl_other) else null;
        for (info.fields) |field| {
            const is_other = other != null and std.mem.eql(u8, field.name, @tagName(other.?));
            if (field.type == void or is_other) continue;
            switch (@typeInfo(field.type)) {
                .@"struct" => |s| {
                    if (s.is_tuple)
                        @compileError(@typeName(U) ++ "." ++ field.name ++ " is a tuple; an arm tagged inside its object is a struct or void");
                    for (s.fields) |member| if (std.mem.eql(u8, member.name, tag))
                        @compileError(@typeName(U) ++ "." ++ field.name ++ " has a field named like the tag \"" ++ tag ++ "\"");
                },
                else => @compileError(@typeName(U) ++ "." ++ field.name ++ " is a " ++ @typeName(field.type) ++ "; an arm tagged inside its object is a struct or void"),
            }
        }
        return .{ .tag = tag, .other = other };
    }
}

/// See `internal`.
pub fn Internal(comptime U: type) type {
    return struct {
        /// The member that holds the arm's name.
        tag: []const u8,
        /// The arm a name that is no arm's is read as.
        other: ?Arm,

        const Arm = switch (@typeInfo(U)) {
            .@"union" => |info| info.tag_type orelse void,
            else => void,
        };
    };
}

/// Whether `T` is, or reaches, a union tagged inside its object: such a
/// value is written by this package's own encoder, which knows the shape,
/// in every format.
pub fn reaches(comptime T: type) bool {
    comptime {
        @setEvalBranchQuota(1_000_000);
        return reachesFrom(T, .{});
    }
}

fn reachesFrom(comptime T: type, comptime ancestors: anytype) bool {
    inline for (ancestors) |ancestor| if (T == ancestor) return false;
    const next = ancestors ++ .{T};
    return switch (@typeInfo(T)) {
        .optional => |i| reachesFrom(i.child, next),
        .array => |i| reachesFrom(i.child, next),
        .vector => |i| reachesFrom(i.child, next),
        .pointer => |i| reachesFrom(i.child, next),
        .@"struct" => |i| fields: {
            for (i.fields) |field| if (reachesFrom(field.type, next)) break :fields true;
            break :fields false;
        },
        .@"union" => |i| fields: {
            if (internal(T) != null) break :fields true;
            for (i.fields) |field| if (reachesFrom(field.type, next)) break :fields true;
            break :fields false;
        },
        else => false,
    };
}

test internal {
    const External = union(enum) { a: struct { x: u8 }, b };
    try std.testing.expect(comptime internal(External) == null);
    const Inside = union(enum) {
        a: struct { x: u8 },
        b,
        other,
        pub const jsonl_tag = "kind";
        pub const jsonl_other = .other;
    };
    const got = comptime internal(Inside).?;
    try std.testing.expectEqualStrings("kind", got.tag);
    try std.testing.expectEqual(.other, got.other.?);
    try std.testing.expect(comptime reaches(struct { m: ?[]const Inside }));
    try std.testing.expect(comptime !reaches(struct { m: External }));
}
