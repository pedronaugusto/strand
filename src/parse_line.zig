//! Line parsing, assembled with the shared Raw type.
const codec = @import("codec.zig");
pub const ParseOptions = codec.parser.ParseOptions;
pub const Diagnostics = codec.parser.Diagnostics;
pub const DuplicateFields = codec.parser.DuplicateFields;
pub const ParseLineError = codec.parser.ParseLineError;
pub const parseLine = codec.parser.parseLine;
pub const parseLineInto = codec.parser.parseLineInto;
pub const parsePrefixInto = codec.parser.parsePrefixInto;
pub const direct = codec.parser.direct;
