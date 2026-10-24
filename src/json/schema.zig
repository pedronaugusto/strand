//! JSON Schema (2020-12) for the JSON strand writes and reads for a type,
//! made at compile time from the same `strand` declarations the codec reads:
//! field names and aliases, casing, defaults, skips, ranges, enum and union
//! spellings, aegis scalars. A schema is a string constant: a program that
//! hands it on (an MCP tool's `inputSchema`, an OpenAPI document) pays
//! nothing for it at run time.
//!
//! The schema says what `json.parse` accepts (`.decode`) or what
//! `json.write` writes (`.encode`), which differ where a type's policy makes
//! them differ: a field with a default may be absent from what is read but is
//! always written unless it is omitted, an alias is read but never written.
//! A type with a codec of its own declares its schema
//! (`pub const strand_json_schema = "..."`), since strand cannot know what
//! the codec writes; one that does not is refused when it is compiled, with
//! the path to it, as a type strand cannot encode is.
const std = @import("std");
const descriptor = @import("../core/descriptor.zig");
const scalars = @import("../core/scalars.zig");

pub const Direction = enum {
    /// What `json.parse` accepts.
    decode,
    /// What `json.write` writes.
    encode,
};

pub const Options = struct {
    direction: Direction = .decode,
    /// Write `$schema` at the root, naming 2020-12.
    dialect: bool = true,
    /// Mirrors `ParseOptions.ignore_unknown_fields`: with it false, as by
    /// default, an object takes no member it does not name
    /// (`additionalProperties: false`); with it true, a type's
    /// `unknown_fields` policy decides, and ignoring is the default. Only for
    /// `.decode`: what is written has exactly the type's members.
    ignore_unknown_fields: bool = false,
};

/// The JSON Schema of `T`, as compact JSON.
pub fn of(comptime T: type, comptime options: Options) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        const recursive = findRecursive(T, &.{}, &.{});
        const g: Gen = .{ .options = options, .root = T, .recursive = recursive };
        var body = g.schema(T, .{}, "");
        var defs: []const u8 = "";
        for (recursive, 0..) |R, i| {
            if (R == T) continue;
            if (defs.len != 0) defs = defs ++ ",";
            defs = defs ++ string(defName(recursive, i)) ++ ":" ++ g.body(R, "", .{});
        }
        if (defs.len != 0) body = merge(body, "\"$defs\":{" ++ defs ++ "}");
        if (options.dialect) body = merge("{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\"}", body[1 .. body.len - 1]);
        return body;
    }
}

/// `{...}` with `members` (one or more `"key":value`) added before its end.
fn merge(comptime object: []const u8, comptime members: []const u8) []const u8 {
    if (members.len == 0) return object;
    if (object.len == 2) return "{" ++ members ++ "}";
    return object[0 .. object.len - 1] ++ "," ++ members ++ "}";
}

const Gen = struct {
    options: Options,
    root: type,
    /// Types that contain themselves: each is written once, under `$defs`
    /// (the root as the whole document), and referred to everywhere.
    recursive: []const type,

    /// The schema of a value of `T` in a place with `policy`.
    fn schema(comptime g: Gen, comptime T: type, comptime policy: descriptor.Field, comptime path: []const u8) []const u8 {
        for (g.recursive, 0..) |R, i| if (R == T) {
            if (T == g.root and path.len != 0) return "{\"$ref\":\"#\"}";
            if (T != g.root) return "{\"$ref\":\"#/$defs/" ++ defName(g.recursive, i) ++ "\"}";
        };
        return g.body(T, path, policy);
    }

    fn body(comptime g: Gen, comptime T: type, comptime path: []const u8, comptime policy: descriptor.Field) []const u8 {
        if (descriptor.has(T, "strand_json_schema")) return T.strand_json_schema;
        if (descriptor.has(T, "StrandRawFormat")) return "true";
        if (descriptor.has(T, "strandSerialize") or descriptor.has(T, "strandDeserialize") or descriptor.has(T, "StrandKey") or descriptor.has(T, "strand_scalar") or descriptor.has(T, "strand_bytes") or descriptor.has(T, "strand_named_shape"))
            @compileError(path ++ ": a type with a codec of its own declares its schema as `strand_json_schema`");
        if (scalars.kind(T)) |k| return switch (k) {
            .text => "{\"type\":\"string\"}",
            .ranged => integer(T.minimum, T.maximum),
            .nonzero => merge(bounds(T.Representation), "\"not\":{\"const\":0}"),
            .integer, .counter => integer(std.math.minInt(T.Representation), std.math.maxInt(T.Representation)),
        };
        return switch (@typeInfo(T)) {
            .bool => "{\"type\":\"boolean\"}",
            .int => if (policy.as == .normal) bounds(T) else @compileError(path ++ ": a text or byte representation needs a u8 array or slice"),
            .float => "{\"type\":\"number\"}",
            .void => "{\"type\":\"object\",\"maxProperties\":0}",
            .null => "{\"type\":\"null\"}",
            .@"enum" => |i| blk: {
                var names: []const u8 = "";
                for (i.field_names) |name| {
                    const v = descriptor.variant(T, name);
                    names = names ++ (if (names.len == 0) "" else ",") ++ string(v.name);
                    if (g.options.direction == .decode) for (v.aliases) |a| {
                        names = names ++ "," ++ string(a);
                    };
                }
                break :blk "{\"type\":\"string\",\"enum\":[" ++ names ++ "]}";
            },
            .optional => |i| nullable(g.schema(i.child, policy, path)),
            .pointer => |i| switch (i.size) {
                .one => if (@typeInfo(i.child) == .array and @typeInfo(i.child).array.child == u8) text(policy, path) else g.schema(i.child, policy, path),
                .slice => if (i.child == u8) text(policy, path) else "{\"type\":\"array\",\"items\":" ++ g.schema(i.child, .{}, path ++ "[]") ++ maxItems(policy) ++ "}",
                else => @compileError(path ++ ": pointer has no data meaning"),
            },
            inline .array, .vector => |i| if (policy.as != .normal)
                text(policy, path)
            else
                "{\"type\":\"array\",\"items\":" ++ g.schema(i.child, .{}, path ++ "[]") ++ std.fmt.comptimePrint(",\"minItems\":{d},\"maxItems\":{d}}}", .{ i.len, i.len }),
            .@"struct" => |i| if (i.is_tuple) g.tuple(T, path) else g.record(T, path),
            .@"union" => |i| if (i.tag_type == null) @compileError(path ++ ": an untagged union has no data meaning") else g.variants(T, path),
            else => @compileError(path ++ ": type has no JSON meaning"),
        };
    }

    fn tuple(comptime g: Gen, comptime T: type, comptime path: []const u8) []const u8 {
        const i = @typeInfo(T).@"struct";
        var items: []const u8 = "";
        for (i.field_types, 0..) |F, k| items = items ++ (if (k == 0) "" else ",") ++ g.schema(F, .{}, std.fmt.comptimePrint("{s}[{d}]", .{ path, k }));
        return std.fmt.comptimePrint("{{\"type\":\"array\",\"prefixItems\":[{s}],\"items\":false,\"minItems\":{d},\"maxItems\":{d}}}", .{ items, i.field_types.len, i.field_types.len });
    }

    /// A struct as an object: its members as `properties`, the ones that
    /// must be there as `required`.
    fn record(comptime g: Gen, comptime T: type, comptime path: []const u8) []const u8 {
        const props = g.properties(T, path, &.{});
        var out: []const u8 = "{\"type\":\"object\"";
        if (description(descriptor.options(T))) |d| out = out ++ ",\"description\":" ++ string(d);
        out = out ++ ",\"properties\":{" ++ props.members ++ "}";
        if (props.required.len != 0) out = out ++ ",\"required\":[" ++ props.required ++ "]";
        if (props.any_of.len != 0) out = out ++ ",\"allOf\":[" ++ props.any_of ++ "]";
        if (g.closed(T)) out = out ++ ",\"additionalProperties\":false";
        return out ++ "}";
    }

    /// Whether an object of `T` refuses members it does not name.
    fn closed(comptime g: Gen, comptime T: type) bool {
        if (g.options.direction == .encode) return true;
        if (!g.options.ignore_unknown_fields) return true;
        const opt = descriptor.options(T);
        return @hasField(@TypeOf(opt), "unknown_fields") and opt.unknown_fields == .reject;
    }

    const Properties = struct {
        members: []const u8 = "",
        required: []const u8 = "",
        /// `{"anyOf":[{"required":[name]},{"required":[alias]}]}` for each
        /// required field that has aliases, any of whose names will do.
        any_of: []const u8 = "",
    };

    /// `T`'s fields as properties, leaving out the names in `except` (an
    /// internal tag's).
    fn properties(comptime g: Gen, comptime T: type, comptime path: []const u8, comptime except: []const []const u8) Properties {
        var p: Properties = .{};
        const i = @typeInfo(T).@"struct";
        for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| {
            if (attrs.@"comptime") continue;
            const f = descriptor.field(T, name);
            if (g.options.direction == .decode and f.skip_decode) continue;
            if (g.options.direction == .encode and f.skip_encode) continue;
            if (contains(except, f.name)) continue;
            const declared = descriptor.fieldOptions(T, name);
            var s = if (@hasField(@TypeOf(declared), "codec"))
                (if (@hasDecl(declared.codec, "strand_json_schema")) declared.codec.strand_json_schema else @compileError(path ++ "." ++ name ++ ": a field codec declares its schema as `strand_json_schema`"))
            else
                g.schema(F, f, path ++ "." ++ name);
            if (@hasField(@TypeOf(declared), "range")) s = numberIn(F, declared.range);
            if (@hasField(@TypeOf(declared), "description")) s = merge(s, "\"description\":" ++ string(declared.description));
            const names: []const []const u8 = if (g.options.direction == .decode) &[_][]const u8{f.name} ++ f.aliases else &.{f.name};
            for (names) |n| p.members = p.members ++ (if (p.members.len == 0) "" else ",") ++ string(n) ++ ":" ++ s;
            if (g.required(T, name, F, f)) {
                if (names.len == 1) {
                    p.required = p.required ++ (if (p.required.len == 0) "" else ",") ++ string(f.name);
                } else {
                    var alternatives: []const u8 = "";
                    for (names) |n| alternatives = alternatives ++ (if (alternatives.len == 0) "" else ",") ++ "{\"required\":[" ++ string(n) ++ "]}";
                    p.any_of = p.any_of ++ (if (p.any_of.len == 0) "" else ",") ++ "{\"anyOf\":[" ++ alternatives ++ "]}";
                }
            }
        }
        return p;
    }

    /// Whether a field must be there: read, when it has no default; written,
    /// when it is written whatever its value.
    fn required(comptime g: Gen, comptime T: type, comptime name: []const u8, comptime F: type, comptime f: descriptor.Field) bool {
        if (g.options.direction == .decode) return !descriptor.hasDefault(T, name);
        if (f.omit != .never or @hasField(@TypeOf(descriptor.fieldOptions(T, name)), "omit_if")) return false;
        // `WriteOptions.nulls = .omit` leaves a null out of any record.
        return @typeInfo(F) != .optional;
    }

    /// A tagged union, as its `strand` declaration spells it: externally
    /// (`{"arm": payload}`), internally (`{"tag": "arm", ...}`) or
    /// adjacently (`{"tag": "arm", "content": payload}`) tagged.
    fn variants(comptime g: Gen, comptime T: type, comptime path: []const u8) []const u8 {
        const opt = descriptor.options(T);
        const i = @typeInfo(T).@"union";
        var arms: []const u8 = "";
        for (i.field_names, i.field_types) |name, F| {
            const v = descriptor.variant(T, name);
            const here = path ++ "." ++ name;
            const names: []const []const u8 = if (g.options.direction == .decode) &[_][]const u8{v.name} ++ v.aliases else &.{v.name};
            const tag = if (names.len == 1) "{\"const\":" ++ string(v.name) ++ "}" else "{\"enum\":[" ++ list(names) ++ "]}";
            const arm = if (@hasField(@TypeOf(opt), "other") and std.mem.eql(u8, name, opt.other))
                // The catch-all: any tag the others do not name, kept as it came.
                (if (@hasField(@TypeOf(opt), "tag")) "{\"type\":\"object\",\"required\":[" ++ string(opt.tag) ++ "]}" else "{\"type\":\"object\",\"minProperties\":1,\"maxProperties\":1}")
            else if (@hasField(@TypeOf(opt), "tag") and @hasField(@TypeOf(opt), "content"))
                (if (F == void)
                    "{\"type\":\"object\",\"properties\":{" ++ string(opt.tag) ++ ":" ++ tag ++ "},\"required\":[" ++ string(opt.tag) ++ "],\"additionalProperties\":false}"
                else
                    "{\"type\":\"object\",\"properties\":{" ++ string(opt.tag) ++ ":" ++ tag ++ "," ++ string(opt.content) ++ ":" ++ g.schema(F, .{}, here) ++ "},\"required\":[" ++ string(opt.tag) ++ "," ++ string(opt.content) ++ "],\"additionalProperties\":false}")
            else if (@hasField(@TypeOf(opt), "tag")) internal: {
                if (F == void) break :internal "{\"type\":\"object\",\"properties\":{" ++ string(opt.tag) ++ ":" ++ tag ++ "},\"required\":[" ++ string(opt.tag) ++ "]" ++ (if (g.closed(T)) ",\"additionalProperties\":false" else "") ++ "}";
                const p = g.properties(F, here, &.{opt.tag});
                var out: []const u8 = "{\"type\":\"object\",\"properties\":{" ++ string(opt.tag) ++ ":" ++ tag ++ (if (p.members.len == 0) "" else ",") ++ p.members ++ "},\"required\":[" ++ string(opt.tag) ++ (if (p.required.len == 0) "" else ",") ++ p.required ++ "]";
                if (p.any_of.len != 0) out = out ++ ",\"allOf\":[" ++ p.any_of ++ "]";
                if (g.closed(F)) out = out ++ ",\"additionalProperties\":false";
                break :internal out ++ "}";
            } else external: {
                var out: []const u8 = "";
                for (names) |n| out = out ++ (if (out.len == 0) "" else ",") ++ "{\"type\":\"object\",\"properties\":{" ++ string(n) ++ ":" ++ g.schema(F, .{}, here) ++ "},\"required\":[" ++ string(n) ++ "],\"additionalProperties\":false}";
                break :external out;
            };
            arms = arms ++ (if (arms.len == 0) "" else ",") ++ arm;
        }
        var out: []const u8 = "{\"oneOf\":[" ++ arms ++ "]";
        if (description(opt)) |d| out = out ++ ",\"description\":" ++ string(d);
        return out ++ "}";
    }
};

fn description(comptime opt: anytype) ?[]const u8 {
    return if (@hasField(@TypeOf(opt), "description")) opt.description else null;
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn list(comptime names: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (names) |n| out = out ++ (if (out.len == 0) "" else ",") ++ string(n);
    return out;
}

/// A text field: JSON's string. Bytes have no JSON spelling; bytes that are
/// text when they can be (`.text_or_bytes`) are a string or their byte values.
fn text(comptime policy: descriptor.Field, comptime path: []const u8) []const u8 {
    if (policy.as == .bytes) @compileError(path ++ ": JSON has no bytes; give the field a codec");
    if (policy.as == .text_or_bytes) return "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}}]}";
    return "{\"type\":\"string\"}";
}

fn maxItems(comptime policy: descriptor.Field) []const u8 {
    if (policy.max_len == std.math.maxInt(usize)) return "";
    return std.fmt.comptimePrint(",\"maxItems\":{d}", .{policy.max_len});
}

fn nullable(comptime s: []const u8) []const u8 {
    // `{"type":"x"}` alone becomes `{"type":["x","null"]}`; anything else is
    // `anyOf` with null.
    const prefix = "{\"type\":\"";
    if (std.mem.startsWith(u8, s, prefix)) {
        const end = std.mem.findScalarPos(u8, s, prefix.len, '"').?;
        if (std.mem.eql(u8, s[end + 1 ..], "}") and !std.mem.eql(u8, s[prefix.len..end], "null"))
            return "{\"type\":[\"" ++ s[prefix.len..end] ++ "\",\"null\"]}";
    }
    if (std.mem.eql(u8, s, "true")) return s;
    return "{\"anyOf\":[" ++ s ++ ",{\"type\":\"null\"}]}";
}

fn integer(comptime min: anytype, comptime max: anytype) []const u8 {
    return std.fmt.comptimePrint("{{\"type\":\"integer\",\"minimum\":{d},\"maximum\":{d}}}", .{ min, max });
}

/// A number field held to its `range`, which lies within its type.
fn numberIn(comptime F: type, comptime range: anytype) []const u8 {
    if (@typeInfo(F) == .float) return std.fmt.comptimePrint("{{\"type\":\"number\",\"minimum\":{d},\"maximum\":{d}}}", .{ range.min, range.max });
    return integer(@max(range.min, std.math.minInt(F)), @min(range.max, std.math.maxInt(F)));
}

fn bounds(comptime R: type) []const u8 {
    return integer(std.math.minInt(R), std.math.maxInt(R));
}

/// `s` as a JSON string, at compile time.
fn string(comptime s: []const u8) []const u8 {
    var out: []const u8 = "\"";
    for (s) |c| out = out ++ switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        0...8, 11, 12, 14...31 => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
        else => &[_]u8{c},
    };
    return out ++ "\"";
}

/// The name a recursive type goes under in `$defs`: the last part of its
/// type name, with the index after it when another recursive type ends the same.
fn defName(comptime recursive: []const type, comptime index: usize) []const u8 {
    const short = shortName(recursive[index]);
    for (recursive, 0..) |R, i| if (i != index and std.mem.eql(u8, shortName(R), short))
        return std.fmt.comptimePrint("{s}{d}", .{ short, index });
    return short;
}

fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    var start: usize = 0;
    var depth: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    var name: []const u8 = "";
    for (full[start..]) |c| name = name ++ if (std.ascii.isAlphanumeric(c) or c == '_') &[_]u8{c} else "_";
    return name;
}

/// The struct and union types reachable from `T` that reach themselves.
fn findRecursive(comptime T: type, comptime stack: []const type, comptime found: []const type) []const type {
    for (stack) |S| if (S == T) return if (containsType(found, T)) found else found ++ .{T};
    if (descriptor.has(T, "strand_json_schema") or descriptor.has(T, "StrandRawFormat")) return found;
    if (scalars.kind(T) != null) return found;
    var result = found;
    switch (@typeInfo(T)) {
        inline .optional, .array, .vector => |i| result = findRecursive(i.child, stack, result),
        .pointer => |i| result = findRecursive(i.child, stack, result),
        .@"struct" => |i| for (i.field_types) |F| {
            result = findRecursive(F, stack ++ .{T}, result);
        },
        .@"union" => |i| for (i.field_types) |F| {
            result = findRecursive(F, stack ++ .{T}, result);
        },
        else => {},
    }
    return result;
}

fn containsType(comptime items: []const type, comptime item: type) bool {
    for (items) |x| if (x == item) return true;
    return false;
}
