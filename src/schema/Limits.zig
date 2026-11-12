//! What compiling a schema and validating an instance may take. Every bound
//! is checked as the work grows, `error.TooLarge` (or the error its field
//! names) past it; nothing is sized by the input alone.
const aegis = @import("aegis");

const Bytes = aegis.units.Bytes(usize);

/// Active evaluations at once: a schema node at an instance location. The
/// schema's size times the instance's depth bounds them; this bounds that.
frames: usize = 64 * 1024,
/// Per-container state, where a keyword needs some (`unevaluatedProperties`,
/// `unevaluatedItems`, `uniqueItems`, `dependentRequired`,
/// `dependentSchemas`), charged as it grows.
state: Bytes = .literal("16MiB"),
/// Errors a `basic` output collects before it stops.
errors: usize = 100,
/// The largest decimal exponent a number may have, in a schema or an
/// instance: past it the number is refused, never approximated.
exponent: u32 = 4096,
/// How deep an instance may nest.
depth: usize = 128,
/// The largest schema document compiled.
schema_bytes: Bytes = .literal("4MiB"),
/// Subschemas one compile makes.
subschemas: usize = 64 * 1024,
/// References followed in a chain before compiling refuses it.
reference_chain: usize = 256,
