//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/encode/Buffer.zig",
        "src/encode.zig",
        "src/file_id.zig",
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
        "src/sync.zig",
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

pub const modules: []const gantry.NamedModule = &.{.{ .name = "strand.owned", .path = "src/owned.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "build_options",
        "builtin",
        "rejection_options",
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

/// Tokens only their owners may spell: how a file is made durable and how
/// one is identified each have one file.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "sync owner", .token = "fsync", .owners = &.{"src/sync.zig"} },
    .{ .name = "sync owner", .token = "fdatasync", .owners = &.{"src/sync.zig"} },
    .{ .name = "sync owner", .token = "F_FULLFSYNC", .owners = &.{"src/sync.zig"} },
    .{ .name = "sync owner", .token = "FlushFileBuffers", .owners = &.{"src/sync.zig"} },
    .{ .name = "file identity owner", .token = "statx", .owners = &.{"src/file_id.zig"} },
    .{ .name = "file identity owner", .token = "fstat", .owners = &.{"src/file_id.zig"} },
    .{ .name = "file identity owner", .token = "FILE_ID_INFO", .owners = &.{"src/file_id.zig"} },
};
