//! MessagePack: golden vectors from the specification for every format family
//! and each of its boundaries, kawanet's msgpack-test-suite (every encoding of
//! every value read, ours among them and the shortest), what is not
//! MessagePack, typed values both ways, extensions and timestamps, the
//! deterministic profile, limits at their edges, allocation failures, and
//! properties over generated values and bytes.
//!
//! msgpack-test-suite at e04f6edeaae589c768d6b70fcce80aa786b7800e (MIT,
//! src/corpus/msgpack/LICENSE).
const std = @import("std");
const msgpack = @import("msgpack.zig");
const json = @import("json.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;
const Value = msgpack.Value;

fn bytesOf(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}
fn written(value: anytype, options: msgpack.WriteOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try msgpack.write(&out.writer, value, options);
    return out.toOwnedSlice();
}
fn expectRead(input: []const u8, want: Value) !void {
    var parsed = msgpack.parse(Value, gpa, input, .{}) catch |err| {
        std.debug.print("{x}: {t}\n", .{ input, err });
        return err;
    };
    defer parsed.deinit();
    if (!parsed.value.eql(want)) {
        std.debug.print("{x}: read {any}\n", .{ input, parsed.value });
        return error.TestUnexpectedResult;
    }
}
/// `input` is read as `want`, written back as `input`, and refused cut short
/// anywhere.
fn expectGolden(input: []const u8, want: Value) !void {
    try expectRead(input, want);
    const out = try written(want, .{});
    defer gpa.free(out);
    std.testing.expectEqualSlices(u8, input, out) catch |err| {
        std.debug.print("{any} written as {x}\n", .{ want, out });
        return err;
    };
    for (0..input.len) |end| {
        if (msgpack.parse(Value, gpa, input[0..end], .{})) |p| {
            var cut = p;
            cut.deinit();
            std.debug.print("{x} cut at {d} was read\n", .{ input, end });
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.SyntaxError, err);
    }
}

const Golden = struct { hex: []const u8, want: Value };
const fixed_goldens = [_]Golden{
    // nil and bool
    .{ .hex = "c0", .want = .nil },
    .{ .hex = "c2", .want = .{ .boolean = false } },
    .{ .hex = "c3", .want = .{ .boolean = true } },
    // positive fixint and the unsigned family, at every edge
    .{ .hex = "00", .want = .{ .unsigned = 0 } },
    .{ .hex = "7f", .want = .{ .unsigned = 0x7f } },
    .{ .hex = "cc80", .want = .{ .unsigned = 0x80 } },
    .{ .hex = "ccff", .want = .{ .unsigned = 0xff } },
    .{ .hex = "cd0100", .want = .{ .unsigned = 0x100 } },
    .{ .hex = "cdffff", .want = .{ .unsigned = 0xffff } },
    .{ .hex = "ce00010000", .want = .{ .unsigned = 0x10000 } },
    .{ .hex = "ceffffffff", .want = .{ .unsigned = 0xffff_ffff } },
    .{ .hex = "cf0000000100000000", .want = .{ .unsigned = 0x1_0000_0000 } },
    .{ .hex = "cfffffffffffffffff", .want = .{ .unsigned = std.math.maxInt(u64) } },
    // negative fixint and the signed family, at every edge
    .{ .hex = "ff", .want = .{ .negative = -1 } },
    .{ .hex = "e0", .want = .{ .negative = -32 } },
    .{ .hex = "d0df", .want = .{ .negative = -33 } },
    .{ .hex = "d080", .want = .{ .negative = -128 } },
    .{ .hex = "d1ff7f", .want = .{ .negative = -129 } },
    .{ .hex = "d18000", .want = .{ .negative = -32768 } },
    .{ .hex = "d2ffff7fff", .want = .{ .negative = -32769 } },
    .{ .hex = "d280000000", .want = .{ .negative = -(1 << 31) } },
    .{ .hex = "d3ffffffff7fffffff", .want = .{ .negative = -(1 << 31) - 1 } },
    .{ .hex = "d38000000000000000", .want = .{ .negative = std.math.minInt(i64) } },
    // float 32 where it holds the bits, float 64 where it does not
    .{ .hex = "ca00000000", .want = .{ .float = 0.0 } },
    .{ .hex = "ca80000000", .want = .{ .float = -0.0 } },
    .{ .hex = "ca3f000000", .want = .{ .float = 0.5 } },
    .{ .hex = "ca7f800000", .want = .{ .float = std.math.inf(f64) } },
    .{ .hex = "caff800000", .want = .{ .float = -std.math.inf(f64) } },
    .{ .hex = "ca7f7fffff", .want = .{ .float = std.math.floatMax(f32) } },
    .{ .hex = "cb3ff199999999999a", .want = .{ .float = 1.1 } },
    .{ .hex = "cb7fefffffffffffff", .want = .{ .float = std.math.floatMax(f64) } },
    .{ .hex = "cb0000000000000001", .want = .{ .float = std.math.floatTrueMin(f64) } },
    // str, bin, arrays and maps of a few items
    .{ .hex = "a0", .want = .{ .str = "" } },
    .{ .hex = "a161", .want = .{ .str = "a" } },
    .{ .hex = "a3e29da4", .want = .{ .str = "\u{2764}" } },
    .{ .hex = "c400", .want = .{ .bin = "" } },
    .{ .hex = "c40200ff", .want = .{ .bin = &.{ 0, 0xff } } },
    .{ .hex = "90", .want = .{ .array = &.{} } },
    .{ .hex = "9201c0", .want = .{ .array = &.{ .{ .unsigned = 1 }, .nil } } },
    .{ .hex = "80", .want = .{ .map = &.{} } },
    .{ .hex = "82a16101c3a162", .want = .{ .map = &.{ .{ .key = .{ .str = "a" }, .value = .{ .unsigned = 1 } }, .{ .key = .{ .boolean = true }, .value = .{ .str = "b" } } } } },
    // fixext 1, 2, 4, 8 and 16, ext 8 for the other short lengths, and the
    // timestamp's three forms
    .{ .hex = "d40110", .want = .{ .ext = .{ .type_id = 1, .data = &.{0x10} } } },
    .{ .hex = "d5022021", .want = .{ .ext = .{ .type_id = 2, .data = &.{ 0x20, 0x21 } } } },
    .{ .hex = "d6ff5a4af6a5", .want = .{ .ext = .{ .type_id = -1, .data = &.{ 0x5a, 0x4a, 0xf6, 0xa5 } } } },
    .{ .hex = "d7ffa1dcd7c85a4af6a5", .want = .{ .ext = .{ .type_id = -1, .data = &.{ 0xa1, 0xdc, 0xd7, 0xc8, 0x5a, 0x4a, 0xf6, 0xa5 } } } },
    .{ .hex = "d88000000000000000000000000000000000", .want = .{ .ext = .{ .type_id = -128, .data = &@as([16]u8, @splat(0)) } } },
    .{ .hex = "c7007f", .want = .{ .ext = .{ .type_id = 127, .data = "" } } },
    .{ .hex = "c70307707172", .want = .{ .ext = .{ .type_id = 7, .data = "pqr" } } },
    .{ .hex = "c70cff000000000000000400000000", .want = .{ .ext = .{ .type_id = -1, .data = &.{ 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0 } } } },
};

test "the specification's formats: every family at its edges, read and written back" {
    inline for (fixed_goldens) |golden| {
        const input = bytesOf(golden.hex);
        try expectGolden(&input, golden.want);
    }
    // A NaN keeps its bits, in float 32 where they fit and float 64 where not.
    try expectGolden(&bytesOf("ca7fc00000"), .{ .float = std.math.nan(f64) });
    const payload: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_0001));
    const out = try written(Value{ .float = payload }, .{});
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &bytesOf("cb7ff8000000000001"), out);
}

/// `n` bytes of `fill`.
fn filled(n: usize, fill: u8) ![]u8 {
    const b = try gpa.alloc(u8, n);
    @memset(b, fill);
    return b;
}

test "lengths at every header's edge: str, bin, array, map and ext" {
    const Edge = struct { n: usize, header: []const u8 };
    const str_edges = [_]Edge{ .{ .n = 31, .header = &.{0xbf} }, .{ .n = 32, .header = &.{ 0xd9, 0x20 } }, .{ .n = 255, .header = &.{ 0xd9, 0xff } }, .{ .n = 256, .header = &.{ 0xda, 0x01, 0x00 } }, .{ .n = 65535, .header = &.{ 0xda, 0xff, 0xff } }, .{ .n = 65536, .header = &.{ 0xdb, 0x00, 0x01, 0x00, 0x00 } } };
    const bin_edges = [_]Edge{ .{ .n = 0, .header = &.{ 0xc4, 0x00 } }, .{ .n = 255, .header = &.{ 0xc4, 0xff } }, .{ .n = 256, .header = &.{ 0xc5, 0x01, 0x00 } }, .{ .n = 65535, .header = &.{ 0xc5, 0xff, 0xff } }, .{ .n = 65536, .header = &.{ 0xc6, 0x00, 0x01, 0x00, 0x00 } } };
    const array_edges = [_]Edge{ .{ .n = 15, .header = &.{0x9f} }, .{ .n = 16, .header = &.{ 0xdc, 0x00, 0x10 } }, .{ .n = 65535, .header = &.{ 0xdc, 0xff, 0xff } }, .{ .n = 65536, .header = &.{ 0xdd, 0x00, 0x01, 0x00, 0x00 } } };
    const map_edges = [_]Edge{ .{ .n = 15, .header = &.{0x8f} }, .{ .n = 16, .header = &.{ 0xde, 0x00, 0x10 } }, .{ .n = 65535, .header = &.{ 0xde, 0xff, 0xff } }, .{ .n = 65536, .header = &.{ 0xdf, 0x00, 0x01, 0x00, 0x00 } } };
    const ext_edges = [_]Edge{ .{ .n = 0, .header = &.{ 0xc7, 0x00 } }, .{ .n = 1, .header = &.{0xd4} }, .{ .n = 2, .header = &.{0xd5} }, .{ .n = 3, .header = &.{ 0xc7, 0x03 } }, .{ .n = 4, .header = &.{0xd6} }, .{ .n = 8, .header = &.{0xd7} }, .{ .n = 15, .header = &.{ 0xc7, 0x0f } }, .{ .n = 16, .header = &.{0xd8} }, .{ .n = 17, .header = &.{ 0xc7, 0x11 } }, .{ .n = 255, .header = &.{ 0xc7, 0xff } }, .{ .n = 256, .header = &.{ 0xc8, 0x01, 0x00 } }, .{ .n = 65535, .header = &.{ 0xc8, 0xff, 0xff } }, .{ .n = 65536, .header = &.{ 0xc9, 0x00, 0x01, 0x00, 0x00 } } };
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    for (str_edges) |e| {
        const s = try filled(e.n, 'x');
        defer gpa.free(s);
        input.clearRetainingCapacity();
        try input.appendSlice(gpa, e.header);
        try input.appendSlice(gpa, s);
        try expectGolden(input.items, .{ .str = s });
    }
    for (bin_edges) |e| {
        const s = try filled(e.n, 0xab);
        defer gpa.free(s);
        input.clearRetainingCapacity();
        try input.appendSlice(gpa, e.header);
        try input.appendSlice(gpa, s);
        try expectRead(input.items, .{ .bin = s });
        const out = try written(Value{ .bin = s }, .{});
        defer gpa.free(out);
        try std.testing.expectEqualSlices(u8, input.items, out);
    }
    for (ext_edges) |e| {
        const s = try filled(e.n, 0xcd);
        defer gpa.free(s);
        input.clearRetainingCapacity();
        try input.appendSlice(gpa, e.header);
        try input.append(gpa, 0x05);
        try input.appendSlice(gpa, s);
        try expectRead(input.items, .{ .ext = .{ .type_id = 5, .data = s } });
        const out = try written(Value{ .ext = .{ .type_id = 5, .data = s } }, .{});
        defer gpa.free(out);
        try std.testing.expectEqualSlices(u8, input.items, out);
    }
    for (array_edges) |e| {
        const items = try gpa.alloc(Value, e.n);
        defer gpa.free(items);
        @memset(items, .nil);
        input.clearRetainingCapacity();
        try input.appendSlice(gpa, e.header);
        try input.appendNTimes(gpa, 0xc0, e.n);
        try expectRead(input.items, .{ .array = items });
        const out = try written(Value{ .array = items }, .{});
        defer gpa.free(out);
        try std.testing.expectEqualSlices(u8, input.items, out);
    }
    for (map_edges) |e| {
        const entries = try gpa.alloc(msgpack.Entry, e.n);
        defer gpa.free(entries);
        @memset(entries, .{ .key = .nil, .value = .nil });
        input.clearRetainingCapacity();
        try input.appendSlice(gpa, e.header);
        try input.appendNTimes(gpa, 0xc0, 2 * e.n);
        try expectRead(input.items, .{ .map = entries });
        const out = try written(Value{ .map = entries }, .{});
        defer gpa.free(out);
        try std.testing.expectEqualSlices(u8, input.items, out);
    }
}

test "every integer family read wherever it fits, and written in the smallest" {
    // Each value in each family that holds it, the shortest first.
    const Case = struct { want: i65, hexes: []const []const u8 };
    const cases = [_]Case{
        .{ .want = 0, .hexes = &.{ "00", "cc00", "cd0000", "ce00000000", "cf0000000000000000", "d000", "d10000", "d200000000", "d30000000000000000", "e0" } },
        .{ .want = 127, .hexes = &.{ "7f", "cc7f", "cd007f", "d07f", "d1007f", "d3000000000000007f" } },
        .{ .want = 128, .hexes = &.{ "cc80", "cd0080", "d10080", "d200000080" } },
        .{ .want = -1, .hexes = &.{ "ff", "d0ff", "d1ffff", "d2ffffffff", "d3ffffffffffffffff" } },
        .{ .want = -33, .hexes = &.{ "d0df", "d1ffdf", "d2ffffffdf" } },
        .{ .want = std.math.maxInt(i64), .hexes = &.{ "cf7fffffffffffffff", "d37fffffffffffffff" } },
    };
    for (cases) |case| for (case.hexes, 0..) |hex, i| {
        // 0xe0 is -32, not 0: the first column's last entry is a negative fixint.
        if (case.want == 0 and std.mem.eql(u8, hex, "e0")) continue;
        var buffer: [9]u8 = undefined;
        const input = try std.fmt.hexToBytes(&buffer, hex);
        var parsed = try msgpack.parse(i65, gpa, input, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.want, parsed.value);
        if (i == 0) {
            const out = try written(case.want, .{});
            defer gpa.free(out);
            try std.testing.expectEqualSlices(u8, input, out);
        }
    };
}

/// A JSON value of the suite as the MessagePack value it stands for: a number
/// with no fraction or exponent an integer, any other a float.
fn fromJson(a: std.mem.Allocator, v: json.Value) !Value {
    return switch (v) {
        .null_value => .nil,
        .boolean => |b| .{ .boolean = b },
        .number => |lexeme| integerOf(lexeme) orelse .{ .float = try std.fmt.parseFloat(f64, lexeme) },
        .string => |s| .{ .str = s },
        .array => |items| blk: {
            const out = try a.alloc(Value, items.len);
            for (out, items) |*o, element| o.* = try fromJson(a, element);
            break :blk .{ .array = out };
        },
        .object => |members| blk: {
            const out = try a.alloc(msgpack.Entry, members.len);
            for (out, members) |*o, m| o.* = .{ .key = .{ .str = m.key }, .value = try fromJson(a, m.value) };
            break :blk .{ .map = out };
        },
    };
}
fn integerOf(text: []const u8) ?Value {
    const n = std.fmt.parseInt(i65, text, 10) catch return null;
    return if (n >= 0) .{ .unsigned = @intCast(n) } else .{ .negative = @intCast(n) };
}
/// Whether `read` is `want`, where the suite's numbers are a number however
/// they are encoded: an integer may come as a float of the same value.
fn sameNumber(read: Value, want: Value) bool {
    if (read == .float) switch (want) {
        .unsigned => |n| return read.float == @as(f64, @floatFromInt(n)),
        .negative => |n| return read.float == @as(f64, @floatFromInt(n)),
        else => {},
    };
    return switch (want) {
        .array => |items| read == .array and read.array.len == items.len and for (read.array, items) |r, w| {
            if (!sameNumber(r, w)) break false;
        } else true,
        .map => |entries| read == .map and read.map.len == entries.len and for (read.map, entries) |r, w| {
            if (!r.key.eql(w.key) or !sameNumber(r.value, w.value)) break false;
        } else true,
        else => read.eql(want),
    };
}
fn hexOf(a: std.mem.Allocator, dashed: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, dashed, '-');
    while (it.next()) |pair| try out.append(a, try std.fmt.parseInt(u8, pair, 16));
    return out.toOwnedSlice(a);
}

test "msgpack-test-suite: every encoding of every value read, and ours the shortest of them" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const suite = try json.parseLeaky(json.Value, a, @embedFile("corpus/msgpack/msgpack-test-suite.json"), .{});
    var cases: usize = 0;
    var encodings: usize = 0;
    for (suite.object) |group| for (group.value.array) |case| {
        var encoded: []const json.Value = &.{};
        var kind: []const u8 = "";
        var spec: json.Value = .null_value;
        for (case.object) |m| {
            if (std.mem.eql(u8, m.key, "msgpack")) {
                encoded = m.value.array;
            } else if (kind.len == 0 or std.mem.eql(u8, m.key, "bignum")) {
                kind = m.key;
                spec = m.value;
            }
        }
        const want: Value, const timestamp: ?msgpack.Timestamp = if (std.mem.eql(u8, kind, "bignum"))
            .{ integerOf(spec.string).?, null }
        else if (std.mem.eql(u8, kind, "binary"))
            .{ .{ .bin = try hexOf(a, spec.string) }, null }
        else if (std.mem.eql(u8, kind, "ext"))
            .{ .{ .ext = .{ .type_id = @intCast(try std.fmt.parseInt(i8, spec.array[0].number, 10)), .data = try hexOf(a, spec.array[1].string) } }, null }
        else if (std.mem.eql(u8, kind, "timestamp"))
            .{ .nil, .{ .seconds = try std.fmt.parseInt(i64, spec.array[0].number, 10), .nanoseconds = try std.fmt.parseInt(u32, spec.array[1].number, 10) } }
        else
            .{ try fromJson(a, spec), null };
        var shortest: usize = std.math.maxInt(usize);
        var ours: []const u8 = &.{};
        if (timestamp) |t| ours = try written(t, .{}) else ours = try written(want, .{});
        defer gpa.free(ours);
        var listed = false;
        for (encoded) |e| {
            const input = try hexOf(a, e.string);
            listed = listed or std.mem.eql(u8, input, ours);
            encodings += 1;
            if (timestamp) |t| {
                var parsed = try msgpack.parse(msgpack.Timestamp, gpa, input, .{});
                defer parsed.deinit();
                try std.testing.expectEqual(t, parsed.value);
                shortest = @min(shortest, input.len);
                continue;
            }
            var parsed = msgpack.parse(Value, gpa, input, .{}) catch |err| {
                std.debug.print("{s} {s}: {t}\n", .{ group.key, e.string, err });
                return err;
            };
            defer parsed.deinit();
            // The shortest of the encodings of the same kind: an integer may
            // also be listed as a float.
            if (parsed.value.eql(want)) shortest = @min(shortest, input.len);
            if (!sameNumber(parsed.value, want)) {
                std.debug.print("{s} {s}: read {any}\n", .{ group.key, e.string, parsed.value });
                return error.TestUnexpectedResult;
            }
        }
        if (!listed or ours.len != shortest) {
            std.debug.print("{s}: wrote {x}\n", .{ group.key, ours });
            return error.TestUnexpectedResult;
        }
        cases += 1;
    };
    // Every case of the suite, none skipped.
    try std.testing.expectEqual(85, cases);
    try std.testing.expectEqual(233, encodings);
}

test "what is not MessagePack is refused" {
    const malformed = [_][]const u8{
        // Nothing; the byte never used, alone and inside a container.
        "",                                   "c1",         "91c1",             "81c1c0",           "81c0c1",
        // Every header cut short.
        "cc",                                 "cd00",       "ce000000",         "cf00000000000000", "d0",
        "d100",                               "d2000000",   "d300000000000000", "ca000000",         "cb00000000000000",
        "d9",                                 "da00",       "db000000",         "c4",               "c500",
        "c6000000",                           "c7",         "c701",             "c80001",           "c900000001",
        "d4",                                 "d401",       "d50100",           "d601000000",       "d70100000000000000",
        "d801000000000000000000000000000000", "dc00",       "dd000000",         "de00",             "df000000",
        // Content shorter than its length.
        "a1",                                 "a261",       "d901",             "c401",             "91",
        "92c0",                               "81c0",       "82c0c0c0",         "c70201ff",
        // A count past the input left, before anything is counted for it.
                "ddffffffff",
        "dfffffffff",                         "dbffffffff", "c6ffffffff",       "c9ffffffff01",
        // A second value after the first.
            "c0c0",
        "9000",
    };
    for (malformed) |hex| {
        var buffer: [32]u8 = undefined;
        const input = try std.fmt.hexToBytes(&buffer, hex);
        if (msgpack.parse(Value, gpa, input, .{})) |p| {
            var parsed = p;
            parsed.deinit();
            std.debug.print("{s} was read\n", .{hex});
            return error.TestUnexpectedResult;
        } else |err| if (err != error.SyntaxError) {
            std.debug.print("{s}: {t}\n", .{ hex, err });
            return err;
        }
    }
    // A str that is not UTF-8, as a value and as a key; the same bytes as bin are bytes.
    try std.testing.expectError(error.InvalidUtf8, msgpack.parse(Value, gpa, &bytesOf("a1ff"), .{}));
    try std.testing.expectError(error.InvalidUtf8, msgpack.parse(Value, gpa, &bytesOf("d902c328"), .{}));
    try std.testing.expectError(error.InvalidUtf8, msgpack.parse(struct { a: u8 }, gpa, &bytesOf("81a1ff01"), .{}));
    try expectRead(&bytesOf("c401ff"), .{ .bin = &.{0xff} });
}

const Shape = union(enum) { circle: f32, square: struct { side: u16 }, empty };
const Record = struct {
    id: u64,
    name: []const u8,
    blob: []const u8,
    delta: i32,
    ratio: f64,
    tags: []const []const u8,
    shape: Shape,
    note: ?[]const u8 = null,
    mode: enum { fast, careful },
    at: msgpack.Timestamp,
    extra: msgpack.Ext,
    pub const strand = .{ .fields = .{ .blob = .{ .as = .bytes } } };
};

test "typed values both ways: str apart from bin, extensions, integers apart from floats and names" {
    const value: Record = .{ .id = 7, .name = "ada", .blob = &.{ 0, 255 }, .delta = -3, .ratio = 0.5, .tags = &.{ "a", "b" }, .shape = .{ .square = .{ .side = 3 } }, .mode = .careful, .at = .{ .seconds = 1514862245, .nanoseconds = 678901234 }, .extra = .{ .type_id = 9, .data = "xyz" } };
    const bytes = try written(value, .{});
    defer gpa.free(bytes);
    var parsed = try msgpack.parse(Record, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ada", parsed.value.name);
    try std.testing.expectEqualSlices(u8, value.blob, parsed.value.blob);
    try std.testing.expectEqual(3, parsed.value.shape.square.side);
    try std.testing.expectEqual(null, parsed.value.note);
    try std.testing.expectEqual(value.at, parsed.value.at);
    try std.testing.expectEqual(9, parsed.value.extra.type_id);
    try std.testing.expectEqualStrings("xyz", parsed.value.extra.data);
    // Strings and extension data are borrowed from the input.
    for ([_][]const u8{ parsed.value.name, parsed.value.blob, parsed.value.extra.data }) |s|
        try std.testing.expect(@intFromPtr(s.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(s.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
    // bin for text, str for bytes, an extension for either.
    try std.testing.expectError(error.UnexpectedType, msgpack.parse([]const u8, gpa, &bytesOf("c40161"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(struct {
        b: []const u8,
        pub const strand = .{ .fields = .{ .b = .{ .as = .bytes } } };
    }, gpa, &bytesOf("81a162a161"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse([]const u8, gpa, &bytesOf("d40161"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(msgpack.Timestamp, gpa, &bytesOf("d6015a4af6a5"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(msgpack.Timestamp, gpa, &bytesOf("c40400000000"), .{}));
    // A timestamp of another length, or nanoseconds past a second.
    try std.testing.expectError(error.UnsupportedValue, msgpack.parse(msgpack.Timestamp, gpa, &bytesOf("d5ff0000"), .{}));
    try std.testing.expectError(error.UnsupportedValue, msgpack.parse(msgpack.Timestamp, gpa, &bytesOf("c70cff3b9aca000000000000000000"), .{}));
    // An integer is no float and no enum's name; a float is no integer.
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(f64, gpa, &bytesOf("01"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(u8, gpa, &bytesOf("ca3f800000"), .{}));
    try std.testing.expectError(error.UnexpectedType, msgpack.parse(enum { a, b }, gpa, &bytesOf("00"), .{}));
    // Integers to their range, both ways.
    try std.testing.expectError(error.NumberOutOfRange, msgpack.parse(i8, gpa, &bytesOf("d1ff7f"), .{}));
    try std.testing.expectError(error.NumberOutOfRange, msgpack.parse(u64, gpa, &bytesOf("ff"), .{}));
    try std.testing.expectError(error.NumberOutOfRange, msgpack.parse(i64, gpa, &bytesOf("cf8000000000000000"), .{}));
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.NumberOutOfRange, msgpack.write(&out.writer, @as(u128, 1 << 64), .{}));
    try std.testing.expectError(error.NumberOutOfRange, msgpack.write(&out.writer, @as(i128, std.math.minInt(i64)) - 1, .{}));
    try std.testing.expectError(error.NumberOutOfRange, msgpack.write(&out.writer, @as(f128, 0.1), .{}));
    try std.testing.expectError(error.UnsupportedValue, msgpack.write(&out.writer, msgpack.Timestamp{ .seconds = 0, .nanoseconds = 1_000_000_000 }, .{}));
    // A union's arm with no payload is its name; a void is nil.
    const unit = try written(Shape.empty, .{});
    defer gpa.free(unit);
    try std.testing.expectEqualSlices(u8, &bytesOf("a5656d707479"), unit);
    const nothing = try written({}, .{});
    defer gpa.free(nothing);
    try std.testing.expectEqualSlices(u8, &bytesOf("c0"), nothing);
    // An f32 is float 32, its NaN's bits included.
    const single = try written(@as(f32, @bitCast(@as(u32, 0x7f800001))), .{});
    defer gpa.free(single);
    try std.testing.expectEqualSlices(u8, &bytesOf("ca7f800001"), single);
}

test "a tuple of scalars is read and written with no allocation" {
    const Tuple = struct { u32, i16, f64, bool, ?u8 };
    const value: Tuple = .{ 70000, -300, 2.5, true, null };
    var buffer: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try msgpack.write(&fixed, value, .{});
    try std.testing.expectEqualSlices(u8, &bytesOf("95ce00011170d1fed4ca40200000c3c0"), fixed.buffered());
    const read = try msgpack.parseLeaky(Tuple, std.testing.failing_allocator, fixed.buffered(), .{});
    try std.testing.expectEqual(value, read);
}

test "a raw value is checked when read and written back as it came" {
    const Envelope = struct { kind: []const u8, body: msgpack.Raw };
    const input = bytesOf("82a46b696e64a161a4626f6479cd0100");
    var parsed = try msgpack.parse(Envelope, gpa, &input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &bytesOf("cd0100"), parsed.value.body.bytes);
    const out = try written(parsed.value, .{});
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &input, out);
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(error.InvalidRaw, msgpack.write(&sink.writer, Envelope{ .kind = "a", .body = .{ .bytes = &bytesOf("cd01") } }, .{}));
}

test "the deterministic profile sorts each map by its encoded keys and refuses a key twice" {
    const entries = [_]msgpack.Entry{
        .{ .key = .{ .str = "b" }, .value = .{ .map = &.{ .{ .key = .{ .unsigned = 2 }, .value = .nil }, .{ .key = .{ .unsigned = 1 }, .value = .nil } } } },
        .{ .key = .{ .negative = -1 }, .value = .{ .boolean = true } },
        .{ .key = .{ .str = "a" }, .value = .nil },
        .{ .key = .{ .unsigned = 200 }, .value = .nil },
    };
    const out = try written(Value{ .map = &entries }, .{ .profile = .deterministic, .allocator = gpa });
    defer gpa.free(out);
    // 0xa1 "a", 0xa1 "b", 0xcc 200, 0xff -1; the inner map 1 before 2.
    try std.testing.expectEqualSlices(u8, &bytesOf("84a161c0a1628201c002c0ccc8c0ffc3"), out);
    const twice: Value = .{ .map = &.{ .{ .key = .{ .unsigned = 1 }, .value = .nil }, .{ .key = .{ .unsigned = 1 }, .value = .nil } } };
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(error.DuplicateField, msgpack.write(&sink.writer, twice, .{ .profile = .deterministic, .allocator = gpa }));
    // An extension as a key is ordered by its whole encoding.
    const ext_keys: Value = .{ .map = &.{ .{ .key = .{ .ext = .{ .type_id = 2, .data = "a" } }, .value = .nil }, .{ .key = .{ .ext = .{ .type_id = 1, .data = "b" } }, .value = .nil } } };
    const ext_out = try written(ext_keys, .{ .profile = .deterministic, .allocator = gpa });
    defer gpa.free(ext_out);
    try std.testing.expectEqualSlices(u8, &bytesOf("82d40162c0d40261c0"), ext_out);
}

test "limits at their edges: a value exactly at a limit is read, one past it refused" {
    const text = bytesOf("a3616263");
    try std.testing.expectError(error.LengthLimit, msgpack.parse(Value, gpa, &text, .{ .limits = .{ .string_bytes = .fromRaw(2) } }));
    var at = try msgpack.parse(Value, gpa, &text, .{ .limits = .{ .string_bytes = .fromRaw(3) } });
    at.deinit();
    const ext = bytesOf("c70301616263");
    try std.testing.expectError(error.LengthLimit, msgpack.parse(Value, gpa, &ext, .{ .limits = .{ .string_bytes = .fromRaw(2) } }));
    var ext_at = try msgpack.parse(Value, gpa, &ext, .{ .limits = .{ .string_bytes = .fromRaw(3) } });
    ext_at.deinit();
    const nested = bytesOf("91919100");
    const Nested = []const []const []const u32;
    try std.testing.expectError(error.DepthLimit, msgpack.parse(Nested, gpa, &nested, .{ .limits = .{ .depth = 2 } }));
    var deep = try msgpack.parse(Nested, gpa, &nested, .{ .limits = .{ .depth = 3 } });
    deep.deinit();
    const four = bytesOf("9401020304");
    try std.testing.expectError(error.ItemLimit, msgpack.parse([]const u32, gpa, &four, .{ .limits = .{ .container_items = 3 } }));
    var items = try msgpack.parse([]const u32, gpa, &four, .{ .limits = .{ .container_items = 4 } });
    items.deinit();
    try std.testing.expectError(error.InputLimit, msgpack.parse([]const u32, gpa, &four, .{ .limits = .{ .input_bytes = .fromRaw(4) } }));
    var input = try msgpack.parse([]const u32, gpa, &four, .{ .limits = .{ .input_bytes = .fromRaw(5) } });
    input.deinit();
    var buffer: [8]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.OutputLimit, msgpack.write(&fixed, "abcd", .{ .limits = .{ .output_bytes = .fromRaw(4) } }));
    fixed = .fixed(&buffer);
    try msgpack.write(&fixed, "abcd", .{ .limits = .{ .output_bytes = .fromRaw(5) } });
    // A map held for sorting is refused once it holds more than the output left.
    const map: Value = .{ .map = &.{.{ .key = .{ .str = "abcdefgh" }, .value = .nil }} };
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    try std.testing.expectError(error.OutputLimit, msgpack.write(&sink.writer, map, .{ .profile = .deterministic, .allocator = gpa, .limits = .{ .output_bytes = .fromRaw(8) } }));
    try msgpack.write(&sink.writer, map, .{ .profile = .deterministic, .allocator = gpa, .limits = .{ .output_bytes = .fromRaw(11) } });
}

fn sweep(a: std.mem.Allocator) !void {
    const input = bytesOf("83a161929101d6ff00000001a162c402010281a163ca3f800000c0");
    var parsed = try msgpack.parseOwned(Value, a, &input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // The writer's own allocation failing is its write failing.
    msgpack.write(&out.writer, parsed.value, .{ .profile = .deterministic, .allocator = a }) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

test "every allocation failure while reading and writing is an error, never a leak" {
    try std.testing.checkAllAllocationFailures(gpa, sweep, .{});
}

/// A generated value: every kind, nested a few levels.
fn item(case: *shakedown.Case, depth: u8) !Value {
    const s = case.source;
    const a = case.gpa;
    const kinds: u8 = if (depth == 0) 9 else 11;
    return switch (gen.intRange(s, u8, 0, kinds)) {
        0 => .{ .unsigned = gen.int(s, u64) },
        1 => .{ .negative = gen.intRange(s, i64, std.math.minInt(i64), -1) },
        2 => .{ .bin = try gen.string(s, a, .{ .kind = .bytes, .max_len = 12 }) },
        3 => .{ .str = try gen.string(s, a, .{ .max_len = 40 }) },
        4 => .{ .boolean = gen.boolean(s) },
        5 => .nil,
        6 => .{ .float = @bitCast(gen.int(s, u64)) },
        7 => .{ .float = gen.oneOf(s, f64, &.{ 0.0, -0.0, 1.5, 0.1, 3.4028234663852886e38, std.math.inf(f64) }) },
        8 => .{ .ext = .{ .type_id = gen.int(s, i8), .data = try gen.string(s, a, .{ .kind = .bytes, .max_len = 20 }) } },
        9 => .{ .unsigned = gen.intRange(s, u64, 0, 300) },
        10 => blk: {
            const items = try a.alloc(Value, gen.intRange(s, usize, 0, 4));
            for (items) |*v| v.* = try item(case, depth - 1);
            break :blk .{ .array = items };
        },
        else => blk: {
            const entries = try a.alloc(msgpack.Entry, gen.intRange(s, usize, 0, 4));
            for (entries) |*e| e.* = .{ .key = try item(case, depth - 1), .value = try item(case, depth - 1) };
            break :blk .{ .map = entries };
        },
    };
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value = try item(case, 3);
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try msgpack.write(&out.writer, value, .{});
    case.note("msgpack: {x}", .{out.written()});
    var parsed = try msgpack.parse(Value, case.gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(value));
    // Truncated anywhere, it is refused, never read as something else.
    for (0..out.written().len) |end| {
        if (msgpack.parse(Value, case.gpa, out.written()[0..end], .{})) |p| {
            var cut = p;
            cut.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // In the deterministic profile, written again it is the same bytes.
    var det: std.Io.Writer.Allocating = .init(case.gpa);
    if (msgpack.write(&det.writer, value, .{ .profile = .deterministic, .allocator = case.gpa })) {
        var again = try msgpack.parse(Value, case.gpa, det.written(), .{});
        defer again.deinit();
        var twice: std.Io.Writer.Allocating = .init(case.gpa);
        try msgpack.write(&twice.writer, again.value, .{ .profile = .deterministic, .allocator = case.gpa });
        try std.testing.expectEqualSlices(u8, det.written(), twice.written());
    } else |err| try std.testing.expectEqual(error.DuplicateField, err);
}

test "generated values read back as they were, truncated nowhere, deterministic twice the same" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 600 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const input = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 64 });
    case.note("input: {x}", .{input});
    const options: msgpack.ParseOptions = .{ .limits = .{ .work = 1 << 16, .depth = 32 } };
    var parsed = msgpack.parse(Value, case.gpa, input, options) catch return;
    defer parsed.deinit();
    // What was read, written and read again, is the same value, in no more
    // bytes than it came in: every part is written in its smallest format.
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try msgpack.write(&out.writer, parsed.value, .{});
    try std.testing.expect(out.written().len <= input.len);
    var again = try msgpack.parse(Value, case.gpa, out.written(), .{});
    defer again.deinit();
    try std.testing.expect(again.value.eql(parsed.value));
    // An extension of type -1 is a timestamp or refused as one, and a
    // timestamp read is written as the same time.
    if (parsed.value == .ext and parsed.value.ext.type_id == msgpack.Timestamp.ext_type) {
        const t = msgpack.Timestamp.decode(parsed.value.ext.data) orelse return;
        var buffer: [12]u8 = undefined;
        try std.testing.expectEqual(t, msgpack.Timestamp.decode(t.encode(&buffer).?).?);
    }
}

test "fuzz: any bytes are a value or refused, and a value read is written as itself in no more bytes" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
