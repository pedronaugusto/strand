//! MessagePack on the shared core: every format family read, each value
//! written in its smallest format, extensions and timestamps, and a
//! deterministic profile.
const api = @import("msgpack/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Raw = api.Raw;
pub const Parsed = api.Parsed;
pub const Value = api.Value;
pub const Entry = api.Entry;
pub const Ext = api.Ext;
pub const Timestamp = api.Timestamp;
pub const Profile = api.Profile;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
