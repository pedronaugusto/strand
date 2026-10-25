//! A service's settings as INI, in Python configparser's dialect: keys
//! before the first section, sections as structs, a value continued on
//! indented lines, configparser's booleans, keys lowercased, and the same
//! settings written back; then any document as `ini.Value`.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- ini`
//! extracts the region between the ini markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Settings = struct {
    name: []const u8,
    debug: bool = false,
    server: struct { host: []const u8, port: u16 },
    banner: struct { text: []const u8 = "" },
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:ini ---

    const text =
        \\# relay's settings
        \\name = relay
        \\Debug = yes
        \\
        \\[server]
        \\host = 0.0.0.0
        \\port: 8443
        \\
        \\[banner]
        \\text = Welcome
        \\    to relay
    ;
    var settings = try strand.ini.parse(Settings, gpa, text, .{});
    defer settings.deinit();
    std.debug.assert(settings.value.debug);
    std.debug.assert(settings.value.server.port == 8443);
    std.debug.assert(std.mem.eql(u8, settings.value.banner.text, "Welcome\nto relay"));

    // Written back: keys first, then each section; a continued value on
    // tab-indented lines.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.ini.write(&out.writer, settings.value, .{});
    std.debug.assert(std.mem.eql(u8, out.written(), "name = relay\ndebug = true\n\n[server]\nhost = 0.0.0.0\nport = 8443\n\n[banner]\ntext = Welcome\n\tto relay\n"));

    // Any document, in another dialect: comments after values, keys with
    // no value. No interpolation: `%(name)s` is text.
    const dialect: strand.ini.Dialect = .{ .inline_comment_prefixes = &.{";"}, .keys_without_values = true };
    var value = try strand.ini.parse(strand.ini.Value, gpa, "[mysqld]\nskip-networking\nuser = %(name)s ; who runs it\n", .{ .dialect = dialect });
    defer value.deinit();
    const mysqld = value.value.section("mysqld").?;
    std.debug.assert(mysqld[0].value == .none);
    std.debug.assert(std.mem.eql(u8, strand.ini.Value.text(mysqld, "user").?, "%(name)s"));
    // --- README:ini ---

    std.log.info("ini:\n{s}", .{out.written()});
}
