//! Compile-time type policy; inspection itself never instantiates a codec.
const std = @import("std");
const context = @import("context.zig");
pub const Support = enum { supported, conditional, unsupported };
pub const Capabilities = struct {
    bytes: bool = true,
    null_value: bool = true,
    nested_optional: bool = false,
    scalar_roots: bool = true,
    borrowed: bool = true,
    max_integer_bits: usize = 128,
    max_float_bits: usize = 128,
};
pub const Description = struct {
    support: Support = .supported,
    encode: bool = true,
    decode: bool = true,
    path: []const u8 = "",
    reason: []const u8 = "",
};
pub const Representation = enum { normal, text, bytes };
pub const Omit = enum { never, null_value, default_value };
pub const Duplicates = enum { reject, first, last };
pub const Unknown = enum { ignore, reject };
pub const Field = struct {
    name: []const u8 = "",
    aliases: []const []const u8 = &.{},
    borrow: context.Borrow = .prefer,
    as: Representation = .normal,
    omit: Omit = .never,
    skip_encode: bool = false,
    skip_decode: bool = false,
    max_len: usize = std.math.maxInt(usize),
};

pub fn has(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}
pub fn options(comptime T: type) if (has(T, "strand")) @TypeOf(T.strand) else @TypeOf(.{}) {
    return if (has(T, "strand")) T.strand else .{};
}
pub fn field(comptime T: type, comptime name: []const u8) Field {
    const opt = options(T);
    var f: Field = .{ .name = name };
    if (@hasField(@TypeOf(opt), "fields") and @hasField(@TypeOf(opt.fields), name)) {
        const declared = @field(opt.fields, name);
        inline for (@typeInfo(@TypeOf(declared)).@"struct".field_names) |option| {
            if (@hasField(Field, option)) @field(f, option) = @field(declared, option);
        }
    }
    return f;
}
pub fn default(comptime T: type, comptime name: []const u8) ?@FieldType(T, name) {
    const opt = options(T);
    if (@hasField(@TypeOf(opt), "fields") and @hasField(@TypeOf(opt.fields), name)) {
        const f = @field(opt.fields, name);
        if (@hasField(@TypeOf(f), "default")) return f.default;
    }
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_attrs) |n, attrs| {
        if (std.mem.eql(u8, n, name)) return if (attrs.default_value_ptr) |p| blk: {
            // safe: Zig provides the correctly typed and aligned default storage.
            const value: *const @FieldType(T, name) = @ptrCast(@alignCast(p)); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
            break :blk value.*;
        } else null;
    }
    unreachable;
}

pub fn describe(comptime T: type, comptime format: Capabilities) Description {
    @setEvalBranchQuota(1_000_000);
    return comptime inspect(T, format, &.{}, "");
}
fn rejected(comptime path: []const u8, comptime why: []const u8) Description {
    return .{ .support = .unsupported, .encode = false, .decode = false, .path = path, .reason = why };
}
fn secret(comptime T: type) bool {
    // The landed Secret contract refuses formatting with this exact named error.
    // Fail closed even when an encode hook is declared on such an owner.
    if (!has(T, "format")) return false;
    const f = @typeInfo(@TypeOf(T.format));
    if (f != .@"fn") return false;
    const result_type = f.@"fn".return_type orelse return false;
    if (@typeInfo(result_type) != .error_union) return false;
    const set = @typeInfo(@typeInfo(result_type).error_union.error_set).error_set orelse return false;
    for (set) |e| if (std.mem.eql(u8, e.name, "SecretNotFormattable")) return true;
    return false;
}
fn inspect(comptime T: type, comptime fmt: Capabilities, comptime seen: []const type, comptime path: []const u8) Description {
    if (T == std.mem.Allocator or T == std.Io or T == std.Io.File or T == std.Io.Mutex or secret(T)) return rejected(path, "resource or secret is not automatic data");
    for (seen) |v| if (T == v) return .{};
    const next = seen ++ .{T};
    if (has(T, "strandSerialize") or has(T, "strandDeserialize")) return .{ .support = .conditional, .encode = has(T, "strandSerialize"), .decode = has(T, "strandDeserialize"), .path = path, .reason = "explicit data codec" };
    if (has(T, "deinit")) return rejected(path, "resource owner requires an explicit data codec");
    return switch (@typeInfo(T)) {
        .bool, .void => .{},
        .null => if (fmt.null_value) .{} else rejected(path, "format has no null"),
        .int => |i| if (i.bits > fmt.max_integer_bits) .{ .support = .conditional, .path = path, .reason = "format numeric range" } else .{},
        .float => |i| if (i.bits > fmt.max_float_bits) .{ .support = .conditional, .path = path, .reason = "format float fidelity" } else .{},
        .@"enum" => |i| if (i.is_exhaustive) .{} else rejected(path, "nonexhaustive enum requires a numeric codec"),
        .optional => |i| if (!fmt.null_value or (@typeInfo(i.child) == .optional and !fmt.nested_optional)) rejected(path, "optional shape needs an explicit codec") else inspect(i.child, fmt, next, path),
        .pointer => |i| if ((i.size != .one and i.size != .slice) or i.attrs.@"volatile" or i.attrs.@"allowzero" or (i.attrs.@"addrspace" orelse .generic) != .generic) rejected(path, "pointer has no safe data meaning") else inspect(i.child, fmt, next, path),
        .array => |i| inspect(i.child, fmt, next, path),
        .vector => |i| inspect(i.child, fmt, next, path),
        .@"struct" => |i| aggregate: {
            var result: Description = .{};
            for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| {
                const f = field(T, name);
                const child = inspect(F, fmt, next, path ++ "." ++ name);
                if (child.support == .unsupported) break :aggregate child;
                if (child.support == .conditional) result = child;
                if (attrs.@"comptime" and containsPointers(F, &.{})) break :aggregate rejected(path ++ "." ++ name, "comptime field cannot retain pointers");
                if (f.as == .bytes and !fmt.bytes) break :aggregate rejected(path ++ "." ++ name, "format has no native bytes");
                if ((f.skip_decode or f.skip_encode) and default(T, name) == null) result = .{ .support = .conditional, .path = path ++ "." ++ name, .reason = "skipped field lacks a default" };
            }
            break :aggregate result;
        },
        .@"union" => |i| aggregate: {
            if (i.tag_type == null) break :aggregate rejected(path, "untagged union has no active member witness");
            var result: Description = .{};
            for (i.field_names, i.field_types) |name, F| {
                const child = inspect(F, fmt, next, path ++ "." ++ name);
                if (child.support == .unsupported) break :aggregate child;
                if (child.support == .conditional) result = child;
            }
            break :aggregate result;
        },
        else => rejected(path, "type has no automatic data meaning"),
    };
}
fn containsPointers(comptime T: type, comptime seen: []const type) bool {
    for (seen) |v| if (T == v) return false;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |i| containsPointers(i.child, next),
        .array => |i| containsPointers(i.child, next),
        .vector => |i| containsPointers(i.child, next),
        inline .@"struct", .@"union" => |i| blk: {
            for (i.field_types) |F| if (containsPointers(F, next)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Compile-time collision checks cover primary/alias names and same-field repeats.
pub fn check(comptime T: type, comptime fmt: Capabilities, comptime decoding: bool, comptime ownership: context.Ownership) void {
    const d = describe(T, fmt);
    if (d.support == .unsupported or (decoding and !d.decode) or (!decoding and !d.encode)) @compileError(d.path ++ ": " ++ d.reason);
    checkOptions(T, ownership, &.{});
}
fn checkOptions(comptime T: type, comptime ownership: context.Ownership, comptime seen: []const type) void {
    for (seen) |v| if (T == v) return;
    const next = seen ++ .{T};
    switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| checkOptions(i.child, ownership, next),
        .@"struct" => |i| {
            for (i.field_names, i.field_types) |name, F| {
                const f = field(T, name);
                if (ownership == .owned and f.borrow == .require) @compileError("owned decoding conflicts with borrow.require at " ++ name);
                for (f.aliases, 0..) |a, ai| {
                    if (std.mem.eql(u8, a, f.name)) @compileError("wire name collision at " ++ name);
                    for (f.aliases[0..ai]) |b| if (std.mem.eql(u8, a, b)) @compileError("repeated alias at " ++ name);
                }
                for (i.field_names) |other| {
                    if (std.mem.eql(u8, name, other)) continue;
                    const o = field(T, other);
                    if (std.mem.eql(u8, f.name, o.name)) @compileError("wire name collision at " ++ name);
                    for (f.aliases) |a| {
                        if (std.mem.eql(u8, a, o.name)) @compileError("wire alias collision at " ++ name);
                        for (o.aliases) |b| if (std.mem.eql(u8, a, b)) @compileError("wire alias collision at " ++ name);
                    }
                }
                checkOptions(F, ownership, next);
            }
        },
        .@"union" => |i| for (i.field_types) |F| checkOptions(F, ownership, next),
        else => {},
    }
}
