# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `parseLine` and `Writer` accept a schema too large for the compiler's
  default comptime budget. Deciding whether a type takes the direct path
  walks every field reachable from it, and a line protocol of sixty
  requests ran past a thousand steps and failed to compile.

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
  `src/fixtures.zig` for the scaffolding three test files were each carrying.

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

[0.5.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.1.0
