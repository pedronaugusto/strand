//! ZON: the notation Zig writes its data in, on the shared core.
const api = @import("zon");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Raw = api.Raw;
pub const Parsed = api.Parsed;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
