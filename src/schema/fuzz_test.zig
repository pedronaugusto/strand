//! Fuzz targets: compiling any bytes, and validating any instance against
//! any schema. Each reads to a value or a named error and nothing else:
//! no panic, no leak, and a validation gives back every slot and byte of
//! state it charged (`Schema.validate` asserts the recount). `zig build
//! test` runs them over seeded cases; `--fuzz` steers them by coverage.
const std = @import("std");
const strand = @import("strand");
const shakedown = @import("shakedown");
const Schema = @import("Schema.zig");
const Dialect = @import("dialect.zig").Dialect;

const testing = std.testing;
const gen = shakedown.gen;

/// Schemas the mutations start from: every keyword family, references,
/// dynamic anchors, patterns and formats.
const schemas = [_][]const u8{
    "{\"type\": \"object\", \"properties\": {\"a\": {\"type\": \"integer\", \"minimum\": 1}}, \"required\": [\"a\"], \"additionalProperties\": false}",
    "{\"$defs\": {\"n\": {\"items\": {\"$ref\": \"#/$defs/n\"}, \"maxItems\": 3}}, \"$ref\": \"#/$defs/n\"}",
    "{\"anyOf\": [{\"type\": \"string\", \"pattern\": \"^a+$\"}, {\"multipleOf\": 0.5}], \"not\": {\"const\": 1}}",
    "{\"if\": {\"minProperties\": 1}, \"then\": {\"unevaluatedProperties\": false, \"properties\": {\"x\": true}}, \"else\": {\"enum\": [[1, 2], null]}}",
    "{\"prefixItems\": [{\"format\": \"date\"}], \"items\": {\"uniqueItems\": true}, \"contains\": {\"type\": \"array\"}, \"minContains\": 0, \"unevaluatedItems\": false}",
    "{\"$id\": \"http://e.com/t\", \"$dynamicAnchor\": \"node\", \"properties\": {\"c\": {\"$dynamicRef\": \"#node\"}}, \"dependentSchemas\": {\"c\": {\"required\": [\"d\"]}}}",
    "{\"patternProperties\": {\"^x-\": {\"format\": \"ipv6\"}}, \"propertyNames\": {\"maxLength\": 4}, \"dependentRequired\": {\"a\": [\"b\"]}}",
    "{\"$schema\": \"http://json-schema.org/draft-07/schema#\", \"items\": [true, {\"type\": \"null\"}], \"additionalItems\": false, \"dependencies\": {\"a\": [\"b\"]}}",
    "{\"$schema\": \"https://json-schema.org/draft/2019-09/schema\", \"$recursiveAnchor\": true, \"properties\": {\"r\": {\"$recursiveRef\": \"#\"}}}",
    "true",
};

const instances = [_][]const u8{
    "{\"a\": 1}",                    "[[1], [2, [3]], []]",      "\"aaa\"",
    "{\"x\": 1, \"y\": [1, 1.0]}",   "[\"2020-02-29\", [1, 2]]", "{\"c\": {\"c\": 1}, \"d\": null}",
    "{\"x-1\": \"::1\", \"ab\": 2}", "[null, null, 1]",          "1e400",
    "{\"r\": {\"r\": {\"r\": {}}}}",
};

test "fuzz: compiling any bytes makes a schema or a named error" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var buffer: [512]u8 = undefined;
            const bytes = gen.mutated(s, &buffer, &schemas);
            const dialect = gen.enumValue(s, Dialect);
            var compiled = Schema.compile(testing.allocator, testing.io, strand.json, .init(bytes), .{
                .dialect = dialect,
                .formats = if (gen.boolean(s)) .assert else .annotate,
                .unsupported_pattern = if (gen.boolean(s)) .downgrade else .refuse,
                .limits = .{ .subschemas = gen.intRange(s, usize, 1, 64), .reference_chain = gen.intRange(s, usize, 1, 16) },
            }) catch return;
            compiled.deinit();
        }
    }.one, .{ .cases = 5000, .seed = 0xf022 });
}

test "fuzz: validating any instance against any schema gives a verdict or a named error, and gives back its state" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var schema_buffer: [512]u8 = undefined;
            const schema_bytes = if (gen.boolean(s)) schemas[gen.intRange(s, usize, 0, schemas.len - 1)] else gen.mutated(s, &schema_buffer, &schemas);
            var compiled = Schema.compile(testing.allocator, testing.io, strand.json, .init(schema_bytes), .{
                .formats = if (gen.boolean(s)) .assert else .annotate,
                .unsupported_pattern = .downgrade,
                .limits = .{ .frames = gen.intRange(s, usize, 1, 256), .state = .fromRaw(gen.intRange(s, usize, 0, 4096)), .errors = gen.intRange(s, usize, 0, 8), .depth = gen.intRange(s, usize, 1, 16) },
            }) catch return;
            defer compiled.deinit();
            var buffer: [512]u8 = undefined;
            const instance = gen.mutated(s, &buffer, &instances);
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const flag = compiled.validate(testing.io, state.allocator(), strand.json, .init(instance), .{ .flag = null }) catch return;
            // `basic` gives the same verdict, or meets the same limit.
            var errors: Schema.Errors = .{};
            const basic = compiled.validate(testing.io, state.allocator(), strand.json, .init(instance), .{ .basic = &errors }) catch |err| switch (err) {
                error.TooLarge, error.TooManyFrames, error.TooDeep => return,
                else => return err,
            };
            try testing.expectEqual(flag, basic);
            // An invalid verdict says why, unless no record is allowed; a valid
            // one has none.
            if (compiled.limits.errors == 0) {
                try testing.expectEqual(0, errors.records.len);
            } else {
                try testing.expectEqual(basic, errors.records.len == 0);
            }
            try testing.expect(errors.records.len <= compiled.limits.errors);
        }
    }.one, .{ .cases = 5000, .seed = 0xf023 });
}
