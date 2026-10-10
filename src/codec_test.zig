//! The decoder and the encoder held to `std.json`, value for value and byte
//! for byte, over values of every shape a line carries — and where
//! `std.json` has no answer because it panics, held to having one.
const codec_module = @import("json/api.zig").codec_module;
const parse_module = @import("json/api.zig").parse_module;
const fixtures_module = @import("testing/fixtures.zig");

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const strand = @import("strand.zig");

fn Delegating(comptime T: type) type {
    return struct {
        pub const Self = @This();
        value: T,
        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Self {
            return .{ .value = try strand.innerParse(T, a, source, options) };
        }
    };
}

test "custom hooks delegate to the public checked token decoder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fields = struct { bytes: @Vector(2, u8), number: u128, text: []const u8 };
    const Hook = Delegating(Fields);
    const bytes = "{\"bytes\":\"ab\",\"number\":1.8e38,\"text\":\"borrowed\"}";
    for (0..4) |path| {
        var where: strand.Diagnostics = .{};
        var input: std.Io.Reader = .fixed(bytes);
        var tokens = std.json.Reader.init(a, &input);
        defer tokens.deinit();
        const result = switch (path) {
            0 => try strand.parseLine(Hook, a, bytes, .{}),
            1 => try strand.parseLine(Hook, a, bytes, .{ .copy_strings = true, .diagnostics = &where }),
            2 => try std.json.parseFromSliceLeaky(Hook, a, bytes, .{}),
            3 => try std.json.parseFromTokenSourceLeaky(Hook, a, &tokens, .{}),
            else => unreachable,
        };
        try testing.expectEqual(@as(u8, 'a'), result.value.bytes[0]);
        try testing.expectEqual(@as(u8, 'b'), result.value.bytes[1]);
        try testing.expect(result.value.number > std.math.maxInt(i128));
        try testing.expectEqualStrings("borrowed", result.value.text);
        if (path == 0) try testing.expect(result.value.text.ptr == bytes.ptr + std.mem.find(u8, bytes, "borrowed").?);
        if (path == 1) try testing.expect(result.value.text.ptr != bytes.ptr + std.mem.find(u8, bytes, "borrowed").?);
    }
    const overflow = "{\"bytes\":\"ab\",\"number\":3.5e38,\"text\":\"x\"}";
    try testing.expectError(error.Overflow, strand.parseLine(Hook, a, overflow, .{}));
    try testing.expectError(error.Overflow, std.json.parseFromSliceLeaky(Hook, a, overflow, .{}));
    try testing.expectError(error.UnexpectedToken, strand.parseLine(Delegating(@Vector(2, bool)), a, "\"ab\"", .{}));
    try testing.expectError(error.LengthMismatch, strand.parseLine(Delegating(@Vector(2, u8)), a, "\"abc\"", .{}));

    // An inner decoder reads one value and leaves the enclosing tokens to
    // the hook. It also keeps the hook's duplicate and unknown-field policy.
    const HookPair = struct { Hook, u8 };
    const pair = try strand.parseLine(HookPair, a, "[" ++ bytes ++ ",7]", .{});
    try testing.expectEqual(@as(u8, 7), pair[1]);
    const repeated = "{\"number\":1,\"number\":2,\"extra\":0,\"bytes\":[97,98],\"text\":\"x\"}";
    try testing.expectEqual(@as(u128, 1), (try strand.parseLine(Hook, a, repeated, .{ .duplicate_fields = .use_first })).value.number);
    try testing.expectEqual(@as(u128, 2), (try strand.parseLine(Hook, a, repeated, .{ .duplicate_fields = .use_last })).value.number);
    try testing.expectError(error.UnknownField, strand.parseLine(Hook, a, repeated, .{ .duplicate_fields = .use_last, .ignore_unknown_fields = false }));
}

const Hue = enum { red, @"gr\"een", blue };

/// Every shape the decoder reads itself, so that a line of it takes the
/// direct path, and a type that contains itself, which takes the token
/// path.
pub const Plain = union(enum) {
    empty,
    flag: bool,
    small: i8,
    wide: u64,
    signed: i64,
    huge: u128,
    negative: i128,
    text: []const u8,
    maybe: ?[]const u8,
    hue: Hue,
    list: []const u32,
    fixed: [3]u16,
    nested: struct { a: ?u8, b: []const []const u8, d: Hue, e: ?*const Plain },
    many: []const ?Hue,
    twice: ??bool,
    @"odd \"tag\"": u8,
};

/// The same shapes with nothing recursive in them: the direct decoder's.
pub const Flat = union(enum) {
    empty,
    flag: bool,
    small: i8,
    wide: u64,
    signed: i64,
    huge: u128,
    negative: i128,
    text: []const u8,
    maybe: ?[]const u8,
    hue: Hue,
    list: []const u32,
    fixed: [3]u16,
    nested: struct { a: ?u8, b: []const []const u8, d: Hue },
    many: []const ?Hue,
    twice: ??bool,
    @"odd \"tag\"": u8,
};

/// A record and its most common shape: a number and a string.
pub const Pair = struct { value: u64, padding: []const u8 };

/// A string built to be awkward: runs longer than a vector of clean bytes
/// with the things JSON escapes at every position, and UTF-8 both whole and
/// broken.
fn awkward(random: std.Random, buffer: []u8) []const u8 {
    const pieces = [_][]const u8{
        "a", "z", " ", "\"", "\\", "\n", "\t", "\x00", "\x1f", "\x7f", "/",
        "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", // whole UTF-8
        "\xff", "\x80", "\xc3", "\xed\xa0\x80", // not UTF-8
        "abcdefghijklmnopqrstuvwxyz0123456789", // longer than a vector
    };
    var len: usize = 0;
    const parts = random.uintLessThan(usize, 12);
    for (0..parts) |_| {
        // Mostly the clean bytes and the escapes, sometimes a byte that is
        // not UTF-8.
        const pick = if (random.uintLessThan(u8, 8) == 0)
            pieces[random.uintLessThan(usize, pieces.len)]
        else
            pieces[random.uintLessThan(usize, 14)];
        const repeat = 1 + random.uintLessThan(usize, 3);
        for (0..repeat) |_| {
            if (len + pick.len > buffer.len) return buffer[0..len];
            @memcpy(buffer[len..][0..pick.len], pick);
            len += pick.len;
        }
    }
    return buffer[0..len];
}

/// A string with nothing in it JSON escapes.
fn clean(random: std.Random, buffer: []u8) []const u8 {
    const pieces = [_][]const u8{ "a", "Z", " ", "0", "/", "~", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "a longer run of clean bytes" };
    var len: usize = 0;
    for (0..random.uintLessThan(usize, 12)) |_| {
        const pick = pieces[random.uintLessThan(usize, pieces.len)];
        if (len + pick.len > buffer.len) break;
        @memcpy(buffer[len..][0..pick.len], pick);
        len += pick.len;
    }
    return buffer[0..len];
}

fn randomPlain(a: std.mem.Allocator, random: std.Random, depth: u8, clean_strings: bool) !Plain {
    const text = if (clean_strings)
        try a.dupe(u8, clean(random, try a.alloc(u8, 200)))
    else
        try a.dupe(u8, awkward(random, try a.alloc(u8, 96)));
    return switch (random.uintLessThan(u8, 18)) {
        16 => .{ .huge = random.int(u128) >> random.int(u7) },
        17 => .{ .negative = random.int(i128) >> random.int(u7) },
        0 => .empty,
        1 => .{ .flag = random.boolean() },
        2 => .{ .small = random.int(i8) },
        3 => .{ .wide = random.int(u64) >> random.int(u6) },
        4 => .{ .signed = random.int(i64) >> random.int(u6) },
        5 => .{ .wide = std.math.maxInt(u64) },
        6 => .{ .signed = std.math.minInt(i64) },
        7 => .{ .text = text },
        8 => .{ .maybe = if (random.boolean()) text else null },
        9 => .{ .hue = random.enumValue(Hue) },
        10 => .{ .list = try a.dupe(u32, &.{ random.int(u32), 0, std.math.maxInt(u32) }) },
        11 => .{ .fixed = .{ random.int(u16), 0, 7 } },
        12 => .{ .nested = .{
            .a = if (random.boolean()) random.int(u8) else null,
            .b = try a.dupe([]const u8, &.{ text, "second" }),
            .d = random.enumValue(Hue),
            .e = if (depth < 3 and random.boolean()) blk: {
                const inner = try a.create(Plain);
                inner.* = try randomPlain(a, random, depth + 1, clean_strings);
                break :blk inner;
            } else null,
        } },
        13 => .{ .many = try a.dupe(?Hue, &.{ null, random.enumValue(Hue) }) },
        14 => .{ .twice = switch (random.uintLessThan(u8, 3)) {
            0 => null,
            1 => @as(?bool, null),
            else => random.boolean(),
        } },
        else => .{ .@"odd \"tag\"" = random.int(u8) },
    };
}

/// Whether `bytes` carry a number `std.json` (Zig 0.16.0) can panic on
/// reading into a 128-bit integer: written with a fraction or an exponent,
/// whole, and from 2^127 to 2^128, which its range check lets through and
/// its cast through `i128` cannot hold. Worked out from the tokens alone,
/// not from the type. `null` when a string carries such a number, which
/// some types read as one and others as text.
fn stdPanicsOn(a: std.mem.Allocator, bytes: []const u8) ?bool {
    var scanner: std.json.Scanner = .initCompleteInput(a, bytes);
    defer scanner.deinit();
    const low = std.math.ldexp(@as(f128, 1), 127);
    const high = std.math.ldexp(@as(f128, 1), 128);
    var found = false;
    while (true) {
        const token = scanner.nextAlloc(a, .alloc_if_needed) catch return found;
        const text, const quoted = switch (token) {
            .end_of_document => return found,
            .number, .allocated_number => |text| .{ text, false },
            .string, .allocated_string => |text| .{ text, true },
            else => continue,
        };
        if (std.json.isNumberFormattedLikeAnInteger(text)) continue;
        const float = std.fmt.parseFloat(f128, text) catch continue;
        if (@round(float) != float or float < low or float > high) continue;
        if (quoted) return null;
        found = true;
    }
}

/// `parseLine` — by the direct decoder and by the token path, which a
/// caller asking for diagnostics takes — and `std.json` given the same
/// bytes: the same value, or the same error. Where `std.json` would panic,
/// the two paths here agree with each other. Everything is allocated on
/// `a`, an arena the caller drops.
pub fn expectSameParse(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !void {
    const options: strand.ParseOptions = .{ .ignore_unknown_fields = false };
    errdefer std.debug.print("{s}: {s}\n", .{ @typeName(T), bytes });
    const ours = strand.parseLine(T, a, bytes, options);
    var where: strand.Diagnostics = .{};
    var diagnosed = options;
    diagnosed.diagnostics = &where;
    const token = strand.parseLine(T, a, bytes, diagnosed);
    if (ours) |value| {
        try testing.expectEqualDeep(value, try token);
    } else |err| try testing.expectError(err, token);

    // A line has no terminator in it: the one deliberate difference from
    // `std.json`, which reads a value followed by whitespace.
    if (bytes.len != 0 and bytes[bytes.len - 1] == '\n') return testing.expectError(error.SyntaxError, ours);
    const panics = stdPanicsOn(a, bytes) orelse return;
    if (panics) return;
    const theirs = std.json.parseFromSliceLeaky(T, a, bytes, .{});
    if (theirs) |value| {
        try testing.expectEqualDeep(value, try ours);
    } else |err| {
        try testing.expectError(err, ours);
    }
}

/// Bytes in the written shape, changed in one of the ways a line in some
/// other shape differs from it: whitespace, a byte replaced, dropped or
/// doubled, a string escaped, a number written as a fraction or with an
/// exponent, a member written that the type does not have.
fn mutate(a: std.mem.Allocator, random: std.Random, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return bytes;
    const at = random.uintLessThan(usize, bytes.len);
    const replacements = "{}[]\":,\\0-.e1anu\x00\xff";
    return switch (random.uintLessThan(u8, 9)) {
        8 => exponent(a, bytes),
        0 => try std.mem.concat(a, u8, &.{ bytes[0..at], " ", bytes[at..] }),
        1 => try std.mem.concat(a, u8, &.{ bytes[0..at], "\n\t", bytes[at..] }),
        2 => try std.mem.concat(a, u8, &.{ bytes[0..at], bytes[at + 1 ..] }),
        3 => try std.mem.concat(a, u8, &.{ bytes[0 .. at + 1], bytes[at..] }),
        4 => blk: {
            const copy = try a.dupe(u8, bytes);
            copy[at] = replacements[random.uintLessThan(usize, replacements.len)];
            break :blk copy;
        },
        5 => try std.mem.replaceOwned(u8, a, bytes, "a", "\\u0061"),
        6 => try std.mem.replaceOwned(u8, a, bytes, "0", "0.0"),
        else => try std.mem.replaceOwned(u8, a, bytes, ",", ",\"wide\":1,"),
    };
}

/// The first run of digits in `bytes` written again with an exponent, as the
/// same number: `123` as `1.23e2`. What a person or another program writing
/// a large integer may well write, and what `std.json` reads through a float.
fn exponent(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const from = std.mem.findAny(u8, bytes, "0123456789") orelse return bytes;
    var to = from;
    while (to < bytes.len and std.ascii.isDigit(bytes[to])) to += 1;
    const digits = bytes[from..to];
    const number = if (digits.len == 1)
        try a.print("{s}e0", .{digits})
    else
        try a.print("{c}.{s}e{d}", .{ digits[0], digits[1..], digits.len - 1 });
    return std.mem.concat(a, u8, &.{ bytes[0..from], number, bytes[to..] });
}

test "a line is read as std.json reads it, in the written shape and out of it" {
    var prng: std.Random.DefaultPrng = .init(0x9a55_ed17);
    const random = prng.random();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (0..20_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const value = try randomPlain(a, random, 0, random.boolean());
        const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
        try expectSameParse(Plain, a, bytes);
        try expectSameParse(Flat, a, bytes);
        for (0..4) |_| {
            const changed = try mutate(a, random, bytes);
            try expectSameParse(Plain, a, changed);
            try expectSameParse(Flat, a, changed);
        }
        try expectSameParse(Pair, a, bytes);

        const pair: Pair = .{ .value = random.int(u64), .padding = awkward(random, try a.alloc(u8, 200)) };
        const written = try std.json.Stringify.valueAlloc(a, pair, .{});
        try expectSameParse(Pair, a, written);
        try expectSameParse(Pair, a, try mutate(a, random, written));
    }
    // The integers at their edges.
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    inline for (.{ u0, u1, i1, u8, i8, u64, i64, u128, i128 }) |Int| {
        for ([_]Int{ std.math.minInt(Int), std.math.maxInt(Int) }) |edge| {
            var buffer: [48]u8 = undefined;
            try expectSameParse(Int, a, try std.mem.print(&buffer, "{d}", .{edge}));
        }
    }
    for ([_][]const u8{
        "0",  "-0", "00",                                      "-",     "1e2", "1.0",
        "-1", "01", "18446744073709551616",                    "\"1\"", " 1",  "1 ",
        "1x", "",   "340282366920938463463374607431768211456", "-00",
    }) |text| {
        try expectSameParse(u64, a, text);
        try expectSameParse(i128, a, text);
        try expectSameParse(u128, a, text);
        try expectSameParse(u1, a, text);
    }
}

test "a line that ends inside a character is cut short, as std.json says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The start of a character the input ends before finishing is input
    // that ran out; a byte that cannot start or continue one is not UTF-8.
    // Both in a value and in a member's name, and on the token path a
    // `std.json.Value` is read on.
    for ([_][]const u8{
        "{\"text\":\"caf\xc3",
        "{\"text\":\"\xe2\x82",
        "{\"text\":\"\xf0\x9f\x98",
        "{\"text\":\"\xf4\x8f",
        "{\"text\":\"\xed\xa0",
        "{\"text\":\"\xe0\x80",
        "{\"text\":\"\xf0\x80",
        "{\"text\":\"\xf4\x90",
        "{\"text\":\"\xc0",
        "{\"text\":\"\xff",
        "{\"text\":\"\xc3\xc3",
        "{\"te\xc3",
        "{\"te\xe2\x82",
        "{\"text\":\"x\\u0041\xc3",
        "\"\xc3",
    }) |line| {
        try expectSameParse(Plain, a, line);
        try expectSameParse(Flat, a, line);
        try expectSameParse(Pair, a, line);
        try expectSameParse(std.json.Value, a, line);
        try expectSameParse([]const u8, a, line);
    }
}

test "a bracket that closes the other kind of container is a syntax error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Read through the token path a `Raw` member takes, where an array closed
    // by `}` came back as the end of an object and a value was skipped that
    // was not there.
    const Carrying = struct { data: strand.Raw = .null, more: []const strand.Raw = &.{} };
    for ([_][]const u8{
        "{\"more\":[1}",
        "{\"more\":[1,2}}",
        "{\"more\":[{\"a\":1]]}",
        "{\"data\":1]",
        "{\"data\":[1}}",
        "[1}",
        "{\"a\":1]",
    }) |line| {
        try expectSameParse(Carrying, a, line);
        try expectSameParse(std.json.Value, a, line);
        try expectSameParse(strand.Raw, a, line);
    }
}

test "a whole number std.json cannot cast is read as the number it is, or refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each of these panicked in `std.json`: a float at or past 2^127 goes
    // through an `i128` cast there, and so does 2^127 itself into an
    // `i128`, whose largest value rounds up to it. Here the ones in range
    // are the number they are, and the rest are `Overflow`, on both paths.
    const in_range = 180_000_000_000_000_000_000_000_000_000_000_000_000;
    const S = struct { a: u8, b: ?[]const u128 };
    const U = union(enum) { x: [2]i128 };
    var where: strand.Diagnostics = .{};
    for ([_]strand.ParseOptions{ .{}, .{ .diagnostics = &where } }) |options| {
        try testing.expectEqual(@as(u128, in_range), try strand.parseLine(u128, a, "1.8e38", options));
        try testing.expectEqual(@as(u128, 200_000_000_000_000_000_000_000_000_000_000_000_000), try strand.parseLine(u128, a, "\"2e38\"", options));
        try testing.expectError(error.Overflow, strand.parseLine(u128, a, "3.402823669209384634633746074317682114555e38", options));
        try testing.expectError(error.Overflow, strand.parseLine(i128, a, "1.7014118346046923173168730371588410572e38", options));
        try testing.expectError(error.Overflow, strand.parseLine(u120, a, "1.329227995784915872903807060280344576e36", options));
        const s = try strand.parseLine(S, a, "{ \"a\":1, \"b\":[1, 2.0e38] }", options);
        try testing.expectEqual(@as(u128, 200_000_000_000_000_000_000_000_000_000_000_000_000), s.b.?[1]);
        try testing.expectError(error.Overflow, strand.parseLine(U, a, "{\"x\":[0,1.7014118346046923173168730371588410572e38]}", options));
    }

    // Around them, std.json's own answers.
    const neighbours = [_][]const u8{
        "1.7e38",                                     "-1.7014118346046923173168730371588410572e38",
        "1.7014118346046923173168730371588410571e38", "3.5e38",
        "-1.8e38",                                    "1.5e3",
        "2.5",                                        "1e999",
    };
    for (neighbours) |text| {
        try expectSameParse(u128, a, text);
        try expectSameParse(i128, a, text);
        try expectSameParse(u64, a, text);
    }
    // std.json refuses the unknown member before it reaches the number.
    try testing.expectError(error.UnknownField, strand.parseLine(struct { a: u128 }, a, "{\"b\":1,\"a\":1.8e38}", .{ .ignore_unknown_fields = false }));
}

//=========================================================================
// The bytes a value is written as.
//=========================================================================

/// A type with its own `jsonStringify`, which is handed to `std.json`.
pub const Custom = struct {
    n: u8,
    pub fn jsonStringify(self: Custom, jw: anytype) !void {
        try jw.write(.{ .custom = self.n });
    }
};

pub const Inner = struct { a: ?u8, b: []const []const u8, c: void, d: Hue };

/// Every shape the encoder writes itself, and a few it hands on.
const Shape = union(enum) {
    empty,
    flag: bool,
    small: i8,
    wide: u64,
    signed: i64,
    huge: u128,
    negative: i128,
    vast: u256,
    text: []const u8,
    maybe: ?[]const u8,
    hue: Hue,
    list: []const u32,
    fixed: [3]u16,
    nested: Inner,
    pointer: *const Inner,
    many: []const ?Hue,
    real: f64,
    tuple: struct { u8, bool },
    custom: Custom,
    value: std.json.Value,
    @"odd \"tag\"": u8,
    @"caf\xc3\xa9": u8,
};

/// `v` written by a `Writer` and by `writeValue` under each combination of
/// the options that change bytes, into a destination with room for the
/// record and into one with none, and by `std.json`: the same bytes every
/// time. Written on `a`, an arena the caller drops.
pub fn expectSameAsStdJson(a: std.mem.Allocator, v: anytype) !void {
    inline for (.{ false, true }) |emit_null| {
        inline for (.{ false, true }) |escape_unicode| {
            var theirs: std.Io.Writer.Allocating = .init(a);
            try std.json.Stringify.value(v, .{
                .emit_null_optional_fields = emit_null,
                .escape_unicode = escape_unicode,
            }, &theirs.writer);
            try theirs.writer.writeByte('\n');
            inline for (.{ 0, 4096 }) |room| {
                var ours: std.Io.Writer.Allocating = try .initCapacity(a, room);
                var writer: strand.Writer(@TypeOf(v)) = .init(&ours.writer, .{
                    .emit_null_optional_fields = emit_null,
                    .escape_unicode = escape_unicode,
                });
                try writer.write(v);
                try testing.expectEqualStrings(theirs.written(), ours.written());

                // The value alone, framed by nobody.
                var alone: std.Io.Writer.Allocating = try .initCapacity(a, room);
                try strand.writeValue(&alone.writer, v, .{
                    .emit_null_optional_fields = emit_null,
                    .escape_unicode = escape_unicode,
                });
                try testing.expectEqualStrings(theirs.written()[0 .. theirs.written().len - 1], alone.written());
            }
        }
    }
}

test "a value is written as std.json writes it, whatever its shape" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_c4a0);
    const random = prng.random();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (0..5_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const text = try a.dupe(u8, awkward(random, try a.alloc(u8, 96)));
        const inner: Inner = .{
            .a = if (random.boolean()) random.int(u8) else null,
            .b = &.{ text, awkward(random, try a.alloc(u8, 48)) },
            .c = {},
            .d = random.enumValue(Hue),
        };
        const boxed = try a.create(Inner);
        boxed.* = inner;
        const shapes = [_]Shape{
            .empty,
            .{ .flag = random.boolean() },
            .{ .small = random.int(i8) },
            .{ .wide = random.int(u64) >> random.int(u6) },
            .{ .signed = random.int(i64) >> random.int(u6) },
            .{ .huge = random.int(u128) >> random.int(u7) },
            .{ .negative = random.int(i128) >> random.int(u7) },
            .{ .vast = random.int(u256) >> random.int(u8) },
            .{ .text = text },
            .{ .maybe = if (random.boolean()) text else null },
            .{ .hue = random.enumValue(Hue) },
            .{ .list = &.{ random.int(u32), 0, std.math.maxInt(u32) } },
            .{ .fixed = .{ random.int(u16), 0, 7 } },
            .{ .nested = inner },
            .{ .pointer = boxed },
            .{ .many = &.{ null, random.enumValue(Hue) } },
            .{ .real = @bitCast(random.int(u64)) },
            .{ .tuple = .{ random.int(u8), random.boolean() } },
            .{ .custom = .{ .n = random.int(u8) } },
            .{ .value = .{ .string = text } },
            .{ .@"odd \"tag\"" = random.int(u8) },
            .{ .@"caf\xc3\xa9" = random.int(u8) },
        };
        for (shapes) |shape| try expectSameAsStdJson(a, shape);
        try expectSameAsStdJson(a, text);
        try expectSameAsStdJson(a, Pair{ .value = random.int(u64), .padding = text });
    }
    // The edges of the integers, which a random draw rarely lands on.
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    inline for (.{ u0, u1, i1, u8, i8, u63, u64, i64, u65, i65, u127, u128, i128, u129, i256 }) |Int| {
        try expectSameAsStdJson(a, @as(Int, std.math.minInt(Int)));
        try expectSameAsStdJson(a, @as(Int, std.math.maxInt(Int)));
    }
    for ([_]u128{ 9_999_999_999_999_999_999, 10_000_000_000_000_000_000, std.math.maxInt(u64), std.math.maxInt(u64) + 1, 100_000_000_000_000_000_000_000_000_000_000_000_000 }) |edge| {
        try expectSameAsStdJson(a, edge);
    }
    try expectSameAsStdJson(a, @as([]const u8, ""));
    try expectSameAsStdJson(a, @as([]const u32, &.{}));
    try expectSameAsStdJson(a, struct {}{});
    try expectSameAsStdJson(a, struct { a: void }{ .a = {} });
}

test "vectors decode their elements without assuming array bit layout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        .{ @Vector(3, bool), "[true,false,true]" },
        .{ @Vector(3, u3), "[1,2,7]" },
        .{ @Vector(3, i3), "[-4,0,3]" },
        .{ @Vector(3, *const u32), "[1,2,7]" },
    }) |case| {
        const case_type = case[0];
        const expected = try std.json.parseFromSliceLeaky(case_type, a, case[1], .{});
        const direct = try strand.parseLine(case_type, a, case[1], .{});
        var where: strand.Diagnostics = .{};
        const diagnosed = try strand.parseLine(case_type, a, case[1], .{ .diagnostics = &where });
        inline for (0..3) |i| {
            try testing.expectEqualDeep(expected[i], direct[i]);
            try testing.expectEqualDeep(expected[i], diagnosed[i]);
        }
    }
}

fn expectVectorPaths(expected: anytype, bytes: []const u8) !void {
    const T = @TypeOf(expected);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (comptime codec_module.decode.supports(T)) {
        var direct: T = undefined;
        try codec_module.decode.parseInto(T, a, bytes, .{ .allocate = .alloc_if_needed, .max_value_len = bytes.len }, &direct);
        try testing.expectEqualDeep(expected, direct);
    }
    for ([_]bool{ false, true }) |copy| {
        try testing.expectEqualDeep(expected, try strand.parseLine(T, a, bytes, .{ .copy_strings = copy }));
        var where: strand.Diagnostics = .{};
        try testing.expectEqualDeep(expected, try strand.parseLine(T, a, bytes, .{ .copy_strings = copy, .diagnostics = &where }));
    }
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    try testing.expectEqualDeep(expected, try parse_module.inner(T, a, &scanner, .{ .allocate = .alloc_if_needed, .max_value_len = bytes.len }));
    var input: std.Io.Reader = .fixed(bytes);
    var tokens = std.json.Reader.init(a, &input);
    defer tokens.deinit();
    try testing.expectEqualDeep(expected, try parse_module.inner(T, a, &tokens, .{ .allocate = .alloc_always, .max_value_len = bytes.len }));
    const dynamic = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try testing.expectEqualDeep(expected, try strand.payloadOf(T, a, dynamic));

    const Payload = struct {
        pub const Self = @This();
        item: T,
        pub const jsonl_version: u32 = 2;
        pub fn jsonlMigrate(allocator: std.mem.Allocator, from: u32, data: std.json.Value) std.json.ParseFromValueError!Self {
            if (from != 1) return error.UnknownField;
            return strand.payloadOf(Self, allocator, data);
        }
    };
    const Envelope = strand.Versioned(Payload);
    // Streaming payload, stashed payload, migration, and duplicate policy's
    // stashed payload all reach the same value through different decoders.
    for ([_][]const u8{
        try a.print("{{\"v\":2,\"data\":{{\"item\":{s}}}}}", .{bytes}),
        try a.print("{{\"data\":{{\"item\":{s}}},\"v\":2}}", .{bytes}),
        try a.print("{{\"v\":1,\"data\":{{\"item\":{s}}}}}", .{bytes}),
    }) |envelope| {
        for ([_]strand.DuplicateFields{ .@"error", .use_last }) |duplicates| {
            try testing.expectEqualDeep(expected, (try strand.parseLine(Envelope, a, envelope, .{ .duplicate_fields = duplicates })).value.item);
            var where: strand.Diagnostics = .{};
            try testing.expectEqualDeep(expected, (try strand.parseLine(Envelope, a, envelope, .{ .duplicate_fields = duplicates, .diagnostics = &where })).value.item);
        }
    }

    const framed = try std.mem.concat(a, u8, &.{ bytes, "\n" });
    var stream: std.Io.Reader = .fixed(framed);
    var reader = strand.Reader(T).init(testing.allocator, &stream, .{});
    defer reader.deinit();
    try testing.expectEqualDeep(expected, (try reader.next()).?.value);
    var fixture = try fixtures_module.Fixture.init(framed, 1);
    defer fixture.deinit();
    var tail = try strand.Tail(T).init(testing.allocator, &fixture.reader, .{ .block_bytes = 1 });
    defer tail.deinit();
    try testing.expectEqualDeep(expected, (try tail.prev()).?.value);
    var batch_tail = try strand.Tail(T).init(testing.allocator, &fixture.reader, .{ .block_bytes = 1 });
    defer batch_tail.deinit();
    const batch = try batch_tail.last(testing.allocator, 1);
    defer {
        for (batch) |item| strand.freeOwned(testing.allocator, item);
        testing.allocator.free(batch);
    }
    try testing.expectEqualDeep(expected, batch[0]);
    try fixture.reader.seekTo(0);
    var follower = strand.Follower(T).init(testing.allocator, &fixture.reader, .{});
    defer follower.deinit(testing.io);
    try testing.expectEqualDeep(expected, (try follower.next(testing.io)).value);
}

fn expectVectorRoundTrip(expected: anytype) !void {
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try strand.writeLine(&encoded.writer, expected);
    const bytes = encoded.written()[0 .. encoded.written().len - 1];
    const std_bytes = try std.json.Stringify.valueAlloc(testing.allocator, expected, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(std_bytes);
    try testing.expectEqualStrings(std_bytes, bytes);
    try expectVectorPaths(expected, bytes);
    // Pretty output takes std.json's encoder instead of the direct encoder.
    encoded.clearRetainingCapacity();
    var writer = strand.Writer(@TypeOf(expected)).init(&encoded.writer, .{ .format = .pretty });
    try writer.write(expected);
    const pretty = encoded.written()[0 .. encoded.written().len - 1];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualDeep(expected, try strand.parseLine(@TypeOf(expected), arena.allocator(), pretty, .{}));
    var input: std.Io.Reader = .fixed(encoded.written());
    var reader = strand.Reader(@TypeOf(expected)).init(testing.allocator, &input, .{ .format = .pretty });
    defer reader.deinit();
    try testing.expectEqualDeep(expected, (try reader.next()).?.value);
}

test "vector round trips preserve std.json bytes on every parse path" {
    const number: u32 = 42;
    inline for (.{
        @as(@Vector(1, u8), .{0}),
        @as(@Vector(3, u8), .{ 'a', 'b', 'c' }),
        @as(@Vector(4, u8), .{ 0xc3, 0xa9, '\n', '"' }),
        @as(@Vector(4, u8), .{ 0xf0, 0x9f, 0x98, 0x80 }),
        @as(@Vector(3, u8), .{ 0xff, 0x80, 0xc3 }),
        @as(@Vector(3, bool), .{ true, false, true }),
        @as(@Vector(3, u0), .{ 0, 0, 0 }),
        @as(@Vector(3, i1), .{ -1, 0, -1 }),
        @as(@Vector(3, u3), .{ 0, 2, 7 }),
        @as(@Vector(3, i3), .{ -4, 0, 3 }),
        @as(@Vector(3, u64), .{ 0, 1 << 63, std.math.maxInt(u64) }),
        @as(@Vector(3, i64), .{ std.math.minInt(i64), 0, std.math.maxInt(i64) }),
        @as(@Vector(3, u128), .{ 0, 1 << 127, std.math.maxInt(u128) }),
        @as(@Vector(3, i128), .{ std.math.minInt(i128), 0, std.math.maxInt(i128) }),
        @as(@Vector(3, f16), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, f64), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, f32), .{ -1.25, 0, 3.5 }),
        @as(@Vector(3, *const u32), .{ &number, &number, &number }),
    }) |vector| {
        try expectVectorRoundTrip(vector);
        const V = @TypeOf(vector);
        const Containers = struct {
            optional: ?V,
            pointer: *const V,
            array: [2]V,
            slice: []const V,
            tuple: struct { V, bool },
            arm: union(enum) { vector: V, empty },
        };
        // Built from a runtime copy: Zig 0.17.0 miscompiles a comptime-known
        // struct whose `?@Vector(n, u64)` member (32 bytes or more) comes
        // before a pointer, and the pointer reads back as part of the
        // vector. Six lines reproduce it without strand.
        var runtime_vector = vector;
        _ = &runtime_vector;
        try expectVectorRoundTrip(Containers{
            .optional = runtime_vector,
            .pointer = &vector,
            .array = .{ vector, vector },
            .slice = &.{ vector, vector },
            .tuple = .{ vector, true },
            .arm = .{ .vector = vector },
        });
    }
}

test "byte vector strings and arrays decode to the same bytes on every parse path" {
    try expectVectorPaths(@as(@Vector(3, u8), .{ 'a', 'b', 'c' }), "\"abc\"");
    try expectVectorPaths(@as(@Vector(3, u8), .{ 'a', 'b', 'c' }), "[97,98,99]");
    try expectVectorPaths(@as(@Vector(3, u8), .{ 0xc3, 0xa9, '\n' }), "\"\\u00e9\\n\"");
    try expectVectorPaths(@as(@Vector(3, u8), .{ 0xc3, 0xa9, '\n' }), "[195,169,10]");
}

test "zero lane vector round trips on every parse path" {
    try expectVectorRoundTrip(@as(@Vector(0, u8), .{}));
    try expectVectorRoundTrip(@as(@Vector(0, bool), .{}));
}

test "byte vector lane counts round trip across scanner boundaries" {
    inline for (.{ 0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33 }) |n| {
        try expectVectorRoundTrip(@as(@Vector(n, u8), @splat('a')));
        if (n != 0) try expectVectorRoundTrip(@as(@Vector(n, u8), @splat(0xff)));
    }
}

test "vector strings require byte elements and the exact byte count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        .{ @Vector(3, u8), "\"ab\"", error.LengthMismatch },
        .{ @Vector(3, u8), "\"abcd\"", error.LengthMismatch },
        .{ @Vector(1, u8), "\"\\u00e9\"", error.LengthMismatch },
        .{ @Vector(3, u3), "\"abc\"", error.UnexpectedToken },
        .{ @Vector(3, bool), "\"abc\"", error.UnexpectedToken },
        .{ @Vector(3, u8), "{}", error.UnexpectedToken },
        .{ @Vector(3, u8), "null", error.UnexpectedToken },
    }) |case| {
        try testing.expectError(case[2], strand.parseLine(case[0], a, case[1], .{}));
        var where: strand.Diagnostics = .{};
        try testing.expectError(case[2], strand.parseLine(case[0], a, case[1], .{ .diagnostics = &where }));
        const dynamic = try std.json.parseFromSliceLeaky(std.json.Value, a, case[1], .{});
        try testing.expectError(case[2], strand.payloadOf(case[0], a, dynamic));
    }
}

test "a direct decoder allocation failure is not retried as a parse refusal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .alloc, .n = 1 } },
        .fault = .{ .fail = error.OutOfMemory },
    }} });
    defer fio.deinit();
    const failing = try fio.allocator(arena.allocator());
    // The escape needs the line's first allocation, which is refused; a
    // parse that took that for a refusal of the line would ask again.
    try testing.expectError(error.OutOfMemory, strand.parseLine([]const u8, failing, "\"escaped\\ttext\"", .{}));
    try testing.expectEqual(@as(u64, 1), fio.count(.alloc));
}
