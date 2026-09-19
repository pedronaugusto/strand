const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, `std` only: nothing to link, nothing to vendor,
    // no build options, and so nothing a consumer has to match.
    //=====================================================================

    const module = b.addModule("strand", .{
        .root_source_file = b.path("src/strand.zig"),
        .target = target,
        .optimize = optimize,
    });

    //=====================================================================
    // Tests. Every one of them runs under `std.testing.allocator`, so a leak
    // or a double free is a failing test rather than a silent habit.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "strand-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/strand.zig"),
            .target = target,
            .optimize = optimize,
            // Off so that `zig build test --fuzz` compiles. The test runner
            // the compiler links in fuzz mode hands `@errorReturnTrace()` to
            // `std.debug.writeStackTrace`, and on 0.16.0 those are two
            // different `StackTrace` types; with error return tracing off the
            // branch is comptime-dead and the runner builds. The cost is the
            // return trace on a test that fails with an error it did not
            // expect — `std.testing`'s own reports are unaffected.
            .error_tracing = false,
        }),
    });

    // How much generated input the properties are run over, and which. The
    // default is what a `zig build test` should cost; a campaign is what CI
    // and a rainy afternoon are for. Only the test build has these, so the
    // module a consumer gets has no build options to match.
    const campaign = b.option(
        usize,
        "campaign",
        "Rounds of generated input for the fuzz properties (default 32)",
    ) orelse 32;
    const seed = b.option(u64, "seed", "Which rounds of generated input (default 0)") orelse 0;
    const test_options = b.addOptions();
    test_options.addOption(usize, "campaign", campaign);
    test_options.addOption(u64, "seed", seed);
    tests.root_module.addOptions("build_options", test_options);

    const test_step = b.step("test", "Run strand tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Compiling without running is what a target the host cannot execute can
    // still be held to, and it is the default step: a module on its own
    // installs nothing, so `zig build` would otherwise do no work at all.
    const check_step = b.step("check", "Compile the tests and examples without running them");
    check_step.dependOn(&tests.step);
    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the code does what the text around it says. examples/usage.zig
    // is also where README.md's Usage block comes from — see
    // ci/readme_usage.sh — so the snippet a reader copies is code CI
    // executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "strand", .module = module }},
            }),
        });
        examples_step.dependOn(&b.addRunArtifact(example).step);
        check_step.dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // Benchmark
    //
    // Its own step, and not one `test` depends on: a number that varies with
    // the machine is not a thing to fail a build over. It is still built by
    // `check`, so it cannot rot.
    //=====================================================================

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "strand", .module = module }},
        }),
    });
    const bench_step = b.step("bench", "Build and run the benchmark");
    bench_step.dependOn(&b.addRunArtifact(bench).step);
    check_step.dependOn(&bench.step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/logbook.zig",
};
