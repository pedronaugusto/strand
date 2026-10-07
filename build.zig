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

    // A follower's cancellation is a second task ending a wait the first is
    // in, so it is the one claim here a race detector can check rather than
    // a reader: `zig build test -Dthread-sanitizer`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "strand-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = if (thread_sanitizer) true else null,
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

    const scratch_tests = b.addTest(.{
        .name = "logbook-scratch-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/scratch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(scratch_tests).step);

    // Compiling without running is what a target the host cannot execute can
    // still be held to, and it is the default step: a module on its own
    // installs nothing, so `zig build` would otherwise do no work at all.
    const check_step = b.step("check", "Compile the tests and examples without running them");
    check_step.dependOn(&tests.step);
    check_step.dependOn(&scratch_tests.step);
    b.getInstallStep().dependOn(check_step);

    // A null optional or inactive union arm must not hide an unsupported
    // field type. The same gate applies to copying and freeing. Run these
    // with the ownership tests, and in the full and compile-only suites.
    if (test_filter == null or std.mem.find(u8, "owned", test_filter.?) != null) {
        for (0..17) |case| {
            for ([_]bool{ false, true }) |free_only| {
                const rejection_options = b.addOptions();
                rejection_options.addOption(usize, "case", case);
                rejection_options.addOption(bool, "free_only", free_only);
                const rejected = b.addObject(.{
                    .name = b.fmt("owned-rejected-{d}-{s}", .{ case, if (free_only) "free" else "copy" }),
                    .root_module = b.createModule(.{
                        .root_source_file = b.path("src/testing/owned_rejected.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{.{ .name = "strand.owned", .module = b.createModule(.{
                            .root_source_file = b.path("src/owned.zig"),
                            .target = target,
                            .optimize = optimize,
                        }) }},
                    }),
                });
                rejected.root_module.addOptions("rejection_options", rejection_options);
                rejected.expect_errors = .{ .contains = "cannot be copied by copyOwned" };
                test_step.dependOn(&rejected.step);
                check_step.dependOn(&rejected.step);
            }
        }
    }

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what
    // proves the code does what the text around it says. examples/usage.zig
    // is also where README.md's Usage block comes from — see
    // zig build docs -- usage — so the snippet a reader copies is code CI
    // executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
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
    // CI wiring
    //
    // Only in strand's own tree. preflight is a lazy dependency, and a lazy
    // package's build.zig can only be reached through `lazyImport`: a plain
    // `@import` of it fails to compile in any project that depends on strand
    // and has not fetched preflight, which is every such project.
    //=====================================================================

    if (b.pkg_hash.len != 0) return;

    //=====================================================================
    // Benchmarks
    //
    // Only in strand's own tree, and never part of `zig build test`: a
    // number that varies with the machine is not a thing to fail a build
    // over. `check` compiles them so they keep up with the API; `bench`
    // runs them. Numbers worth reading come from -Doptimize=fast.
    //=====================================================================

    const bench_options = b.addOptions();
    bench_options.addOption(bool, "smoke", b.option(
        bool,
        "bench-smoke",
        "Run the benchmarks once over tiny inputs, without reading a clock",
    ) orelse false);
    const bench = b.addExecutable(.{
        .name = "strand-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "strand", .module = module }},
        }),
    });
    bench.root_module.addOptions("bench_options", bench_options);
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    b.step("bench", "Run the benchmarks").dependOn(&bench_run.step);
    check_step.dependOn(&bench.step);
    const bench_tests = b.addTest(.{
        .name = "strand-bench-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_scratch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    check_step.dependOn(&bench_tests.step);

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // A project that depends on strand by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "strand", .program = b.path("ci/consumer.zig") });
    }
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/logbook.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
