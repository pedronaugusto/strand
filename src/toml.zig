//! TOML (1.1.0, and 1.0.0 on request) on the shared core: a document as a
//! type or as `toml.Value`, its four kinds of date and time as types of their
//! own, and a document written from a struct, a map or a union.
const api = @import("toml/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Version = api.Version;
pub const Parsed = api.Parsed;
pub const Value = api.Value;
pub const Entry = api.Entry;
pub const OffsetDateTime = api.OffsetDateTime;
pub const LocalDateTime = api.LocalDateTime;
pub const LocalDate = api.LocalDate;
pub const LocalTime = api.LocalTime;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
