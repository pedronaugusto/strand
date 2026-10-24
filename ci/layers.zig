//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "core bounds", .patterns = &.{"src/core/context.zig"} },
    .{ .name = "core vocabulary and schema", .patterns = &.{
        "src/core/model.zig",
        "src/core/scalars.zig",
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
        "src/json/indent.zig",
        "src/json/number.zig",
    } },
    .{ .name = "JSON wire", .patterns = &.{
        "src/json/Decoder.zig",
        "src/json/Encoder.zig",
        "src/json/Value.zig",
        "src/json/std_value.zig",
        "src/json/route.zig",
        "src/json/members.zig",
    } },
    .{ .name = "JSON module", .patterns = &.{"src/json/api.zig"} },
    .{ .name = "JSON canonical form", .patterns = &.{"src/json/canonical.zig"} },
    .{ .name = "JSON schema", .patterns = &.{"src/json/schema.zig"} },
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
    .{ .name = "URL-encoded text", .patterns = &.{"src/urlencoded/text.zig"} },
    .{ .name = "URL-encoded wire", .patterns = &.{ "src/urlencoded/Decoder.zig", "src/urlencoded/Encoder.zig" } },
    .{ .name = "URL-encoded module", .patterns = &.{"src/urlencoded/api.zig"} },
    .{ .name = "URL-encoded facade", .patterns = &.{"src/urlencoded.zig"} },
    .{ .name = "CSV text", .patterns = &.{"src/csv/text.zig"} },
    .{ .name = "CSV wire", .patterns = &.{ "src/csv/Decoder.zig", "src/csv/Encoder.zig" } },
    .{ .name = "CSV module", .patterns = &.{"src/csv/api.zig"} },
    .{ .name = "CSV facade", .patterns = &.{"src/csv.zig"} },
    .{ .name = "binary kernels", .patterns = &.{"src/binary/sorted.zig"} },
    .{ .name = "CBOR bytes", .patterns = &.{"src/cbor/wire.zig"} },
    .{ .name = "CBOR wire", .patterns = &.{ "src/cbor/Decoder.zig", "src/cbor/Encoder.zig" } },
    .{ .name = "CBOR values", .patterns = &.{ "src/cbor/Value.zig", "src/cbor/codecs.zig" } },
    .{ .name = "CBOR module", .patterns = &.{"src/cbor/api.zig"} },
    .{ .name = "CBOR facade", .patterns = &.{"src/cbor.zig"} },
    .{ .name = "MessagePack bytes", .patterns = &.{"src/msgpack/wire.zig"} },
    .{ .name = "MessagePack wire", .patterns = &.{ "src/msgpack/Decoder.zig", "src/msgpack/Encoder.zig" } },
    .{ .name = "MessagePack values", .patterns = &.{ "src/msgpack/codecs.zig", "src/msgpack/Value.zig" } },
    .{ .name = "MessagePack module", .patterns = &.{"src/msgpack/api.zig"} },
    .{ .name = "MessagePack facade", .patterns = &.{"src/msgpack.zig"} },
    .{ .name = "TOML text", .patterns = &.{ "src/toml/text.zig", "src/toml/number.zig", "src/toml/temporal.zig" } },
    .{ .name = "TOML syntax", .patterns = &.{"src/toml/syntax.zig"} },
    .{ .name = "TOML wire", .patterns = &.{ "src/toml/Decoder.zig", "src/toml/Encoder.zig" } },
    .{ .name = "TOML values", .patterns = &.{ "src/toml/codecs.zig", "src/toml/Value.zig" } },
    .{ .name = "TOML module", .patterns = &.{"src/toml/api.zig"} },
    .{ .name = "TOML facade", .patterns = &.{"src/toml.zig"} },
    .{ .name = "YAML text", .patterns = &.{ "src/yaml/scanner.zig", "src/yaml/schema.zig" } },
    .{ .name = "YAML events", .patterns = &.{"src/yaml/parser.zig"} },
    .{ .name = "YAML nodes", .patterns = &.{"src/yaml/document.zig"} },
    .{ .name = "YAML wire", .patterns = &.{ "src/yaml/Decoder.zig", "src/yaml/Encoder.zig" } },
    .{ .name = "YAML values", .patterns = &.{"src/yaml/Value.zig"} },
    .{ .name = "YAML module", .patterns = &.{"src/yaml/api.zig"} },
    .{ .name = "YAML facade", .patterns = &.{"src/yaml.zig"} },
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
            "other_aegis",
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
