//! XML 1.0 on the shared core: a document's root element read as a type or
//! as `xml.Element`, its doctype's internal entities expanded within the
//! operation's limits and no external entity ever fetched, and documents
//! written from types. `xml.Scanner` reads a document's tokens for a reader
//! of one too large to read whole.
const api = @import("xml/api.zig");
pub const Format = api.Format;
pub const capabilities = api.capabilities;
pub const Parsed = api.Parsed;
pub const Element = api.Element;
pub const Entry = api.Entry;
pub const Part = api.Part;
pub const Scanner = api.Scanner;
pub const ParseOptions = api.ParseOptions;
pub const parse = api.parse;
pub const parseOwned = api.parseOwned;
pub const parseLeaky = api.parseLeaky;
pub const Whitespace = api.Whitespace;
pub const Namespace = api.Namespace;
pub const WriteOptions = api.WriteOptions;
pub const write = api.write;
