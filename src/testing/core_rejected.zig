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
pub const Secret = struct {
    material: [16]u8,
    pub fn format(_: *const Secret, _: *std.Io.Writer) error{SecretNotFormattable}!void {
        return error.SecretNotFormattable;
    }
};
pub const UnboundedHook = struct {
    pub fn strandSerialize(_: UnboundedHook, _: anytype) anyerror!void {}
};
pub const StdHooks = struct {
    pub fn jsonStringify(_: StdHooks, _: anytype) error{}!void {}
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
            core.serialize(StdHooks{}, &backend, &c) catch unreachable;
        },
        9 => {
            // An aegis scalar of a later contract than strand reads: refused by
            // its number, never read as contract 1.
            const Later = enum(u16) {
                pub const aegis_scalar = .{ .contract = 2, .kind = .ranged, .representation = u16, .minimum = 1, .maximum = 64 };
                _,
            };
            core.serialize(@as(Later, @fromBackingInt(@intCast(1))), &backend, &c) catch unreachable;
        },
        // A text form declared, each part of it wrong: named at compile time.
        10 => {
            const NoParse = struct {
                pub const text_form = .{ .max_len = 8 };
                pub fn format(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
            };
            core.serialize(NoParse{}, &backend, &c) catch unreachable;
        },
        11 => {
            const Allocating = struct {
                pub const text_form = .{ .max_len = 8 };
                pub fn parse(_: std.mem.Allocator, _: []const u8) error{Malformed}!@This() {
                    return .{};
                }
                pub fn format(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
            };
            core.serialize(Allocating{}, &backend, &c) catch unreachable;
        },
        12 => {
            const LooseFormat = struct {
                pub const text_form = .{ .max_len = 8 };
                pub fn parse(_: []const u8) error{Malformed}!@This() {
                    return .{};
                }
                pub fn format(_: @This(), _: *std.Io.Writer) error{Unwritten}!void {}
            };
            core.serialize(LooseFormat{}, &backend, &c) catch unreachable;
        },
        13 => {
            const NoLength = struct {
                pub const text_form = .{ .schema_format = "date" };
                pub fn parse(_: []const u8) error{Malformed}!@This() {
                    return .{};
                }
                pub fn format(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
            };
            core.serialize(NoLength{}, &backend, &c) catch unreachable;
        },
        14 => {
            const Misspelled = struct {
                pub const text_form = .{ .max_len = 8, .maxlen = 8 };
                pub fn parse(_: []const u8) error{Malformed}!@This() {
                    return .{};
                }
                pub fn format(_: @This(), _: *std.Io.Writer) std.Io.Writer.Error!void {}
            };
            core.serialize(Misspelled{}, &backend, &c) catch unreachable;
        },
        15 => {
            // An aegis duration of a copy that declares no text form: refused,
            // never read as the enum it is held in.
            const OldDuration = enum(u64) {
                pub const aegis_scalar = .{ .contract = 1, .kind = .duration, .representation = u64, .unit = .millisecond };
                _,
            };
            core.serialize(@as(OldDuration, @fromBackingInt(@intCast(1))), &backend, &c) catch unreachable;
        },
        else => unreachable,
    }
}
