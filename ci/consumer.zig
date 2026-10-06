//! What a project that depends on strand and nothing else writes. Built by
//! `zig build check-consumer` with only the packages strand itself needs, so
//! strand's build.zig must work without any of its own CI dependencies.
const strand = @import("strand");

const Event = struct { kind: []const u8 };

pub fn main() void {
    _ = &strand.Reader(Event).init;
    _ = &strand.Writer(Event).init;
}
