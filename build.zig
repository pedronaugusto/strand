const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

/// What a project that depends on strand builds: the `strand` module, on aegis and airlock.
pub fn build(b: *std.Build) void {
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
    const xenoglyph = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph");
    _ = b.addModule("strand", .{
        .root_source_file = b.path("src/strand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock }, .{ .name = "xenoglyph", .module = xenoglyph } },
    });
}

/// strand's development: its tests, examples, checks and benchmarks, under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package = b.dependency("strand", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const preflight = tools.preflight;
    const module = package.module("strand");
    const airlock_dependency = p.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const xenoglyph = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph");

    //=====================================================================
    // Tests. Every one of them runs under `std.testing.allocator`, so a leak
    // or a double free is a failing test rather than a silent habit.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "strand-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock }, .{ .name = "xenoglyph", .module = xenoglyph } },
        }),
    });
    // shakedown, and airlock's seam built on it.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    tests.root_module.addImport("airlock.testing", airlock_build.testing(airlock_dependency, shakedown.module("shakedown")));
    // A second copy of aegis, from its sources at another path: what a program
    // pinning another aegis version than strand's builds beside strand's.
    const aegis_sources = b.addWriteFiles().addCopyDirectory(p.dependency("aegis", .{ .target = target, .optimize = optimize }).path("src"), "aegis", .{});
    tests.root_module.addImport("other_aegis", b.createModule(.{ .root_source_file = aegis_sources.path(b, "root.zig"), .target = target, .optimize = optimize }));

    // The W3C XML suite's documents the manifest lists, embedded from where
    // the build fetched them (`null` when it runs without lazy dependencies).
    tests.root_module.addImport("xmlconf_documents", xmlconfDocuments(b, p));

    const test_step = b.step("test", "Run strand tests");
    // The assembly reaches every test once, in one executable.
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const scratch_tests = b.addTest(.{
        .name = "logbook-scratch-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/scratch.zig"),
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
            .root_source_file = p.path("ci/json-consumer.zig"),
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
                    .root_source_file = p.path("src/testing/clone_rejected.zig"),
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
            "error: : resource or secret is not automatic data",              "error: wire alias collision at left",               "error: owned decoding conflicts with borrow.require at label",
            "error: : explicit data codec",                                   "error: : resource or secret is not automatic data", "error: : pointer has no safe data meaning",
            "error: tag collides with payload alias",                         "error: data codecs require a named error set",      "error: : std.json hooks are not read here; declare strandDeserialize and strandSerialize",
            "is an aegis scalar of contract 2; this strand reads contract 1",
        };
        for (expected, 0..) |message, case| {
            const rejection_options = b.addOptions();
            rejection_options.addOption(usize, "case", case);
            const rejected = b.addObject(.{
                .name = b.fmt("core-rejected-{d}", .{case}),
                .root_module = b.createModule(.{
                    .root_source_file = p.path("src/testing/core_rejected.zig"),
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
    // bay docs -- usage — so the snippet a reader copies is code CI
    // executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
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
    // Never timed by `bay test`: a number that varies with the
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
    {
        const dependency = b.dependency("shakedown", .{ .target = target, .optimize = bench_mode });
        const s2_bench = b.addExecutable(.{
            .name = "strand-s2-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/s2.zig"), .target = target, .optimize = bench_mode, .imports = &.{.{ .name = "seam", .module = benchSeam(b, target, bench_mode) }} }),
        });
        s2_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("s2-bench-build", "Compile explicit paired S2 observations").dependOn(&b.addInstallArtifact(s2_bench, .{}).step);
        check_step.dependOn(&s2_bench.step);
        const zon_bench = b.addExecutable(.{
            .name = "strand-zon-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/zon.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        zon_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("zon-bench-build", "Compile explicit paired ZON observations against std.zon").dependOn(&b.addInstallArtifact(zon_bench, .{}).step);
        check_step.dependOn(&zon_bench.step);
        const zon_smoke = b.addRunArtifact(zon_bench);
        zon_smoke.addArg("--smoke");
        test_step.dependOn(&zon_smoke.step);
        const toml_bench = b.addExecutable(.{
            .name = "strand-toml-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/toml.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        toml_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("toml-bench-build", "Compile TOML observations").dependOn(&b.addInstallArtifact(toml_bench, .{}).step);
        check_step.dependOn(&toml_bench.step);
        const toml_smoke = b.addRunArtifact(toml_bench);
        toml_smoke.addArg("--smoke");
        test_step.dependOn(&toml_smoke.step);
        const yaml_bench = b.addExecutable(.{
            .name = "strand-yaml-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/yaml.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        yaml_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("yaml-bench-build", "Compile YAML observations").dependOn(&b.addInstallArtifact(yaml_bench, .{}).step);
        check_step.dependOn(&yaml_bench.step);
        const yaml_smoke = b.addRunArtifact(yaml_bench);
        yaml_smoke.addArg("--smoke");
        test_step.dependOn(&yaml_smoke.step);
        const xml_bench = b.addExecutable(.{
            .name = "strand-xml-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/xml.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        xml_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("xml-bench-build", "Compile XML observations").dependOn(&b.addInstallArtifact(xml_bench, .{}).step);
        check_step.dependOn(&xml_bench.step);
        const xml_smoke = b.addRunArtifact(xml_bench);
        xml_smoke.addArg("--smoke");
        test_step.dependOn(&xml_smoke.step);
        const ini_bench = b.addExecutable(.{
            .name = "strand-ini-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/ini.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        ini_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("ini-bench-build", "Compile INI observations").dependOn(&b.addInstallArtifact(ini_bench, .{}).step);
        check_step.dependOn(&ini_bench.step);
        const ini_smoke = b.addRunArtifact(ini_bench);
        ini_smoke.addArg("--smoke");
        test_step.dependOn(&ini_smoke.step);
        const json5_bench = b.addExecutable(.{
            .name = "strand-json5-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/json5.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        json5_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("json5-bench-build", "Compile JSON5 observations").dependOn(&b.addInstallArtifact(json5_bench, .{}).step);
        check_step.dependOn(&json5_bench.step);
        const json5_smoke = b.addRunArtifact(json5_bench);
        json5_smoke.addArg("--smoke");
        test_step.dependOn(&json5_smoke.step);
        const dotenv_bench = b.addExecutable(.{
            .name = "strand-dotenv-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/dotenv.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        dotenv_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("dotenv-bench-build", "Compile .env observations").dependOn(&b.addInstallArtifact(dotenv_bench, .{}).step);
        check_step.dependOn(&dotenv_bench.step);
        const dotenv_smoke = b.addRunArtifact(dotenv_bench);
        dotenv_smoke.addArg("--smoke");
        test_step.dependOn(&dotenv_smoke.step);
        const edit_bench = b.addExecutable(.{
            .name = "strand-edit-bench",
            .root_module = b.createModule(.{ .root_source_file = p.path("bench/edit.zig"), .target = target, .optimize = bench_mode, .imports = benchImports(b, target, bench_mode) }),
        });
        edit_bench.root_module.addImport("shakedown", dependency.module("shakedown"));
        b.step("edit-bench-build", "Compile editing observations").dependOn(&b.addInstallArtifact(edit_bench, .{}).step);
        check_step.dependOn(&edit_bench.step);
        const edit_smoke = b.addRunArtifact(edit_bench);
        edit_smoke.addArg("--smoke");
        test_step.dependOn(&edit_smoke.step);
        const s2_smoke = b.addRunArtifact(s2_bench);
        s2_smoke.addArg("--smoke");
        test_step.dependOn(&s2_smoke.step);
        inline for (.{ "core", "hand" }) |which| {
            const schema_options = b.addOptions();
            schema_options.addOption(bool, "common", comptime std.mem.eql(u8, which, "core"));
            const schema = b.addExecutable(.{
                .name = "strand-schema-" ++ which,
                .root_module = b.createModule(.{ .root_source_file = p.path("bench/schema.zig"), .target = target, .optimize = bench_mode, .imports = &.{.{ .name = "seam", .module = s2_bench.root_module.import_table.get("seam").? }} }),
            });
            schema.root_module.addOptions("schema_options", schema_options);
            b.step("schema-" ++ which ++ "-build", "Compile ten 100-field checked JSON encoders").dependOn(&b.addInstallArtifact(schema, .{}).step);
            check_step.dependOn(&schema.step);
            test_step.dependOn(&b.addRunArtifact(schema).step);
        }
        const proof_module = b.createModule(.{ .root_source_file = p.path("src/core_test.zig"), .target = target, .optimize = bench_mode, .imports = &.{ .{ .name = "shakedown", .module = dependency.module("shakedown") }, .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = bench_mode }).module("aegis") } } });
        const core_bench = b.addExecutable(.{
            .name = "strand-core-bench",
            .root_module = b.createModule(.{
                .root_source_file = p.path("bench/core.zig"),
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
    }

    const bench_tests = b.addTest(.{
        .name = "strand-bench-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("bench/bench_scratch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    check_step.dependOn(&bench_tests.step);

    //=====================================================================
    // CI wiring
    //=====================================================================

    preflight.addCi(b, p, .{
        .tests = test_step,
        // The release tier fuzzes the properties and runs the suite under
        // ThreadSanitizer: a follower's cancellation is a second task ending a
        // wait the first is in, a claim a race detector checks rather than a
        // reader (`bay hardened-tsan` on Linux).
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
        .portable_tests = true,
        .bench = .{
            .programs = &.{.{ .name = "strand-bench", .source = "bench/bench.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on strand by path, with airlock, aegis and xenoglyph
    // and nothing else to fetch: the build a consumer gets.
    preflight.addConsumerCheck(b, p, .{
        .package = "strand",
        .modules = &.{"strand"},
        .program = p.path("ci/consumer.zig"),
        .packages = &.{ p.dependency("aegis", .{}), p.dependency("airlock", .{}), p.dependency("xenoglyph", .{}) },
    });
}

/// strand again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module. And shakedown.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "strand", .module = strand }}) catch @panic("OOM");
}

/// The way below the public API for the two benchmarks that time the wire
/// encoder against `core.serialize`. A source file belongs to one module, so
/// they cannot take it beside `strand`: this root names both, and is not part
/// of the strand module.
fn benchSeam(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const p = b.dependency("strand", .{ .target = target, .optimize = optimize }).builder;
    const airlock = p.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock");
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const xenoglyph = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph");
    return b.createModule(.{ .root_source_file = p.path("src/seam.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "aegis", .module = aegis }, .{ .name = "airlock", .module = airlock }, .{ .name = "xenoglyph", .module = xenoglyph } } });
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/logbook.zig",
    "examples/zon.zig",
    "examples/form.zig",
    "examples/table.zig",
    "examples/config.zig",
    "examples/deploy.zig",
    "examples/listing.zig",
    "examples/edit.zig",
    "examples/settings.zig",
    "examples/json5.zig",
    "examples/environment.zig",
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

/// A module of the W3C XML suite's documents, one per line of strand's
/// manifest and in its order: `documents`, or `null` without the suite.
fn xmlconfDocuments(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    if (b.dependencyLazy("xmlts", .{})) |xmlts| {
        source.appendSlice(b.allocator, "pub const documents: ?[]const []const u8 = &.{\n") catch @panic("OOM");
        var lines = std.mem.tokenizeScalar(u8, @embedFile("src/corpus/xml/xmlconf.manifest"), '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next();
            _ = fields.next();
            const path = fields.next().?;
            _ = files.addCopyFile(xmlts.path(path), b.fmt("xmlconf/{s}", .{path}));
            source.print(b.allocator, "    @embedFile(\"xmlconf/{s}\"),\n", .{path}) catch @panic("OOM");
        }
        source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    } else |_| source.appendSlice(b.allocator, "pub const documents: ?[]const []const u8 = null;\n") catch @panic("OOM");
    _ = p;
    return b.createModule(.{ .root_source_file = files.add("documents.zig", source.items) });
}
