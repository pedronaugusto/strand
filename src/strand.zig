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
//!   object — `{"type":"assistant",...}` — as serde's `#[serde(tag)]` is,
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
//! line means. There is no global state and no dependency beyond `std`.
const codec_module = @import("codec.zig");
const parse_module = @import("parse.zig");
const reader_module = @import("line/reader.zig");
const reader_module_ = @import("reader.zig");
const writer_module = @import("writer.zig");
const leading_module = @import("leading.zig");
const tail_module = @import("tail.zig");
const follow_module = @import("follow.zig");
const file_id_module = @import("file_id.zig");
const versioned_module = @import("versioned.zig");
const route_module = @import("route.zig");
const control_module = @import("control.zig");
const sync_module = @import("sync.zig");

const parse_line = codec_module.parser;
pub const parseLine = parse_line.parseLine;
pub const innerParse = parse_module.inner;
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

pub const LineReader = reader_module.LineReader;
pub const Reader = reader_module_.Reader;
pub const Writer = writer_module.Writer;
pub const writeLine = writer_module.writeLine;
pub const writeValue = writer_module.writeValue;
pub const writeObjectOpen = writer_module.writeObjectOpen;
pub const OpenObject = writer_module.OpenObject;
pub const leadingIntMembers = leading_module.leadingIntMembers;
pub const IntMembers = leading_module.IntMembers;
pub const ValueOptions = writer_module.ValueOptions;
pub const Tail = tail_module.Tail;
pub const Follower = follow_module.Follower;
pub const Opener = follow_module.Opener;
pub const PathOpener = follow_module.PathOpener;
pub const Identity = follow_module.Identity;
pub const FileId = file_id_module.FileId;
pub const Versioned = versioned_module.Versioned;
pub const payloadOf = versioned_module.payloadOf;
pub const Raw = codec_module.Raw;
const owned = @import("owned.zig");
pub const copyOwned = owned.copyOwned;
pub const freeOwned = owned.freeOwned;
pub const kindOf = route_module.kindOf;
pub const tagOf = route_module.tagOf;
pub const memberOf = route_module.memberOf;
pub const memberStringOf = route_module.memberStringOf;
pub const indexOfControl = control_module.indexOfControl;
pub const syncFile = sync_module.syncFile;
pub const syncDir = sync_module.syncDir;
pub const SyncLevel = sync_module.SyncLevel;
pub const SyncKind = sync_module.SyncKind;
pub const SyncError = sync_module.SyncError;
