//! An arena result owns storage, never the caller's input or an Io.
const std = @import("std");
const context = @import("context.zig");
const descriptor = @import("descriptor.zig");

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        gpa: std.mem.Allocator,
        state: ?std.heap.ArenaAllocator.State,
        requested_peak: usize,
        retained_bytes: usize,
        const Self = @This();
        pub fn isLive(self: *const Self) bool {
            return self.state != null;
        }
        /// Consumes the owner. A value copy alone never transfers storage.
        pub fn take(self: *Self) Self {
            @setRuntimeSafety(true);
            std.debug.assert(self.isLive());
            const destination = self.*;
            self.state = null;
            self.value = undefined;
            return destination;
        }
        /// Exactly once, infallible; the transferred-from owner is invalid.
        pub fn deinit(self: *Self) void {
            @setRuntimeSafety(true);
            std.debug.assert(self.isLive());
            var arena = self.state.?.promote(self.gpa);
            arena.deinit();
            self.state = null;
            self.value = undefined;
        }
    };
}

/// The callback only receives budgeted context access. No raw backing allocator
/// or result owner escapes. Caller-arena decoders have their own leaky contract.
pub fn acquire(comptime T: type, comptime ownership: context.Ownership, gpa: std.mem.Allocator, bytes: []const u8, limits: context.Limits, comptime decode: anytype) (context.DecodeError || CallbackError(decode))!Parsed(T) {
    @setRuntimeSafety(true);
    comptime descriptor.check(T, .{}, true, ownership);
    if (bytes.len > limits.input_bytes) return error.InputLimit;
    var backing: context.Backing = .{ .gpa = gpa, .limit = limits.allocation_bytes };
    var arena: std.heap.ArenaAllocator = .init(backing.allocator());
    errdefer arena.deinit();
    var c: context.Context = .init(arena.allocator(), limits, ownership);
    const value = decode(&c, bytes) catch |err| return if (backing.limited) error.AllocationLimit else err;
    // Only the linked arena state survives. No pointer into stack-local backing
    // or arena/context survives publication; deinit promotes with the original gpa.
    return .{ .value = value, .gpa = gpa, .state = arena.state, .requested_peak = backing.peak, .retained_bytes = backing.live };
}

fn CallbackError(comptime decode: anytype) type {
    const result = @typeInfo(@TypeOf(decode)).@"fn".return_type.?;
    const errors = @typeInfo(result).error_union.error_set;
    if (@typeInfo(errors).error_set.error_names == null) @compileError("acquisition callbacks require a named error set");
    return errors;
}
