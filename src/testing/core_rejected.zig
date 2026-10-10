//! Negative operation instantiations. Inspection alone remains non-failing.
const std = @import("std");
const core = @import("strand").core;
const options = @import("rejection_options");
const Backend = struct {
    pub const Error = core.DecodeError || core.EncodeError;
    pub const capabilities: core.Capabilities = .{};
};
const Required = struct {
    label: []const u8,
    pub const strand = .{ .fields = .{ .label = .{ .borrow = .require } } };
};
fn required(_: *core.Context, _: []const u8) core.DecodeError!Required {
    return .{ .label = "" };
}
pub const EncodeOnly = struct {
    pub fn strandSerialize(_: EncodeOnly, _: anytype) core.EncodeError!void {}
};
const Secret = struct {
    material: [16]u8,
    pub fn format(_: *const Secret, _: *std.Io.Writer) error{SecretNotFormattable}!void {
        return error.SecretNotFormattable;
    }
};
pub const UnboundedHook = struct {
    pub fn strandSerialize(_: UnboundedHook, _: anytype) anyerror!void {}
};
pub const Legacy = struct {
    pub fn jsonStringify(_: Legacy, _: anytype) error{}!void {}
};
pub export fn rejected() void {
    var backend: Backend = .{};
    var c: core.Context = .init(std.testing.failing_allocator, .{}, .borrowed);
    switch (options.case) {
        0 => core.serialize(@as(?std.mem.Allocator, null), &backend, &c) catch unreachable,
        1 => {
            const T = struct {
                left: u8,
                right: u8,
                pub const strand = .{ .fields = .{ .left = .{ .aliases = &.{"right"} } } };
            };
            core.serialize(@as(T, .{ .left = 1, .right = 2 }), &backend, &c) catch unreachable;
        },
        2 => {
            _ = core.acquire(Required, .owned, std.testing.failing_allocator, "", .{}, required) catch unreachable;
        },
        3 => {
            _ = core.deserialize(EncodeOnly, &backend, &c) catch unreachable;
        },
        4 => core.serialize(@as(struct { hidden: ?Secret }, .{ .hidden = null }), &backend, &c) catch unreachable,
        5 => core.serialize(@as([*c]const u8, undefined), &backend, &c) catch unreachable,
        6 => {
            const Payload = struct {
                x: u8,
                pub const strand = .{ .fields = .{ .x = .{ .aliases = &.{"t"} } } };
            };
            const T = union(enum) {
                data: Payload,
                pub const strand = .{ .tag = "t" };
            };
            core.serialize(T{ .data = .{ .x = 1 } }, &backend, &c) catch unreachable;
        },
        7 => core.serialize(UnboundedHook{}, &backend, &c) catch unreachable,
        8 => {
            core.serialize(Legacy{}, &backend, &c) catch unreachable;
        },
        else => unreachable,
    }
}
