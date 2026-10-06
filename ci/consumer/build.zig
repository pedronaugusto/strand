const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const strand = b.dependency("strand", .{ .target = target });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{.{ .name = "strand", .module = strand.module("strand") }},
    }) });
    b.installArtifact(exe);
}
