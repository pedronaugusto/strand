//! Direct encoding, assembled with the shared Raw type.
const codec = @import("codec.zig");
pub const supports = codec.encode.supports;
pub const value = codec.encode.value;
pub const indented = codec.encode.indented;
pub const BufferError = codec.encode.BufferError;
pub const valueBuffer = codec.encode.valueBuffer;
pub const raw = codec.encode.raw;
