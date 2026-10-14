//! YAML 1.2 on the shared core: a stream's documents read as types or as
//! `yaml.Value` under the core schema, anchors and aliases repeated within
//! the operation's limits, and documents written in block style.
const api = @import("yaml/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Parsed = api.Parsed;
pub const Value = api.Value;
pub const Entry = api.Entry;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const parseStream = api.parseStream;
pub const parseStreamOwned = api.parseStreamOwned;
pub const parseStreamLeaky = api.parseStreamLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
pub const writeStream = api.writeStream;
