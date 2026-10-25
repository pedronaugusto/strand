//! A service's environment in a .env file, read as python-dotenv reads one:
//! comments, `export`, quotes, an escape, a value across lines, a key with
//! no value, `$` as text; read as a struct, as a map of its keys, and
//! written back.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- dotenv`
//! extracts the region between the dotenv markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Service = struct {
    DATABASE_URL: []const u8,
    PORT: u16,
    DEBUG: bool,
    GREETING: []const u8,
    TOKEN: []const u8,
    CERT: []const u8,
    PROXY: ?[]const u8 = null,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:dotenv ---

    const text =
        \\# The service.
        \\export DATABASE_URL=postgres://db:5432/app  # where the data is
        \\PORT = 8443
        \\DEBUG=yes
        \\GREETING="Hello,\n\tworld"
        \\TOKEN='s3cr3t-$keep'
        \\CERT='-----BEGIN-----
        \\abc
        \\-----END-----'
        \\PROXY
    ;
    var service = try strand.dotenv.parse(Service, gpa, text, .{});
    defer service.deinit();
    std.debug.assert(service.value.PORT == 8443);
    std.debug.assert(service.value.DEBUG);
    std.debug.assert(std.mem.eql(u8, service.value.GREETING, "Hello,\n\tworld"));
    // Nothing is expanded: `$keep` is text.
    std.debug.assert(std.mem.eql(u8, service.value.TOKEN, "s3cr3t-$keep"));
    std.debug.assert(service.value.PROXY == null);

    // Any file, as its keys in order, a key with no `=` null.
    var env = try strand.dotenv.parse(strand.core.Pairs([]const u8, ?[]const u8), gpa, text, .{});
    defer env.deinit();
    std.debug.assert(env.value.items.len == 7);

    // Written back, a value quoted only where it must be.
    var out: std.Io.Writer.Allocating = .init(gpa);
    const Banner = struct { NAME: []const u8, MOTD: []const u8, NOTE: []const u8 };
    try strand.dotenv.write(&out.writer, Banner{ .NAME = "relay", .MOTD = "Hello, world #1", .NOTE = "two\nlines" }, .{});
    std.debug.assert(std.mem.eql(u8, out.written(), "NAME=relay\nMOTD='Hello, world #1'\nNOTE=\"two\\nlines\"\n"));
    // --- README:dotenv ---

    std.log.info("dotenv:\n{s}", .{out.written()});
}
