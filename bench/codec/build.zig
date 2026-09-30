const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    const optimize = b.standardOptimizeOption(.{});
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const stringify = b.createModule(.{ .root_source_file = b.path("src/chronicle_bde5a26/stringify.zig"), .target = target, .optimize = optimize });
    const parse = b.createModule(.{ .root_source_file = b.path("src/chronicle_bde5a26/parse.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "codec-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/codec_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "strand", .module = strand },
            .{ .name = "chronicle_stringify", .module = stringify },
            .{ .name = "chronicle_parse", .module = parse },
        },
    }) });
    exe.root_module.addOptions("bench_options", options);
    b.installArtifact(exe);
}
