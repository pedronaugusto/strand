//! CBOR (RFC 8949): every example of Appendix A, the deterministic profiles'
//! orderings (4.2.1, 4.2.3), what is not well-formed (Appendix F), typed
//! values both ways, and properties over generated items and bytes.
const std = @import("std");
const cbor = @import("cbor.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;
const Value = cbor.Value;

fn bytesOf(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}
fn nanValue() Value {
    return .{ .float = std.math.nan(f64) };
}
const tagged_text: Value = .{ .text = "2013-03-21T20:04:00Z" };
const tagged_seconds: Value = .{ .unsigned = 1363896240 };
const tagged_fraction: Value = .{ .float = 1363896240.5 };
const tagged_bytes: Value = .{ .bytes = &.{ 1, 2, 3, 4 } };
const tagged_cbor: Value = .{ .bytes = &.{ 0x64, 0x49, 0x45, 0x54, 0x46 } };
const tagged_uri: Value = .{ .text = "http://www.example.com" };
const big_one: Value = .{ .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0 } };

const Case = struct { hex: []const u8, want: Value, roundtrip: bool };
const appendix_a = [_]Case{
    .{ .hex = "00", .want = .{ .unsigned = 0 }, .roundtrip = true },
    .{ .hex = "01", .want = .{ .unsigned = 1 }, .roundtrip = true },
    .{ .hex = "0a", .want = .{ .unsigned = 10 }, .roundtrip = true },
    .{ .hex = "17", .want = .{ .unsigned = 23 }, .roundtrip = true },
    .{ .hex = "1818", .want = .{ .unsigned = 24 }, .roundtrip = true },
    .{ .hex = "1819", .want = .{ .unsigned = 25 }, .roundtrip = true },
    .{ .hex = "1864", .want = .{ .unsigned = 100 }, .roundtrip = true },
    .{ .hex = "1903e8", .want = .{ .unsigned = 1000 }, .roundtrip = true },
    .{ .hex = "1a000f4240", .want = .{ .unsigned = 1000000 }, .roundtrip = true },
    .{ .hex = "1b000000e8d4a51000", .want = .{ .unsigned = 1000000000000 }, .roundtrip = true },
    .{ .hex = "1bffffffffffffffff", .want = .{ .unsigned = 18446744073709551615 }, .roundtrip = true },
    .{ .hex = "3bffffffffffffffff", .want = .{ .negative = 18446744073709551615 }, .roundtrip = true },
    .{ .hex = "20", .want = .{ .negative = 0 }, .roundtrip = true },
    .{ .hex = "29", .want = .{ .negative = 9 }, .roundtrip = true },
    .{ .hex = "3863", .want = .{ .negative = 99 }, .roundtrip = true },
    .{ .hex = "3903e7", .want = .{ .negative = 999 }, .roundtrip = true },
    .{ .hex = "f90000", .want = .{ .float = 0.0 }, .roundtrip = true },
    .{ .hex = "f98000", .want = .{ .float = -0.0 }, .roundtrip = true },
    .{ .hex = "f93c00", .want = .{ .float = 1.0 }, .roundtrip = true },
    .{ .hex = "fb3ff199999999999a", .want = .{ .float = 1.1 }, .roundtrip = true },
    .{ .hex = "f93e00", .want = .{ .float = 1.5 }, .roundtrip = true },
    .{ .hex = "f97bff", .want = .{ .float = 65504.0 }, .roundtrip = true },
    .{ .hex = "fa47c35000", .want = .{ .float = 100000.0 }, .roundtrip = true },
    .{ .hex = "fa7f7fffff", .want = .{ .float = 3.4028234663852886e+38 }, .roundtrip = true },
    .{ .hex = "fb7e37e43c8800759c", .want = .{ .float = 1e+300 }, .roundtrip = true },
    .{ .hex = "f90001", .want = .{ .float = 5.960464477539063e-08 }, .roundtrip = true },
    .{ .hex = "f90400", .want = .{ .float = 6.103515625e-05 }, .roundtrip = true },
    .{ .hex = "f9c400", .want = .{ .float = -4.0 }, .roundtrip = true },
    .{ .hex = "fbc010666666666666", .want = .{ .float = -4.1 }, .roundtrip = true },
    .{ .hex = "f4", .want = .{ .boolean = false }, .roundtrip = true },
    .{ .hex = "f5", .want = .{ .boolean = true }, .roundtrip = true },
    .{ .hex = "f6", .want = .null_value, .roundtrip = true },
    .{ .hex = "60", .want = .{ .text = "" }, .roundtrip = true },
    .{ .hex = "6161", .want = .{ .text = "a" }, .roundtrip = true },
    .{ .hex = "6449455446", .want = .{ .text = "IETF" }, .roundtrip = true },
    .{ .hex = "62225c", .want = .{ .text = "\"\\" }, .roundtrip = true },
    .{ .hex = "62c3bc", .want = .{ .text = "\u{fc}" }, .roundtrip = true },
    .{ .hex = "63e6b0b4", .want = .{ .text = "\u{6c34}" }, .roundtrip = true },
    .{ .hex = "64f0908591", .want = .{ .text = "\u{10151}" }, .roundtrip = true },
    .{ .hex = "80", .want = .{ .array = &.{} }, .roundtrip = true },
    .{ .hex = "83010203", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .roundtrip = true },
    .{ .hex = "8301820203820405", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .{ .array = &.{ .{ .unsigned = 4 }, .{ .unsigned = 5 } } } } }, .roundtrip = true },
    .{ .hex = "98190102030405060708090a0b0c0d0e0f101112131415161718181819", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .unsigned = 2 }, .{ .unsigned = 3 }, .{ .unsigned = 4 }, .{ .unsigned = 5 }, .{ .unsigned = 6 }, .{ .unsigned = 7 }, .{ .unsigned = 8 }, .{ .unsigned = 9 }, .{ .unsigned = 10 }, .{ .unsigned = 11 }, .{ .unsigned = 12 }, .{ .unsigned = 13 }, .{ .unsigned = 14 }, .{ .unsigned = 15 }, .{ .unsigned = 16 }, .{ .unsigned = 17 }, .{ .unsigned = 18 }, .{ .unsigned = 19 }, .{ .unsigned = 20 }, .{ .unsigned = 21 }, .{ .unsigned = 22 }, .{ .unsigned = 23 }, .{ .unsigned = 24 }, .{ .unsigned = 25 } } }, .roundtrip = true },
    .{ .hex = "a0", .want = .{ .map = &.{} }, .roundtrip = true },
    .{ .hex = "a26161016162820203", .want = .{ .map = &.{ .{ .key = .{ .text = "a" }, .value = .{ .unsigned = 1 } }, .{ .key = .{ .text = "b" }, .value = .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } } } } }, .roundtrip = true },
    .{ .hex = "826161a161626163", .want = .{ .array = &.{ .{ .text = "a" }, .{ .map = &.{.{ .key = .{ .text = "b" }, .value = .{ .text = "c" } }} } } }, .roundtrip = true },
    .{ .hex = "a56161614161626142616361436164614461656145", .want = .{ .map = &.{ .{ .key = .{ .text = "a" }, .value = .{ .text = "A" } }, .{ .key = .{ .text = "b" }, .value = .{ .text = "B" } }, .{ .key = .{ .text = "c" }, .value = .{ .text = "C" } }, .{ .key = .{ .text = "d" }, .value = .{ .text = "D" } }, .{ .key = .{ .text = "e" }, .value = .{ .text = "E" } } } }, .roundtrip = true },
    .{ .hex = "7f657374726561646d696e67ff", .want = .{ .text = "streaming" }, .roundtrip = false },
    .{ .hex = "9fff", .want = .{ .array = &.{} }, .roundtrip = false },
    .{ .hex = "9f018202039f0405ffff", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .{ .array = &.{ .{ .unsigned = 4 }, .{ .unsigned = 5 } } } } }, .roundtrip = false },
    .{ .hex = "9f01820203820405ff", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .{ .array = &.{ .{ .unsigned = 4 }, .{ .unsigned = 5 } } } } }, .roundtrip = false },
    .{ .hex = "83018202039f0405ff", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .{ .array = &.{ .{ .unsigned = 4 }, .{ .unsigned = 5 } } } } }, .roundtrip = false },
    .{ .hex = "83019f0203ff820405", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } }, .{ .array = &.{ .{ .unsigned = 4 }, .{ .unsigned = 5 } } } } }, .roundtrip = false },
    .{ .hex = "9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff", .want = .{ .array = &.{ .{ .unsigned = 1 }, .{ .unsigned = 2 }, .{ .unsigned = 3 }, .{ .unsigned = 4 }, .{ .unsigned = 5 }, .{ .unsigned = 6 }, .{ .unsigned = 7 }, .{ .unsigned = 8 }, .{ .unsigned = 9 }, .{ .unsigned = 10 }, .{ .unsigned = 11 }, .{ .unsigned = 12 }, .{ .unsigned = 13 }, .{ .unsigned = 14 }, .{ .unsigned = 15 }, .{ .unsigned = 16 }, .{ .unsigned = 17 }, .{ .unsigned = 18 }, .{ .unsigned = 19 }, .{ .unsigned = 20 }, .{ .unsigned = 21 }, .{ .unsigned = 22 }, .{ .unsigned = 23 }, .{ .unsigned = 24 }, .{ .unsigned = 25 } } }, .roundtrip = false },
    .{ .hex = "bf61610161629f0203ffff", .want = .{ .map = &.{ .{ .key = .{ .text = "a" }, .value = .{ .unsigned = 1 } }, .{ .key = .{ .text = "b" }, .value = .{ .array = &.{ .{ .unsigned = 2 }, .{ .unsigned = 3 } } } } } }, .roundtrip = false },
    .{ .hex = "826161bf61626163ff", .want = .{ .array = &.{ .{ .text = "a" }, .{ .map = &.{.{ .key = .{ .text = "b" }, .value = .{ .text = "c" } }} } } }, .roundtrip = false },
    .{ .hex = "bf6346756ef563416d7421ff", .want = .{ .map = &.{ .{ .key = .{ .text = "Fun" }, .value = .{ .boolean = true } }, .{ .key = .{ .text = "Amt" }, .value = .{ .negative = 1 } } } }, .roundtrip = false },

    .{ .hex = "a201020304", .want = .{ .map = &.{ .{ .key = .{ .unsigned = 1 }, .value = .{ .unsigned = 2 } }, .{ .key = .{ .unsigned = 3 }, .value = .{ .unsigned = 4 } } } }, .roundtrip = true },
    .{ .hex = "c249010000000000000000", .want = .{ .tag = .{ .number = 2, .value = &big_one } }, .roundtrip = true },
    .{ .hex = "c349010000000000000000", .want = .{ .tag = .{ .number = 3, .value = &big_one } }, .roundtrip = true },
    .{ .hex = "f97c00", .want = .{ .float = std.math.inf(f64) }, .roundtrip = true },
    .{ .hex = "f97e00", .want = .{ .float = std.math.nan(f64) }, .roundtrip = true },
    .{ .hex = "f9fc00", .want = .{ .float = -std.math.inf(f64) }, .roundtrip = true },
    .{ .hex = "fa7f800000", .want = .{ .float = std.math.inf(f64) }, .roundtrip = false },
    .{ .hex = "fa7fc00000", .want = .{ .float = std.math.nan(f64) }, .roundtrip = false },
    .{ .hex = "faff800000", .want = .{ .float = -std.math.inf(f64) }, .roundtrip = false },
    .{ .hex = "fb7ff0000000000000", .want = .{ .float = std.math.inf(f64) }, .roundtrip = false },
    .{ .hex = "fb7ff8000000000000", .want = .{ .float = std.math.nan(f64) }, .roundtrip = false },
    .{ .hex = "fbfff0000000000000", .want = .{ .float = -std.math.inf(f64) }, .roundtrip = false },
    .{ .hex = "f7", .want = .undefined, .roundtrip = true },
    .{ .hex = "f0", .want = .{ .simple = 16 }, .roundtrip = true },
    .{ .hex = "f8ff", .want = .{ .simple = 255 }, .roundtrip = true },
    .{ .hex = "c074323031332d30332d32315432303a30343a30305a", .want = .{ .tag = .{ .number = 0, .value = &tagged_text } }, .roundtrip = true },
    .{ .hex = "c11a514b67b0", .want = .{ .tag = .{ .number = 1, .value = &tagged_seconds } }, .roundtrip = true },
    .{ .hex = "c1fb41d452d9ec200000", .want = .{ .tag = .{ .number = 1, .value = &tagged_fraction } }, .roundtrip = true },
    .{ .hex = "d74401020304", .want = .{ .tag = .{ .number = 23, .value = &tagged_bytes } }, .roundtrip = true },
    .{ .hex = "d818456449455446", .want = .{ .tag = .{ .number = 24, .value = &tagged_cbor } }, .roundtrip = true },
    .{ .hex = "d82076687474703a2f2f7777772e6578616d706c652e636f6d", .want = .{ .tag = .{ .number = 32, .value = &tagged_uri } }, .roundtrip = true },
    .{ .hex = "40", .want = .{ .bytes = "" }, .roundtrip = true },
    .{ .hex = "4401020304", .want = .{ .bytes = &.{ 1, 2, 3, 4 } }, .roundtrip = true },
    .{ .hex = "5f42010243030405ff", .want = .{ .bytes = &.{ 1, 2, 3, 4, 5 } }, .roundtrip = false },
};

test "RFC 8949 Appendix A: every example read, and written back where it is preferred" {
    inline for (appendix_a) |case| {
        const input = bytesOf(case.hex);
        var parsed = cbor.parse(Value, gpa, &input, .{}) catch |err| {
            std.debug.print("{s}: {t}\n", .{ case.hex, err });
            return err;
        };
        defer parsed.deinit();
        if (!parsed.value.eql(case.want)) {
            std.debug.print("{s}: read {any}\n", .{ case.hex, parsed.value });
            return error.TestUnexpectedResult;
        }
        if (case.roundtrip) {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try cbor.write(&out.writer, parsed.value, .{});
            try std.testing.expectEqualSlices(u8, &input, out.written());
        }
    }
    // The simple value 24 has no two-byte form: not well-formed.
    try std.testing.expectError(error.SyntaxError, cbor.parse(Value, gpa, &bytesOf("f818"), .{}));
}

fn written(value: anytype, options: cbor.WriteOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try cbor.write(&out.writer, value, options);
    return out.toOwnedSlice();
}

test "the deterministic profiles order a map's keys as RFC 8949 4.2.1 and 4.2.3 do" {
    const keys = [_]Value{ .{ .unsigned = 10 }, .{ .unsigned = 100 }, .{ .negative = 0 }, .{ .text = "z" }, .{ .text = "aa" }, .{ .array = &.{.{ .unsigned = 100 }} }, .{ .array = &.{.{ .negative = 0 }} }, .{ .boolean = false } };
    // Given in an order of their own, last first.
    var entries: [keys.len]cbor.Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = keys[keys.len - 1 - i], .value = .{ .unsigned = i } };
    const map: Value = .{ .map = &entries };
    const core_order = try written(map, .{ .profile = .deterministic, .allocator = gpa });
    defer gpa.free(core_order);
    var parsed = try cbor.parse(Value, gpa, core_order, .{});
    defer parsed.deinit();
    for (parsed.value.map, keys) |e, k| try std.testing.expect(e.key.eql(k));
    const length_first = try written(map, .{ .profile = .length_first, .allocator = gpa });
    defer gpa.free(length_first);
    var again = try cbor.parse(Value, gpa, length_first, .{});
    defer again.deinit();
    const order = [_]usize{ 0, 2, 7, 1, 3, 6, 4, 5 };
    for (again.value.map, order) |e, k| try std.testing.expect(e.key.eql(keys[k]));
    // A key given twice has no deterministic place.
    const twice: Value = .{ .map = &.{ .{ .key = .{ .unsigned = 1 }, .value = .null_value }, .{ .key = .{ .unsigned = 1 }, .value = .null_value } } };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.DuplicateField, cbor.write(&out.writer, twice, .{ .profile = .deterministic, .allocator = gpa }));
    // Nested maps and tagged keys are ordered inside out.
    const tag_key: Value = .{ .text = "t" };
    const nested: Value = .{ .map = &.{
        .{ .key = .{ .text = "b" }, .value = .{ .map = &.{ .{ .key = .{ .unsigned = 2 }, .value = .null_value }, .{ .key = .{ .unsigned = 1 }, .value = .null_value } } } },
        .{ .key = .{ .tag = .{ .number = 1, .value = &tag_key } }, .value = .{ .boolean = true } },
        .{ .key = .{ .text = "a" }, .value = .null_value },
    } };
    const nested_bytes = try written(nested, .{ .profile = .deterministic, .allocator = gpa });
    defer gpa.free(nested_bytes);
    try std.testing.expectEqualSlices(u8, &bytesOf("a36161f66162a201f602f6c16174f5"), nested_bytes);
}

test "RFC 8949 Appendix F: what is not well-formed is refused" {
    const malformed = [_][]const u8{
        // Truncated heads, arguments and content.
        "18",           "19",                     "1a",       "1b",                 "1901",         "1a0102",   "1b01020304050607", "38",       "58",       "78",
        "98",           "9a01ff00",               "b8",       "d8",                 "f8",           "f900",     "fa0000",           "fb000000", "41",       "61",
        "5affffffff00", "5bffffffffffffffff0102", "81",       "818181818181818181", "8200",         "a1",       "a20102",           "a100",     "a2000000", "c0",
        // Reserved additional information.
        "1c",           "1d",                     "1e",       "3c",                 "5c",           "7c",       "9c",               "bc",       "dc",       "fc",
        // Indefinite lengths where none can be, a break with nothing open.
        "1f",           "3f",                     "df",       "ff",                 "81ff",         "8200ff",   "a1ff",             "a1ff00",   "a100ff",   "9f81ff",
        // A chunk of another type, or chunked itself, in a chunked string.
        "5f00ff",       "5f21ff",                 "5f6100ff", "5f80ff",             "5f5f4100ffff", "7f4100ff", "7f7f6100ffff",
        // A simple value under 32 in two bytes; an odd indefinite map; an open one.
            "f800",     "f817",     "bf00ff",
        "bf000000ff",   "9f",                     "9f01",     "bf",                 "5f4100",       "7f6100",
    };
    for (malformed) |hex| {
        var buffer: [16]u8 = undefined;
        const input = try std.fmt.hexToBytes(&buffer, hex);
        if (cbor.parse(Value, gpa, input, .{})) |p| {
            var parsed = p;
            parsed.deinit();
            std.debug.print("{s} was read\n", .{hex});
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.SyntaxError, error.InvalidUtf8 => {},
            else => {
                std.debug.print("{s}: {t}\n", .{ hex, err });
                return err;
            },
        }
    }
    // Text that is not UTF-8, in one piece or chunked.
    try std.testing.expectError(error.InvalidUtf8, cbor.parse(Value, gpa, &bytesOf("61ff"), .{}));
    try std.testing.expectError(error.InvalidUtf8, cbor.parse(Value, gpa, &bytesOf("7f61c361a9ff"), .{}));
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
    pub const strand = .{ .fields = .{ .blob = .{ .as = .bytes } } };
};

test "typed values both ways: text apart from bytes, tags and undefined refused" {
    const value: Record = .{ .id = 7, .name = "ada", .blob = &.{ 0, 255 }, .delta = -3, .ratio = 0.5, .tags = &.{ "a", "b" }, .shape = .{ .square = .{ .side = 3 } }, .mode = .careful };
    const bytes = try written(value, .{});
    defer gpa.free(bytes);
    var parsed = try cbor.parse(Record, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ada", parsed.value.name);
    try std.testing.expectEqualSlices(u8, value.blob, parsed.value.blob);
    try std.testing.expectEqual(3, parsed.value.shape.square.side);
    try std.testing.expectEqual(null, parsed.value.note);
    // A string is borrowed from the input.
    try std.testing.expect(@intFromPtr(parsed.value.name.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(parsed.value.name.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
    // A tag where a value was asked for, undefined where a null was, bytes for text.
    try std.testing.expectError(error.UnexpectedType, cbor.parse(u64, gpa, &bytesOf("c11a514b67b0"), .{}));
    try std.testing.expectError(error.UnexpectedType, cbor.parse(?u8, gpa, &bytesOf("f7"), .{}));
    try std.testing.expectError(error.UnexpectedType, cbor.parse([]const u8, gpa, &bytesOf("4161"), .{}));
    try std.testing.expectError(error.NumberOutOfRange, cbor.parse(i8, gpa, &bytesOf("3880"), .{}));
    var widest = try cbor.parse(i65, gpa, &bytesOf("3bffffffffffffffff"), .{});
    defer widest.deinit();
    try std.testing.expectEqual(-(1 << 64), widest.value);
    // Wider integers need a bignum.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectError(error.NumberOutOfRange, cbor.write(&out.writer, @as(u128, 1 << 64), .{}));
}

test "tags by name: a value under its own, bignums, date-times and epoch seconds" {
    const Stamp = struct { at: cbor.DateTime, epoch: cbor.Epoch, big: cbor.Bignum, uri: cbor.Tagged([]const u8, 32) };
    const value: Stamp = .{ .at = .{ .text = "2013-03-21T20:04:00Z" }, .epoch = .{ .seconds = 1363896240 }, .big = .{ .negative = false, .magnitude = &.{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 } }, .uri = .{ .value = "http://www.example.com" } };
    const bytes = try written(value, .{});
    defer gpa.free(bytes);
    var parsed = try cbor.parse(Stamp, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(value.at.text, parsed.value.at.text);
    try std.testing.expectEqual(value.epoch.seconds, parsed.value.epoch.seconds);
    // The bignum's leading zero is not written.
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, parsed.value.big.magnitude);
    try std.testing.expectEqualStrings(value.uri.value, parsed.value.uri.value);
    var big = try cbor.parse(cbor.Bignum, gpa, &bytesOf("c349010000000000000000"), .{});
    defer big.deinit();
    try std.testing.expect(big.value.negative);
    try std.testing.expectError(error.UnexpectedType, cbor.parse(cbor.Tagged(u8, 2), gpa, &bytesOf("c101"), .{}));
    try std.testing.expectError(error.UnsupportedValue, cbor.parse(cbor.DateTime, gpa, &bytesOf("c06474657374"), .{}));
}

test "a length past the input is refused before anything is counted for it" {
    try std.testing.expectError(error.SyntaxError, cbor.parse([]const u8, gpa, &bytesOf("5bffffffffffffffff"), .{}));
    try std.testing.expectError(error.SyntaxError, cbor.parse([]const u64, gpa, &bytesOf("9bffffffffffffffff00"), .{}));
    try std.testing.expectError(error.SyntaxError, cbor.parse(Value, gpa, &bytesOf("bb7fffffffffffffff0000"), .{}));
    try std.testing.expectError(error.DepthLimit, cbor.parse(Value, gpa, &bytesOf("8181818100"), .{ .limits = .{ .depth = 3 } }));
    try std.testing.expectError(error.LengthLimit, cbor.parse(Value, gpa, &bytesOf("6461626364"), .{ .limits = .{ .string_bytes = 3 } }));
}

/// A generated item: every kind, nested a few levels.
fn item(case: *shakedown.Case, depth: u8) !Value {
    const s = case.source;
    const a = case.gpa;
    const kinds: u8 = if (depth == 0) 10 else 13;
    return switch (gen.intRange(s, u8, 0, kinds)) {
        0 => .{ .unsigned = gen.int(s, u64) },
        1 => .{ .negative = gen.int(s, u64) },
        2 => .{ .bytes = try gen.string(s, a, .{ .kind = .bytes, .max_len = 12 }) },
        3 => .{ .text = try gen.string(s, a, .{ .max_len = 12 }) },
        4 => .{ .boolean = gen.boolean(s) },
        5 => .null_value,
        6 => .undefined,
        7 => .{ .simple = gen.oneOf(s, u8, &.{ 0, 16, 19, 32, 200, 255 }) },
        8 => .{ .float = @bitCast(gen.int(s, u64)) },
        9 => .{ .float = gen.oneOf(s, f64, &.{ 0.0, -0.0, 1.5, 65504.0, 100000.0, 1.1, std.math.inf(f64) }) },
        10 => .{ .unsigned = gen.intRange(s, u64, 0, 30) },
        11 => blk: {
            const items = try a.alloc(Value, gen.intRange(s, usize, 0, 3));
            for (items) |*v| v.* = try item(case, depth - 1);
            break :blk .{ .array = items };
        },
        12 => blk: {
            const entries = try a.alloc(cbor.Entry, gen.intRange(s, usize, 0, 3));
            for (entries) |*e| e.* = .{ .key = try item(case, depth - 1), .value = try item(case, depth - 1) };
            break :blk .{ .map = entries };
        },
        else => blk: {
            const inner = try a.create(Value);
            inner.* = try item(case, depth - 1);
            break :blk .{ .tag = .{ .number = gen.oneOf(s, u64, &.{ 0, 24, 255, 1 << 40 }), .value = inner } };
        },
    };
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const value = try item(case, 3);
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try cbor.write(&out.writer, value, .{});
    case.note("cbor: {x}", .{out.written()});
    var parsed = try cbor.parse(Value, case.gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(value));
    // Truncated anywhere, it is refused, never read as something else.
    for (0..out.written().len) |end| {
        if (cbor.parse(Value, case.gpa, out.written()[0..end], .{})) |p| {
            var cut = p;
            cut.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // In a deterministic profile, written again it is the same bytes.
    var det: std.Io.Writer.Allocating = .init(case.gpa);
    if (cbor.write(&det.writer, value, .{ .profile = .deterministic, .allocator = case.gpa })) {
        var again = try cbor.parse(Value, case.gpa, det.written(), .{});
        defer again.deinit();
        var twice: std.Io.Writer.Allocating = .init(case.gpa);
        try cbor.write(&twice.writer, again.value, .{ .profile = .deterministic, .allocator = case.gpa });
        try std.testing.expectEqualSlices(u8, det.written(), twice.written());
    } else |err| try std.testing.expectEqual(error.DuplicateField, err);
}

test "generated items read back as they were, truncated nowhere, deterministic twice the same" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 600 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const input = try gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 64 });
    case.note("input: {x}", .{input});
    const options: cbor.ParseOptions = .{ .limits = .{ .work = 1 << 16, .depth = 32 } };
    var parsed = cbor.parse(Value, case.gpa, input, options) catch return;
    defer parsed.deinit();
    // What was read, written and read again, is the same item.
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try cbor.write(&out.writer, parsed.value, .{});
    var again = try cbor.parse(Value, case.gpa, out.written(), .{});
    defer again.deinit();
    try std.testing.expect(again.value.eql(parsed.value));
}

test "any bytes are an item or refused, and an item read is written as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}
