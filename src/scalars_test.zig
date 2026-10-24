//! aegis scalars in every format: what they hold, recognized by the literal
//! each declares, durations and sizes as their text.
const std = @import("std");
const aegis = @import("aegis");
// Another copy of aegis: what a program pinning another aegis version than
// strand's builds beside strand's, whose types are never strand's copy's.
const other_aegis = @import("other_aegis");
const scalars = @import("core/scalars.zig");
const json = @import("json.zig");
const zon = @import("zon.zig");

const Tag = struct {};

test "aegis scalars are recognized by the literal each declares" {
    try std.testing.expectEqual(scalars.Kind.text, scalars.kind(aegis.units.Duration(.millisecond, u64)).?);
    try std.testing.expectEqual(scalars.Kind.text, scalars.kind(aegis.units.Bytes(u64)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.units.Count(Tag, u32)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.units.Bits(u32)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.units.Instant(.real, .second, i64)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.int.Checked(i16)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.int.Saturating(u16)).?);
    try std.testing.expectEqual(scalars.Kind.integer, scalars.kind(aegis.id.Id(Tag, u64)).?);
    try std.testing.expectEqual(scalars.Kind.ranged, scalars.kind(aegis.int.Ranged(u8, 1, 9)).?);
    try std.testing.expectEqual(scalars.Kind.nonzero, scalars.kind(aegis.id.NonZero(Tag, u64)).?);
    try std.testing.expectEqual(scalars.Kind.counter, scalars.kind(aegis.id.Counter(Tag, u64)).?);
    // A type with an aegis scalar's declarations but not its literal is not one.
    const Lookalike = enum(u64) {
        pub const Representation = u64;
        pub const Domain = Tag;
        _,
    };
    try std.testing.expectEqual(null, scalars.kind(Lookalike));
    try std.testing.expectEqual(null, scalars.kind(u64));
}

test "aegis scalars made by another copy of aegis are read and written as aegis scalars" {
    comptime std.debug.assert(other_aegis.int.Ranged(u16, 1, 4096) != aegis.int.Ranged(u16, 1, 4096));
    const Job = struct {
        jobs: other_aegis.int.Ranged(u16, 1, 4096),
        timeout: other_aegis.units.Duration(.millisecond, u64),
        owner: other_aegis.id.NonZero(Tag, u64),
    };
    const text =
        \\{"jobs":4096,"timeout":"1m30s","owner":7}
    ;
    var parsed = try json.parse(Job, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 4096), parsed.value.jobs.raw());
    try std.testing.expectEqual(@as(u64, 90_000), parsed.value.timeout.raw());
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try json.write(&w, parsed.value, .{});
    try std.testing.expectEqualStrings(text, w.buffered());
    try std.testing.expectError(error.NumberOutOfRange, json.parse(Job, std.testing.allocator, "{\"jobs\":0,\"timeout\":\"1s\",\"owner\":7}", .{}));
}

const Config = struct {
    timeout: aegis.units.Duration(.millisecond, u64),
    window: aegis.units.Bytes(u64),
    retries: aegis.int.Ranged(u8, 0, 10),
    sent: aegis.units.Count(Tag, u32),
    total: aegis.int.Checked(i64),
    owner: aegis.id.NonZero(Tag, u64),
    issued: aegis.id.Counter(Tag, u64),
    started: aegis.units.Instant(.real, .second, i64),
    grace: ?aegis.units.Duration(.second, u32) = null,
};

fn sample() !Config {
    var issued: aegis.id.Counter(Tag, u64) = .init(0);
    _ = try issued.next();
    _ = try issued.next();
    return .{
        .timeout = .literal("1m30s"),
        .window = .literal("64KiB"),
        .retries = .literal(3),
        .sent = .fromRaw(12),
        .total = .init(-5),
        .owner = try .fromRaw(7),
        .issued = issued,
        .started = .fromRaw(1_700_000_000),
        .grace = .literal("5s"),
    };
}

test "aegis scalars in JSON: integers as integers, durations and sizes as text" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try json.write(&w, try sample(), .{});
    try std.testing.expectEqualStrings(
        \\{"timeout":"1m30s","window":"64KiB","retries":3,"sent":12,"total":-5,"owner":7,"issued":2,"started":1700000000,"grace":"5s"}
    , w.buffered());
    var parsed = try json.parse(Config, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const want = try sample();
    try std.testing.expectEqual(want.timeout, parsed.value.timeout);
    try std.testing.expectEqual(want.window, parsed.value.window);
    try std.testing.expectEqual(want.retries, parsed.value.retries);
    try std.testing.expectEqual(want.total.raw(), parsed.value.total.raw());
    try std.testing.expectEqual(want.owner, parsed.value.owner);
    try std.testing.expectEqual(want.issued.last().?.raw(), parsed.value.issued.last().?.raw());
    try std.testing.expectEqual(want.grace, parsed.value.grace);
}

test "aegis scalars refuse what they cannot hold" {
    const Limits = struct {
        retries: aegis.int.Ranged(u8, 0, 10) = .literal(3),
        owner: aegis.id.NonZero(Tag, u64) = @fromBackingInt(@intCast(1)),
        timeout: aegis.units.Duration(.second, u32) = .literal("1s"),
        size: aegis.units.Bytes(u32) = .literal("1KiB"),
    };
    const cases = [_]struct { input: []const u8, err: anyerror }{
        .{ .input = "{\"retries\":11}", .err = error.NumberOutOfRange },
        .{ .input = "{\"owner\":0}", .err = error.NumberOutOfRange },
        // Finer than a second, past a u32 of seconds, no duration at all.
        .{ .input = "{\"timeout\":\"1.5s\"}", .err = error.InexactNumber },
        .{ .input = "{\"timeout\":\"200000d\"}", .err = error.NumberOutOfRange },
        .{ .input = "{\"timeout\":\"soon\"}", .err = error.SyntaxError },
        // A duration is text, never a bare number of an unstated unit.
        .{ .input = "{\"timeout\":30}", .err = error.UnexpectedType },
        .{ .input = "{\"size\":\"64KB\"}", .err = error.SyntaxError },
        .{ .input = "{\"size\":\"0.1KiB\"}", .err = error.InexactNumber },
        .{ .input = "{\"retries\":\"3\"}", .err = error.UnexpectedType },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, json.parse(Limits, std.testing.allocator, case.input, .{}));
    }
}

test "aegis scalars in ZON" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try zon.write(&w, try sample(), .{});
    var parsed = try zon.parse(Config, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const want = try sample();
    try std.testing.expectEqual(want.timeout, parsed.value.timeout);
    try std.testing.expectEqual(want.window, parsed.value.window);
    try std.testing.expectEqual(want.started, parsed.value.started);
    try std.testing.expect(std.mem.find(u8, w.buffered(), ".timeout = \"1m30s\"") != null);
}
