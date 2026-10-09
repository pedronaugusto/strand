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
    .{ .name = "primitives", .patterns = &.{
        "src/encode/Buffer.zig",
        "src/encode.zig",
        "src/indent.zig",
        "src/int.zig",
        "src/leading.zig",
        "src/member_scan.zig",
        "src/owned.zig",
        "src/route.zig",
        "src/Scanner.zig",
        "src/tagging.zig",
        "src/value_api.zig",
        "src/work.zig",
    } },
    .{ .name = "decoding and conversion", .patterns = &.{
        "src/control.zig",
        "src/decode.zig",
        "src/from_value.zig",
        "src/parse.zig",
        "src/raw.zig",
    } },
    .{ .name = "parsing and schema", .patterns = &.{
        "src/parse/line.zig",
        "src/versioned.zig",
    } },
    .{ .name = "codec assembly", .patterns = &.{
        "src/codec.zig",
    } },
    .{ .name = "records", .patterns = &.{
        "src/line.zig",
    } },
    .{ .name = "line framing", .patterns = &.{
        "src/line/reader.zig",
        "src/tail.zig",
        "src/writer.zig",
    } },
    .{ .name = "typed streams", .patterns = &.{
        "src/reader.zig",
    } },
    .{ .name = "following", .patterns = &.{
        "src/follow.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/strand.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "strand.owned", .path = "src/owned.zig" },
    .{ .name = "strand.core", .path = "src/core.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "airlock",
        "airlock.testing",
        "build_options",
        "builtin",
        "rejection_options",
        "shakedown",
        "std",
    } },
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
