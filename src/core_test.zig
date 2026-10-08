const shakedown = @import("shakedown");
const std = @import("std");
pub const core = @import("core.zig");
const model = @import("core/model.zig");

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
    var p = try core.acquire([]const u8, .borrowed, std.testing.allocator, &input, .{}, struct {
        fn decode(c: *core.Context, bytes: []const u8) core.DecodeError![]const u8 {
            return c.retain(bytes, .borrowed, .prefer);
        }
    }.decode);
    var destination = p.take();
    try std.testing.expect(!p.isLive());
    try std.testing.expect(destination.isLive());
    destination.deinit();
    try std.testing.expectEqualStrings("ok", &input);
}

pub const Reference = @import("testing/Reference.zig");
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
    var borrowed = try core.acquire(Record, .borrowed, std.testing.allocator, &bytes, .{}, decodeRecord);
    defer borrowed.deinit();
    var owned = try core.acquire(Record, .owned, std.testing.allocator, &bytes, .{}, decodeRecord);
    defer owned.deinit();
    try std.testing.expectEqual(@intFromPtr(&bytes[17]), @intFromPtr(borrowed.value.label.ptr));
    bytes[17] = 'x';
    try std.testing.expectEqualStrings("xk", borrowed.value.label);
    try std.testing.expectEqualStrings("ok", owned.value.label);
    var defaults = try core.acquire(Record, .owned, std.testing.allocator, &.{ 6, 1, 3, 1, 'i', 2, 2, 0 }, .{}, decodeRecord);
    defer defaults.deinit();
    try std.testing.expectEqualStrings("default", defaults.value.label);
    try std.testing.expect(defaults.value.label.ptr != @as([]const u8, "default").ptr);
}

test "S1 reference traverses ignored wire values with limits and exact payload ends" {
    const nested = [_]u8{ 6, 2, 3, 1, 'i', 2, 2, 3, 1, 'x', 5, 1, 5, 1, 2, 1, 0, 0, 0 };
    try std.testing.expectError(error.DepthLimit, core.acquire(Record, .owned, std.testing.allocator, &nested, .{ .depth = 2 }, decodeRecord));
    try std.testing.expectError(error.ItemLimit, core.acquire(Record, .owned, std.testing.allocator, &nested, .{ .items = 5 }, decodeRecord));
    try std.testing.expectError(error.LengthLimit, core.acquire(Record, .owned, std.testing.allocator, &record_bytes, .{ .string_bytes = 1 }, decodeRecord));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .owned, std.testing.allocator, record_bytes[0 .. record_bytes.len - 1], .{}, decodeRecord));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .owned, std.testing.allocator, &(record_bytes ++ .{7}), .{}, decodeRecord));
    try std.testing.expectError(error.AllocationLimit, core.acquire(Record, .owned, std.testing.allocator, &record_bytes, .{ .allocation_bytes = 1 }, decodeRecord));
    try std.testing.expectError(error.InputLimit, core.acquire(Record, .owned, std.testing.allocator, &record_bytes, .{ .input_bytes = 1 }, decodeRecord));
    try std.testing.expectError(error.WorkLimit, core.acquire(Record, .owned, std.testing.allocator, &record_bytes, .{ .work = 1 }, decodeRecord));
}

test "S1 aliases are duplicate slots and optional missing differs from null" {
    const duplicate = [_]u8{ 6, 2, 3, 1, 'i', 2, 2, 3, 2, 'i', 'd', 2, 3, 0 };
    try std.testing.expectError(error.DuplicateField, core.acquire(Record, .owned, std.testing.allocator, &duplicate, .{}, decodeRecord));
    try std.testing.expectError(error.MissingField, core.acquire(Record, .owned, std.testing.allocator, &.{ 6, 0, 0 }, .{}, decodeRecord));
}

fn ownedSweep(gpa: std.mem.Allocator) !void {
    var result = try core.acquire(Record, .owned, gpa, &record_bytes, .{}, decodeRecord);
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
    var result = try core.acquire(Record, .borrowed, std.testing.allocator, memory[0..out.used], .{}, decodeRecord);
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

fn decoded(comptime T: type, c: *core.Context, input: []const u8) @TypeOf(core.deserialize(T, @as(*Reference, undefined), c)) {
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
    try std.testing.expectError(error.InvalidUtf8, core.acquire(Record, .borrowed, std.testing.allocator, &.{ 6, 2, 3, 1, 'i', 2, 1, 3, 1, 'x', 3, 1, 0xff, 0 }, .{}, decodeRecord));
    try std.testing.expectError(error.SyntaxError, core.acquire(Record, .borrowed, std.testing.allocator, &.{ 6, 1, 3, 1, 'i', 2, 1, 3, 1, 'x', 2, 3, 0 }, .{}, decodeRecord));
}

const AlignedRecord = struct { value: []align(32) const u8 };
test "S1 NoResize allocation fault sweep covers aligned sentinel trees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var no_resize: shakedown.alloc.NoResize = .init(gpa);
            var result = try core.acquire(AlignedRecord, .owned, no_resize.allocator(), &.{ 6, 1, 3, 5, 'v', 'a', 'l', 'u', 'e', 3, 2, 'o', 'k', 0 }, .{}, struct {
                fn decode(c: *core.Context, bytes: []const u8) core.DecodeError!AlignedRecord {
                    return decoded(AlignedRecord, c, bytes);
                }
            }.decode);
            defer result.deinit();
            try std.testing.expectEqualStrings("ok", result.value.value);
        }
    }.run, .{});
}

fn generatedReference(_: void, case: *shakedown.Case) anyerror!void {
    const labels = [_][]const u8{ "plain", "a\nb", "say \"yes\"", "λ", "" };
    const value: Record = .{ .id = shakedown.gen.int(case.source, u8), .label = shakedown.gen.oneOf(case.source, []const u8, &labels) };
    var memory: [128]u8 = undefined;
    var output: Reference.Encoder = .{ .buffer = &memory };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(value, &output, &c);
    var parsed = try core.acquire(Record, .owned, case.gpa, memory[0..output.used], .{}, decodeRecord);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
}
test "S1 generated 512 reference encode decode owned equality retained seed" {
    try shakedown.check(std.testing.allocator, {}, generatedReference, .{ .cases = 512, .seed = 0x737472616e645331 });
}

test "S1 fuzz bounded reference data with testing allocator" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [4096]u8 = undefined;
            const data = input[0..smith.slice(&input)];
            if (data.len > 4096) return;
            var parsed = core.acquire(Record, .owned, std.testing.allocator, data, .{ .input_bytes = 4096, .allocation_bytes = 8192, .work = 16384, .depth = 16 }, decodeRecord) catch return;
            parsed.deinit();
        }
    }.run, .{});
}

const ReferenceRaw = core.Raw(Reference.Format);
fn decodeRaw(c: *core.Context, bytes: []const u8) core.DecodeError!ReferenceRaw {
    return decoded(ReferenceRaw, c, bytes);
}
test "S1 format branded raw validates complete nested values with ownership and limits" {
    const input = [_]u8{ 5, 1, 5, 1, 2, 42, 0, 0 };
    var parsed = try core.acquire(ReferenceRaw, .owned, std.testing.allocator, &input, .{}, decodeRaw);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, &input, parsed.value.bytes);
    try std.testing.expect(parsed.value.bytes.ptr != &input);
    try std.testing.expectError(error.DepthLimit, core.acquire(ReferenceRaw, .borrowed, std.testing.allocator, &input, .{ .depth = 1 }, decodeRaw));
    var buffer: [32]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &buffer };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(parsed.value, &out, &c);
    try std.testing.expectEqualSlices(u8, &input, buffer[0..out.used]);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.InvalidRaw, core.serialize(ReferenceRaw{ .bytes = &.{ 5, 1, 2, 42 } }, &out, &c));
}

test "S1 bounded indefinite sequences and generic nontext map keys skip entirely" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c: core.Context = .init(arena.allocator(), .{}, .owned);
    const values = try decoded([]const u8, &c, &.{ 3, 2, 42, 43 });
    try std.testing.expectEqualSlices(u8, &.{ 42, 43 }, values);
    const numbers = try decoded([]const u16, &c, &.{ 10, 2, 42, 2, 43, 0 });
    try std.testing.expectEqualSlices(u16, &.{ 42, 43 }, numbers);
    var raw = try core.acquire(ReferenceRaw, .owned, std.testing.allocator, &.{ 11, 2, 1, 2, 2, 0 }, .{}, decodeRaw);
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 6), raw.value.bytes.len);
}

test "S1 positive type shapes use installed type info and preserve exact fixed arity" {
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    const numbers = [_]u8{ 5, 2, 2, 1, 2, 2, 0 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &(try decoded([2]u8, &c, &numbers)));
    const terminated = try decoded([2:0]u8, &c, &numbers);
    try std.testing.expectEqual(@as(u8, 0), terminated[2]);
    try std.testing.expectEqual(@as(@Vector(2, u8), .{ 1, 2 }), try decoded(@Vector(2, u8), &c, &numbers));
    try std.testing.expectEqual(.{ @as(u8, 1), @as(u8, 2) }, try decoded(struct { u8, u8 }, &c, &numbers));
    const Enum = enum { one, two };
    try std.testing.expectEqual(Enum.two, try decoded(Enum, &c, &.{ 3, 3, 't', 'w', 'o' }));
    try std.testing.expect(core.describe(packed struct { value: u4 }, .{}).support == .supported);
    try std.testing.expect(core.describe(extern struct { value: u32 }, .{}).support == .supported);
    try std.testing.expect(core.describe(union(enum) { ready: void, value: u257 }, .{}).support != .unsupported);
    try std.testing.expect(core.describe(union { x: u8, y: u16 }, .{}).support == .unsupported);
    try std.testing.expect(core.describe(?*const std.Io.File, .{}).support == .unsupported);
}

test "S1 skip decode and duplicate first last policies remain bounded" {
    const First = struct {
        value: u8,
        pub const strand = .{ .duplicates = .first };
    };
    const Last = struct {
        value: u8,
        pub const strand = .{ .duplicates = .last };
    };
    const Skip = struct {
        value: u8 = 7,
        pub const strand = .{ .fields = .{ .value = .{ .skip_decode = true } } };
    };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    const input = [_]u8{ 6, 2, 3, 5, 'v', 'a', 'l', 'u', 'e', 2, 1, 3, 5, 'v', 'a', 'l', 'u', 'e', 2, 2, 0 };
    try std.testing.expectEqual(@as(u8, 1), (try decoded(First, &c, &input)).value);
    try std.testing.expectEqual(@as(u8, 2), (try decoded(Last, &c, &input)).value);
    try std.testing.expectEqual(@as(u8, 7), (try decoded(Skip, &c, &input)).value);
}

pub const Rejected = struct {
    text: []const u8,
    pub fn strandDeserialize(access: anytype) (@TypeOf(access.*).Error || error{PolicyDenied})!Rejected {
        _ = try access.read([]const u8);
        return error.PolicyDenied;
    }
};
fn rejectionSweep(gpa: std.mem.Allocator) !void {
    var result = core.acquire(Rejected, .owned, gpa, &.{ 3, 2, 'o', 'k' }, .{}, struct {
        fn decode(c: *core.Context, bytes: []const u8) (core.DecodeError || error{PolicyDenied})!Rejected {
            return decoded(Rejected, c, bytes);
        }
    }.decode) catch |err| switch (err) {
        error.PolicyDenied => return,
        else => return err,
    };
    result.deinit();
    return error.ExpectedRejection;
}
test "S1 named custom failures compose and rollback allocated surrogate data" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rejectionSweep, .{});
}

test "S1 one way fields never overwrite another field direction exclusion" {
    const Write = struct {
        pub const Self = @This();
        pub fn strandSerialize(_: Self, _: anytype) core.EncodeError!void {}
    };
    const Read = struct {
        pub const Self = @This();
        pub fn strandDeserialize(_: anytype) core.DecodeError!Self {
            return .{};
        }
    };
    const directions = core.describe(struct { write: Write, read: Read }, .{});
    try std.testing.expect(!directions.encode and !directions.decode);
    const missing_default = core.describe(struct {
        value: u8,
        pub const strand = .{ .fields = .{ .value = .{ .skip_decode = true } } };
    }, .{});
    try std.testing.expectEqual(core.Support.unsupported, missing_default.support);
}

test "S1 canonical raw refuses unnormalized bytes before output" {
    const Canonical = struct {
        pub const Error = core.EncodeError;
        pub const Format = Reference.Format;
        pub const canonical = true;
        pub const capabilities: core.Capabilities = .{};
    };
    var backend: Canonical = .{};
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.UnsupportedValue, core.serialize(ReferenceRaw{ .bytes = &.{ 2, 42 } }, &backend, &c));
    try std.testing.expectEqual(@as(usize, 0), c.output_bytes);
}

const FactoryRecord = struct {
    payload: []const u8,
    pub const strand = .{ .fields = .{ .payload = .{ .default = makeDefault } } };
    pub fn makeDefault(c: *core.Context) core.DecodeError![]const u8 {
        const bytes = try c.alloc(u8, 2);
        @memcpy(bytes, "ok");
        return bytes;
    }
};
fn factoryDecode(c: *core.Context, input: []const u8) core.DecodeError!FactoryRecord {
    return decoded(FactoryRecord, c, input);
}
fn factorySweep(gpa: std.mem.Allocator) !void {
    var value = try core.acquire(FactoryRecord, .owned, gpa, &.{ 6, 0, 0 }, .{}, factoryDecode);
    defer value.deinit();
    try std.testing.expectEqualStrings("ok", value.value.payload);
}
test "S1 missing default factory has budgeted allocation and complete failure rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, factorySweep, .{});
    try std.testing.expectError(error.AllocationLimit, core.acquire(FactoryRecord, .owned, std.testing.allocator, &.{ 6, 0, 0 }, .{ .allocation_bytes = 1 }, factoryDecode));
    try std.testing.expectError(error.UnexpectedType, core.acquire(FactoryRecord, .owned, std.testing.allocator, &.{ 6, 1, 3, 7, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 7, 0 }, .{}, factoryDecode));
}

const FieldRecord = struct {
    is_ready: u8,
    item_count: u8,
    pub const strand = .{ .rename_all = .camel_case, .fields = .{
        .is_ready = .{ .codec = BoolByte },
        .item_count = .{ .range = .{ .min = 1, .max = 8 }, .validate = even },
    } };
    pub fn even(value: u8) bool {
        return value % 2 == 0;
    }
    pub const BoolByte = struct {
        pub fn encode(value: u8, access: anytype) @TypeOf(access.*).Error!void {
            try access.write(value != 0);
        }
        pub fn decode(access: anytype) @TypeOf(access.*).Error!u8 {
            return @intFromBool(try access.read(bool));
        }
    };
};
test "S1 field codec casing range and validation share both directions" {
    var storage: [128]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &storage };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(FieldRecord{ .is_ready = 1, .item_count = 4 }, &out, &c);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    const value = try decoded(FieldRecord, &c, storage[0..out.used]);
    try std.testing.expectEqual(@as(u8, 1), value.is_ready);
    try std.testing.expectEqual(@as(u8, 4), value.item_count);
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.NumberOutOfRange, core.serialize(FieldRecord{ .is_ready = 0, .item_count = 9 }, &out, &c));
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.CustomRejected, core.serialize(FieldRecord{ .is_ready = 0, .item_count = 3 }, &out, &c));
}
test "S1 omit default compares slice contents rather than identity" {
    const WithDefault = struct {
        value: []const u8 = "ok",
        pub const strand = .{ .fields = .{ .value = .{ .omit = .default_value } } };
    };
    var different_storage = [_]u8{ 'o', 'k' };
    var storage: [64]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &storage };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(WithDefault{ .value = &different_storage }, &out, &c);
    try std.testing.expectEqualSlices(u8, &.{ 6, 0, 0 }, storage[0..out.used]);
}

const External = union(enum) {
    count: u8,
    empty: void,
    unknown: void,
    pub const strand = .{ .other = "unknown", .variants = .{ .count = .{ .name = "c", .aliases = &.{"count"} } } };
};
const Internal = union(enum) {
    count: struct { value: u8 },
    empty: void,
    pub const strand = .{ .tag = "type" };
};
const Adjacent = union(enum) {
    count: u8,
    empty: void,
    pub const strand = .{ .tag = "t", .content = "c", .duplicates = .last };
};
test "S1 external internal adjacent tagged payloads round trip and never relax repeated tags" {
    var memory: [128]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &memory };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(External{ .count = 9 }, &out, &c);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(u8, 9), (try decoded(External, &c, memory[0..out.used])).count);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(External.unknown, try decoded(External, &c, &.{ 12, 1, 'x', 5, 1, 2, 1, 0, 0 }));
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(Internal{ .count = .{ .value = 5 } }, &out, &c);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(u8, 5), (try decoded(Internal, &c, memory[0..out.used])).count.value);
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(Adjacent{ .count = 7 }, &out, &c);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(u8, 7), (try decoded(Adjacent, &c, memory[0..out.used])).count);
    const content_first = [_]u8{ 6, 2, 3, 1, 'c', 2, 8, 3, 1, 't', 3, 5, 'c', 'o', 'u', 'n', 't', 0 };
    c = .init(std.testing.failing_allocator, .{ .items = 5, .depth = 1 }, .borrowed);
    try std.testing.expectEqual(@as(u8, 8), (try decoded(Adjacent, &c, &content_first)).count);
    const repeated = [_]u8{ 6, 3, 3, 1, 't', 3, 5, 'c', 'o', 'u', 'n', 't', 3, 1, 'c', 2, 8, 3, 1, 't', 3, 5, 'c', 'o', 'u', 'n', 't', 0 };
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.DuplicateField, decoded(Adjacent, &c, &repeated));
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.UnknownVariant, decoded(Adjacent, &c, &.{ 6, 2, 3, 1, 'c', 2, 8, 3, 1, 't', 3, 1, 'x', 0 }));
}

test "S1 ordered generic maps and unicode scalar preserve meaning and ownership" {
    const Map = core.Pairs(u8, []const u8);
    const entries = [_]model.Pair(u8, []const u8){ .{ .key = 1, .value = "one" }, .{ .key = 1, .value = "again" } };
    var memory: [128]u8 = undefined;
    var out: Reference.Encoder = .{ .buffer = &memory };
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(Map{ .items = &entries }, &out, &c);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    c = .init(arena.allocator(), .{}, .owned);
    const result = try decoded(Map, &c, memory[0..out.used]);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("again", result.items[1].value);
    try std.testing.expectEqual(core.Support.unsupported, core.describe(Map, .{ .map_keys = .text_only }).support);
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try core.serialize(core.Scalar{ .value = 0x1f30d }, &out, &c);
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectEqual(@as(u21, 0x1f30d), (try decoded(core.Scalar, &c, memory[0..out.used])).value);
    out.used = 0;
    c = .init(std.testing.failing_allocator, .{}, .borrowed);
    try std.testing.expectError(error.InvalidUtf8, core.serialize(core.Scalar{ .value = 0xd800 }, &out, &c));
}
fn pairsSweep(gpa: std.mem.Allocator) !void {
    const Map = core.Pairs(u8, []const u8);
    var result = try core.acquire(Map, .owned, gpa, &.{ 13, 2, 2, 1, 3, 1, 'a', 2, 2, 3, 1, 'b', 0 }, .{}, struct {
        fn decode(c: *core.Context, input: []const u8) core.DecodeError!Map {
            return decoded(Map, c, input);
        }
    }.decode);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.items.len);
}
test "S1 generic map backing and retained spans fault sweep" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pairsSweep, .{});
}

fn cloneSweep(gpa: std.mem.Allocator) !void {
    var bytes = [_]u8{ 'o', 'k' };
    const value: struct { text: []const u8, sentinel: [2:0]u8, lanes: @Vector(2, u8) } = .{ .text = &bytes, .sentinel = .{ 1, 2 }, .lanes = .{ 3, 4 } };
    var result = try core.clone(gpa, value, .{});
    defer result.deinit();
    bytes[0] = 'x';
    try std.testing.expectEqualStrings("ok", result.value.text);
    try std.testing.expectEqual(@as(u8, 0), result.value.sentinel[2]);
    try std.testing.expectEqual(@as(u8, 4), result.value.lanes[1]);
    try std.testing.expect(result.allocator_resident_bytes >= result.retained_bytes);
}
test "S1 checked clone separates input lifetime preserves fixed shape and rolls back" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneSweep, .{});
    try std.testing.expectError(error.AllocationLimit, core.clone(std.testing.allocator, @as([]const u8, "too long"), .{ .allocation_bytes = 1 }));
    try std.testing.expectError(error.LengthLimit, core.clone(std.testing.allocator, @as([]const u8, "too long"), .{ .string_bytes = 1 }));
}
fn leakySweep(gpa: std.mem.Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const value = try core.acquireLeaky(FactoryRecord, arena.allocator(), &.{ 6, 0, 0 }, .{}, factoryDecode);
    try std.testing.expectEqualStrings("ok", value.payload);
}
test "S1 caller arena accounting failures publish no result and reset cleans retained requests" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, leakySweep, .{});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.AllocationLimit, core.acquireLeaky(FactoryRecord, arena.allocator(), &.{ 6, 0, 0 }, .{ .allocation_bytes = 1 }, factoryDecode));
}

test "S1 nominal semantic wrappers retain unit newtype and fixed tuple distinctions" {
    var memory: [128]u8 = undefined;
    inline for (.{ core.NamedUnit("unit"){}, core.Newtype(u8, "id"){ .value = 7 }, core.NamedTuple(struct { u8, u8 }, "point"){ .value = .{ 1, 2 } } }) |value| {
        var out: Reference.Encoder = .{ .buffer = &memory };
        var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
        try core.serialize(value, &out, &c);
        c = .init(std.testing.failing_allocator, .{}, .borrowed);
        const result = try decoded(@TypeOf(value), &c, memory[0..out.used]);
        try std.testing.expectEqualDeep(value, result);
        try std.testing.expectEqual(core.Support.unsupported, core.describe(@TypeOf(value), .{ .named_shapes = false }).support);
    }
}
