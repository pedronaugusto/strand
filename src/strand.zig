//! Typed JSON Lines: one JSON value per line, read and written on top of
//! `std.json`.
//!
//! The format is the one append-only logs and line protocols already use — a
//! complete JSON value, then `\n`, and nothing else on the line. That makes a
//! file greppable, tailable and appendable, and it makes a stream framable
//! without a length prefix. strand decodes ordinary reflected types from the
//! complete line, keeps `std.json` as the oracle and custom-parser path, and
//! emits ordinary reflected values directly while keeping `std.json` as the
//! custom-stringifier and pretty-output path. Around that is the line layer:
//!
//! * `Reader` turns a `*std.Io.Reader` into a stream of typed values, one per
//!   line, each carrying its 1-based line number, its raw bytes and the byte
//!   offset it began at — and `Reader.resumeAt` starts again from one of
//!   those offsets with the numbering intact.
//! * A malformed line is an error naming the line, not an abort, and can be
//!   skipped instead (`Options.on_malformed`).
//! * Strings borrow from the line's bytes when they need no unescaping, so
//!   the common case copies nothing. `Reader.keep` is how a value outlives
//!   the line it came from.
//! * `kindOf` and `tagOf` answer "what kind of line is this" from the first
//!   key alone, without parsing the value.
//! * `Writer` emits one value per line — minified, or indented for a human —
//!   and counts them, draining the destination and syncing the file under it
//!   as often as it is told to.
//! * `Tail` reads a seekable file backwards, last line first, without
//!   reading what comes before.
//! * `Follower` reads to the end and keeps reading, the way `tail -f` does,
//!   waiting on an `std.Io` and stopping when that `std.Io` cancels it — and,
//!   given an `Opener`, following the path across a rotation rather than the
//!   handle into a file nobody writes to any more.
//! * `Versioned` puts a schema version on a record and migrates an older one
//!   forward.
//! * `Raw` holds a value the reader does not read as its bytes: checked with
//!   the line, written back as it came, and decoded when it is wanted.
//!
//! What this package does NOT do: it does not buffer or own a stream, does
//! not open a file except through an
//! `Opener` a caller hands it, does not lock or compress one, does not index
//! a log or seek to line *n*, does not
//! validate a line it is not asked to parse, and has no opinion about what a
//! line means. There is no global state and no dependency beyond `std`.

const parse_line = @import("parse_line.zig");
pub const parseLine = parse_line.parseLine;
pub const ParseOptions = parse_line.ParseOptions;
pub const Diagnostics = parse_line.Diagnostics;
pub const DuplicateFields = parse_line.DuplicateFields;
pub const ParseLineError = parse_line.ParseLineError;

const line = @import("line.zig");
pub const Line = line.Line;
pub const RawLine = line.RawLine;
pub const Format = line.Format;
pub const Fault = line.Fault;
pub const separator = line.separator;
pub const lines = line.lines;
pub const LineIterator = line.LineIterator;

pub const Reader = @import("reader.zig").Reader;
pub const Writer = @import("writer.zig").Writer;
pub const writeLine = @import("writer.zig").writeLine;
pub const Tail = @import("tail.zig").Tail;
pub const Follower = @import("follow.zig").Follower;
pub const Opener = @import("follow.zig").Opener;
pub const PathOpener = @import("follow.zig").PathOpener;
pub const Identity = @import("follow.zig").Identity;
pub const Versioned = @import("versioned.zig").Versioned;
pub const payloadOf = @import("versioned.zig").payloadOf;
pub const Raw = @import("raw.zig").Raw;
pub const kindOf = @import("route.zig").kindOf;
pub const tagOf = @import("route.zig").tagOf;
pub const indexOfControl = @import("control.zig").indexOfControl;

test {
    _ = @import("parse_line.zig");
    _ = @import("line.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("sync.zig");
    _ = @import("control.zig");
    _ = @import("route.zig");
    _ = @import("tests.zig");
    _ = @import("fuzz.zig");
    _ = @import("tail.zig");
    _ = @import("follow.zig");
    _ = @import("versioned.zig");
    _ = @import("raw.zig");
}
