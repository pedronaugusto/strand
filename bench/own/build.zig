const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "scratch_dir", b.option([]const u8, "scratch-dir", "Generated scratch directory") orelse "build/scratch-own");
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    const optimize = b.standardOptimizeOption(.{});
    const strand_dep = b.dependency("strand", .{ .target = target, .optimize = optimize });

    const ours = b.addExecutable(.{ .name = "strand-own-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "strand", .module = strand_dep.module("strand") }},
    }) });
    ours.root_module.addOptions("bench_options", options);
    b.installArtifact(ours);
}
