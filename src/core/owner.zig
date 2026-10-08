//! An arena result owns storage, never the caller's input or an Io.
const std = @import("std");
const context = @import("context.zig");
const descriptor = @import("descriptor.zig");
const mapping = @import("decode.zig");

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        gpa: std.mem.Allocator,
        state: ?std.heap.ArenaAllocator.State,
        requested_peak: usize,
        retained_bytes: usize,
        allocator_resident_bytes: usize,
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

pub const AcquisitionOptions = struct {
    limits: context.Limits = .{},
    acceptance: context.Acceptance = .{},
    diagnostics: ?*context.Diagnostics = null,
};
/// The callback only receives budgeted context access. No raw backing allocator
/// or result owner escapes. Caller-arena decoders have their own leaky contract.
pub fn acquire(comptime T: type, comptime ownership: context.Ownership, gpa: std.mem.Allocator, bytes: []const u8, limits: context.Limits, comptime decode: anytype) (context.DecodeError || CallbackError(decode))!Parsed(T) {
    return acquireWith(T, ownership, gpa, bytes, .{ .limits = limits }, decode);
}
/// Adds caller acceptance and diagnostics without retaining either in the owner.
pub fn acquireWith(comptime T: type, comptime ownership: context.Ownership, gpa: std.mem.Allocator, bytes: []const u8, options: AcquisitionOptions, comptime decode: anytype) (context.DecodeError || CallbackError(decode))!Parsed(T) {
    const limits = options.limits;
    @setRuntimeSafety(true);
    comptime descriptor.check(T, descriptor.schema_capabilities, true, ownership);
    if (bytes.len > limits.input_bytes) return error.InputLimit;
    var backing: context.Backing = .{ .gpa = gpa, .limit = limits.allocation_bytes };
    var arena: std.heap.ArenaAllocator = .init(backing.allocator());
    errdefer arena.deinit();
    var c: context.Context = .init(arena.allocator(), limits, ownership);
    c.acceptance = options.acceptance;
    c.diagnostics = options.diagnostics;
    const value = decode(&c, bytes) catch |err| return if (backing.limited) error.AllocationLimit else err;
    // Only the linked arena state survives. No pointer into stack-local backing
    // or arena/context survives publication; deinit promotes with the original gpa.
    return .{ .value = value, .gpa = gpa, .state = arena.state, .requested_peak = c.allocation_requested, .retained_bytes = c.allocation_requested, .allocator_resident_bytes = backing.live };
}

fn CallbackError(comptime decode: anytype) type {
    const result = @typeInfo(@TypeOf(decode)).@"fn".return_type.?;
    const errors = @typeInfo(result).error_union.error_set;
    if (@typeInfo(errors).error_set.error_names == null) @compileError("acquisition callbacks require a named error set");
    return errors;
}

/// Caller-arena acquisition has no individual owner. Requests are charged per
/// operation; failed scratch/result allocations remain until the caller resets.
pub fn acquireLeaky(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, limits: context.Limits, comptime decode: anytype) (context.DecodeError || CallbackError(decode))!T {
    comptime descriptor.check(T, descriptor.schema_capabilities, true, .borrowed);
    if (bytes.len > limits.input_bytes) return error.InputLimit;
    var c: context.Context = .init(arena, limits, .borrowed);
    return decode(&c, bytes);
}
/// A checked deep copy into a new owner. Cycles are bounded by the depth limit;
/// resources are excluded even when their serialization has an explicit codec.
pub fn clone(gpa: std.mem.Allocator, value: anytype, limits: context.Limits) context.DecodeError!Parsed(@TypeOf(value)) {
    const T = @TypeOf(value);
    comptime cloneCheck(T, &.{});
    comptime descriptor.check(T, descriptor.schema_capabilities, true, .owned);
    var backing: context.Backing = .{ .gpa = gpa, .limit = limits.allocation_bytes };
    var arena: std.heap.ArenaAllocator = .init(backing.allocator());
    errdefer arena.deinit();
    var c: context.Context = .init(arena.allocator(), limits, .owned);
    const copied = mapping.clone(T, value, &c) catch |err| return if (backing.limited) error.AllocationLimit else err;
    return .{ .value = copied, .gpa = gpa, .state = arena.state, .requested_peak = c.allocation_requested, .retained_bytes = c.allocation_requested, .allocator_resident_bytes = backing.live };
}
fn cloneCheck(comptime T: type, comptime seen: []const type) void {
    for (seen) |prior| if (T == prior) return;
    const next = seen ++ .{T};
    if (T == std.mem.Allocator or T == std.Io or T == std.Io.File or T == std.Io.Mutex or descriptor.has(T, "deinit")) @compileError("checked clone excludes resources");
    switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| cloneCheck(i.child, next),
        inline .@"struct", .@"union" => |i| for (i.field_types) |F| cloneCheck(F, next),
        else => {},
    }
}
