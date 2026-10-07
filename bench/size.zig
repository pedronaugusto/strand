//! How much each measurement runs over: the full sizes, timed, or one pass
//! at the smallest under `--smoke`, which `zig build test` runs to keep the
//! program working and which reads no clock.
const std = @import("std");

pub const Size = struct {
    smoke: bool,
    /// Lines written, read and carried.
    lines: usize,
    /// The one big line's length.
    big_line_bytes: usize,
    /// Lines of the mixed read, and how many times it runs.
    mixed_lines: usize,
    mixed_rounds: usize,
    /// Records synced one by one.
    synced_records: usize,
    /// Looks at one handle's identity.
    identity_looks: usize,

    /// The sizes `args` ask for: `--smoke`, or none.
    pub fn of(args: []const []const u8) error{UnknownArgument}!Size {
        var smoke = false;
        for (args) |arg| {
            if (!std.mem.eql(u8, arg, "--smoke")) return error.UnknownArgument;
            smoke = true;
        }
        if (smoke) return .{
            .smoke = true,
            .lines = 1,
            .big_line_bytes = 64,
            .mixed_lines = 5,
            .mixed_rounds = 1,
            .synced_records = 1,
            .identity_looks = 1,
        };
        return .{
            .smoke = false,
            .lines = 1_000_000,
            .big_line_bytes = 100 << 20,
            .mixed_lines = 120_000,
            .mixed_rounds = 15,
            .synced_records = 500,
            .identity_looks = 200_000,
        };
    }

    /// When a measurement starts; nothing under `--smoke`.
    pub fn now(size: Size, io: std.Io) std.Io.Timestamp {
        if (size.smoke) return .{ .nanoseconds = 0 };
        return std.Io.Clock.awake.now(io);
    }

    /// How long since `started`; a nanosecond under `--smoke`.
    pub fn since(size: Size, started: std.Io.Timestamp, io: std.Io) std.Io.Duration {
        if (size.smoke) return .fromNanoseconds(1);
        return started.untilNow(io, .awake);
    }
};
