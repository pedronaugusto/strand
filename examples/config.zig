//! A service's configuration as TOML: read into a struct, its dates and
//! times as types of their own, and written back.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- toml`
//! extracts the region between the toml markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Listener = struct { host: []const u8, port: u16 };
const Job = union(enum) {
    backup: struct { path: []const u8, keep: u8 = 7 },
    report: struct { to: []const u8 },
    pub const strand = .{ .tag = "kind" };
};
const Config = struct {
    name: []const u8,
    started: strand.toml.OffsetDateTime,
    quiet_from: ?strand.toml.LocalTime = null,
    listen: Listener,
    jobs: []const Job = &.{},
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:toml ---

    const text =
        \\name = "relay"
        \\started = 2026-10-14 09:30:00+01:00
        \\listen = { host = "0.0.0.0", port = 8_443 }
        \\
        \\[[jobs]]
        \\kind = "backup"
        \\path = "/var/relay"
        \\
        \\[[jobs]]
        \\kind = "report"
        \\to = "ops@example.com"
    ;
    var config = try strand.toml.parse(Config, gpa, text, .{});
    defer config.deinit();
    std.debug.assert(config.value.listen.port == 8443);
    std.debug.assert(config.value.started.offset_minutes == 60);
    std.debug.assert(config.value.jobs[0].backup.keep == 7);

    // Written back: values first, then each table under its header. TOML
    // has no null, so a null optional is left out only when asked.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.toml.write(&out.writer, config.value, .{ .allocator = gpa, .nulls = .omit });
    std.debug.assert(std.mem.startsWith(u8, out.written(), "name = \"relay\"\nstarted = 2026-10-14T09:30:00+01:00\n\n[listen]\n"));

    // Any document as a value, its four kinds of date and time kept apart.
    var value = try strand.toml.parse(strand.toml.Value, gpa, "day = 2026-10-14\nat = 07:30", .{});
    defer value.deinit();
    std.debug.assert(value.value.get("day").? == .local_date);
    std.debug.assert(value.value.get("at").?.local_time.hour == 7);
    // --- README:toml ---

    std.log.info("toml:\n{s}", .{out.written()});
}
