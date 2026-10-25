//! JSON: bounded parsing into any Zig type, borrowed, owned or on an arena,
//! checked writing, and an object's members read one at a time off its bytes.
const api = @import("json/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Raw = api.Raw;
pub const Parsed = api.Parsed;
pub const Value = api.Value;
pub const ParseOptions = api.ParseOptions;
pub const ParseError = api.ParseError;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const Prefix = api.Prefix;
pub const parsePrefixLeaky = api.parsePrefixLeaky;
pub const parseStdValue = api.parseStdValue;
/// JSONC: read with JSON's options and promises (`parse`, `parseOwned`,
/// `parseLeaky`), and edited in place, its comments kept (`Edit`).
pub const jsonc = struct {
    pub const parse = api.jsonc.parse;
    pub const parseOwned = api.jsonc.parseOwned;
    pub const parseLeaky = api.jsonc.parseLeaky;
    pub const Edit = @import("json/edit.zig").Edit;
    pub const EditOptions = @import("json/edit.zig").EditOptions;
};
/// The JSON Canonicalization Scheme (RFC 8785).
pub const jcs = @import("json/canonical.zig");
/// JSON Schema (2020-12) for the JSON a type is read and written as.
pub const schema = @import("json/schema.zig");
pub const Whitespace = api.Whitespace;
pub const WriteOptions = api.WriteOptions;
pub const WriteError = api.WriteError;
pub const write = api.write;
pub const writeObjectOpen = api.writeObjectOpen;
pub const OpenObject = api.OpenObject;
pub const kindOf = api.kindOf;
pub const tagOf = api.tagOf;
pub const memberOf = api.memberOf;
pub const memberStringOf = api.memberStringOf;
pub const Members = api.Members;
pub const Member = api.Member;
pub const MembersOptions = api.MembersOptions;
pub const MembersError = api.MembersError;
pub const intOf = api.intOf;
pub const indexOfControl = api.indexOfControl;
