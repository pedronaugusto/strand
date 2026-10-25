//! INI documents on the shared core, in Python configparser's dialect unless
//! another is given: `[section]` headers, `key = value` lines, comments,
//! values continued on indented lines. No interpolation: `%(name)s` and
//! `${name}` are text.
const api = @import("ini/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Dialect = api.Dialect;
pub const Value = api.Value;
pub const Member = api.Member;
pub const Part = api.Part;
pub const Parsed = api.Parsed;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
