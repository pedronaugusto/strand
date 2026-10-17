//! A JSON Schema checker for the tests of `json.schema`: the keywords the
//! derivation writes, applied as 2020-12 applies them, so a property can hold
//! every value strand writes for a type to the schema derived for it. Test
//! support, not a validator anyone else should lean on.
const std = @import("std");
const Value = @import("../json/Value.zig").Value;

pub const Error = error{ Mismatch, UnknownKeyword, BadSchema };

pub fn check(root: Value, schema: Value, value: Value) Error!void {
    return at(root, schema, value);
}

fn member(object: []const @import("../json/Value.zig").Member, key: []const u8) ?Value {
    for (object) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
    return null;
}

fn typeName(value: Value) []const u8 {
    return switch (value) {
        .null_value => "null",
        .boolean => "boolean",
        .number => |n| if (std.mem.findAny(u8, n, ".eE") == null) "integer" else "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn isType(name: []const u8, value: Value) bool {
    const actual = typeName(value);
    if (std.mem.eql(u8, name, actual)) return true;
    return std.mem.eql(u8, name, "number") and std.mem.eql(u8, actual, "integer");
}

fn number(n: []const u8) f128 {
    return std.fmt.parseFloat(f128, n) catch unreachable; // unreachable: strand checked the lexeme
}

fn equal(a: Value, b: Value) bool {
    return switch (a) {
        .null_value => b == .null_value,
        .boolean => |x| b == .boolean and b.boolean == x,
        .number => |x| b == .number and number(x) == number(b.number),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.len == b.array.len and for (x, b.array) |p, q| {
            if (!equal(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.len == b.object.len and for (x) |m| {
            const other = member(b.object, m.key) orelse break false;
            if (!equal(m.value, other)) break false;
        } else true,
    };
}

fn at(root: Value, schema: Value, value: Value) Error!void {
    switch (schema) {
        .boolean => |b| return if (b) {} else error.Mismatch,
        .object => {},
        else => return error.BadSchema,
    }
    for (schema.object) |k| {
        const key = k.key;
        const s = k.value;
        if (std.mem.eql(u8, key, "$schema") or std.mem.eql(u8, key, "$defs") or std.mem.eql(u8, key, "description")) continue;
        if (std.mem.eql(u8, key, "$ref")) {
            const ref = s.string;
            if (std.mem.eql(u8, ref, "#")) try at(root, root, value) else {
                const prefix = "#/$defs/";
                if (!std.mem.startsWith(u8, ref, prefix)) return error.BadSchema;
                const defs = member(root.object, "$defs") orelse return error.BadSchema;
                try at(root, member(defs.object, ref[prefix.len..]) orelse return error.BadSchema, value);
            }
        } else if (std.mem.eql(u8, key, "type")) {
            switch (s) {
                .string => |name| if (!isType(name, value)) return error.Mismatch,
                .array => |names| for (names) |n| {
                    if (isType(n.string, value)) break;
                } else return error.Mismatch,
                else => return error.BadSchema,
            }
        } else if (std.mem.eql(u8, key, "enum")) {
            for (s.array) |e| {
                if (equal(e, value)) break;
            } else return error.Mismatch;
        } else if (std.mem.eql(u8, key, "const")) {
            if (!equal(s, value)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "minimum")) {
            if (value == .number and number(value.number) < number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "maximum")) {
            if (value == .number and number(value.number) > number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "properties")) {
            if (value != .object) continue;
            for (s.object) |p| if (member(value.object, p.key)) |v| try at(root, p.value, v);
        } else if (std.mem.eql(u8, key, "required")) {
            if (value != .object) continue;
            for (s.array) |r| if (member(value.object, r.string) == null) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "additionalProperties")) {
            if (value != .object) continue;
            const named = member(schema.object, "properties");
            for (value.object) |m| {
                if (named) |n| if (member(n.object, m.key) != null) continue;
                try at(root, s, m.value);
            }
        } else if (std.mem.eql(u8, key, "minProperties")) {
            if (value == .object and value.object.len < number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "maxProperties")) {
            if (value == .object and value.object.len > number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "items")) {
            if (value != .array) continue;
            const prefix = if (member(schema.object, "prefixItems")) |p| p.array.len else 0;
            if (value.array.len > prefix) for (value.array[prefix..]) |v| try at(root, s, v);
        } else if (std.mem.eql(u8, key, "prefixItems")) {
            if (value != .array) continue;
            for (s.array, 0..) |p, i| if (i < value.array.len) try at(root, p, value.array[i]);
        } else if (std.mem.eql(u8, key, "minItems")) {
            if (value == .array and value.array.len < number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "maxItems")) {
            if (value == .array and value.array.len > number(s.number)) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "allOf")) {
            for (s.array) |sub| try at(root, sub, value);
        } else if (std.mem.eql(u8, key, "anyOf")) {
            for (s.array) |sub| {
                if (at(root, sub, value)) |_| break else |err| if (err != error.Mismatch) return err;
            } else return error.Mismatch;
        } else if (std.mem.eql(u8, key, "oneOf")) {
            var matched: usize = 0;
            for (s.array) |sub| {
                if (at(root, sub, value)) |_| {
                    matched += 1;
                } else |err| if (err != error.Mismatch) return err;
            }
            if (matched != 1) return error.Mismatch;
        } else if (std.mem.eql(u8, key, "not")) {
            if (at(root, s, value)) |_| return error.Mismatch else |err| if (err != error.Mismatch) return err;
        } else return error.UnknownKeyword;
    }
}
