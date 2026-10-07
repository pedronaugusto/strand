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
//! * `LineReader` turns a `*std.Io.Reader` into a stream of lines: framed at
//!   the terminator, held to a bound, checked for damage, numbered and
//!   placed, and not parsed. A line past the bound is an error the caller
//!   answers, never the end of the stream.
//! * `Reader` is a `LineReader` with a parse on top: a stream of typed values,
//!   one per line, each carrying its 1-based line number, its raw bytes and
//!   the byte offset it began at — and `Reader.resumeAt` starts again from
//!   one of those offsets with the numbering intact.
//! * A malformed line is an error naming the line, not an abort, and can be
//!   skipped instead (`Options.on_malformed`).
//! * Strings borrow from the line's bytes when they need no unescaping, so
//!   the common case copies nothing. `Reader.keep` is how a value outlives
//!   the line it came from.
//! * `copyOwned` copies an already parsed value and every piece of storage
//!   it reaches, without parsing again; `freeOwned` releases that copy.
//! * `kindOf` and `tagOf` answer "what kind of line is this" from the first
//!   key alone, without parsing the value; `memberOf` and `memberStringOf`
//!   answer it from a member named for it, wherever it is in the object.
//! * A union that declares `jsonl_tag` is read and written tagged inside its
//!   object — `{"type":"assistant",...}`, the arm a member of the record —
//!   and `jsonl_other` names the arm a tag naming no arm is read as.
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
//! line means. There is no global state, and no dependency beyond `std`
//! and airlock, which syncs the file under a `Writer` and numbers files for
//! a `Follower`.
const codec_module = @import("codec.zig");
const parse_module = @import("parse.zig");
const reader_module = @import("line/reader.zig");
const reader_module_ = @import("reader.zig");
const writer_module = @import("writer.zig");
const leading_module = @import("leading.zig");
const tail_module = @import("tail.zig");
const follow_module = @import("follow.zig");
const versioned_module = @import("versioned.zig");
const route_module = @import("route.zig");
const control_module = @import("control.zig");
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
pub const LineReader = reader_module.LineReader;
/// A `LineReader` with a parse on top: a stream of typed values.
pub const Reader = reader_module_.Reader;
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
const owned = @import("owned.zig");
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
