//! A log written and then read back: events out through a `zjsonl.Writer`,
//! events in through a `zjsonl.Reader`, one line kept past the line it came
//! from, and a line routed by its first key without being parsed.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const zjsonl = @import("zjsonl");

/// One line of the log.
const Event = struct {
    kind: []const u8,
    at: u64,
    /// Absent from a line that has nothing to say.
    note: ?[]const u8 = null,
    /// Absent from an older line, and defaulted when it is.
    level: enum { info, warn } = .info,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- README:usage ---

    // Write: one JSON value per line, minified, null optionals left out.
    var out: std.Io.Writer.Allocating = .init(arena);
    var log: zjsonl.Writer(Event) = .init(&out.writer, .{});
    try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
    try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
    try log.write(.{ .kind = "close", .at = 3 });

    // Read: a stream of typed lines, each with its number and its bytes.
    var source: std.Io.Reader = .fixed(out.written());
    var events: zjsonl.Reader(Event) = .init(std.heap.page_allocator, &source, .{
        // Defaults, spelled out: a line the reader does not fully understand
        // is still a line, and one it cannot parse at all names itself.
        .ignore_unknown_fields = true,
        .max_line_bytes = 64 * 1024,
        .on_malformed = .fail,
    });
    defer events.deinit();

    var warnings: u32 = 0;
    var last_open: ?Event = null;
    while (try events.next()) |line| {
        // `line.value` is valid until the next `next`: its strings point into
        // `line.line`, which the reader reuses. `keep` copies one out.
        if (std.mem.eql(u8, line.value.kind, "open")) {
            last_open = try events.keep(line, arena);
        }
        if (line.value.level == .warn) warnings += 1;
        std.debug.print("line {d}: {s}\n", .{ line.number, line.line });
    }

    // Route a line by its first key, without parsing the value.
    const kind = zjsonl.kindOf("{\"kind\":\"open\",\"at\":1}");
    // --- README:usage ---

    std.debug.print("read {d} lines, {d} warning(s)\n", .{ events.number, warnings });
    std.debug.print("kept past its line: {s} at {d}, note {?s}\n", .{
        last_open.?.kind,
        last_open.?.at,
        last_open.?.note,
    });
    std.debug.print("first key without parsing: {?s}\n", .{kind});
}
