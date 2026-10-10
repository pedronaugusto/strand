//! What a project that depends on strand and nothing else writes. Built by
//! `zig build check-consumer` with only the packages strand itself needs, so
//! strand's build.zig must work without any of its own CI dependencies.
const strand = @import("strand");

const Event = struct { kind: []const u8 };

pub fn main() void {
    const json = strand.json;
    const jsonl = strand.jsonl;
    const core = strand.core;
    comptime {
        if (json.Raw != core.Raw(json.Format) or json.Parsed(Event) != core.Parsed(Event)) @compileError("facades must retain nominal type identity");
    }
    _ = &jsonl.Reader(Event).init;
    _ = &jsonl.Writer(Event).init;
}
