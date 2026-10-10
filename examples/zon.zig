//! A settings file read and written as ZON, the notation Zig writes its data in:
//! borrowed where the text can be, owned when it must outlive its source, and
//! refused with the line and column of the mistake when it is wrong.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- zon` extracts
//! the region between the zon markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Mode = enum { fast, careful };
const Settings = struct {
    name: []const u8,
    retries: u8 = 3,
    mode: Mode = .fast,
    tags: []const []const u8 = &.{},
    /// Present only when the file says so.
    limit: ?u32 = null,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:zon ---

    const source =
        \\// What to run, and how hard to try.
        \\.{
        \\    .name = "nightly build",
        \\    .mode = .careful,
        \\    .tags = .{ "linux", "release" },
        \\    .limit = 0x10_000,
        \\}
    ;

    // `name` and the tags are spans of `source`: nothing was copied for them.
    var settings = try strand.zon.parse(Settings, gpa, source, .{});
    defer settings.deinit();

    // Written back in Zig's own layout; a default is a field like any other.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.zon.write(&out.writer, settings.value, .{});

    // A mistake is an error that says where it was.
    var diagnostics: strand.core.Diagnostics = .{};
    const bad = ".{ .name = \"x\",\n   .retries = 300 }";
    if (strand.zon.parse(Settings, gpa, bad, .{ .diagnostics = &diagnostics })) |_| {
        unreachable; // unreachable: 300 does not fit a u8.
    } else |err| {
        std.log.info("{s}, line {d}", .{ @errorName(err), diagnostics.line.? });
    }
    // --- README:zon ---

    std.log.info("{s}: {d} retries, {s}, {d} tags, limit {?d}", .{
        settings.value.name,
        settings.value.retries,
        @tagName(settings.value.mode),
        settings.value.tags.len,
        settings.value.limit,
    });
    std.log.info("written:\n{s}", .{out.written()});
}
