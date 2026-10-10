//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "core bounds", .patterns = &.{"src/core/context.zig"} },
    .{ .name = "core vocabulary and schema", .patterns = &.{
        "src/core/model.zig",
        "src/core/descriptor.zig",
        "src/core/codecs.zig",
    } },
    .{ .name = "core mapping", .patterns = &.{
        "src/core/decode.zig",
        "src/core/encode.zig",
        "src/core/compat.zig",
    } },
    .{ .name = "core ownership", .patterns = &.{"src/core/owner.zig"} },
    .{ .name = "core public module", .patterns = &.{"src/core.zig"} },
    .{ .name = "primitives", .patterns = &.{
        "src/json/encode/Buffer.zig",
        "src/json/encode.zig",
        "src/json/indent.zig",
        "src/json/int.zig",
        "src/json/leading.zig",
        "src/json/member_scan.zig",
        "src/jsonl/owned.zig",
        "src/json/route.zig",
        "src/json/Scanner.zig",
        "src/json/tagging.zig",
        "src/json/output.zig",
        "src/json/work.zig",
    } },
    .{ .name = "decoding and conversion", .patterns = &.{
        "src/json/control.zig",
        "src/json/decode.zig",
        "src/json/from_value.zig",
        "src/json/parse.zig",
        "src/json/raw.zig",
    } },
    .{ .name = "parsing and schema", .patterns = &.{
        "src/json/parse/line.zig",
    } },
    .{ .name = "codec assembly", .patterns = &.{
        "src/json/codec.zig",
    } },
    .{ .name = "JSON wire", .patterns = &.{ "src/json/number.zig", "src/json/Decoder.zig", "src/json/Encoder.zig", "src/json/Value.zig", "src/json/std_value.zig" } },
    .{ .name = "JSON module", .patterns = &.{"src/json/api.zig"} },
    .{ .name = "JSON facade", .patterns = &.{"src/json.zig"} },
    .{ .name = "JSONL schema", .patterns = &.{"src/jsonl/versioned.zig"} },
    .{ .name = "records", .patterns = &.{
        "src/jsonl/line.zig",
    } },
    .{ .name = "framing boundaries", .patterns = &.{"src/jsonl/framing.zig"} },
    .{ .name = "line framing", .patterns = &.{
        "src/jsonl/line/reader.zig",
        "src/jsonl/tail.zig",
        "src/jsonl/writer.zig",
    } },
    .{ .name = "typed streams", .patterns = &.{
        "src/jsonl/reader.zig",
        "src/jsonl/decoder.zig",
    } },
    .{ .name = "following", .patterns = &.{
        "src/jsonl/follow.zig",
    } },
    .{ .name = "JSON Lines module", .patterns = &.{"src/jsonl/api.zig"} },
    .{ .name = "JSONL facade", .patterns = &.{"src/jsonl.zig"} },
    .{ .name = "ZON text", .patterns = &.{ "src/zon/text.zig", "src/zon/number.zig" } },
    .{ .name = "ZON wire", .patterns = &.{ "src/zon/Decoder.zig", "src/zon/Encoder.zig" } },
    .{ .name = "ZON module", .patterns = &.{"src/zon/api.zig"} },
    .{ .name = "ZON facade", .patterns = &.{"src/zon.zig"} },
    .{ .name = "public", .patterns = &.{
        "src/strand.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "strand.owned", .path = "src/jsonl/owned.zig" },
    .{ .name = "strand.core", .path = "src/core.zig" },
    .{ .name = "mapping", .path = "src/core/compat.zig" },
    .{ .name = "json", .path = "src/json/api.zig" },
    .{ .name = "strand.json", .path = "src/json.zig" },
    .{ .name = "strand.jsonl", .path = "src/jsonl.zig" },
    .{ .name = "jsonl", .path = "src/jsonl/api.zig" },
    .{ .name = "strand.zon", .path = "src/zon.zig" },
    .{ .name = "zon", .path = "src/zon/api.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{
            "aegis",
            "airlock",
            "airlock.testing",
            "build_options",
            "builtin",
            "rejection_options",
            "shakedown",
            // gantry reads a name that ends `.zon` as a ZON file beside the importer,
            // so it cannot see this module, which `modules` below does name.
            "strand.zon",
            "std",
        },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};

/// Tokens nothing here may spell: how a file is made durable and how one is
/// identified belong to airlock, and strand calls it.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "durability belongs to airlock", .tokens = &.{
        "fsync",
        "fdatasync",
        "F_FULLFSYNC",
        "FULLFSYNC",
        "F_BARRIERFSYNC",
        "BARRIERFSYNC",
        "FlushFileBuffers",
        "NtFlushBuffersFile",
        "NtFlushBuffersFileEx",
        "createFileAtomic",
    } },
    .{ .name = "file identity belongs to airlock", .tokens = &.{ "statx", "fstat", "fstatat", "FILE_ID_INFO" } },
};
