//! JSON Lines framing, durability and legacy contracts.
pub const json = @import("../json.zig");
const codec_module = @import("../json/api.zig").codec_module;
const parse_module = @import("../json/api.zig").parse_module;

const leading_module = @import("../json/api.zig").leading_module;
const route_module = @import("../json/api.zig").route_module;
const control_module = @import("../json/api.zig").control_module;
const airlock = @import("airlock");

const parse_line = codec_module.parser;
/// Parses one line, without its terminator, as a `T` on an arena.
pub const parseLine = parse_line.parseLine;
/// strand's token-source decoder, for a custom `jsonParse` hook that hands
/// its fields back with strand's integer and vector rules.
pub const innerParse = parse_module.inner;
/// What `parseLine` takes beyond `std.json.ParseOptions`.
pub const ParseOptions = parse_line.ParseOptions;
/// Where a refused line went wrong, filled in by `parseLine` on request.
pub const Diagnostics = parse_line.Diagnostics;
/// What a line that names the same member twice means.
pub const DuplicateFields = parse_line.DuplicateFields;
/// Everything `parseLine` can refuse a line with.
pub const ParseLineError = parse_line.ParseLineError;

const line = line_module;
/// One line of input: its value, its bytes, its number and its offset.
pub const Line = line.Line;
/// One line with nothing read out of it: `Line` without the value.
pub const RawLine = line.RawLine;
/// How a value is laid out on the wire: one line each, or indented.
pub const Format = line.Format;
/// What a reader says about the last line it would not hand over.
pub const Fault = line.Fault;
/// The ASCII record separator, which starts a record in
/// `record_separator` mode.
pub const separator = line.separator;
/// The lines of a buffer, as views into it, with nothing allocated.
pub const lines = line.lines;
/// The iterator `lines` returns.
pub const LineIterator = line.LineIterator;

/// A `*std.Io.Reader` as a stream of lines: framed, bounded, checked,
/// numbered and placed, and not parsed.
pub const LineReader = line_reader_module.LineReader;
/// A `LineReader` with a parse on top: a stream of typed values.
pub const Reader = reader_module.Reader;
/// One value per line, minified or indented, counted and synced as told.
pub const Writer = writer_module.Writer;
/// One value as one line, encoded as a `Writer` with default options does.
pub const writeLine = writer_module.writeLine;
/// One value's JSON with no terminator, for a caller that frames the line.
pub const writeValue = writer_module.writeValue;
/// A struct written as `writeValue` writes it but for its closing brace.
pub const writeObjectOpen = writer_module.writeObjectOpen;
/// The object `writeObjectOpen` leaves open: add members, then close it.
pub const OpenObject = writer_module.OpenObject;
/// The integer members a line opens with, read off its bytes.
pub const leadingIntMembers = leading_module.leadingIntMembers;
/// What `leadingIntMembers` read: the members, and where the line goes on.
pub const IntMembers = leading_module.IntMembers;
/// The settings that change the bytes `writeValue` writes.
pub const ValueOptions = writer_module.ValueOptions;
/// A seekable file read backwards, last line first.
pub const Tail = tail_module.Tail;
/// A file read to its end and then as it grows, across rotations given an
/// `Opener`.
pub const Follower = follow_module.Follower;
/// How a `Follower` opens the file a path names now.
pub const Opener = follow_module.Opener;
/// An `Opener` for a path relative to a directory.
pub const PathOpener = follow_module.PathOpener;
/// How a `Follower` tells one file from another.
pub const Identity = follow_module.Identity;
/// Which file a handle is open on, as the filesystem numbers it: airlock's,
/// and the shape a follower's checkpoint records.
pub const FileId = airlock.FileId;
/// A record with a schema version on it, migrated forward when older.
pub const Versioned = versioned_module.Versioned;
/// A `Versioned` payload parsed as an older shape, inside a migration hook.
pub const payloadOf = versioned_module.payloadOf;
/// A JSON value kept as its bytes: checked with the line, written back as
/// it came, and decoded when it is wanted.
pub const Raw = codec_module.Raw;
const owned = owned_module;
/// A parsed value and every piece of storage it reaches, copied without
/// parsing again.
pub const copyOwned = owned.copyOwned;
/// Releases a copy `copyOwned` made.
pub const freeOwned = owned.freeOwned;
/// A line's first key, read without parsing the line.
pub const kindOf = route_module.kindOf;
/// The arm of a union a line is, read from its first key or its tag member.
pub const tagOf = route_module.tagOf;
/// One top-level member of a line by name, read without parsing the line.
pub const memberOf = route_module.memberOf;
/// `memberOf` for a string member, without its quotes.
pub const memberStringOf = route_module.memberStringOf;
/// Where the first C0 control byte other than a tab is, if there is one.
pub const indexOfControl = control_module.indexOfControl;
/// What a `Writer`'s last sync reached: airlock's, weakest first.
pub const Reached = airlock.Reached;

pub const line_module = @import("line.zig");
pub const line_reader_module = @import("line/reader.zig");
pub const reader_module = @import("reader.zig");
pub const owned_module = @import("owned.zig");

pub const writer_module = @import("writer.zig");
pub const tail_module = @import("tail.zig");
pub const follow_module = @import("follow.zig");
pub const versioned_module = @import("versioned.zig");

pub const Decoder = @import("decoder.zig").Decoder;

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = follow_module;
    _ = line_module;
    _ = tail_module;
    _ = writer_module;
}
