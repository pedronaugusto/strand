//! Compile-time type policy; inspection itself never instantiates a codec.
const std = @import("std");
const context = @import("context.zig");
pub const Support = enum { supported, conditional, unsupported };
pub const MapKeys = enum { text_only, scalar, any };
pub const Capabilities = struct {
    map_keys: MapKeys = .any,
    unicode_scalar: bool = true,
    named_shapes: bool = true,
    nonfinite_floats: bool = true,
    bytes: bool = true,
    null_value: bool = true,
    nested_optional: bool = false,
    scalar_roots: bool = true,
    borrowed: bool = true,
    indefinite_containers: bool = true,
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
pub const Rename = enum { snake_case, camel_case, PascalCase, kebab_case, SCREAMING_SNAKE_CASE };
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
    exact: bool = false,
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
    return if (comptime has(T, "strand")) T.strand else .{};
}
pub fn field(comptime T: type, comptime name: []const u8) Field {
    const opt = options(T);
    var f: Field = .{ .name = name };
    if (@hasField(@TypeOf(opt), "rename_all")) f.name = rename(name, opt.rename_all);
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
        if (@hasField(@TypeOf(f), "default") and @typeInfo(@TypeOf(f.default)) != .@"fn") return f.default;
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
    const set = @typeInfo(@typeInfo(result_type).error_union.error_set).error_set;
    if (set.error_names) |names| for (names) |e| if (std.mem.eql(u8, e, "SecretNotFormattable")) return true;
    return false;
}
fn inspect(comptime T: type, comptime fmt: Capabilities, comptime seen: []const type, comptime path: []const u8) Description {
    if (T == std.mem.Allocator or T == std.Io or T == std.Io.File or T == std.Io.Mutex or containsSecret(T, &.{})) return rejected(path, "resource or secret is not automatic data");
    for (seen) |v| if (T == v) return .{};
    const next = seen ++ .{T};
    if (has(T, "strand")) {
        const opt = options(T);
        for (@typeInfo(@TypeOf(opt)).@"struct".field_names) |option| {
            if (!std.mem.eql(u8, option, "fields") and !std.mem.eql(u8, option, "unknown_fields") and !std.mem.eql(u8, option, "duplicates") and !std.mem.eql(u8, option, "rename_all") and !std.mem.eql(u8, option, "variants") and !std.mem.eql(u8, option, "tag") and !std.mem.eql(u8, option, "content") and !std.mem.eql(u8, option, "other")) return rejected(path, "container option is not implemented by this S1 candidate");
        }
        if (@hasField(@TypeOf(opt), "fields")) {
            for (@typeInfo(@TypeOf(opt.fields)).@"struct".field_names) |name| {
                if (!@hasField(T, name)) return rejected(path ++ "." ++ name, "option names no field");
                const f = @field(opt.fields, name);
                for (@typeInfo(@TypeOf(f)).@"struct".field_names) |option| {
                    if (!@hasField(Field, option) and !std.mem.eql(u8, option, "default") and !std.mem.eql(u8, option, "codec") and !std.mem.eql(u8, option, "validate") and !std.mem.eql(u8, option, "range") and !std.mem.eql(u8, option, "omit_if") and !std.mem.eql(u8, option, "equal")) return rejected(path ++ "." ++ name, "field option is not implemented by this S1 candidate");
                }
            }
        }
    }
    if (has(T, "strandScalar") and !fmt.unicode_scalar) return rejected(path, "format has no Unicode scalar codec");
    if (has(T, "strandNamedShape") and !fmt.named_shapes) return rejected(path, "format has no named shape codec");
    if (has(T, "strandKeyType")) {
        const K = T.strandKeyType;
        if (fmt.map_keys == .text_only and !(@typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .slice and @typeInfo(K).pointer.child == u8)) return rejected(path, "format requires text map keys");
        if (fmt.map_keys == .scalar and (@typeInfo(K) == .@"struct" or @typeInfo(K) == .@"union" or @typeInfo(K) == .array or @typeInfo(K) == .vector)) return rejected(path, "format requires scalar map keys");
    }
    if (has(T, "strandSerialize") or has(T, "strandDeserialize")) return .{ .support = .conditional, .encode = has(T, "strandSerialize"), .decode = has(T, "strandDeserialize"), .path = path, .reason = "explicit data codec" };
    if (has(T, "deinit")) return rejected(path, "resource owner requires an explicit data codec");
    return switch (@typeInfo(T)) {
        .bool, .void => .{},
        .null => if (fmt.null_value) .{} else rejected(path, "format has no null"),
        .int => |i| if (i.bits > fmt.max_integer_bits) .{ .support = .conditional, .path = path, .reason = "format numeric range" } else .{},
        .float => |i| if (i.bits > fmt.max_float_bits) .{ .support = .conditional, .path = path, .reason = "format float fidelity" } else .{},
        .@"enum" => |i| if (i.mode == .exhaustive) .{} else rejected(path, "nonexhaustive enum requires a numeric codec"),
        .optional => |i| if (!fmt.null_value or (@typeInfo(i.child) == .optional and !fmt.nested_optional)) rejected(path, "optional shape needs an explicit codec") else inspect(i.child, fmt, next, path),
        .pointer => |i| if ((i.size != .one and i.size != .slice) or i.attrs.@"volatile" or i.attrs.@"allowzero" or (i.attrs.@"addrspace" orelse .generic) != .generic) rejected(path, "pointer has no safe data meaning") else inspect(i.child, fmt, next, path),
        .array => |i| inspect(i.child, fmt, next, path),
        .vector => |i| inspect(i.child, fmt, next, path),
        .@"struct" => |i| aggregate: {
            var result: Description = .{};
            for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| {
                const f = field(T, name);
                const declared = fieldOptions(T, name);
                const child = if (@hasField(@TypeOf(declared), "codec")) Description{ .support = .conditional, .encode = @hasDecl(declared.codec, "encode"), .decode = @hasDecl(declared.codec, "decode"), .path = path ++ "." ++ name, .reason = "explicit field codec" } else inspect(F, fmt, next, path ++ "." ++ name);
                if (child.support == .unsupported) break :aggregate child;
                if (child.support == .conditional) result = merge(result, child);
                if (attrs.@"comptime" and containsPointers(F, &.{})) break :aggregate rejected(path ++ "." ++ name, "comptime field cannot retain pointers");
                if (f.as == .bytes and !fmt.bytes) break :aggregate rejected(path ++ "." ++ name, "format has no native bytes");
                if (f.skip_decode and !hasDefault(T, name)) break :aggregate rejected(path ++ "." ++ name, "skip_decode requires a default");
                if ((f.skip_encode or f.omit != .never or @hasField(@TypeOf(declared), "omit_if")) and !hasDefault(T, name)) result = merge(result, .{ .support = .conditional, .path = path ++ "." ++ name, .reason = "omitted required field prevents lossless round trip" });
            }
            break :aggregate result;
        },
        .@"union" => |i| aggregate: {
            if (i.tag_type == null) break :aggregate rejected(path, "untagged union has no active member witness");
            var result: Description = .{};
            for (i.field_names, i.field_types) |name, F| {
                const declared = fieldOptions(T, name);
                const child = if (@hasField(@TypeOf(declared), "codec")) Description{ .support = .conditional, .encode = @hasDecl(declared.codec, "encode"), .decode = @hasDecl(declared.codec, "decode"), .path = path ++ "." ++ name, .reason = "explicit field codec" } else inspect(F, fmt, next, path ++ "." ++ name);
                if (child.support == .unsupported) break :aggregate child;
                if (child.support == .conditional) result = merge(result, child);
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
        inline .@"union", .@"enum" => |i| {
            const opt = options(T);
            for (i.field_names) |name| {
                const f = variant(T, name);
                for (f.aliases, 0..) |a, ai| {
                    if (std.mem.eql(u8, a, f.name)) @compileError("variant name collision at " ++ name);
                    for (f.aliases[0..ai]) |b| if (std.mem.eql(u8, a, b)) @compileError("repeated variant alias at " ++ name);
                }
                for (i.field_names) |other| {
                    if (std.mem.eql(u8, name, other)) continue;
                    const o = variant(T, other);
                    if (std.mem.eql(u8, f.name, o.name)) @compileError("variant name collision at " ++ name);
                    for (f.aliases) |a| {
                        if (std.mem.eql(u8, a, o.name)) @compileError("variant alias collision at " ++ name);
                        for (o.aliases) |b| if (std.mem.eql(u8, a, b)) @compileError("variant alias collision at " ++ name);
                    }
                }
            }
            if (@hasField(@TypeOf(opt), "content") and !@hasField(@TypeOf(opt), "tag")) @compileError("adjacent content requires tag");
            if (@hasField(@TypeOf(opt), "content") and std.mem.eql(u8, opt.content, opt.tag)) @compileError("tag and content collide");
            if (@typeInfo(T) == .@"union") for (i.field_types, i.field_names) |F, name| {
                if (@hasField(@TypeOf(opt), "tag") and !@hasField(@TypeOf(opt), "content") and F != void) {
                    if (@typeInfo(F) != .@"struct" or @typeInfo(F).@"struct".is_tuple) @compileError("internal tag requires record or void payload");
                    for (@typeInfo(F).@"struct".field_names) |payload_name| if (std.mem.eql(u8, field(F, payload_name).name, opt.tag)) @compileError("tag collides with payload field");
                }
                if (@hasField(@TypeOf(opt), "other") and std.mem.eql(u8, name, opt.other) and F != void and !has(F, "strandRawFormat")) @compileError("other payload requires void or format branded Raw");
                checkOptions(F, ownership, next);
            };
        },
        else => {},
    }
}

fn containsSecret(comptime T: type, comptime seen: []const type) bool {
    if (secret(T)) return true;
    for (seen) |v| if (T == v) return false;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| containsSecret(i.child, next),
        inline .@"struct", .@"union" => |i| blk: {
            for (i.field_types) |F| if (containsSecret(F, next)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn merge(a: Description, b: Description) Description {
    var result = if (a.support == .supported) b else a;
    result.encode = a.encode and b.encode;
    result.decode = a.decode and b.decode;
    return result;
}

/// Resolve one type's orthogonal field policy without copying runtime metadata.
pub fn fieldOptions(comptime T: type, comptime name: []const u8) if (@hasField(@TypeOf(options(T)), "fields") and @hasField(@TypeOf(options(T).fields), name)) @TypeOf(@field(options(T).fields, name)) else @TypeOf(.{}) {
    const opt = options(T);
    return if (comptime @hasField(@TypeOf(opt), "fields") and @hasField(@TypeOf(opt.fields), name)) @field(opt.fields, name) else .{};
}
pub fn hasDefault(comptime T: type, comptime name: []const u8) bool {
    const opt = fieldOptions(T, name);
    return @hasField(@TypeOf(opt), "default") or default(T, name) != null;
}
pub fn validate(comptime T: type, comptime name: []const u8, value: @FieldType(T, name)) error{ NumberOutOfRange, CustomRejected, LengthLimit }!void {
    const opt = comptime fieldOptions(T, name);
    const policy = comptime field(T, name);
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |i| if (i.size == .slice and value.len > policy.max_len) {
            return error.LengthLimit;
        },
        inline .array, .vector => |i| if (i.len > policy.max_len) {
            return error.LengthLimit;
        },
        else => {},
    }
    if (@hasField(@TypeOf(opt), "range")) {
        if (value < opt.range.min or value > opt.range.max) return error.NumberOutOfRange;
    }
    if (@hasField(@TypeOf(opt), "validate")) if (!opt.validate(value)) return error.CustomRejected;
}
fn rename(comptime name: []const u8, comptime style: Rename) []const u8 {
    var result: []const u8 = "";
    var upper = style == .PascalCase;
    for (name, 0..) |ch, i| {
        if (ch == '_' or ch == '-') {
            if (style == .camel_case or style == .PascalCase) {
                upper = true;
                continue;
            }
            result = result ++ .{if (style == .kebab_case) @as(u8, '-') else @as(u8, '_')};
            continue;
        }
        if (std.ascii.isUpper(ch) and i != 0 and name[i - 1] != '_' and name[i - 1] != '-' and std.ascii.isLower(name[i - 1]) and style != .camel_case and style != .PascalCase) result = result ++ .{if (style == .kebab_case) @as(u8, '-') else @as(u8, '_')};
        result = result ++ .{if (upper or style == .SCREAMING_SNAKE_CASE) std.ascii.toUpper(ch) else if (style == .camel_case and i != 0) ch else std.ascii.toLower(ch)};
        upper = false;
    }
    return result;
}

pub fn variant(comptime T: type, comptime name: []const u8) Field {
    const opt = options(T);
    var result: Field = .{ .name = name };
    if (@hasField(@TypeOf(opt), "rename_all")) result.name = rename(name, opt.rename_all);
    if (@hasField(@TypeOf(opt), "variants") and @hasField(@TypeOf(opt.variants), name)) {
        const v = @field(opt.variants, name);
        if (@hasField(@TypeOf(v), "name")) result.name = v.name;
        if (@hasField(@TypeOf(v), "aliases")) result.aliases = v.aliases;
    }
    return result;
}
