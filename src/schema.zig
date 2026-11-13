//! JSON Schema validation over strand's core: a schema compiled once into a
//! program, an instance validated by streaming the core's events through it,
//! with no tree. The module `strand_schema`, built when a project sets
//! `.schema = true` on strand. In progress: `Schema.compile`, the registry
//! and the vocabulary beneath it; validation is still to come.
pub const Limits = @import("schema/Limits.zig");
pub const Location = @import("schema/Location.zig");
pub const Decimal = @import("schema/Decimal.zig");
pub const Schema = @import("schema/Schema.zig");
pub const Program = @import("schema/Program.zig");
pub const Dialect = dialect.Dialect;
pub const dialect = @import("schema/dialect.zig");
pub const canonical = @import("schema/canonical.zig");
pub const Loader = @import("schema/Loader.zig");
pub const metaschemas = @import("schema/metaschemas.zig");
pub const registry = @import("schema/registry.zig");

test {
    _ = Limits;
    _ = Location;
    _ = Decimal;
    _ = Loader;
    _ = metaschemas;
    _ = registry;
    _ = dialect;
    _ = canonical;
    _ = Program;
    _ = Schema;
    _ = @import("schema/compile.zig");
    _ = @import("schema/evaluate.zig");
    _ = @import("schema/formats.zig");
    _ = @import("schema/formats_test.zig");
    _ = @import("schema/fuzz_test.zig");
    _ = @import("schema/generated_test.zig");
    _ = @import("schema/suite_test.zig");
    _ = @import("schema/evaluate_test.zig");
}
