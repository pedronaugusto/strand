//! A table of measurements as CSV: read whole by the header's names, written
//! back as RFC 4180 writes it, and streamed a row at a time.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- csv`
//! extracts the region between the csv markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Reading = struct {
    station: []const u8,
    celsius: f64,
    note: ?[]const u8 = null,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:csv ---

    // Columns in any order; a quoted field may hold commas, quotes and lines.
    const table =
        "celsius,station,note\r\n" ++
        "21.5,\"Lisbon, PT\",\r\n" ++
        "-3,Oslo,\"wind \"\"strong\"\"\"\r\n";
    var readings = try strand.csv.parse([]const Reading, gpa, table, .{});
    defer readings.deinit();
    std.debug.assert(std.mem.eql(u8, readings.value[0].station, "Lisbon, PT"));
    // An empty field is a null where the type takes one.
    std.debug.assert(readings.value[0].note == null);

    // Written in the struct's order, with RFC 4180's quoting.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.csv.write(&out.writer, readings.value, .{});
    std.debug.assert(std.mem.startsWith(u8, out.written(), "station,celsius,note\r\n\"Lisbon, PT\",21.5,\r\n"));

    // A row at a time off a reader, numbered, in a dialect of its own.
    var source: std.Io.Reader = .fixed("station;celsius\nRome;30\n");
    var rows: strand.csv.Reader(Reading) = .init(gpa, &source, .{ .parse = .{ .dialect = .{ .delimiter = ';' } } });
    defer rows.deinit();
    while (try rows.next()) |row| {
        std.debug.assert(row.number == 1);
        std.debug.assert(row.value.celsius == 30);
    }
    // --- README:csv ---

    std.log.info("csv: {s}", .{out.written()});
}
