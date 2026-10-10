//! JSON Lines: framing, typed streams, tail and follow, and airlock durability.
const airlock = @import("airlock");

const line = @import("line.zig");
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
/// Chunks pushed in, records out: the same framing as `Reader`, for a
/// caller that owns the reading.
pub const Decoder = @import("decoder.zig").Decoder;
/// One value per line, minified or indented, counted and synced as told.
pub const Writer = writer_module.Writer;
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
/// What a `Writer`'s last sync reached: airlock's, weakest first.
pub const Reached = airlock.Reached;

const line_reader_module = @import("line/reader.zig");
const reader_module = @import("reader.zig");
const writer_module = @import("writer.zig");
const tail_module = @import("tail.zig");
const follow_module = @import("follow.zig");
const versioned_module = @import("versioned.zig");

// This root is reached by the test assembly. Name every embedded
// test namespace explicitly so coverage survives changes in consumers.
test {
    _ = follow_module;
    _ = line;
    _ = line_reader_module;
    _ = reader_module;
    _ = tail_module;
    _ = writer_module;
    _ = versioned_module;
}
