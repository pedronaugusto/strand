# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Independent JSON and JSON Lines build modules on the shared core; the root
  remains a facade with its existing source, wire, error and ownership contracts.
- Strict slice, owned and caller-arena JSON parsing, JSON-native numeric lexemes,
  checked decimal integers, exact float policy, full wire limits and checked writes.
- Push JSON Lines decoding with consumed counts, explicit final-record policy,
  bounded persistent oversize recovery and independent retained owners.
- An explicit bounded `parseStdValue` adapter that transfers one arena into the
  standard dynamic owner, and checked standard Value writing with explicit scratch.
- The complete pinned JSONTestSuite corpus and chunk/lifetime/limit tests.

### Core framework

- Add the provisional std-only `strand.core` module with recursive descriptors,
  type-declared options, immediate semantic mapping and bounded arena owners.
- Add a small reference test backend, generic ordered maps, explicit standard
  list codec, fixed-buffer paths, rollback and full wire-limit proofs.
- Compile manual paired timing drivers in ordinary CI; timings run only through
  an explicit manual workflow. Existing JSON Lines entry points are unchanged.

- Give the manual Raw comparison equal schema specialization and call-site reuse
  on both revisions, with a semantic equality check before timing.

### Fixed

- `Versioned` returned a `null` optional vector field for a record whose payload held a
  48-byte vector such as `@Vector(3, u128)` in an optional, in ReleaseSafe and ReleaseFast
  on aarch64 macOS. Zig 0.17.0 miscompiles such an optional; the envelope now keeps its
  payload as a value and a flag.

### Breaking

- S2 adds the `core.Event.number` lexeme alternative; exhaustive backend event
  switches must handle it. `core.EncodeError` adds `DuplicateField` for checked
  dynamic object keys. Existing root JSONL parse/write error sets are unchanged.

- strand requires Zig 0.17.0.
- `Follower` keeps no `std.Io`: `init(gpa, source, options)` takes none, and `next`, `checkpoint`, `truncated` and `deinit` take the `io` they block on. `resumeFrom(gpa, io, source, point, options)` takes `point` before `options`.
- `Reader.resumeAt` and `LineReader.resumeAt` take `start` before `options`.
- A recursive schema, one that reaches itself, is held to `ParseOptions.max_depth` (and `Reader.Options.max_depth`, `Tail.Options.max_depth`), 512 levels of arrays and objects by default: a line nested deeper is `error.NestingTooDeep`, which a reader reports as `MalformedLine`. One deeply nested line inside the default line bound overflowed the stack. `ParseLineError` gains `NestingTooDeep`.
- Opener callbacks take `io` before `context`. Internal parse helpers put comptime selectors and allocators before data.
- `Raw.encode` adds `WriteFailed` for a custom stringify hook's refusal and reports `OutOfMemory` only when its owned encoding buffer cannot allocate.
- Bounded writers use `initBounded(gpa, output, max_line_bytes, options)` or `initFileBounded(gpa, file_writer, max_line_bytes, options)` instead of `Options.max_line_bytes`, require `deinit`, encode once into reusable owned scratch and emit the bytes measured; `Writer.Error` adds `OutOfMemory`, while unbounded `init` and `initFile` keep streaming without scratch.
- The benchmark moved from `examples/bench.zig` to `bench/`; `zig build bench` runs it in strand's own tree and is not there in a project that depends on strand. Unit tests retain deterministic framing, parse, allocation and borrowing checks.
- Owned schemas refuse pointer-bearing vector sentinels, including empty arrays and slices and fields in null optionals or inactive union arms.
- Byte vectors accept both JSON strings of the exact UTF-8 byte length and arrays on every decoder path, replacing string refusal; encoding stays byte-for-byte std.json, including empty vectors.
- `Tail.last` parses each line normally and copies through `copyOwned`, requires the same owned-data contract as `keep`, returns only `NextError`, and releases partial batches on failure; its internal `batch_allocator` field is removed.
- `Identity.inode` is now `Identity.file_id`, including serialized policy tags; the old `inode` tag is refused with `error.UnknownField`, with no compatibility path, and followers start fresh.
- `Reader.keep`, `Tail.keep` and `Follower.keep` copy `line.value` through `copyOwned` and return `Allocator.Error!T`, preserving edits and migrations without calling parsers again; schemas must meet the owned-copy data contract.
- `Identity.Taken.id` holds the full `FileId` instead of `inode` and optional `volume`; old checkpoints are refused with `error.MissingField`, with no conversion or fallback, and callers choose where to restart.
- `max_line_bytes` counts JSON payload bytes everywhere, excluding the separator, terminator and discarded torn prefix; writer and tail boundary acceptance changes.
- `Reader(T)` is a `LineReader` with a parse on top, and keeps it as `Reader.lines`. The reader's place in the stream is kept there: `reader.number`, `reader.offset`, `reader.skipped`, `reader.fault` and `reader.input` are now `reader.lines.number`, `reader.lines.offset`, `reader.lines.skipped`, `reader.lines.fault` and `reader.lines.input`. `Reader.Options` is unchanged. `Reader.Joined` is `LineReader.Joined`. The framing is one piece of code, no longer compiled once for every `T`.

### Added

- A union that declares `jsonl_tag` is read and written tagged inside its object, `{"type":"assistant",...}`, the arm a member of the record, by every decoder and by `Writer` in both formats; `jsonl_other` names an arm for a tag naming no arm, and `tagOf` reads the arm from the tag member.
- `memberOf` and `memberStringOf` read one top-level member of a line by name, wherever it is, without parsing the line; the first of a repeated member is the answer.
- `innerParse` exposes the checked token-source decoder so custom `jsonParse` hooks can delegate fields with strand's integer and vector rules.
- `copyOwned` and `freeOwned` copy a parsed value and all its storage without a JSON round-trip, including `Raw` bytes and `std.json.Value`, and clean up a failed copy.
- `LineReader`, the line layer on its own: a `*std.Io.Reader` as a stream of lines, framed at the terminator, held to `max_line_bytes`, checked for raw control bytes and missing separators, numbered and placed, and not parsed. It is for bytes whose meaning is somebody else's — a line protocol with its own decoder, a child process's output — which until now had to name a type for a `Reader` they never parsed into. A line past the bound is `error.LineTooLong` with the line consumed to its end, so the caller answers it and reads on; the stream's own buffer can be much smaller than the longest line. `LineReader.recordStart` and `LineReader.reset` are how a file still being written is read: where the record the reader was last on began, and carrying on from a place the stream has been put back to. `LineReader.join` appends the next physical line to a record, for a reader that knows when a record spread over several lines is finished.
- `writeValue`, one value's JSON with no terminator, for a caller that frames the line itself — an envelope around the value, a checksum after it — with `ValueOptions` for the two settings that change its bytes. `emit_null_optional_fields = true` is `std.json`'s default spelling. A value that fits in the unused part of the destination's buffer is encoded there, as `Writer` does.
- `LineReader.Options.oversized_member` and `Reader.Options.oversized_member`: the name of a top-level member to keep from a line refused as `error.LineTooLong`, read as the line is discarded and returned by `LineReader.oversizedMember` — a request's id, for a line protocol that answers an over-long request under it. Only a scalar of at most `max_oversized_member_bytes` that is valid JSON is kept; the outermost object's own member, the last of a duplicate, matched as written.
- `writeObjectOpen`, a struct written as `writeValue` writes it but for its closing brace, and the `OpenObject` it returns: `member` adds a member spelled as a field would be, after a comma where one is needed, and `close` writes the brace. For a record that carries a checksum over the bytes before it, without trimming the brace off a finished value.
- `leadingIntMembers`, the integer members a line opens with — `{"seq":7,"at":-3,` — read off its bytes as a struct of integer fields, with the offset where the line goes on (`IntMembers`). Only the minified shape `writeValue` writes, in field order and with JSON's integer spelling; null for any other, which is the parser's.
- `FileId`, which file or directory a handle is open on as the filesystem numbers it: the device and the inode on POSIX, the volume's serial number and the 128-bit file id on Windows. It is [airlock](https://github.com/pedronaugusto/airlock)'s `FileId`: `FileId.of(io, file)` for a handle, `FileId.ofPath(io, dir, sub_path, .{})` for a path, which also names a socket. What `Identity` compares, and what a caller comparing two handles wants.
- `Writer.reached`, what the writer's last sync reached (`Reached`, airlock's): `.data` or better where the filesystem takes the call, less where it declines it, such as `.written` from a network mount on macOS. Declining is not failing, and the writer carries on.
- `LineReader.unfinished`: whether the stream ended in the middle of a record — `next` returned `null` over bytes with no terminator after them, or refused as too long a line the stream ended inside — rather than after a line. A reader of a file still being written tells an unfinished record from the end of the file by it.
- `crlf`, on `LineReader.Options`, `Reader.Options` and `Tail.Options`: on by default, as before, and off for a format whose lines are checked byte for byte — a checksum over each — where a `\r` in front of the newline is a byte of the line and not part of the terminator.
- `Tail.prevRaw`, a line read backwards as its bytes, framed and checked and not parsed; and `Tail.Options.end`, where the file ends for the reader, for a log that reserves space ahead of its records.
- A line-protocol recipe in `examples/logbook.zig`: requests read with a `LineReader`, one past the bound answered, and the replies written a record at a time.

### Changed

- strand depends on airlock, which makes a `Writer`'s sync and a `Follower`'s file identity. The sync is the same call at the same cost on Linux (`fdatasync`) and macOS (`F_FULLFSYNC`); on Windows NTFS it is now the data-only flush, `NtFlushBuffersFileEx(DATA_SYNC_ONLY)`, which covers a record and the length that finds it without the timestamps.
- `Raw.encode` returns `Raw.EncodeError`, a named set a caller can put in its own.
- The fetched package holds the build files, `src` and the three documents; the examples, benchmarks, `ci/` and `.github/` stay in the repository.
- `Follower` names its error sets: `CheckpointError`, `ResumeError`, `TruncatedError` and `RestartError`; `Identity.take` returns `Identity.TakeError`. `Follower.source` documents that a rotation under an opener rewrites the caller's `File.Reader`.
- `Reader`, `Writer`, `Tail` and `Follower` share their policy types across record types: `Reader(A).Options` is `Reader(B).Options`, and likewise `NextError`, `Start`, `Flush`, `Sync`, `Error`, `InitError`, `Wait` and `Checkpoint`. Methods keep their typed signatures and doc comments.
- Name the scanner token and allocation error sets as public error sets, and name integer conversion failures as public `int.Error`. Qualify file identity results as public `Identity.Taken`. Expose custom JSON hook fixture types to match their public signatures.
- A `.pretty` reader of a type the direct decoder reads parses a record where it lies in the input's buffer, across its line breaks, in one pass; it joins lines only for a record that straddles a refill, or one with a blank line, a `\r` or a fault in it, as before.
- A follower retains the identity measured when it adopts or restarts a file, so later rewrites cannot change a checkpoint of records already read.
- Direct decoding propagates allocator failure immediately instead of reparsing the line and potentially hiding `OutOfMemory`.
- Value conversion handles empty arrays through the reflected walker, avoiding std.json's nonexistent-element indexing in nested payloads and migrations.
- The logbook example owns a separate scratch directory per invocation so concurrent builds cannot overwrite or remove each other's files.
- Vector decoding converts array elements as values, supporting booleans and narrow integers on every parse path including array input for byte vectors.
- Owned copies give pointer-vector elements independent storage and release them on failure or `freeOwned`.
- Owned-copy type checking accepts full protocol schemas without exhausting the compiler's default evaluation budget.
- Value conversion reads checked integers and vectors through their reflected containers, preserving the first conversion error and supporting nested vectors in migrations.
- `Follower` rewinds a half-written record and begins again after a truncation through `LineReader.reset`, rather than by setting the reader's fields.
- Faster where chronicle's own codec was faster, and the same bytes. A string with something to escape in it is scanned a vector at a time and written in runs, each escape `std.json`'s own spelling, where it used to go to `std.json` whole, a byte at a time; a member's key, with its comma where the comma is certain, and an enum's name are one constant each; an integer past 64 bits is written nineteen digits a division and read nineteen digits at a time. The decoder matches the key it expects next as the constant it is before reading one. The same property over every shape, under every option that changes bytes, and a fuzz target hold the writer to `std.json`'s bytes.
- Check a string's high bytes in the vector that found its closing quote or escape.
- Keep the framing scan in its own call and find a control lane only in a vector that holds one.
- Assemble codecs around one raw value type and keep integration tests above the public module.
- The README usage excerpt keeps the example calls without the surrounding commentary.
- Allocator parameters are named `gpa`, and `arena` where nothing is freed piecewise: `parseLine`, `innerParse`, `Raw.parse` and the `jsonlMigrate` hook.
- Every declaration the root module re-exports has a doc comment, and fields outside the API say `Private:`.

### Fixed

- Caller-arena JSON parsing resets diagnostic format/path/offset before each
  operation, including input-limit refusal, matching owned and borrowed parsing.

- Push decoding accepts a BOM only at stream offset zero, including after
  draining an oversized first record; every two-chunk split checks this edge.

- `writeValue` and a bounded `Writer` write a non-exhaustive enum: a named value by name, any other by number, as `writeLine` does. Such an enum failed to compile on the buffered path.
- `Tail.init` refuses a pipe or socket as `error.Streaming`, as documented; it read whatever the system reported as the stream's size.
- `Writer.write` publishes a record whole: one that fails partway leaves nothing in the destination, where the next record was appended to its bytes and lost with them. A record that fails after outgrowing the destination's buffer sets `torn`, and the next record starts on a line of its own.
- A line refused as too long that the stream ended inside is discarded to its end when the rest arrives. A `Follower` read its tail as a malformed line, misplaced the next record and read the refused line again.
- In `record_separator` mode every separator starts a record: the record on a line is what follows its last separator, and each torn record before it is dropped, counted in `skipped` and named in `fault`. A torn record followed by a whole one on the same line lost the whole one, forwards and in `Tail`.
- A `Follower` with an opener waits while the path names nothing, as it does between a rotation's rename and its create, where it ended with `error.ReopenFailed`; an opener reports that moment as `error.FileNotFound`, and `PathOpener` does.
- A `.pretty` reader follows a record to where its JSON value ends and parses it there, once; it parsed the record again after every line joined to it, so a record of n lines cost n parses. A record that is JSON but not a `T` is refused as the lines its value takes, where it was refused at the line it went wrong on and the lines after that were read as records of their own.
- A `Raw` read where no value starts, as in `[1}` read through `std.json` or the token path, is an error rather than a panic in `skipValue`.
- A line that ends inside a character is `UnexpectedEndOfInput`, as `std.json` reads it, rather than `SyntaxError`.
- `parseLine` fills diagnostics when it refuses a trailing terminator before parsing, replacing stale coordinates from an earlier call.
- Bounded record scratch treats an empty repeated write pattern as no bytes, so a custom stringify hook can finish that write regardless of its repetition count.
- Pretty-record joins count and bound only physical lines that exist, preserve subsequent line numbers after refusal, and retain an unfinished record's rewind point.
- Follower truncation docs describe automatic reopening through the configured opener.
- Separated blank-line framing honors `crlf` and drops at most one final carriage return.
- Reader.next keeps framing and parsing in one result handoff without changing either layer's ownership.
- The ARM framing scan reduces byte-sized lane indices without unpacking narrow vector elements.
- The separator-mode docs say which bytes each reader and writer counts against its bound.
- A follower checks cancellation before returning a record already in its buffer.
- A separated record keeps its separator offset when physical framing fails.
- Versioned accepts payload fields named v, since payload fields live inside data and cannot collide with the envelope.
- The test build accepts -Dtest-filter to run the named part of the suite.
- A reader that meets a stream with no byte on it yet looks for a byte-order mark when the first bytes arrive. It used to decide there was none, so a file that was empty when it was first read, and was then written mark first, read its first line with the mark in it and refused it. `Follower` had worked around this for itself.
- No line takes the process down over a number. `std.json` in Zig 0.16.0 reads a number written with a fraction or an exponent into an integer through a float and panics on two that pass its range check: a value from 2^127 up, whatever the type (`1.8e38` into a `u128`), and the type's largest value rounded up (2^127 into an `i128`, 2^64 into a `u64` from a `std.json.Value`). Both of strand's parsers read such a number as the number it is, and one past the type is `error.Overflow`; so does `Versioned`, which read its payload through `std.json`, and `payloadOf`, whose value is now checked for those numbers before `std.json` is given it. Wherever `std.json` answers, the answer is unchanged, which a property over 20,000 values of every shape, each changed four ways, and a fuzz target hold both parsers to.
- A follower tells two files apart by the volume they are on as well as by their number. A file on another volume carrying the number of the one being followed read as the same file, so a rotation onto another mount was a silence.
- The token parser refuses a string where an array belongs before reading the string, and reads a `\u` escape a byte at a time, as `std.json` does: an unfinished line of either kind was `error.UnexpectedEndOfInput` where `std.json` says `error.UnexpectedToken` or `error.SyntaxError`.

## [0.7.0] - 2026-09-24

### Added

- `Raw`, a JSON value kept as its bytes, for a line that carries something
  it does not read: another program's record passed along, a plugin's
  payload, a request handed on as it came. A field of it is checked when its
  line is read — a value that is not JSON is the line's error — and holds
  the value from its first byte to its last, whitespace inside it included,
  borrowed from the line as a string is and copied by `keep`. It is written
  back as it came, except that a line break inside it is a space in a
  minified line and `escape_unicode` escapes what is not ASCII. `Raw.parse`
  decodes it as any type when it is wanted, and `Raw.encode` makes one from
  a value. A struct or union holding one stays on the direct decoder and
  writer, where a `std.json.Value` in its place takes the whole line to
  `std.json`.

### Changed

- Passing over a value — an unknown field, or a `Raw` — checks it in the
  decoder's own loop rather than token by token through the scanner, with
  nothing allocated, to a depth of sixty-four; a deeper value goes to the
  scanner as before. In `zig build bench` on an Apple M3 Max, a line
  carrying a small object reads as a `Raw` in 105 ns rather than 165, and
  in 455 with a `std.json.Value` in the same place.

### Fixed

- A type whose largest value is one digit — `u1` to `u3`, `i2` to `i4` —
  refuses a digit it cannot hold with `error.Overflow` on every path. The
  path that names a line's error let the digit through, and every line the
  direct decoder refuses is read again on that path, so such a line
  panicked in Debug and ReleaseSafe and was undefined in the fast modes.

- `Writer` writes an integer one bit narrower than a power of two — `u1`,
  `u3`, `i7`, `u15`, `i31`, `u63` and the rest. The length of the buffer its
  digits are written into was worked out in a type too narrow to hold it,
  and a record with such a field failed to compile.

- A struct holding a packed struct decodes. Since values are decoded in
  place, each field was decoded through its address, and the fields of a
  packed struct are bits of one integer with no address of their own, so
  such a type failed to compile for `parseLine` and the readers. Its fields
  are decoded and then stored.

## [0.6.1] - 2026-09-23

### Fixed

- `parseLine` and `Writer` accept a schema too large for the compiler's
  default comptime budget. Deciding whether a type takes the direct path
  walks every field reachable from it, and a line protocol of sixty
  requests ran past a thousand steps and failed to compile.
- A line read by `Reader` costs what its parse costs on x86_64 too. It
  measured 1.06x to 1.13x the parse on GitHub's x86_64 runners, past the
  tenth the suite holds it to: the decoder copied each value out and the
  reader copied it again into its `Line`, and there a load that spans two
  recent stores waits for both to reach the cache. Values are now decoded
  in place, and the end of a line is found with a bitmask rather than a
  vector reduction. A line measures 0.95x to 0.98x its parse there, and
  `parseLine` itself is faster.

## [0.6.0] - 2026-09-20

Typed decoding and writing several times faster, cancellation reported as
itself, and the fixes a second reading found.

### Breaking

- `Opener.OpenError`, `Follower.checkpoint`, `resumeFrom`, `truncated` and
  `restart` now expose `error.Canceled` instead of translating cancellation
  into an unrelated operation failure.

### Fixed

- `parseLine` rejects a trailing line terminator as documented.

- `Tail` treats `block_bytes = 0` as a one-byte block instead of panicking.

- `Versioned` applies `duplicate_fields` to both `v` and `data` envelope
  keys.

- Byte-order marks are recognized on streams whose reader buffer is smaller
  than three bytes.

- A zero-length follower fingerprint falls back to inode identity instead of
  making every file identical.

- Separated readers discard a torn prefix before applying `max_line_bytes` to
  the framed record.

- `Follower.next` preserves `error.Canceled` from length, identity and seek
  operations as well as from reads and waits.

- Recursive pointer schemas fall back to the standard JSON paths without
  exhausting compile-time evaluation.

- Line bounds exclude a CRLF terminator and the first record's byte-order
  mark in both forward and backward readers.

- Null tuple elements are emitted as `null` so later elements keep their
  positions.

- `Tail` snapshots the file's current length even when its file reader cached
  an earlier end.

- Followers preserve progress over complete blank or skipped records while
  waiting for an unfinished record to grow.

- Followers started on an empty file still recognize a byte-order mark when
  the first record arrives.

- Followers retain a partially written pretty record until its closing lines
  arrive.

- Deeply nested unknown fields are skipped with a heap-backed scanner rather
  than consuming the process stack.

- Large unsigned integers written with exponent notation decode without an
  intermediate signed range limit.

### Changed

- Typed decoding scans unescaped strings a vector at a time, borrows them
  directly, and decodes ordinary reflected types from the complete line.
  Fixed-width positive integers use a checked decimal path; floats and types
  with custom parsing keep the standard-library paths. On the cross-language
  fixtures, regular records rose from 370.9 to 1034.8 MB/s and long-string
  records from 758.0 to 3700.2 MB/s.

- Typed writing encodes ordinary minified values directly into the caller's
  unused buffer, scans plain ASCII strings a vector at a time and publishes a
  complete record at once. Buffered throughput rose from 1066.7 to 3321.5
  MB/s, and per-record flushing from 241.0 to 286.5 MB/s; custom stringifiers
  and pretty output keep the standard-library path.

- `Tail` reads backwards in 64 KiB blocks by default, and `last` decodes
  owned values directly onto the caller's allocator instead of parsing every
  line twice. Returning the last 1,000 typed records fell from 1.321 ms to
  0.302 ms.

## [0.5.0] - 2026-09-19

A pass over the package asking what a line should cost, what it should say
when it goes wrong, and how it is found again after a crash.

### Breaking

- **`Reader.last_error_line`, `.last_error` and `.last_error_offset` are
  `Reader.fault.line`, `.fault.err` and `.fault.offset`**, and the same on
  `Tail`. One fact about one line is one struct, and a reader now says what
  happened by naming it rather than by setting three fields in the right
  order.

- **`Reader.NextError` and `Tail.NextError` gained
  `error.MissingSeparator`**, and **`Writer.Error` gained
  `error.LineTooLong`.** A caller that switches exhaustively over either has
  one more arm to write.

- **`Writer.Flush` and `Writer.Sync` are tagged unions rather than enums**,
  so that a count can be one of the settings. Every setting that was spelled
  `.never`, `.per_record` or `.per_batch` still is.

- **A `Writer` whose sync has failed refuses every later record**, where it
  used to take them.

- **`Reader.record_start` is gone.** It was assigned 0 and never anything
  else.

### Added

- **`Reader.nextRaw` and `Reader.parse`.** `kindOf` and `tagOf` are
  documented as the way to route a line without parsing its value, and no
  streaming reader would hand one over: routing meant parsing every line into
  a `std.json.Value` first, allocating for lines about to be thrown away, or
  writing the line loop this package exists to save. `nextRaw` is `next` with
  the parse left out — it frames the record, counts it, places it, passes
  over blank lines and checks it for control bytes — and `parse` is how one
  becomes a `Line(T)` afterwards. `next` is the two of them in a loop.
  `RawLine` gained `offset`, and `lines` fills it in.

- **`Writer.flush` and `Writer.sync`**, the one-off beside the policy, for a
  barrier at a checkpoint or at the end of a run. A caller on `flush =
  .never` had to reach past the writer to the stream it does not own, which
  is the reach `Options.flush` was added to remove.

- **`Flush` and `Sync` gained `.per_records`.** Per record is one sync per
  line, and per batch only helps a caller who already holds a batch; a stream
  of records had neither. A count is counted across `write` and `writeAll`
  alike: the cost divided by *n*, against losing up to *n*. There is no
  setting that drains on a timer, and the reason is on `Options.sync` — a
  writer is only called when there is a record, so a timer needs a task and
  this package owns none.

- **`Writer.Options.max_line_bytes`.** A reader refuses a line past its bound
  and a writer had none, so this package would write a log it would not read
  back, with nothing said at the place the mistake was made. Off by default,
  because the check costs a second encoding pass; with it, the record is
  refused before a byte of it reaches the log.

- **`Follower.Options.identity`.** A follower asked the system which file a
  handle was and nothing else. A filesystem may give a new file the number of
  one just deleted, or renumber a file it did not replace, and a rotation
  that copies the log away and writes the same file again from the top is
  invisible to a number by construction. `.fingerprint` hashes the file's
  first bytes instead — written once and not written again, so they name the
  file in a way the filesystem cannot take back. What a file is, is taken
  when the follower takes it up and kept, since reading both sides of a
  rotation afresh would find the same bytes.

- **`Follower.Checkpoint`, `Follower.checkpoint` and
  `Follower.resumeFrom`.** `Reader.resumeAt` exists so that a crash can be
  resumed from, and the thing that crashes is the follower; its place was
  reachable only in pieces, with nothing that bundled them and nothing that
  read one back. A checkpoint is four numbers — which file, how far in, what
  the next line is numbered, how many files it has been through — and the
  file handed to `resumeFrom` is not necessarily the file it names, since a
  log can rotate while nothing is following it. Same file: the read carries
  on with the recorded numbering. Different file: it is read from its start,
  and `rotations` says so.

- **Record separators.** JSON Lines has no resync marker: a line that does
  not parse is either damage or a record from a writer that knows something
  this reader does not, and nothing tells the two apart. `record_separator`
  on the writer and on both readers is RFC 7464's framing — ASCII RS, 0x1E,
  in front of every record, the only byte that cannot appear unescaped inside
  a JSON value. What lies before the first separator on a line is the tail of
  a torn record and is dropped; a line with no separator is
  `error.MissingSeparator`. `Line.offset` is the separator, since that is
  where the record begins.

- **Generated input two ways, and a corpus on disk.** The properties only
  ever saw five seeds and the table. `zig build test --fuzz` builds and runs
  them now: the test runner the compiler links in fuzz mode hands
  `@errorReturnTrace()` to `std.debug.writeStackTrace`, and on 0.16.0 those
  are two different `StackTrace` types, so the test build turns error return
  tracing off and the branch goes with it. Beside it, a campaign that ends:
  `-Dcampaign=N` seeded rounds, `-Dseed=N` choosing which, both printed on a
  failure so the run repeats, twenty thousand of them in CI. The seeds are
  files under `src/corpus`, so an input either mode finds can be kept.

- **Tests for what had none**: `escape_unicode`,
  `emit_null_optional_fields`, `Versioned` through `Tail` and through
  `Follower`, a byte-order mark in the fuzz corpus and table, and `.pretty`
  with `.skip` and a control byte, which is the combination that was
  diagnosed wrongly.

- **Two recipes in `examples/logbook.zig`**, so README.md shows them as code
  CI runs rather than describing them: a follower checkpointed and resumed
  into a second follower, and a torn record in front of a separated stream
  that the reader drops without losing the records behind it.

### Changed

- **A line already in the stream's buffer is framed where it lies.** Every
  line was copied into the reader's own buffer before it was parsed, even
  when the whole of it was already sitting in the buffer the stream had just
  filled. A record that is all there is handed over as a slice of that buffer
  now: the bytes are read once, the line buffer is never written to, and the
  borrow rule the values already lived under covers it unchanged. A line that
  straddles a refill is assembled in the line buffer as before, and a pretty
  record about to be joined to copies itself out first. Over mixed lines in
  ReleaseFast the reader cost about fifteen per cent more than the same parse
  with no line layer over it at all; it now costs about one.

- **The control scan and the backwards scan read a register at a time.**
  `indexOfControl` runs over every line a reader hands back and was a byte
  loop; it is a `@Vector` scan with four blocks folded into one horizontal
  question, since asking a vector whether any lane matched is the expensive
  instruction and the compares are not. That scan cost 20 ns/line and costs
  4. The backwards newline scan in `Tail` had the same shape and the same
  fix, and nothing in `std` vectorises a scan that runs backwards.

- **What a line costs is held to a budget.** The numbers in README.md went
  unchecked, and the two things they measure are exactly the kind that rot
  quietly. *a line costs what the parse under it costs, within a
  tenth* times this reader against the same parse over a frame taken straight
  out of the stream's buffer, and fails if the gap opens up. A ratio rather
  than an absolute, because an absolute ns/line is a fact about the machine
  that ran it.

- **A malformed line says where in it the parse gave up.**
  `last_error_offset` was the control byte's place and nothing else, and the
  field beside it said `std.json` reports no offset and this reader does not
  invent one. `std.json` does report one. A line that has already failed is
  parsed a second time with the scanner's diagnostics on, so the first parse
  — the one every good line goes through — pays nothing for it. `parseLine`
  takes a `Diagnostics` of its own for a caller that wants the line and
  column too.

- **A sync is the call the platform means by it, and no more.** The
  durability table said a synced record survives the machine, and on macOS
  that was not true: `fsync` there hands the bytes to the drive without
  making it write them down. A sync asks for `fcntl(F_FULLFSYNC)` on that
  platform now, and a filesystem with no such call gets `fsync`, which is
  then the strongest thing on it. On Linux the table was true and the call
  was more than a log needs: `fsync` writes the file's timestamps back as
  well, a second metadata write per record for a time no reader of this log
  consults. A sync there is the `fdatasync` syscall, made directly, since
  `std.Io.File` exposes no such call — which also makes it the same call
  whether or not libc is linked — and a file that declines it gets `fsync`.

- **Two internal files.** `src/line.zig` for what a line is whichever
  direction it is read in — the mark, the terminator, the blank line, `keep`,
  where `std.json` gave up, and the `Fault` a reader records — and
  `src/testing/fixtures.zig` for the scaffolding three test files were each carrying.

### Fixed

- **A record that is damaged is not a record that ran out.** `joinPhysical`
  answered `null` to two different questions, so a pretty record whose
  continuation line carried a raw NUL was skipped correctly and then
  diagnosed wrongly: the control byte and its offset were overwritten with
  `error.UnexpectedEndOfInput` and no offset at all. The join answers with a
  named outcome now.

- **A line shorter than one vector register was scanned for control bytes a
  byte at a time.** The scan took the widest register the machine has and
  gave up on anything narrower, so on a machine with 512-bit registers every
  line under sixty-four bytes — which is most log lines — went through the
  byte loop, and a line cost a fifth more than the parse under it rather than
  a thirtieth. The scan now takes the widest register, then half of it, and
  half of that, and a reader that frames a line off the stream's own buffer
  scans it once rather than twice: the byte that ends a line and the byte
  that must not appear raw inside one are the same predicate, so the first
  byte that answers it is either the terminator or the damage.

## [0.4.0] - 2026-09-14

A reader that resumes at an offset, and a follower that reopens.

### Breaking

- **`Follower.NextError` gained `error.ReopenFailed`**, which is an opener
  declining or the system refusing to say which file a handle is.

- **`Writer.Error` gained `error.SyncFailed`**, so a caller that switches
  exhaustively over it has one more arm to write. `writeLine` is unchanged:
  its policy is the default one and it cannot sync.

### Added

- **`Reader.resumeAt(allocator, input, options, start)`, with `Reader.Start`
  beside it.** `Line.offset` made an index buildable and nothing could read
  one back: a reader started on a stream seeked to an offset called that line
  1 at offset 0, so an index entry was a place and not a line number, and a
  report or a resume built on it named the wrong line. A resumed reader is
  told the offset it stands at and how many lines are behind it, and reports
  the recorded number and the recorded offset for the line it finds there and
  the ones after it. A byte-order mark is looked for only at offset 0, since
  that is the only place one can be. `Reader.init` is `resumeAt` from the
  start of the stream, and `Follower` seeds its reader through it rather than
  by hand.

- **`Follower.Options.reopen`, with `Opener` and `PathOpener` beside it.** A
  follower held an open handle, so a log renamed away and recreated left it
  reading a file nobody was writing to any more, for ever and without saying
  so; the only cure was for the caller to notice, build a second `Follower`
  and throw the first away. Given an `Opener` — one call returning the file a
  path names now — the follower does it: when the file it holds has stopped
  growing it asks what the path holds, and moves to it if that is a different
  file. The order is stated rather than implied: **the old file is read to
  its end first, then the new one from its start**, with the line numbering
  beginning again and `Follower.rotations` counting how often that has
  happened. A truncation is acted on the same way instead of being reported,
  so `error.Truncated` does not arise when `reopen` is set. The follower
  closes handles it opened and never the one it was given, and `Opener` is an
  interface rather than a path so a test can stage the files itself.

- **`Writer.Options.sync`: `.never`, `.per_record` or `.per_batch`, with
  `Writer.initFile`** to give a writer the file a sync needs. A flush moves a
  record out of this program's buffer into the operating system's, which is
  enough to survive the process and not enough to survive the machine, and
  `flush` was all this package offered, so a log that had to be on the disk
  had no setting to say so and the caller had to reach past the writer for
  the file after every record. A sync drains first, whatever `flush` says,
  since bytes still in this program's buffer have never reached the file.
  What it does not cover is stated rather than implied: the directory entry
  is not synced, because creating and opening the file are the caller's.
  `Writer.Options.flush`'s type is now the named `Writer.Flush` rather than
  an anonymous enum, and `Writer.Sync` is beside it.

### Changed

- **The reason `Tail` has no `.pretty` mode is on `Tail.Options`** rather
  than left as a line in the documents. Joining lines needs an answer to "is
  this the whole of a value, or only part of one". Forwards there is one:
  `std.json` reports `error.UnexpectedEndOfInput` when a value is cut off at
  the end, and `Reader` joins on that failure and on no other. Backwards
  there is no mirror of it, so a backwards join would have to treat every
  failure as "not the beginning yet" — sound on a file this package wrote,
  and unbounded on anything else, where one damaged line would prepend lines
  until `max_line_bytes` and end in one malformed record that has swallowed
  every good record inside it.

### Fixed

- **No test or example waits on a task that could have failed.** A producer
  on a task that fails leaves a consumer waiting for lines that will never be
  written, and a wait with nothing to wait for does not end: the suite hung
  on the Windows runner rather than failing on it. The producer is the
  caller's own thread now and the follower is the task, so a write that fails
  is a failed test; the logbook example appends its records itself instead of
  from a task; the rotation tests check that the system really does call the
  two files different files, since a follower with nothing to notice waits;
  and every CI job has `timeout-minutes: 20`.

- **A file's length is asked of a handle that is open for reading.** Reading
  a file's attributes is read access, and Windows refuses the query on a
  handle opened only for writing, so the logbook example measured the end of
  the log through the handle it reads with rather than the one it appends
  with. `Opener` says the same thing about the file it hands over: the
  follower reads it and asks the system which file it is, and both need read
  access.

## [0.3.0] - 2026-09-14

A pass over the package asking what a JSON Lines reader is expected to answer
and this one could not.

### Added

- **`Line.offset`, and `Reader.offset` beside it.** A line number is what a
  person needs and a byte offset is what a program needs, and this package
  had the second only on `Tail`: `Reader` could say a line was bad and not
  where it was, so an index, a resume or a report that a caller could act on
  had nothing to be built out of. A byte-order mark and the terminators of
  earlier lines are counted, `Follower` seeds it from the file position so
  that it is a file offset there too, and the fuzz properties hold it to an
  oracle that counts bytes independently — and hold the forwards and
  backwards readers to the same answer about where each line is.

- **`Reader.skipped` and `Tail.skipped`.** `on_malformed = .skip` tolerated
  damage and then said nothing about how much, which is not a mode a log can
  be operated under. Both now count what they let past.

- **`ParseOptions.duplicate_fields`**, forwarded to `Reader`, `Tail` and
  `parseLine`. `std.json` refuses a repeated key, which is right, but plenty
  of writers emit one anyway and settle it by keeping one of the two — so a
  log from such a writer was unreadable here rather than merely questionable.
  The default is unchanged.

- **`Writer.Options.flush`: `.never`, `.per_record` or `.per_batch`.**
  Draining is the one thing about durability a line writer can offer without
  owning the stream. The destination is still the caller's and the default
  still touches it never.

### Changed

- **Bytes that are not UTF-8 have a written-down answer rather than an
  implied one: rejected, not repaired.** `std.json` validates UTF-8, so a
  truncated sequence, an overlong encoding or a lone surrogate half is
  `error.MalformedLine` naming the line, and the line after it is read. The
  asymmetry on the writing side is pinned too: a Zig `[]const u8` that is not
  valid UTF-8 is written by `std.json` as an array of byte values, which
  reads back here byte for byte and reads elsewhere as an array rather than a
  string.

- **Behaviour that was already true and never proved is now proved**: a
  `Reader` over a stream that cannot seek and hands over a byte at a time
  reads the same lines as one over a file; a record with its own
  `jsonStringify` is written through it, one line per record;
  `Reader(std.json.Value)` is a schemaless line bounded by `max_line_bytes`
  and not by the call stack, so nesting costs bytes rather than frames;
  and a file that shrinks under a `Tail` is `error.Truncated` rather than two
  files spliced together.

## [0.2.0] - 2026-09-13

The line layer grew the three things a log asks for once it is older than an
afternoon: read it from the end, read it while it is written, and read it
after the record has changed shape.

### Breaking

- **`Reader.NextError` gained `error.ControlByte`.** A line that would have
  been `error.MalformedLine` for holding a NUL is now that instead; under
  `on_malformed = .skip` nothing changes.

- **`Reader` grew `last_error_offset`**, and the reader is no longer the only
  thing in the package that reads lines, so the memory rules in README.md are
  now stated for `Reader`, `Tail` and `Follower` together.

### Added

- **`Tail(T)` reads a seekable file backwards**, last line first, one block
  at a time: `prev` is the reverse of `next` and `last(n)` is the reason to
  have it — the last hundred lines of a gigabyte cost one block read. Line
  numbers run the other way, 1 being the last line, because a backwards read
  never learns how many lines came before it, and `offset` says where in the
  file the line was.

- **`Follower(T)` reads to the end, waits, and carries on.** The two things
  that makes hard are both handled rather than papered over. A half-written
  line is not a line — `Reader.Options.require_terminator`, new and usable on
  its own, makes a final line with no `\n` invisible, and the follower rewinds
  the file to where it began. Waiting goes through the `std.Io` it was given,
  an `Io.sleep` or an `Io.Event` you set from a filesystem watch, so
  cancelling the task cancels the wait and `error.Canceled` comes back out of
  `next` — including when the cancellation lands inside a read, which arrives
  as `error.ReadFailed` on the interface and is unwrapped here. Rotation is a
  documented contract: `truncated` and `restart` for a file emptied in place,
  and reopening the path for one renamed away, because this package does not
  open files.

- **`Versioned(T)`**, the `{"v":N,"data":...}` envelope, with
  `T.jsonl_version` for what this build writes, `T.jsonlMigrate` for what it
  reads, and `T.jsonl_version_unstamped` for a line written before any of
  this existed. It is an ordinary `std.json` type — `jsonParse` and
  `jsonStringify` — so it composes with `Reader`, `Writer`, `Tail` and
  `Follower` without a second set of names. `v` before `data` parses the
  payload straight into `T` with the borrow intact; the other order falls
  back to a `std.json.Value`. A `T` with a field named `v` is a compile error
  rather than a quiet collision.

- **Bytes a log really does contain**, handled by default. A UTF-8 byte-order mark at the start of a stream is
  not part of the first line (`skip_bom`). A raw C0 control byte other than
  tab — a NUL above all, which is what a torn write leaves behind — is the
  new `error.ControlByte`, naming the line and the offset rather than
  reaching `std.json` as a syntax error (`reject_control_bytes`). Both are
  options, so neither is a decision taken away.

- **`Writer.Options.format` adds `.pretty`**, which indents a record over
  several lines for a human, and `Reader.Options.format` adds the `.pretty`
  that reads one back by joining lines until they parse. A `.pretty` reader
  reads a minified stream too, and `max_line_bytes` bounds the joined record.

- **`Writer.writeAll(slice)`** writes a batch, byte for byte what the loop
  wrote.

- **`zig build bench`** writes and reads a million lines and prints the
  numbers, `ci/linux.sh` runs Debug and ReleaseSafe inside a container
  because a cross-compile proves nothing about reading a file at an offset,
  and the fuzz properties grew from four to eight.

## [0.1.0] - 2026-09-13

First release: the line layer over `std.json`, and nothing else.

### Added

- **`Reader(T)`** reads a `*std.Io.Reader` as a stream of typed lines, each
  carrying its value, its raw bytes and its 1-based number. One line buffer
  and one arena are recycled per line, so the cost of a stream is the cost of
  its longest line; `keep` copies a value onto a caller's allocator when it
  has to outlive the line it came from.

- **A malformed line is `error.MalformedLine`** naming the line in
  `last_error_line`, with the `std.json` error in `last_error`, or is skipped
  under `on_malformed = .skip`. An over-long line is `error.LineTooLong` and
  is discarded whole. No failure desynchronizes the stream.

- **Strings borrow from the line's own bytes** when they need no unescaping
  (`std.json`'s `.alloc_if_needed`), and the borrow's lifetime is documented
  per field rather than implied.

- **`kindOf` and `tagOf`** answer what kind of line this is from the first
  key alone, allocating nothing and parsing no value; both answer `null`
  rather than guess at an escaped key.

- **`Writer(T)` and `writeLine`** emit one minified value per line, omitting
  null optional fields by default, and count what they wrote. `parseLine` and
  `lines` cover a buffer already in memory.

- **Four `std.testing.fuzz` tests** hold the reader, `kindOf`, `tagOf` and
  `lines` to everything above, over generated lines and over a table of
  awkward inputs, with the line numbering checked against an index scan that
  shares no code with the package.

[Unreleased]: https://github.com/pedronaugusto/strand/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.7.0
[0.6.1]: https://github.com/pedronaugusto/strand/releases/tag/v0.6.1
[0.6.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.6.0
[0.5.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.1.0
