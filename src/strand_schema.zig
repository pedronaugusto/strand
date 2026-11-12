//! JSON Schema validation over strand's core: a schema compiled once into a
//! program, an instance validated by streaming the core's events through it,
//! with no tree. The module `strand_schema`, built when a project sets
//! `.schema = true` on strand. In progress: the vocabulary below, on which
//! the compiler and the evaluator rest.
pub const Limits = @import("schema/Limits.zig");
pub const Location = @import("schema/Location.zig");
pub const Decimal = @import("schema/Decimal.zig");

test {
    _ = Limits;
    _ = Location;
    _ = Decimal;
}
