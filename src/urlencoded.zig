//! Forms and query strings (application/x-www-form-urlencoded) on the shared
//! core: `a=1&tag=x&tag=y&user%5Bname%5D=ada`.
const api = @import("urlencoded/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Parsed = api.Parsed;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
