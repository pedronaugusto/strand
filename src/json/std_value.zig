//! The standard dynamic Value bridge uses the same bounded operation context.
//! Precision follows std.json.Value's integer/float/number_string alternatives.
const std = @import("std");
const core = @import("strand.core");
const native = @import("Value.zig");
pub fn fromNative(value: native.Value, c: *core.Context) core.DecodeError!std.json.Value {
    try c.chargeWork(1);
    const container = value == .array or value == .object;
    if (container) try c.enter();
    defer if (container) c.leave();
    return switch (value) {
        .null_value => .null,
        .boolean => |v| .{ .bool = v },
        .string => |v| .{ .string = v },
        .number => |v| blk: {
            try c.chargeWork(v.len);
            break :blk std.json.Value.parseFromNumberSlice(v);
        },
        .array => |v| blk: {
            const values = try c.alloc(std.json.Value, v.len);
            for (values, v) |*dest, item| dest.* = try fromNative(item, c);
            break :blk .{ .array = .{ .allocator = c.storage, .items = values, .capacity = values.len, .pointer_stability = .{} } };
        },
        .object => |v| blk: {
            var object: std.json.ObjectMap = .empty;
            try object.ensureTotalCapacity(c.allocator(), v.len);
            for (v) |member| {
                try c.chargeWork(member.key.len);
                object.putAssumeCapacity(member.key, try fromNative(member.value, c));
            }
            break :blk .{ .object = object };
        },
    };
}
pub fn toNative(value: std.json.Value, c: *core.Context) core.EncodeError!native.Value {
    try c.chargeWork(1);
    const container = value == .array or value == .object;
    if (container) try c.enter();
    defer if (container) c.leave();
    return switch (value) {
        .null => .null_value,
        .bool => |v| .{ .boolean = v },
        .string => |v| .{ .string = v },
        .number_string => |v| .{ .number = v },
        .integer, .float => blk: {
            if (value == .float and !std.math.isFinite(value.float)) return error.UnsupportedValue;
            const memory = try c.alloc(u8, 128);
            const text = switch (value) {
                .integer => |v| std.mem.print(memory, "{d}", .{v}),
                .float => |v| std.mem.print(memory, "{}", .{v}),
                else => unreachable, // unreachable: this arm accepts only integer and float.
            } catch return error.NumberOutOfRange;
            break :blk .{ .number = text };
        },
        .array => |v| blk: {
            if (v.items.len > c.limits.container_items) return error.ItemLimit;
            const values = try c.alloc(native.Value, v.items.len);
            for (values, v.items) |*dest, item| dest.* = try toNative(item, c);
            break :blk .{ .array = values };
        },
        .object => |v| blk: {
            if (v.count() > c.limits.container_items) return error.ItemLimit;
            const values = try c.alloc(native.Member, v.count());
            for (values, v.keys(), v.values()) |*dest, key, item| {
                try c.span(key.len, true);
                try c.chargeWork(key.len);
                dest.* = .{ .key = key, .value = try toNative(item, c) };
            }
            break :blk .{ .object = values };
        },
    };
}

/// Move, never duplicate, the core arena into the standard dynamic owner.
pub fn take(source: *core.Parsed(native.Value), limits: core.Limits) core.DecodeError!std.json.Parsed(std.json.Value) {
    const overhead = @sizeOf(std.heap.ArenaAllocator);
    if (overhead > limits.allocation_bytes - source.requested_peak or overhead > limits.allocation_bytes - source.allocator_resident_bytes) return error.AllocationLimit;
    const gpa = source.gpa;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    var backing: core.Backing = .{ .gpa = gpa, .limit = limits.allocation_bytes - overhead, .live = source.allocator_resident_bytes };
    const moved = source.take();
    arena.* = moved.state.?.promote(backing.allocator());
    errdefer arena.deinit();
    var c: core.Context = .init(arena.allocator(), limits, .owned);
    c.allocation_requested = moved.requested_peak + overhead;
    c.work = moved.work_used;
    const value = fromNative(moved.value, &c) catch |err| return if (backing.limited or c.allocation_limited) error.AllocationLimit else err;
    arena.child_allocator = gpa;
    return .{ .arena = arena, .value = value };
}
