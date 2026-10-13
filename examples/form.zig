//! A search form, as a browser submits it or a link carries it in its query:
//! names with bracketed paths read into nested structs, repeated names into
//! a slice, and written back as a browser would write them.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- form`
//! extracts the region between the form markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Search = struct {
    q: []const u8,
    page: u32 = 1,
    tag: []const []const u8 = &.{},
    filter: struct { lang: []const u8 = "any", stars: ?u16 = null } = .{},
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:form ---

    // `+` is a space, `%XX` a byte; the brackets may come encoded or not.
    const query = "q=zig+serde&tag=json&filter%5Blang%5D=zig&tag=toml&filter[stars]=100";
    var search = try strand.urlencoded.parse(Search, gpa, query, .{});
    defer search.deinit();
    std.debug.assert(std.mem.eql(u8, search.value.q, "zig serde"));
    std.debug.assert(search.value.tag.len == 2);
    std.debug.assert(search.value.filter.stars.? == 100);

    // Written as a browser's form serializer writes it.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.urlencoded.write(&out.writer, search.value, .{});
    std.debug.assert(std.mem.eql(u8, out.written(), "q=zig+serde&page=1&tag=json&tag=toml&filter%5Blang%5D=zig&filter%5Bstars%5D=100"));

    // A name given twice where one value belongs is refused.
    if (strand.urlencoded.parse(Search, gpa, "q=a&q=b", .{})) |_| {
        unreachable; // unreachable: `q` holds one value.
    } else |err| std.debug.assert(err == error.DuplicateField);
    // --- README:form ---

    std.log.info("form: {s}", .{out.written()});
}
