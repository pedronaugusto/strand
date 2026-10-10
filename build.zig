const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig on `std`, aegis (the checked work in the core) and
    // airlock (which syncs the file under a writer and tells one file from
    // another for a follower): nothing to link, nothing to vendor, no build
    // options, and so nothing a consumer has to match. core, json, jsonl and
    // zon are namespaces of it, not modules of their own: every user fetches
    // the same two packages whichever part they take, no part links anything,
    // and Zig analyzes only the part a program names. The layering inside is
    // ci/layers.zig's, checked at file level.
    //=====================================================================

    const airlock_dependency = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const module = b.addModule("strand", .{
        .root_source_file = b.path("src/strand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock } },
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
            .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock } },
        }),
    });
    // shakedown, and airlock's seam on it, are lazy and test-only: no
    // module a consumer builds imports them. Their error is returned last,
    // so one configure pass asks for them and for preflight together.
    // One shakedown in the graph: the one airlock's seam is built on.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (airlock_build.testing(airlock_dependency)) |seam| {
        tests.root_module.addImport("airlock.testing", seam);
        tests.root_module.addImport("shakedown", seam.import_table.get("shakedown").?);
    } else |err| needed = err;

    const test_step = b.step("test", "Run strand tests");
    // The assembly reaches every test once, in one executable.
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

    const json_consumer = b.addExecutable(.{
        .name = "json-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/json-consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "strand", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(json_consumer).step);
    check_step.dependOn(&json_consumer.step);

    // A null optional or inactive union arm must not hide an unsupported
    // field type from a checked copy. Run these with the ownership tests,
    // and in the full and compile-only suites.
    if (test_filter == null or std.mem.find(u8, "owned", test_filter.?) != null) {
        for (clone_rejections, 0..) |message, case| {
            const rejection_options = b.addOptions();
            rejection_options.addOption(usize, "case", case);
            const rejected = b.addObject(.{
                .name = b.fmt("clone-rejected-{d}", .{case}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/testing/clone_rejected.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "strand", .module = module }},
                }),
            });
            rejected.root_module.addOptions("rejection_options", rejection_options);
            rejected.expect_errors = .{ .contains = message };
            test_step.dependOn(&rejected.step);
            check_step.dependOn(&rejected.step);
        }
    }

    if (test_filter == null or std.mem.find(u8, "S1", test_filter.?) != null) {
        const expected = [_][]const u8{
            "error: : resource or secret is not automatic data", "error: wire alias collision at left",               "error: owned decoding conflicts with borrow.require at label",
            "error: : explicit data codec",                      "error: : resource or secret is not automatic data", "error: : pointer has no safe data meaning",
            "error: tag collides with payload alias",            "error: data codecs require a named error set",      "error: : std.json hooks are not read here; declare strandDeserialize and strandSerialize",
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
                    .imports = &.{.{ .name = "strand", .module = module }},
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

    // The benchmarks are timed, and smoke-run by the tests, in ReleaseFast. A
    // target this host cannot run is only held to compiling them, and a debug
    // compile analyses the same source for a fraction of the optimizer's time,
    // which is most of what a cross-target check costs.
    const host = b.graph.host.result;
    const runs_here = target.result.cpu.arch == host.cpu.arch and target.result.os.tag == host.os.tag;
    const bench_mode: std.lang.Optimize = if (runs_here or optimize != .debug) .fast else .debug;

    // Explicit manual measurement, compiled without timing by the check graph.
    if (shakedownFor(b, target, bench_mode)) |dependency| {
        const s2_bench = b.addExecutable(.{
            .name = "strand-s2-bench",
            .root_module = b.createModule(.{ .root_source_file = b.path("bench/s2.zig"), .target = target, .optimize = bench_mode, .imports = &.{.{ .name = "seam", .module = benchSeam(b, target, bench_mode) }} }),
        });
        s2_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("s2-bench-build", "Compile explicit paired S2 observations").dependOn(&b.addInstallArtifact(s2_bench, .{}).step);
        check_step.dependOn(&s2_bench.step);
        const zon_bench = b.addExecutable(.{
            .name = "strand-zon-bench",
            .root_module = b.createModule(.{ .root_source_file = b.path("bench/zon.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        zon_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("zon-bench-build", "Compile explicit paired ZON observations against std.zon").dependOn(&b.addInstallArtifact(zon_bench, .{}).step);
        check_step.dependOn(&zon_bench.step);
        const zon_smoke = b.addRunArtifact(zon_bench);
        zon_smoke.addArg("--smoke");
        test_step.dependOn(&zon_smoke.step);
        const s2_smoke = b.addRunArtifact(s2_bench);
        s2_smoke.addArg("--smoke");
        test_step.dependOn(&s2_smoke.step);
        inline for (.{ "core", "hand" }) |which| {
            const schema_options = b.addOptions();
            schema_options.addOption(bool, "common", comptime std.mem.eql(u8, which, "core"));
            const schema = b.addExecutable(.{
                .name = "strand-schema-" ++ which,
                .root_module = b.createModule(.{ .root_source_file = b.path("bench/schema.zig"), .target = target, .optimize = bench_mode, .imports = &.{.{ .name = "seam", .module = s2_bench.root_module.import_table.get("seam").? }} }),
            });
            schema.root_module.addOptions("schema_options", schema_options);
            b.step("schema-" ++ which ++ "-build", "Compile ten 100-field checked JSON encoders").dependOn(&b.addInstallArtifact(schema, .{}).step);
            check_step.dependOn(&schema.step);
            test_step.dependOn(&b.addRunArtifact(schema).step);
        }
        const proof_module = b.createModule(.{ .root_source_file = b.path("src/core_test.zig"), .target = target, .optimize = bench_mode, .imports = &.{ .{ .name = "shakedown", .module = dependency.module("shakedown") }, .{ .name = "aegis", .module = b.dependency("aegis", .{ .target = target, .optimize = bench_mode }).module("aegis") } } });
        const core_bench = b.addExecutable(.{
            .name = "strand-core-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/core.zig"),
                .target = target,
                .optimize = bench_mode,
                .imports = &.{
                    .{ .name = "proof", .module = proof_module },
                    .{ .name = "shakedown", .module = dependency.module("shakedown") },
                },
            }),
        });
        b.step("core-bench-build", "Compile paired manual reference observations").dependOn(&b.addInstallArtifact(core_bench, .{}).step);
        check_step.dependOn(&core_bench.step);
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
        // A project that depends on strand by path, with airlock and aegis
        // and nothing else to fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{
            .package = "strand",
            .modules = &.{"strand"},
            .program = b.path("ci/consumer.zig"),
            .packages = &.{ b.dependency("aegis", .{}), b.dependency("airlock", .{}) },
        });
    }
    return needed;
}

/// shakedown for the benchmarks, bound to strand's aegis, so a build links
/// one aegis.
fn shakedownFor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) error{LazyDependencyNeeded}!*std.Build.Dependency {
    const shakedown = try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    const shakedown_build = b.lazyImport(@This(), "shakedown") orelse return error.LazyDependencyNeeded;
    shakedown_build.useAegis(shakedown, b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    return shakedown;
}

/// strand and airlock again, in the mode a benchmark builds in: an
/// imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const airlock = b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const strand = b.createModule(.{ .root_source_file = b.path("src/strand.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock } } });
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "strand", .module = strand }}) catch @panic("OOM");
}

/// The way below the public API for the two benchmarks that time the wire
/// encoder against `core.serialize`. A source file belongs to one module, so
/// they cannot take it beside `strand`: this root names both, and is not part
/// of the strand module.
fn benchSeam(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const airlock = b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.createModule(.{ .root_source_file = b.path("src/seam.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock } } });
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/logbook.zig",
    "examples/zon.zig",
};

// Build-only tooling belongs to a root invocation, never a consumer's dependency graph.

/// What a checked copy of each type in src/testing/clone_rejected.zig is
/// refused with, in case order.
const clone_rejections = [_][]const u8{
    "error: : pointer has no safe data meaning",
    "error: : pointer has no safe data meaning",
    "error: : type has no automatic data meaning",
    "error: : untagged union has no active member witness",
    "error: .unsafe: pointer has no safe data meaning",
    "error: : pointer has no safe data meaning",
    "error: : type has no automatic data meaning",
    "error: : type has no automatic data meaning",
    "error: checked clone excludes resources",
    "error: : pointer has no safe data meaning",
    "error: : pointer has no safe data meaning",
    "error: .unsafe: pointer-containing sentinel cannot change ownership",
};
