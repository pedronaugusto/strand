//! A build tool's settings in JSON5, as a person keeps them: comments,
//! unquoted keys, single quotes, a string continued on the next line,
//! hexadecimal, a trailing comma and `Infinity`; read as a struct, read as
//! `json.Value` with its numbers as written, and written back as JSON5.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- json5`
//! extracts the region between the json5 markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Settings = struct {
    name: []const u8,
    jobs: u8,
    umask: u16,
    timeout: f64,
    targets: []const []const u8,
    banner: []const u8,
};

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:json5 ---

    const text =
        \\// The build's settings.
        \\{
        \\  name: 'relay',
        \\  jobs: +8,
        \\  umask: 0x1ED,           // 0755
        \\  timeout: Infinity,      /* no limit */
        \\  targets: ['linux', "macos",],
        \\  banner: 'Built by \
        \\the relay',
        \\}
    ;
    var settings = try strand.json.json5.parse(Settings, gpa, text, .{});
    defer settings.deinit();
    std.debug.assert(settings.value.umask == 0o755);
    std.debug.assert(std.math.isPositiveInf(settings.value.timeout));
    std.debug.assert(std.mem.eql(u8, settings.value.banner, "Built by the relay"));

    // Any document: a number stays as it was written.
    var value = try strand.json.json5.parse(strand.json.Value, gpa, text, .{});
    defer value.deinit();
    std.debug.assert(std.mem.eql(u8, value.value.object[2].value.number, "0x1ED"));

    // Written as JSON, but for the floats JSON cannot spell.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.json.json5.write(&out.writer, settings.value, .{});
    std.debug.assert(std.mem.eql(u8, out.written(),
        \\{"name":"relay","jobs":8,"umask":493,"timeout":Infinity,"targets":["linux","macos"],"banner":"Built by the relay"}
    ));
    // --- README:json5 ---

    std.log.info("json5: {s}", .{out.written()});
}
