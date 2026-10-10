//! A log written and then read back: events out through a `jsonl.Writer`,
//! events in through a `jsonl.Reader`, one line kept past the line it came
//! from, and a line routed by its first key without being parsed.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const strand = @import("strand");

/// One line of the log.
const Event = struct {
    kind: []const u8,
    at: u64,
    /// Absent from a line that has nothing to say.
    note: ?[]const u8 = null,
    /// Absent from an older line, and defaulted when it is.
    level: enum { info, warn } = .info,

    /// A note that is not there is not written.
    pub const strand = .{ .fields = .{ .note = .{ .omit = .null_value } } };
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- README:usage ---

    var out: std.Io.Writer.Allocating = .init(arena);
    var log: strand.jsonl.Writer(Event) = .init(&out.writer, .{});
    try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
    try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
    try log.write(.{ .kind = "close", .at = 3 });

    var source: std.Io.Reader = .fixed(out.written());
    var events: strand.jsonl.Reader(Event) = .init(arena, &source, .{
        .parse = .{ .ignore_unknown_fields = true },
        .max_line_bytes = 64 * 1024,
        .on_malformed = .fail,
    });
    defer events.deinit();

    var warnings: u32 = 0;
    // A kept value has an owner of its own, here on the arena.
    var last_open: ?strand.core.Parsed(Event) = null;
    while (try events.next()) |line| {
        if (std.mem.eql(u8, line.value.kind, "open")) {
            last_open = try events.keep(arena, line);
        }
        if (line.value.level == .warn) warnings += 1;
        std.log.info("line {d}: {s}", .{ line.number, line.line });
    }

    const kind = strand.json.kindOf("{\"kind\":\"open\",\"at\":1}");
    // --- README:usage ---

    std.log.info("read {d} lines, {d} warning(s)", .{ events.lines.number, warnings });
    std.log.info("kept past its line: {s} at {d}, note {?s}", .{
        last_open.?.value.kind,
        last_open.?.value.at,
        last_open.?.value.note,
    });
    std.log.info("first key without parsing: {?s}", .{kind});
}
