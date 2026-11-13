//! The official meta-schemas of the dialects strand_schema reads, embedded,
//! so a schema naming one by `$schema` or `$ref` compiles with no loader.
//! The files are json-schema-spec's, under its LICENSE (`metaschemas/`).
const std = @import("std");

pub const Document = struct {
    /// Its `$id`, with no fragment: the URI it is found by.
    uri: []const u8,
    bytes: []const u8,
};

pub const all = [_]Document{
    .{ .uri = "https://json-schema.org/draft/2020-12/schema", .bytes = @embedFile("metaschemas/draft2020-12/schema.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .bytes = @embedFile("metaschemas/draft2020-12/meta/core.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .bytes = @embedFile("metaschemas/draft2020-12/meta/applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .bytes = @embedFile("metaschemas/draft2020-12/meta/unevaluated.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .bytes = @embedFile("metaschemas/draft2020-12/meta/validation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .bytes = @embedFile("metaschemas/draft2020-12/meta/meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .bytes = @embedFile("metaschemas/draft2020-12/meta/format-annotation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-assertion", .bytes = @embedFile("metaschemas/draft2020-12/meta/format-assertion.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .bytes = @embedFile("metaschemas/draft2020-12/meta/content.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/schema", .bytes = @embedFile("metaschemas/draft2019-09/schema.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/core", .bytes = @embedFile("metaschemas/draft2019-09/meta/core.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/applicator", .bytes = @embedFile("metaschemas/draft2019-09/meta/applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/validation", .bytes = @embedFile("metaschemas/draft2019-09/meta/validation.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/meta-data", .bytes = @embedFile("metaschemas/draft2019-09/meta/meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/format", .bytes = @embedFile("metaschemas/draft2019-09/meta/format.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/content", .bytes = @embedFile("metaschemas/draft2019-09/meta/content.json") },
    .{ .uri = "http://json-schema.org/draft-07/schema", .bytes = @embedFile("metaschemas/draft-07/schema.json") },
};

/// The embedded document at `uri` (no fragment), if strand has it.
pub fn get(uri: []const u8) ?[]const u8 {
    for (all) |d| if (std.mem.eql(u8, d.uri, uri)) return d.bytes;
    return null;
}

test "each embedded document is found by its own `$id`" {
    for (all) |d| {
        const key = "\"$id\": \"";
        const at = std.mem.find(u8, d.bytes, key).? + key.len;
        const end = std.mem.findScalarPos(u8, d.bytes, at, '"').?;
        const id = std.mem.trimEnd(u8, d.bytes[at..end], "#");
        try std.testing.expectEqualStrings(d.uri, id);
        try std.testing.expect(get(id).?.ptr == d.bytes.ptr);
    }
    try std.testing.expect(get("https://json-schema.org/draft/2020-12/meta/hyper-schema") == null);
}
