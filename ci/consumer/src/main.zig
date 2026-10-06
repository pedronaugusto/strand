const strand = @import("strand");

const Event = struct { kind: []const u8 };

pub fn main() void {
    _ = &strand.Reader(Event).init;
    _ = &strand.Writer(Event).init;
}
