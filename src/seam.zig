//! The way below the public API for the benchmarks that time the wire encoder
//! against `core.serialize`. Only the build's benchmark graph roots a module
//! here; it is not part of the strand module.
pub const strand = @import("strand.zig");
pub const Encoder = @import("json/Encoder.zig");
