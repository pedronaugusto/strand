//! Assemble one Raw type and its codecs without coupling their implementations.
pub const Raw = @import("raw.zig").RawType(@This()).Raw;
pub const encode = @import("encode.zig").Encoder(Raw);
pub const decode = @import("decode.zig").Decoder(Raw);
pub const parser = @import("parse/line.zig").Parser(decode);
pub const ParseOptions = parser.ParseOptions;
pub const ParseLineError = parser.ParseLineError;
pub const parseLine = parser.parseLine;
const values = @import("value_api.zig").Values(encode);
pub const ValueOptions = values.ValueOptions;
pub const writeValue = values.writeValue;
pub const writeObjectOpen = values.writeObjectOpen;
pub const OpenObject = values.OpenObject;
