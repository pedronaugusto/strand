//! JSON Lines: framing, typed streams, tail/follow and airlock durability.
const airlock = @import("airlock");

const line = line_module;
/// What reading a line as a `T` can refuse it with.
pub const ParseError = line.ParseError;
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
/// What `payloadOf` can refuse with.
pub const PayloadError = versioned_module.PayloadError;
/// What a `Writer`'s last sync reached: airlock's, weakest first.
pub const Reached = airlock.Reached;
/// Push decoding: chunks in, records out.
pub const Decoder = @import("decoder.zig").Decoder;

pub const line_module = @import("line.zig");
pub const line_reader_module = @import("line/reader.zig");
pub const reader_module = @import("reader.zig");
pub const writer_module = @import("writer.zig");
pub const tail_module = @import("tail.zig");
pub const follow_module = @import("follow.zig");
pub const versioned_module = @import("versioned.zig");

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = follow_module;
    _ = line_module;
    _ = tail_module;
    _ = writer_module;
}
