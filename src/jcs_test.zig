//! RFC 8785 (JCS): the RFC's number samples, and the cyberphone
//! json-canonicalization corpus at 32a48195b9b20fe67b1795e39e4509f14d860b45
//! (Apache-2.0, its licence beside the files).
const std = @import("std");
const json = @import("json.zig");
const canonical = @import("json/canonical.zig");

const gpa = std.testing.allocator;

test "JCS: RFC 8785 Appendix B, every number sample" {
    const samples = [_]struct { bits: u64, want: ?[]const u8 }{
        .{ .bits = 0x0000000000000000, .want = "0" },
        .{ .bits = 0x8000000000000000, .want = "0" },
        .{ .bits = 0x0000000000000001, .want = "5e-324" },
        .{ .bits = 0x8000000000000001, .want = "-5e-324" },
        .{ .bits = 0x7fefffffffffffff, .want = "1.7976931348623157e+308" },
        .{ .bits = 0xffefffffffffffff, .want = "-1.7976931348623157e+308" },
        .{ .bits = 0x4340000000000000, .want = "9007199254740992" },
        .{ .bits = 0xc340000000000000, .want = "-9007199254740992" },
        .{ .bits = 0x4430000000000000, .want = "295147905179352830000" },
        .{ .bits = 0x7fffffffffffffff, .want = null },
        .{ .bits = 0x7ff0000000000000, .want = null },
        .{ .bits = 0x44b52d02c7e14af5, .want = "9.999999999999997e+22" },
        .{ .bits = 0x44b52d02c7e14af6, .want = "1e+23" },
        .{ .bits = 0x44b52d02c7e14af7, .want = "1.0000000000000001e+23" },
        .{ .bits = 0x444b1ae4d6e2ef4e, .want = "999999999999999700000" },
        .{ .bits = 0x444b1ae4d6e2ef4f, .want = "999999999999999900000" },
        .{ .bits = 0x444b1ae4d6e2ef50, .want = "1e+21" },
        .{ .bits = 0x3eb0c6f7a0b5ed8c, .want = "9.999999999999997e-7" },
        .{ .bits = 0x3eb0c6f7a0b5ed8d, .want = "0.000001" },
        .{ .bits = 0x41b3de4355555553, .want = "333333333.3333332" },
        .{ .bits = 0x41b3de4355555554, .want = "333333333.33333325" },
        .{ .bits = 0x41b3de4355555555, .want = "333333333.3333333" },
        .{ .bits = 0x41b3de4355555556, .want = "333333333.3333334" },
        .{ .bits = 0x41b3de4355555557, .want = "333333333.33333343" },
        .{ .bits = 0xbecbf647612f3696, .want = "-0.0000033333333333333333" },
        .{ .bits = 0x43143ff3c1cb0959, .want = "1424953923781206.2" },
    };
    for (samples) |sample| {
        const v: f64 = @bitCast(sample.bits);
        if (sample.want) |want| {
            var buffer: [64]u8 = undefined;
            try std.testing.expectEqualStrings(want, canonical.ecmascript(&buffer, v));
            // Written as JSON and canonicalized, a number comes out the same.
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try json.jcs.write(gpa, &out.writer, v, .{});
            try std.testing.expectEqualStrings(want, out.written());
        } else try std.testing.expect(!std.math.isFinite(v));
    }
}

test "JCS: the cyberphone corpus, every file" {
    const files = [_][]const u8{ "arrays", "french", "structures", "unicode", "values", "weird" };
    const inputs = [_][]const u8{
        @embedFile("corpus/jcs/input/arrays.json"),     @embedFile("corpus/jcs/input/french.json"),
        @embedFile("corpus/jcs/input/structures.json"), @embedFile("corpus/jcs/input/unicode.json"),
        @embedFile("corpus/jcs/input/values.json"),     @embedFile("corpus/jcs/input/weird.json"),
    };
    const outputs = [_][]const u8{
        @embedFile("corpus/jcs/output/arrays.json"),     @embedFile("corpus/jcs/output/french.json"),
        @embedFile("corpus/jcs/output/structures.json"), @embedFile("corpus/jcs/output/unicode.json"),
        @embedFile("corpus/jcs/output/values.json"),     @embedFile("corpus/jcs/output/weird.json"),
    };
    for (files, inputs, outputs) |name, input, want| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        canonical.canonicalize(gpa, &out.writer, input, .{}) catch |err| {
            std.debug.print("{s}: {t}\n", .{ name, err });
            return err;
        };
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, want, "\n"), out.written());
    }
}

test "JCS refuses what has no one spelling" {
    const refused = [_]struct { input: []const u8, err: anyerror }{
        // A name given twice, a number past a double.
        .{ .input = "{\"a\":1,\"a\":2}", .err = error.DuplicateField },
        .{ .input = "1e400", .err = error.NumberOutOfRange },
        .{ .input = "[-1e309]", .err = error.NumberOutOfRange },
    };
    for (refused) |case| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try std.testing.expectError(case.err, json.jcs.canonicalize(gpa, &out.writer, case.input, .{}));
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // A typed integer past 2^53 - 1 is refused even where a double holds it:
    // its canonical spelling is the double's.
    try std.testing.expectError(error.NumberOutOfRange, json.jcs.write(gpa, &out.writer, @as(u64, 1 << 60), .{}));
    try std.testing.expectError(error.NumberOutOfRange, json.jcs.write(gpa, &out.writer, [_]i64{-(1 << 53)}, .{}));
    out.clearRetainingCapacity();
    try json.jcs.write(gpa, &out.writer, @as(f64, 0x1p60), .{});
    try std.testing.expectEqualStrings("1152921504606847000", out.written());
    out.clearRetainingCapacity();
    // In JSON text a number is the double nearest it, as JCS reads it.
    try json.jcs.canonicalize(gpa, &out.writer, "[1152921504606846976,9007199254740993]", .{});
    try std.testing.expectEqualStrings("[1152921504606847000,9007199254740992]", out.written());
    out.clearRetainingCapacity();
    try json.jcs.write(gpa, &out.writer, struct { b: u8, a: []const u8, c: ?u8 }{ .b = 2, .a = "x\u{7f}\u{1}", .c = null }, .{});
    try std.testing.expectEqualStrings("{\"a\":\"x\u{7f}\\u0001\",\"b\":2,\"c\":null}", out.written());
}

const shakedown = @import("shakedown");
const gen = shakedown.gen;

fn numbers(_: void, case: *shakedown.Case) anyerror!void {
    const v: f64 = @bitCast(gen.int(case.source, u64));
    if (!std.math.isFinite(v)) return;
    var buffer: [64]u8 = undefined;
    const spelled = canonical.ecmascript(&buffer, v);
    case.note("{x} as {s}", .{ @as(u64, @bitCast(v)), spelled });
    // It reads back as the same double, and is JSON.
    try std.testing.expectEqual(if (v == 0) 0 else v, try std.fmt.parseFloat(f64, spelled));
    var parsed = try json.parse(f64, gpa, spelled, .{});
    defer parsed.deinit();
}

test "JCS: a double's spelling reads back as the double" {
    try shakedown.check(gpa, {}, numbers, .{ .cases = 5000 });
}

fn idempotent(_: void, case: *shakedown.Case) anyerror!void {
    const Entry = struct { key: []const u8, value: f64 };
    const entries = try case.gpa.alloc(Entry, gen.intRange(case.source, usize, 0, 6));
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var n: usize = 0;
    for (entries) |_| {
        const key = try gen.string(case.source, case.gpa, .{ .max_len = 4 });
        if ((try used.getOrPut(case.gpa, key)).found_existing) continue;
        const real = gen.float(case.source, f64);
        entries[n] = .{ .key = key, .value = if (std.math.isFinite(real)) real else 0 };
        n += 1;
    }
    const pairs = try case.gpa.alloc(@import("core.zig").Pair([]const u8, f64), n);
    for (pairs, entries[0..n]) |*p, e| p.* = .{ .key = e.key, .value = e.value };
    var once: std.Io.Writer.Allocating = .init(case.gpa);
    try json.jcs.write(case.gpa, &once.writer, @import("core.zig").Pairs([]const u8, f64){ .items = pairs }, .{});
    var twice: std.Io.Writer.Allocating = .init(case.gpa);
    try json.jcs.canonicalize(case.gpa, &twice.writer, once.written(), .{});
    try std.testing.expectEqualStrings(once.written(), twice.written());
}

test "JCS: the canonical form of a canonical form is itself" {
    try shakedown.check(gpa, {}, idempotent, .{ .cases = 500 });
}
