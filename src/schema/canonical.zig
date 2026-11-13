//! One spelling for each JSON value as JSON Schema compares them: two values
//! are equal exactly when their encodings are the same bytes. Numbers are
//! equal by their mathematical value (`1.0` is `1`, and a number past a
//! double's range keeps every digit), so a number is its exact decimal; an
//! object's members are in the order of their names' bytes; strings are
//! their bytes with their length before them, so nothing needs escaping.
//! `enum` and `const` compile to these, and an instance's value is encoded
//! the same way as it streams.
const std = @import("std");
const strand = @import("strand");
const Decimal = @import("Decimal.zig");

const Value = strand.json.Value;
const Member = strand.core.Pair([]const u8, Value);

pub const Error = error{
    OutOfMemory,
    /// A number that is not JSON's.
    Invalid,
    /// A number's exponent past the bound.
    TooLarge,
};

/// The tags: one byte before each value.
pub const tag = struct {
    pub const @"null" = 'n';
    pub const @"true" = 't';
    pub const @"false" = 'f';
    /// `#`, `-` for a negative number, its digits, `e`, its exponent, `;`;
    /// zero is `#0;`.
    pub const number = '#';
    /// `s`, the length in decimal, `:`, the bytes.
    pub const string = 's';
    pub const array_begin = '[';
    pub const array_end = ']';
    pub const object_begin = '{';
    pub const object_end = '}';
};

/// `value` encoded onto `out`, with numbers' exponents bounded by
/// `max_exponent`.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: Value, max_exponent: u32) Error!void {
    switch (value) {
        .null_value => try out.append(gpa, tag.null),
        .boolean => |b| try out.append(gpa, if (b) tag.true else tag.false),
        .number => |text| try number(gpa, out, text, max_exponent),
        .string => |s| try string(gpa, out, s),
        .array => |items| {
            try out.append(gpa, tag.array_begin);
            for (items) |item| try encode(gpa, out, item, max_exponent);
            try out.append(gpa, tag.array_end);
        },
        .object => |members| {
            const sorted = try gpa.dupe(Member, members);
            defer gpa.free(sorted);
            std.mem.sort(Member, sorted, {}, byName);
            try out.append(gpa, tag.object_begin);
            for (sorted) |m| {
                try string(gpa, out, m.key);
                try encode(gpa, out, m.value, max_exponent);
            }
            try out.append(gpa, tag.object_end);
        },
    }
}

/// `value`'s encoding, on `gpa`.
pub fn encodeAlloc(gpa: std.mem.Allocator, value: Value, max_exponent: u32) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encode(gpa, &out, value, max_exponent);
    return out.toOwnedSlice(gpa);
}

fn byName(_: void, a: Member, b: Member) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// The number JSON's text `text` spells.
pub fn number(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max_exponent: u32) Error!void {
    const buffer = try gpa.alloc(u8, text.len);
    defer gpa.free(buffer);
    const d = Decimal.parse(text, buffer, max_exponent) catch |err| return switch (err) {
        error.Invalid => error.Invalid,
        error.TooLarge => error.TooLarge,
    };
    try out.append(gpa, tag.number);
    if (d.isZero()) {
        try out.appendSlice(gpa, "0;");
        return;
    }
    if (d.negative) try out.append(gpa, '-');
    try out.appendSlice(gpa, d.digits);
    try out.print(gpa, "e{d};", .{d.exponent});
}

pub fn string(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) Error!void {
    try out.print(gpa, "{c}{d}:", .{ tag.string, s.len });
    try out.appendSlice(gpa, s);
}

const testing = std.testing;

fn encoded(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const value = try strand.json.parseLeaky(Value, arena, text, .{});
    return encodeAlloc(arena, value, 4096);
}

test "equal values encode the same, and unequal ones differently" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const same = [_][2][]const u8{
        .{ "1", "1.0" },
        .{ "1", "1e0" },
        .{ "100", "1e2" },
        .{ "-0", "0" },
        .{ "0.0", "0e10" },
        .{ "{\"a\": 1, \"b\": [true, null]}", "{\"b\": [true, null], \"a\": 1.00}" },
        .{ "12345678901234567890123", "1.2345678901234567890123e22" },
    };
    for (same) |pair| try testing.expectEqualStrings(try encoded(a, pair[0]), try encoded(a, pair[1]));
    const different = [_][2][]const u8{
        .{ "1", "true" },
        .{ "0", "false" },
        .{ "null", "false" },
        .{ "\"1\"", "1" },
        .{ "[]", "{}" },
        .{ "[1, 2]", "[2, 1]" },
        .{ "{\"a\": 1}", "{\"a\": 1, \"b\": 1}" },
        // Past a double's precision, still apart.
        .{ "9007199254740993", "9007199254740992" },
        .{ "-1", "1" },
        // A string holding what looks like another value's encoding.
        .{ "[\"a\", \"b\"]", "[\"a\\\"b\"]" },
        .{ "\"s1:a\"", "\"a\"" },
    };
    for (different) |pair| try testing.expect(!std.mem.eql(u8, try encoded(a, pair[0]), try encoded(a, pair[1])));
}

test "a number past the exponent bound is refused" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const value = try strand.json.parseLeaky(Value, a, "1e5000", .{});
    try testing.expectError(error.TooLarge, encodeAlloc(a, value, 4096));
}

test "any two values: the same encoding exactly when JSON Schema calls them equal" {
    const shakedown = @import("shakedown");
    try shakedown.check(testing.allocator, {}, struct {
        /// A value as JSON Schema compares it: numbers by sign, significand
        /// and exponent with no trailing zero, objects as sets of members.
        const Model = union(enum) {
            null,
            boolean: bool,
            number: struct { negative: bool, digits: []const u8, exponent: i32 },
            string: []const u8,
            array: []const Model,
            /// Distinct names.
            object: []const struct { name: []const u8, value: Model },
        };

        const words = [_][]const u8{ "", "a", "b", "ab", "é" };
        const significands = [_][]const u8{ "", "1", "2", "15", "9007199254740993" };

        fn model(a: std.mem.Allocator, s: *shakedown.Source, depth: u32) !Model {
            const gen = shakedown.gen;
            const kind = gen.intRange(s, u8, 0, if (depth < 3) 6 else 4);
            return switch (kind) {
                0 => .null,
                1 => .{ .boolean = gen.boolean(s) },
                2, 3 => blk: {
                    const digits = significands[gen.intRange(s, usize, 0, significands.len - 1)];
                    break :blk .{ .number = .{ .negative = digits.len > 0 and gen.boolean(s), .digits = digits, .exponent = if (digits.len == 0) 0 else gen.intRange(s, i32, -3, 3) } };
                },
                4 => .{ .string = words[gen.intRange(s, usize, 0, words.len - 1)] },
                5 => blk: {
                    const items = try a.alloc(Model, gen.intRange(s, usize, 0, 3));
                    for (items) |*item| item.* = try model(a, s, depth + 1);
                    break :blk .{ .array = items };
                },
                else => blk: {
                    var members: std.ArrayList(@typeInfo(@FieldType(Model, "object")).pointer.child) = .empty;
                    for (words) |name| if (gen.intRange(s, u8, 0, 2) == 0) try members.append(a, .{ .name = name, .value = try model(a, s, depth + 1) });
                    break :blk .{ .object = members.items };
                },
            };
        }

        fn equal(x: Model, y: Model) bool {
            if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
            return switch (x) {
                .null => true,
                .boolean => |b| b == y.boolean,
                .number => |n| (n.digits.len == 0 and y.number.digits.len == 0) or
                    (n.negative == y.number.negative and n.exponent == y.number.exponent and std.mem.eql(u8, n.digits, y.number.digits)),
                .string => |t| std.mem.eql(u8, t, y.string),
                .array => |items| items.len == y.array.len and for (items, y.array) |p, q| {
                    if (!equal(p, q)) break false;
                } else true,
                .object => |members| members.len == y.object.len and for (members) |m| {
                    const other = for (y.object) |o| {
                        if (std.mem.eql(u8, o.name, m.name)) break o;
                    } else break false;
                    if (!equal(m.value, other.value)) break false;
                } else true,
            };
        }

        /// `m` written as JSON in a spelling chosen by `s`: numbers with
        /// their zeros moved between digits and exponent, a fraction or none,
        /// strings escaped or not, members in any order.
        fn spell(a: std.mem.Allocator, s: *shakedown.Source, out: *std.ArrayList(u8), m: Model) !void {
            const gen = shakedown.gen;
            switch (m) {
                .null => try out.appendSlice(a, "null"),
                .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
                .number => |n| {
                    if (n.digits.len == 0) {
                        const zeros = [_][]const u8{ "0", "-0", "0.0", "0e5", "-0.00E-2" };
                        return out.appendSlice(a, zeros[gen.intRange(s, usize, 0, zeros.len - 1)]);
                    }
                    if (n.negative) try out.append(a, '-');
                    const pad = gen.intRange(s, u8, 0, 2);
                    if (gen.boolean(s)) {
                        // d.ddd × 10^k: the point after the first digit.
                        try out.append(a, n.digits[0]);
                        try out.append(a, '.');
                        if (n.digits.len > 1) try out.appendSlice(a, n.digits[1..]) else try out.append(a, '0');
                        for (0..pad) |_| try out.append(a, '0');
                        try out.print(a, "e{d}", .{n.exponent + @as(i32, @intCast(n.digits.len)) - 1});
                    } else {
                        try out.appendSlice(a, n.digits);
                        for (0..pad) |_| try out.append(a, '0');
                        try out.print(a, "E{d}", .{n.exponent - pad});
                    }
                },
                .string => |t| {
                    try out.append(a, '"');
                    for (t) |byte| if (byte < 0x80 and gen.boolean(s)) try out.print(a, "\\u{x:0>4}", .{byte}) else try out.append(a, byte);
                    try out.append(a, '"');
                },
                .array => |items| {
                    try out.append(a, '[');
                    for (items, 0..) |item, i| {
                        if (i > 0) try out.append(a, ',');
                        try spell(a, s, out, item);
                    }
                    try out.append(a, ']');
                },
                .object => |members| {
                    const order = try a.alloc(usize, members.len);
                    for (order, 0..) |*o, i| o.* = i;
                    var i = order.len;
                    while (i > 1) : (i -= 1) std.mem.swap(usize, &order[i - 1], &order[gen.intRange(s, usize, 0, i - 1)]);
                    try out.append(a, '{');
                    for (order, 0..) |o, k| {
                        if (k > 0) try out.append(a, ',');
                        try spell(a, s, out, .{ .string = members[o].name });
                        try out.append(a, ':');
                        try spell(a, s, out, members[o].value);
                    }
                    try out.append(a, '}');
                },
            }
        }

        fn encodedOf(a: std.mem.Allocator, s: *shakedown.Source, m: Model) ![]const u8 {
            var text: std.ArrayList(u8) = .empty;
            try spell(a, s, &text, m);
            return encodeAlloc(a, try strand.json.parseLeaky(Value, a, text.items, .{}), 4096);
        }

        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const x = try model(a, case.source, 0);
            const y = try model(a, case.source, 0);
            const x1 = try encodedOf(a, case.source, x);
            const x2 = try encodedOf(a, case.source, x);
            try testing.expectEqualStrings(x1, x2);
            const y1 = try encodedOf(a, case.source, y);
            try testing.expectEqual(equal(x, y), std.mem.eql(u8, x1, y1));
        }
    }.one, .{ .cases = 5000, .seed = 0xca0 });
}
