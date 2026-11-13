//! The evaluator against a reference: random schemas over most of 2020-12's
//! keywords and random instances, each verdict streamed through the program
//! compared with a plain tree walk of the schema written here from the
//! specification's text, which reads the instance whole and applies each
//! keyword one at a time. The streaming evaluator promises the same verdict
//! with no tree; this holds it to that.
const std = @import("std");
const strand = @import("strand");
const shakedown = @import("shakedown");
const Schema = @import("Schema.zig");

const Value = strand.json.Value;
const Member = strand.core.Pair([]const u8, Value);
const testing = std.testing;

const names = [_][]const u8{ "a", "b", "c" };

fn get(members: []const Member, name: []const u8) ?Value {
    for (members) |m| if (std.mem.eql(u8, m.key, name)) return m.value;
    return null;
}

/// Numbers are integers and halves, exact as doubles, so the reference
/// compares them as doubles.
fn number(v: Value) f64 {
    return std.fmt.parseFloat(f64, v.number) catch unreachable;
}

fn equal(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null_value => true,
        .boolean => |b| b == y.boolean,
        .number => number(x) == number(y),
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |items| items.len == y.array.len and for (items, y.array) |p, q| {
            if (!equal(p, q)) break false;
        } else true,
        .object => |members| members.len == y.object.len and for (members) |m| {
            const other = get(y.object, m.key) orelse break false;
            if (!equal(m.value, other)) break false;
        } else true,
    };
}

fn typeIs(name: []const u8, v: Value) bool {
    return switch (v) {
        .null_value => std.mem.eql(u8, name, "null"),
        .boolean => std.mem.eql(u8, name, "boolean"),
        .number => std.mem.eql(u8, name, "number") or (std.mem.eql(u8, name, "integer") and @floor(number(v)) == number(v)),
        .string => std.mem.eql(u8, name, "string"),
        .array => std.mem.eql(u8, name, "array"),
        .object => std.mem.eql(u8, name, "object"),
    };
}

/// What a schema makes of a value: whether it is valid and, if so, which of
/// an object's members (by name, a bit each for `a`, `b`, `c`) and an
/// array's items (by position) its keywords and their passing in-place
/// subschemas evaluated: the annotations `unevaluated*` reads.
const Walked = struct { valid: bool, members: u8 = 0, items: u8 = 0 };

fn bit(name: []const u8) u8 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @as(u8, 1) << @intCast(i);
    unreachable;
}

fn valid(subschema: Value, instance: Value, root: Value) bool {
    return walk(subschema, instance, root).valid;
}

/// The specification's reading, keyword by keyword, over the whole instance.
fn walk(subschema: Value, instance: Value, root: Value) Walked {
    const members = switch (subschema) {
        .boolean => |b| return .{ .valid = b },
        .object => |m| m,
        else => unreachable,
    };
    var out: Walked = .{ .valid = true };
    for (members) |m| {
        const v = m.value;
        const k = m.key;
        const ok = if (std.mem.eql(u8, k, "type")) switch (v) {
            .string => |s| typeIs(s, instance),
            .array => |list| for (list) |t| {
                if (typeIs(t.string, instance)) break true;
            } else false,
            else => unreachable,
        } else if (std.mem.eql(u8, k, "const")) equal(v, instance) else if (std.mem.eql(u8, k, "enum")) for (v.array) |c| {
            if (equal(c, instance)) break true;
        } else false else if (std.mem.eql(u8, k, "minimum")) instance != .number or number(instance) >= number(v) else if (std.mem.eql(u8, k, "maximum")) instance != .number or number(instance) <= number(v) else if (std.mem.eql(u8, k, "exclusiveMinimum")) instance != .number or number(instance) > number(v) else if (std.mem.eql(u8, k, "exclusiveMaximum")) instance != .number or number(instance) < number(v) else if (std.mem.eql(u8, k, "multipleOf")) instance != .number or @rem(number(instance), number(v)) == 0 else if (std.mem.eql(u8, k, "minLength")) instance != .string or instance.string.len >= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "maxLength")) instance != .string or instance.string.len <= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "required")) instance != .object or for (v.array) |r| {
            if (get(instance.object, r.string) == null) break false;
        } else true else if (std.mem.eql(u8, k, "dependentRequired")) instance != .object or for (v.object) |d| {
            if (get(instance.object, d.key) == null) continue;
            if (for (d.value.array) |r| {
                if (get(instance.object, r.string) == null) break true;
            } else false) break false;
        } else true else if (std.mem.eql(u8, k, "minProperties")) instance != .object or instance.object.len >= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "maxProperties")) instance != .object or instance.object.len <= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "properties")) instance != .object or for (v.object) |p| {
            if (get(instance.object, p.key)) |child| {
                out.members |= bit(p.key);
                if (!walk(p.value, child, root).valid) break false;
            }
        } else true else if (std.mem.eql(u8, k, "additionalProperties")) instance != .object or for (instance.object) |im| {
            const named = if (get(members, "properties")) |props| get(props.object, im.key) != null else false;
            if (named) continue;
            out.members |= bit(im.key);
            if (!walk(v, im.value, root).valid) break false;
        } else true else if (std.mem.eql(u8, k, "propertyNames")) instance != .object or for (instance.object) |im| {
            if (!walk(v, .{ .string = im.key }, root).valid) break false;
        } else true else if (std.mem.eql(u8, k, "minItems")) instance != .array or instance.array.len >= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "maxItems")) instance != .array or instance.array.len <= @as(usize, @intFromFloat(number(v))) else if (std.mem.eql(u8, k, "uniqueItems")) instance != .array or !v.boolean or for (instance.array, 0..) |x, i| {
            if (for (instance.array[i + 1 ..]) |y| {
                if (equal(x, y)) break true;
            } else false) break false;
        } else true else if (std.mem.eql(u8, k, "prefixItems")) instance != .array or for (v.array, 0..) |sub, i| {
            if (i >= instance.array.len) continue;
            out.items |= @as(u8, 1) << @intCast(i);
            if (!walk(sub, instance.array[i], root).valid) break false;
        } else true else if (std.mem.eql(u8, k, "items")) instance != .array or blk: {
            const from = if (get(members, "prefixItems")) |p| p.array.len else 0;
            for (instance.array, 0..) |item, i| if (i >= from) {
                out.items |= @as(u8, 1) << @intCast(i);
                if (!walk(v, item, root).valid) break :blk false;
            };
            break :blk true;
        } else if (std.mem.eql(u8, k, "contains")) instance != .array or blk: {
            var matched: usize = 0;
            for (instance.array, 0..) |item, i| if (walk(v, item, root).valid) {
                matched += 1;
                out.items |= @as(u8, 1) << @intCast(i);
            };
            const min: usize = if (get(members, "minContains")) |x| @intFromFloat(number(x)) else 1;
            const max: ?usize = if (get(members, "maxContains")) |x| @intFromFloat(number(x)) else null;
            break :blk matched >= min and (max == null or matched <= max.?);
        } else if (std.mem.eql(u8, k, "allOf")) for (v.array) |sub| {
            if (!take(&out, walk(sub, instance, root))) break false;
        } else true else if (std.mem.eql(u8, k, "anyOf")) blk: {
            var any = false;
            for (v.array) |sub| any = take(&out, walk(sub, instance, root)) or any;
            break :blk any;
        } else if (std.mem.eql(u8, k, "oneOf")) blk: {
            var count: usize = 0;
            for (v.array) |sub| if (take(&out, walk(sub, instance, root))) {
                count += 1;
            };
            break :blk count == 1;
        } else if (std.mem.eql(u8, k, "not")) !walk(v, instance, root).valid else if (std.mem.eql(u8, k, "if")) blk: {
            if (take(&out, walk(v, instance, root))) {
                break :blk if (get(members, "then")) |t| take(&out, walk(t, instance, root)) else true;
            }
            break :blk if (get(members, "else")) |e| take(&out, walk(e, instance, root)) else true;
        } else if (std.mem.eql(u8, k, "dependentSchemas")) instance != .object or for (v.object) |d| {
            if (get(instance.object, d.key) == null) continue;
            if (!take(&out, walk(d.value, instance, root))) break false;
        } else true else if (std.mem.eql(u8, k, "$ref")) blk: {
            const name = v.string["#/$defs/".len..];
            break :blk take(&out, walk(get(get(root.object, "$defs").?.object, name).?, instance, root));
        } else true;
        if (!ok) out.valid = false;
    }
    // `unevaluated*` last, over what nothing else evaluated.
    if (get(members, "unevaluatedProperties")) |u| if (instance == .object) {
        for (instance.object) |im| if (out.members & bit(im.key) == 0) {
            if (!walk(u, im.value, root).valid) out.valid = false;
        };
        for (instance.object) |im| out.members |= bit(im.key);
    };
    if (get(members, "unevaluatedItems")) |u| if (instance == .array) {
        for (instance.array, 0..) |item, i| if (out.items & (@as(u8, 1) << @intCast(i)) == 0) {
            if (!walk(u, item, root).valid) out.valid = false;
        };
        for (0..instance.array.len) |i| out.items |= @as(u8, 1) << @intCast(i);
    };
    if (!out.valid) return .{ .valid = false };
    return out;
}

/// A passing in-place subschema's annotations become the schema's.
fn take(out: *Walked, w: Walked) bool {
    if (w.valid) {
        out.members |= w.members;
        out.items |= w.items;
    }
    return w.valid;
}

/// A random schema, written as JSON: `defs` names the definitions a
/// reference may name, each only those after it, so none applies itself.
fn randomSchema(a: std.mem.Allocator, s: *shakedown.Source, out: *std.ArrayList(u8), depth: u32, defs: usize) !void {
    const gen = shakedown.gen;
    if (depth > 2 or gen.intRange(s, u8, 0, 6) == 0) return out.appendSlice(a, if (gen.boolean(s)) "true" else "false");
    try out.append(a, '{');
    var first = true;
    const keywords = [_][]const u8{
        "type",              "const",            "enum",                  "minimum",          "exclusiveMaximum",     "multipleOf",
        "minLength",         "maxLength",        "required",              "properties",       "additionalProperties", "propertyNames",
        "maxProperties",     "prefixItems",      "items",                 "contains",         "minItems",             "allOf",
        "anyOf",             "oneOf",            "not",                   "if",               "$ref",                 "uniqueItems",
        "dependentRequired", "dependentSchemas", "unevaluatedProperties", "unevaluatedItems",
    };
    for (keywords) |k| {
        if (gen.intRange(s, u8, 0, 7) != 0) continue;
        if (std.mem.eql(u8, k, "$ref") and defs == 0) continue;
        if (!first) try out.appendSlice(a, ", ");
        first = false;
        try out.print(a, "\"{s}\": ", .{k});
        if (std.mem.eql(u8, k, "type")) {
            const types = [_][]const u8{ "\"null\"", "\"boolean\"", "\"integer\"", "\"number\"", "\"string\"", "\"array\"", "\"object\"", "[\"string\", \"integer\"]" };
            try out.appendSlice(a, types[gen.intRange(s, usize, 0, types.len - 1)]);
        } else if (std.mem.eql(u8, k, "const")) {
            try randomInstance(a, s, out, 1);
        } else if (std.mem.eql(u8, k, "enum")) {
            try out.append(a, '[');
            try randomInstance(a, s, out, 1);
            try out.appendSlice(a, ", ");
            try randomInstance(a, s, out, 1);
            try out.append(a, ']');
        } else if (std.mem.eql(u8, k, "minimum") or std.mem.eql(u8, k, "exclusiveMaximum")) {
            try scalarNumber(a, s, out);
        } else if (std.mem.eql(u8, k, "multipleOf")) {
            const divisors = [_][]const u8{ "1", "2", "0.5", "1.5" };
            try out.appendSlice(a, divisors[gen.intRange(s, usize, 0, divisors.len - 1)]);
        } else if (std.mem.eql(u8, k, "minLength") or std.mem.eql(u8, k, "maxLength") or std.mem.eql(u8, k, "maxProperties") or std.mem.eql(u8, k, "minItems")) {
            try out.print(a, "{d}", .{gen.intRange(s, u8, 0, 3)});
        } else if (std.mem.eql(u8, k, "required")) {
            try out.print(a, "[\"{s}\"]", .{names[gen.intRange(s, usize, 0, names.len - 1)]});
        } else if (std.mem.eql(u8, k, "properties")) {
            try out.append(a, '{');
            for (names, 0..) |name, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.print(a, "\"{s}\": ", .{name});
                try randomSchema(a, s, out, depth + 1, defs);
            }
            try out.append(a, '}');
        } else if (std.mem.eql(u8, k, "prefixItems") or std.mem.eql(u8, k, "allOf") or std.mem.eql(u8, k, "anyOf") or std.mem.eql(u8, k, "oneOf")) {
            try out.append(a, '[');
            try randomSchema(a, s, out, depth + 1, defs);
            try out.appendSlice(a, ", ");
            try randomSchema(a, s, out, depth + 1, defs);
            try out.append(a, ']');
        } else if (std.mem.eql(u8, k, "if")) {
            try randomSchema(a, s, out, depth + 1, defs);
            try out.appendSlice(a, ", \"then\": ");
            try randomSchema(a, s, out, depth + 1, defs);
            if (gen.boolean(s)) {
                try out.appendSlice(a, ", \"else\": ");
                try randomSchema(a, s, out, depth + 1, defs);
            }
        } else if (std.mem.eql(u8, k, "contains")) {
            try randomSchema(a, s, out, depth + 1, defs);
            if (gen.boolean(s)) try out.print(a, ", \"minContains\": {d}", .{gen.intRange(s, u8, 0, 2)});
            if (gen.boolean(s)) try out.print(a, ", \"maxContains\": {d}", .{gen.intRange(s, u8, 1, 3)});
        } else if (std.mem.eql(u8, k, "$ref")) {
            try out.print(a, "\"#/$defs/d{d}\"", .{gen.intRange(s, usize, 0, defs - 1)});
        } else if (std.mem.eql(u8, k, "uniqueItems")) {
            try out.appendSlice(a, if (gen.boolean(s)) "true" else "false");
        } else if (std.mem.eql(u8, k, "dependentRequired")) {
            try out.print(a, "{{\"{s}\": [\"{s}\"]}}", .{ names[gen.intRange(s, usize, 0, names.len - 1)], names[gen.intRange(s, usize, 0, names.len - 1)] });
        } else if (std.mem.eql(u8, k, "dependentSchemas")) {
            try out.print(a, "{{\"{s}\": ", .{names[gen.intRange(s, usize, 0, names.len - 1)]});
            try randomSchema(a, s, out, depth + 1, defs);
            try out.append(a, '}');
        } else {
            try randomSchema(a, s, out, depth + 1, defs);
        }
    }
    try out.append(a, '}');
}

fn scalarNumber(a: std.mem.Allocator, s: *shakedown.Source, out: *std.ArrayList(u8)) !void {
    const numbers = [_][]const u8{ "-2", "-0.5", "0", "1", "1.0", "1.5", "2", "3", "1e0", "15e-1" };
    try out.appendSlice(a, numbers[shakedown.gen.intRange(s, usize, 0, numbers.len - 1)]);
}

fn randomInstance(a: std.mem.Allocator, s: *shakedown.Source, out: *std.ArrayList(u8), depth: u32) !void {
    const gen = shakedown.gen;
    switch (gen.intRange(s, u8, 0, if (depth < 3) 6 else 4)) {
        0 => try out.appendSlice(a, "null"),
        1 => try out.appendSlice(a, if (gen.boolean(s)) "true" else "false"),
        2, 3 => try scalarNumber(a, s, out),
        4 => {
            const strings = [_][]const u8{ "\"\"", "\"a\"", "\"ab\"", "\"abc\"", "\"b\"" };
            try out.appendSlice(a, strings[gen.intRange(s, usize, 0, strings.len - 1)]);
        },
        5 => {
            try out.append(a, '[');
            for (0..gen.intRange(s, usize, 0, 3)) |i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try randomInstance(a, s, out, depth + 1);
            }
            try out.append(a, ']');
        },
        else => {
            try out.append(a, '{');
            var first = true;
            for (names) |name| if (gen.boolean(s)) {
                if (!first) try out.appendSlice(a, ", ");
                first = false;
                try out.print(a, "\"{s}\": ", .{name});
                try randomInstance(a, s, out, depth + 1);
            };
            try out.append(a, '}');
        },
    }
}

/// Whether `pointer` names a value in `v`.
fn resolves(v: Value, pointer: []const u8) bool {
    if (pointer.len == 0) return true;
    if (pointer[0] != '/') return false;
    const rest = pointer[1..];
    const end = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const token = rest[0..end];
    const next = rest[end..];
    return switch (v) {
        .object => |members| if (get(members, token)) |child| resolves(child, next) else false,
        .array => |items| blk: {
            const i = std.fmt.parseInt(usize, token, 10) catch break :blk false;
            break :blk i < items.len and resolves(items[i], next);
        },
        else => false,
    };
}

test "any schema and instance: streaming gives the verdict the specification's tree walk gives" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gen = shakedown.gen;
            const s = case.source;
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var text: std.ArrayList(u8) = .empty;
            const defs = gen.intRange(s, usize, 0, 2);
            try text.appendSlice(a, "{\"$defs\": {");
            for (0..defs) |i| {
                if (i > 0) try text.appendSlice(a, ", ");
                try text.print(a, "\"d{d}\": ", .{i});
                // Each definition may name only those after it.
                var body: std.ArrayList(u8) = .empty;
                try randomSchema(a, s, &body, 1, 0);
                try text.appendSlice(a, body.items);
            }
            try text.appendSlice(a, "}, \"allOf\": [");
            try randomSchema(a, s, &text, 0, defs);
            try text.appendSlice(a, "]}");
            var compiled = try Schema.compile(testing.allocator, testing.io, strand.json, .init(text.items), .{});
            defer compiled.deinit();
            const root = try strand.json.parseLeaky(Value, a, text.items, .{});
            for (0..8) |_| {
                var data: std.ArrayList(u8) = .empty;
                try randomInstance(a, s, &data, 0);
                const value = try strand.json.parseLeaky(Value, a, data.items, .{});
                const expected = valid(root, value, root);
                const got = try compiled.validate(testing.io, a, strand.json, .init(data.items), .flag);
                testing.expectEqual(expected, got) catch |err| {
                    std.debug.print("schema {s}\ninstance {s}\n", .{ text.items, data.items });
                    return err;
                };
                // `basic` gives the same verdict, and an invalid one says
                // why, each record's instance location a value in the
                // instance and its keyword location one in the schema.
                var errors: Schema.Errors = .{};
                try testing.expectEqual(got, try compiled.validate(testing.io, a, strand.json, .init(data.items), .{ .basic = &errors }));
                try testing.expectEqual(got, errors.records.len == 0);
                for (errors.records) |r| {
                    try testing.expect(resolves(value, r.instance_location));
                    try testing.expect(std.mem.startsWith(u8, r.absolute_keyword_location, "urn:strand:schema#"));
                }
            }
        }
    }.one, .{ .cases = 3000, .seed = 0xe7a1 });
}
