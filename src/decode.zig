//! Direct decoding, assembled with the shared Raw type.
const codec = @import("codec.zig");
pub const supports = codec.decode.supports;
pub const parseInto = codec.decode.parseInto;
pub const parsePrefixInto = codec.decode.parsePrefixInto;
