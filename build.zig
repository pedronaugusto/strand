const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig on `std` and airlock, which syncs the file under
    // a writer and tells one file from another for a follower: nothing to
    // link, nothing to vendor, no build options, and so nothing a consumer
    // has to match.
    //=====================================================================

    const airlock_dependency = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const module = b.addModule("strand", .{
        .root_source_file = b.path("src/strand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "airlock", .module = airlock }},
    });

    // The core's build has no runtime import or link to durability or tooling.
    const core_module = b.addModule("strand.core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Everything below is strand's own: a project depending on strand
    // neither builds nor fetches its tests, benchmarks or CI.
    if (b.pkg_hash.len != 0) return;

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
            .imports = &.{.{ .name = "airlock", .module = airlock }},
        }),
    });
    // shakedown, and airlock's seam on it, are lazy and test-only: no
    // module a consumer builds imports them. Their error is returned last,
    // so one configure pass asks for them and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    if (airlock_build.testing(airlock_dependency)) |seam| {
        tests.root_module.addImport("airlock.testing", seam);
    } else |err| needed = err;

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

    if (test_filter == null or std.mem.find(u8, "S1", test_filter.?) != null) {
        const expected = [_][]const u8{
            "error: : resource or secret is not automatic data", "error: wire alias collision at left",               "error: owned decoding conflicts with borrow.require at label",
            "error: : explicit data codec",                      "error: : resource or secret is not automatic data", "error: : pointer has no safe data meaning",
        };
        for (expected, 0..) |message, case| {
            const rejection_options = b.addOptions();
            rejection_options.addOption(usize, "case", case);
            const rejected = b.addObject(.{
                .name = b.fmt("core-rejected-{d}", .{case}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/testing/core_rejected.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "strand.core", .module = core_module }},
                }),
            });
            rejected.root_module.addOptions("rejection_options", rejection_options);
            rejected.expect_errors = .{ .contains = message };
            test_step.dependOn(&rejected.step);
            check_step.dependOn(&rejected.step);
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
    // Benchmarks
    //
    // Never timed by `zig build test`: a number that varies with the
    // machine is not a thing to fail a build over. preflight's `bench` runs
    // bench/bench.zig in ReleaseFast; the tests run it once with `--smoke`.
    // bench_scratch.zig's own tests check the scratch files it writes.
    //=====================================================================

    // Explicit manual measurement, compiled without timing by the check graph.
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = .fast })) |dependency| {
        const baseline = b.addExecutable(.{
            .name = "strand-baseline",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/baseline.zig"),
                .target = target,
                .optimize = .fast,
                .imports = benchImports(b, target, .fast),
            }),
        });
        baseline.root_module.addImport("shakedown", dependency.module("shakedown"));
        const proof_module = b.createModule(.{ .root_source_file = b.path("src/core_test.zig"), .target = target, .optimize = .fast, .imports = &.{.{ .name = "shakedown", .module = dependency.module("shakedown") }} });
        const core_bench = b.addExecutable(.{
            .name = "strand-core-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/core.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "proof", .module = proof_module },
                    .{ .name = "shakedown", .module = dependency.module("shakedown") },
                },
            }),
        });
        b.step("core-bench-build", "Compile paired manual reference observations").dependOn(&b.addInstallArtifact(core_bench, .{}).step);
        check_step.dependOn(&core_bench.step);
        const install = b.addInstallArtifact(baseline, .{});
        b.step("baseline-build", "Compile the manual legacy timing driver").dependOn(&install.step);
        check_step.dependOn(&baseline.step);
    } else |err| needed = err;

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

    //=====================================================================
    // CI wiring
    //
    // preflight is a lazy dependency, and a lazy package's build.zig can
    // only be reached through `lazyImport`: a plain `@import` of it fails to
    // compile in any project that depends on strand and has not fetched
    // preflight, which is every such project.
    //=====================================================================

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{.{ .name = "strand-bench", .source = "bench/bench.zig" }},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on strand by path, with airlock and
        // nothing else to fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{
            .package = "strand",
            .program = b.path("ci/consumer.zig"),
            .packages = &.{b.dependency("airlock", .{})},
        });
    }
    return needed;
}

/// strand and airlock again, in the mode a benchmark builds in: an
/// imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const airlock = b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const strand = b.createModule(.{
        .root_source_file = b.path("src/strand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "airlock", .module = airlock }},
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "strand", .module = strand }}) catch @panic("OOM");
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/logbook.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.
