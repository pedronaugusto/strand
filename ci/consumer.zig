//! What a project that depends on strand and nothing else writes, plain and
//! with `.schema = true`. Built by `zig build check-consumer` with only the
//! packages strand itself needs, so strand's build.zig must work without any
//! of its own CI dependencies; `strand_schema` is imported where the build
//! made it.
const strand = @import("strand");

const Event = struct { kind: []const u8 };

pub fn main() void {
    const json = strand.json;
    const jsonl = strand.jsonl;
    const core = strand.core;
    comptime {
        if (json.Raw.StrandRawFormat != json.Format or json.Parsed(Event) != core.Parsed(Event)) @compileError("facades must retain nominal type identity");
    }
    _ = &jsonl.Reader(Event).init;
    _ = &jsonl.Writer(Event).init;
    if (strand.built_with.schema) schema(@import("strand_schema"));
}

/// strand_schema's names, in the build that has them: compiling and
/// validating are analyzed whole, every format's recognizer among them, as a
/// consumer's build analyzes them with its own copies of the dependencies.
fn schema(comptime strand_schema: type) void {
    _ = strand_schema.Limits;
    _ = &strand_schema.Decimal.parse;
    _ = &Use(strand_schema).validateOnce;
}

fn Use(comptime strand_schema: type) type {
    return struct {
        fn validateOnce(gpa: @import("std").mem.Allocator, io: @import("std").Io) !bool {
            var s = try strand_schema.Schema.compile(gpa, io, strand.json, .init("{\"type\": \"string\", \"format\": \"uri\", \"pattern\": \"^h\"}"), .{ .formats = .assert });
            defer s.deinit();
            var errors: strand_schema.Schema.Errors = .{};
            return s.validate(io, gpa, strand.yaml, .init("http://example.com"), .{ .basic = &errors });
        }
    };
}
