//! Assemble one Raw type and its codecs without coupling their implementations.
const raw_module = @import("raw.zig");
const encode_module = @import("encode.zig");
const decode_module = @import("decode.zig");
const line_module = @import("parse/line.zig");
const output_module = @import("output.zig");
pub const Raw = raw_module.RawType(@This()).Raw;
pub const encode = encode_module.Encoder(Raw);
pub const decode = decode_module.Decoder(Raw);
pub const parser = line_module.Parser(decode);
pub const ParseOptions = parser.ParseOptions;
pub const ParseLineError = parser.ParseLineError;
pub const parseLine = parser.parseLine;
const values = output_module.Values(encode);
pub const ValueOptions = values.ValueOptions;
pub const writeValue = values.writeValue;
pub const writeObjectOpen = values.writeObjectOpen;
pub const OpenObject = values.OpenObject;
