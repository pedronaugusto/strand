const std = @import("std");
const core = @import("core.zig");

test "S1 admission sees rejected inactive branches and recursive data" {
    const Node = struct {
        const Self = @This();
        value: i257,
        next: ?*const Self,
    };
    try std.testing.expect(core.describe(Node, .{}).support != .unsupported);
    try std.testing.expectEqual(core.Support.unsupported, core.describe(?std.mem.Allocator, .{}).support);
    try std.testing.expectEqualStrings(".child", core.describe(struct { child: std.Io }, .{}).path);
}

test "S1 finite budgets include borrowed spans and full wire frames" {
    var c: core.Context = .init(std.testing.allocator, .{ .depth = 1, .items = 2, .string_bytes = 3, .work = 8 }, .borrowed);
    try c.enter();
    try std.testing.expectError(error.DepthLimit, c.enter());
    c.leave();
    try c.node();
    try c.node();
    try std.testing.expectError(error.ItemLimit, c.node());
    try std.testing.expectError(error.LengthLimit, c.span(4, false));
    try c.chargeWork(8);
    try std.testing.expectError(error.WorkLimit, c.chargeWork(1));
}

test "S1 owner transfer invalidates source and frees only result storage" {
    var input = [_]u8{ 'o', 'k' };
    var p = try core.acquire([]const u8, .borrowed, struct {
        fn decode(c: *core.Context, bytes: []const u8) core.DecodeError![]const u8 {
            return c.retain(bytes, .borrowed, .prefer);
        }
    }.decode, std.testing.allocator, &input, .{});
    var destination = p.take();
    try std.testing.expect(!p.isLive());
    try std.testing.expect(destination.isLive());
    destination.deinit();
    try std.testing.expectEqualStrings("ok", &input);
}

const Reference = @import("testing/Reference.zig");
const Record = struct {
    id: u8,
    label: []const u8 = "default",
    pub const strand = .{ .fields = .{ .id = .{ .name = "i", .aliases = &.{"id"} } } };
};
const record_bytes = [_]u8{ 6, 2, 3, 2, 'i', 'd', 2, 42, 3, 5, 'l', 'a', 'b', 'e', 'l', 3, 2, 'o', 'k', 0 };
fn decodeRecord(c: *core.Context, bytes: []const u8) core.DecodeError!Record {
    var backend: Reference = .{ .input = bytes };
    return core.deserialize(Record, &backend, c);
}

test "S1 reference borrowed owned and default storage" {
    var bytes = record_bytes;
    var borrowed = try core.acquire(Record, .borrowed, decodeRecord, std.testing.allocator, &bytes, .{});
    defer borrowed.deinit();
    var owned = try core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &bytes, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@intFromPtr(&bytes[17]), @intFromPtr(borrowed.value.label.ptr));
    bytes[17] = 'x';
    try std.testing.expectEqualStrings("xk", borrowed.value.label);
    try std.testing.expectEqualStrings("ok", owned.value.label);
    var defaults = try core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &.{ 6, 1, 3, 1, 'i', 2, 2, 0 }, .{});
    defer defaults.deinit();
    try std.testing.expectEqualStrings("default", defaults.value.label);
    try std.testing.expect(defaults.value.label.ptr != @as([]const u8, "default").ptr);
}

test "S1 reference traverses ignored wire values with limits and exact payload ends" {
    const nested = [_]u8{ 6, 2, 3, 1, 'i', 2, 2, 3, 1, 'x', 5, 1, 5, 1, 2, 1, 0, 0, 0 };
    try std.testing.expectError(error.DepthLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &nested, .{ .depth = 2 }));
    try std.testing.expectError(error.ItemLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &nested, .{ .items = 5 }));
    try std.testing.expectError(error.LengthLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &record_bytes, .{ .string_bytes = 1 }));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, record_bytes[0 .. record_bytes.len - 1], .{}));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &(record_bytes ++ .{7}), .{}));
    try std.testing.expectError(error.AllocationLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &record_bytes, .{ .allocation_bytes = 1 }));
    try std.testing.expectError(error.InputLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &record_bytes, .{ .input_bytes = 1 }));
    try std.testing.expectError(error.WorkLimit, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &record_bytes, .{ .work = 1 }));
}

test "S1 aliases are duplicate slots and optional missing differs from null" {
    const duplicate = [_]u8{ 6, 2, 3, 1, 'i', 2, 2, 3, 2, 'i', 'd', 2, 3, 0 };
    try std.testing.expectError(error.DuplicateField, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &duplicate, .{}));
    try std.testing.expectError(error.MissingField, core.acquire(Record, .owned, decodeRecord, std.testing.allocator, &.{ 6, 0, 0 }, .{}));
}

fn ownedSweep(gpa: std.mem.Allocator) !void {
    var result = try core.acquire(Record, .owned, decodeRecord, gpa, &record_bytes, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("ok", result.value.label);
}
test "S1 result arena allocation rollback fault sweep" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedSweep, .{});
}

test "S1 semantic encoder fixed buffer zero allocations and same typed round trip" {
    var memory: [64]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &memory };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(Record{ .id = 42, .label = "ok" }, &out, &c);
    try std.testing.expectEqual(@as(usize, 0), c.allocation_requested);
    var result = try core.acquire(Record, .borrowed, decodeRecord, std.testing.allocator, memory[0..out.used], .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 42), result.value.id);
    try std.testing.expectEqualStrings("ok", result.value.label);
    try std.testing.expectEqual(@as(usize, 0), result.requested_peak);
    c = .init(std.testing.failing_allocator, .{ .output_bytes = 2 }, .borrowed);
    out.used = 0;
    try std.testing.expectError(error.OutputLimit, core.serialize(Record{ .id = 1 }, &out, &c));
}

test "S1 checked encoding rejects active cycles and invalid UTF8" {
    const Node = struct {
        const Self = @This();
        next: ?*const Self,
    };
    var node: Node = .{ .next = null };
    node.next = &node;
    var memory: [64]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &memory };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.CycleDetected, core.serialize(&node, &out, &c));
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.InvalidUtf8, core.serialize(@as([]const u8, &.{0xff}), &out, &c));
}

fn decoded(comptime T: type, c: *core.Context, input: []const u8) core.DecodeError!T {
    var backend: Reference = .{ .input = input };
    return core.deserialize(T, &backend, c);
}

test "S1 transient spans always copy and require borrow rejects scratch" {
    var c: core.Context = .init(std.testing.allocator, .{}, .borrowed);
    const input: []const u8 = "temporary";
    const copy = try c.retain(input, .transient, .prefer);
    defer std.testing.allocator.free(copy);
    try std.testing.expect(copy.ptr != input.ptr);
    try std.testing.expectError(error.BorrowUnavailable, c.retain(input, .transient, .require));
}

test "S1 mutable aligned and sentinel span storage is independently typed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c: core.Context = .init(arena.allocator(), .{}, .borrowed);
    const input = [_]u8{ 3, 2, 'o', 'k' };
    const mutable = try decoded([]u8, &c, &input);
    try std.testing.expect(@intFromPtr(mutable.ptr) != @intFromPtr(&input[2]));
    const aligned = try decoded([]align(32) const u8, &c, &input);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 32);
    const terminated = try decoded([:0]const u8, &c, &input);
    try std.testing.expectEqual(@as(u8, 0), terminated[terminated.len]);
    try std.testing.expectEqualStrings("ok", terminated);
}

test "S1 numeric conversion checks signed min and destination width without floats" {
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(i8, -128), try decoded(i8, &c, &.{ 9, 128 }));
    try std.testing.expectError(error.NumberOutOfRange, decoded(i8, &c, &.{ 2, 128 }));
    try std.testing.expectError(error.NumberOutOfRange, decoded(u7, &c, &.{ 2, 128 }));
    try std.testing.expectError(error.NumberOutOfRange, decoded(u128, &c, &.{ 9, 1 }));
    try std.testing.expectEqual(@as(i257, 255), try decoded(i257, &c, &.{ 2, 255 }));
}

pub const Checked = struct {
    value: u8,
    pub fn strandDeserialize(access: anytype) core.DecodeError!Checked {
        const value = try access.read(u8);
        if (value > 100) return error.CustomRejected;
        return .{ .value = value };
    }
    pub fn strandSerialize(self: Checked, access: anytype) core.EncodeError!void {
        try access.write(self.value);
    }
};
pub const Twice = struct {
    pub fn strandDeserialize(access: anytype) core.DecodeError!Twice {
        _ = try access.read(u8);
        _ = try access.read(u8);
        return .{};
    }
};
test "S1 hooks consume exactly one bounded surrogate and reject before publication" {
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(u8, 42), (try decoded(Checked, &c, &.{ 2, 42 })).value);
    try std.testing.expectError(error.CustomRejected, decoded(Checked, &c, &.{ 2, 200 }));
    try std.testing.expectError(error.CustomRejected, decoded(Twice, &c, &.{ 2, 1, 2, 2 }));
}

test "S1 skip validation rejects invalid ignored text and false count hints" {
    try std.testing.expectError(error.InvalidUtf8, core.acquire(Record, .borrowed, decodeRecord, std.testing.allocator, &.{ 6, 2, 3, 1, 'i', 2, 1, 3, 1, 'x', 3, 1, 0xff, 0 }, .{}));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .borrowed, decodeRecord, std.testing.allocator, &.{ 6, 1, 3, 1, 'i', 2, 1, 3, 1, 'x', 2, 3, 0 }, .{}));
}

const AlignedRecord = struct { value: []align(32) const u8 };
test "S1 NoResize allocation fault sweep covers aligned sentinel trees" {
    const shakedown = @import("shakedown");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var no_resize: shakedown.alloc.NoResize = .init(gpa);
            var result = try core.acquire(AlignedRecord, .owned, struct {
                fn decode(c: *core.Context, bytes: []const u8) core.DecodeError!AlignedRecord {
                    return decoded(AlignedRecord, c, bytes);
                }
            }.decode, no_resize.allocator(), &.{ 6, 1, 3, 5, 'v', 'a', 'l', 'u', 'e', 3, 2, 'o', 'k', 0 }, .{});
            defer result.deinit();
            try std.testing.expectEqualStrings("ok", result.value.value);
        }
    }.run, .{});
}
