//! Compile-error fixtures: a checked copy may not silently accept a type it
//! cannot walk, whatever the value in that type.
const std = @import("std");
const core = @import("strand").core;
const options = @import("rejection_options");
const sentinel: u8 = 0;
const pointer_lanes: @Vector(2, *const u8) = .{ &sentinel, &sentinel };

const T = switch (options.case) {
    0 => [*]const u8,
    1 => [*c]const u8,
    2 => *const fn () void,
    3 => union { integer: u32, bytes: []const u8 },
    4 => union(enum) { safe, unsafe: [*]const u8 },
    5 => ?[*]const u8,
    6 => []const *const anyopaque,
    7 => [0]*const anyopaque,
    8 => std.mem.Allocator,
    9 => *volatile u8,
    10 => *allowzero u8,
    11 => union(enum) { safe, unsafe: [0:pointer_lanes]@Vector(2, *const u8) },
    else => unreachable,
};

export fn rejected() void {
    const value: T = switch (options.case) {
        4, 11 => .safe,
        5 => null,
        6 => &.{},
        7 => .{},
        else => undefined,
    };
    var copy = core.clone(std.heap.page_allocator, value, .{}) catch unreachable;
    copy.deinit();
}
