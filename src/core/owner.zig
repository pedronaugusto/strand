//! An arena result owns storage, never the caller's input or an Io.
const std = @import("std");
const aegis = @import("aegis");
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
        work_used: usize = 0,
        const Self = @This();
        pub fn isLive(self: *const Self) bool {
            return self.state != null;
        }
        /// Consumes the owner. A value copy alone never transfers storage.
        pub fn take(self: *Self) Self {
            aegis.assert.pre(self.isLive(), "a parsed owner was used after it was taken or released");
            const destination = self.*;
            self.state = null;
            self.value = undefined;
            return destination;
        }
        /// Exactly once, infallible; the transferred-from owner is invalid.
        pub fn deinit(self: *Self) void {
            aegis.assert.pre(self.isLive(), "a parsed owner was used after it was taken or released");
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
    return .{ .value = value, .gpa = gpa, .state = arena.state, .requested_peak = c.allocationRequested(), .retained_bytes = c.allocationRequested(), .allocator_resident_bytes = backing.live, .work_used = c.workUsed() };
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
/// An owner for `value`, which was built on `arena`: the owner takes the
/// arena, whose child allocator must be `gpa`, and `deinit` releases it. The
/// arena is left empty. Nothing about the value is checked: this is for a
/// caller that built it through the bounded operations here, one at a time.
pub fn adopt(comptime T: type, gpa: std.mem.Allocator, arena: *std.heap.ArenaAllocator, value: T) Parsed(T) {
    aegis.assert.pre(arena.child_allocator.ptr == gpa.ptr and arena.child_allocator.vtable == gpa.vtable, "an arena is adopted only with the allocator under it");
    const resident = arena.queryCapacity();
    const state = arena.state;
    arena.state = .init;
    return .{ .value = value, .gpa = gpa, .state = state, .requested_peak = resident, .retained_bytes = resident, .allocator_resident_bytes = resident };
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
    return .{ .value = copied, .gpa = gpa, .state = arena.state, .requested_peak = c.allocationRequested(), .retained_bytes = c.allocationRequested(), .allocator_resident_bytes = backing.live, .work_used = c.workUsed() };
}
/// `clone` onto an arena the caller owns and resets, as `acquireLeaky` parses
/// onto one: requests are charged per operation, and a failed copy's storage
/// stays on the arena until the caller resets it.
pub fn cloneLeaky(arena: std.mem.Allocator, value: anytype, limits: context.Limits) context.DecodeError!@TypeOf(value) {
    const T = @TypeOf(value);
    comptime cloneCheck(T, &.{});
    comptime descriptor.check(T, descriptor.schema_capabilities, true, .owned);
    var c: context.Context = .init(arena, limits, .owned);
    return mapping.clone(T, value, &c);
}
fn cloneCheck(comptime T: type, comptime seen: []const type) void {
    // A whole protocol is more than the default thousand steps; the walk
    // stops at a type it is already inside.
    @setEvalBranchQuota(1_000_000);
    for (seen) |prior| if (T == prior) return;
    const next = seen ++ .{T};
    if (T == std.mem.Allocator or T == std.Io or T == std.Io.File or T == std.Io.Mutex or descriptor.has(T, "deinit")) @compileError("checked clone excludes resources");
    switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| cloneCheck(i.child, next),
        inline .@"struct", .@"union" => |i| for (i.field_types) |F| cloneCheck(F, next),
        else => {},
    }
}
