//! .env files on the shared core, read as python-dotenv reads them:
//! `KEY=value` and `export KEY=value` lines, values unquoted or in single or
//! double quotes across lines, comments. No interpolation: `$NAME` and
//! `${NAME}` are text.
const api = @import("dotenv/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Parsed = api.Parsed;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
