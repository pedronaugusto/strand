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
    } },
    .{ .name = "core ownership", .patterns = &.{"src/core/owner.zig"} },
    .{ .name = "core public module", .patterns = &.{"src/core.zig"} },
    .{ .name = "JSON text", .patterns = &.{
        "src/json/work.zig",
        "src/json/text.zig",
        "src/json/control.zig",
        "src/json/member_scan.zig",
        "src/json/leading.zig",
        "src/json/indent.zig",
        "src/json/number.zig",
    } },
    .{ .name = "JSON wire", .patterns = &.{
        "src/json/Decoder.zig",
        "src/json/Encoder.zig",
        "src/json/Value.zig",
        "src/json/std_value.zig",
        "src/json/route.zig",
    } },
    .{ .name = "JSON module", .patterns = &.{"src/json/api.zig"} },
    .{ .name = "JSON facade", .patterns = &.{"src/json.zig"} },
    .{ .name = "JSONL schema", .patterns = &.{"src/jsonl/versioned.zig"} },
    .{ .name = "records", .patterns = &.{
        "src/jsonl/line.zig",
        "src/jsonl/Buffer.zig",
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
    .{ .name = "benchmark seam", .patterns = &.{"src/seam.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "strand", .path = "src/strand.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{
            "aegis",
            "airlock",
            "airlock.testing",
            "builtin",
            "rejection_options",
            "shakedown",
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
