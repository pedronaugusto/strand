//! Compile-error fixtures: neither ownership operation may silently accept
//! a type it cannot walk, regardless of the value in that type.
const std = @import("std");
const owned = @import("owned.zig");
const options = @import("rejection_options");
const sentinel: u8 = 0;

const T = switch (options.case) {
    0 => [*]const u8,
    1 => [*c]const u8,
    2 => *const fn () void,
    3 => union { integer: u32, bytes: []const u8 },
    4 => union(enum) { safe, unsafe: [*]const u8 },
    5 => ?[*]const u8,
    6 => []const *const anyopaque,
    7 => [0]*const anyopaque,
    8 => struct { comptime text: []const u8 = "borrowed" },
    9 => std.mem.Allocator,
    10 => *volatile u8,
    11 => *allowzero u8,
    12 => [:&sentinel]const ?*const u8,
    else => unreachable,
};

export fn rejected() void {
    const value: T = switch (options.case) {
        4 => .safe,
        5 => null,
        6 => &.{},
        7, 8 => .{},
        else => undefined,
    };
    if (options.free_only) {
        owned.freeOwned(std.heap.page_allocator, value);
    } else {
        _ = owned.copyOwned(std.heap.page_allocator, value) catch unreachable;
    }
}
