# Changelog

Each entry says what the old shape could not express, so a port has the reason
and not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

## Unreleased

- `Reader.resumeAt(allocator, input, options, start)`, with `Reader.Start`
  beside it. `Line.offset` made an index buildable and nothing could read one
  back: a reader started on a stream seeked to an offset called that line 1 at
  offset 0, so an index entry was a place and not a line number, and a report
  or a resume built on it named the wrong line. A resumed reader is told the
  offset it stands at and how many lines are behind it, and reports the
  recorded number and the recorded offset for the line it finds there and the
  ones after it. A byte-order mark is looked for only at offset 0, since that
  is the only place one can be. `Reader.init` is `resumeAt` from the start of
  the stream, and `Follower` seeds its reader through it rather than by hand.
  *a reader resumed at an offset carries the line number with it* walks an
  index of every tenth line of five hundred; *fuzz: a resumed Reader over
  generated lines* resumes at every line the byte-counting oracle has and
  holds the whole rest of the stream to the oracle's numbers and offsets.
- `Follower.Options.reopen`, with `Opener` and `PathOpener` beside it. A
  follower held an open handle, so a log renamed away and recreated left it
  reading a file nobody was writing to any more, for ever and without saying
  so; the only cure was for the caller to notice, build a second `Follower`
  and throw the first away. Given an `Opener` — one call returning the file a
  path names now — the follower does it: when the file it holds has stopped
  growing it asks what the path holds, and moves to it if that is a different
  file. The order is the point, and it is stated rather than implied: **the
  old file is read to its end first, then the new one from its start**, with
  the line numbering beginning again and `Follower.rotations` counting how
  often that has happened. A truncation is acted on the same way instead of
  being reported, so `error.Truncated` does not arise when `reopen` is set.
  The follower closes handles it opened and never the one it was given.
  `Opener` is an interface rather than a path because a test stages the files
  itself: *the opener is an interface, and a test hands over the files itself*
  drives a rotation with no filesystem involved, *a follower given an opener
  follows the path across a rename* and *a truncation is begun again rather
  than reported when there is an opener* drive the two real ones, *the old
  file is read to its end before the new one is started* rotates before a
  single line has been read and still gets all three lines of the old file
  first, and *fuzz: a follower over a file replaced under it* does that over
  generated pairs of files, holding the result to what a plain reader makes of
  each of the two.
- Breaking: `Follower.NextError` gained `error.ReopenFailed`, which is an
  opener declining or the system refusing to say which file a handle is.
- `Writer.Options.sync`: `.never`, `.per_record` or `.per_batch`, with
  `Writer.initFile` to give a writer the file a sync needs. A flush moves a
  record out of this program's buffer into the operating system's, which is
  enough to survive the process and not enough to survive the machine — the
  operating system may hold those bytes in memory as long as it likes — and
  `flush` was all this package offered, so a log that had to be on the disk
  had no setting to say so and the caller had to reach past the writer for
  the file after every record. A sync drains first, whatever `flush` says,
  since bytes still in this program's buffer have never reached the file.
  What it does not cover is stated rather than implied: the directory entry
  is not synced, because creating and opening the file are the caller's.
  `Writer.Options.flush`'s type is now the named `Writer.Flush` rather than an
  anonymous enum, and `Writer.Sync` is beside it. *a sync policy drains the
  destination before it asks the file* measures the file after every record,
  *a per-batch sync is once for the batch and not once for the record* shows a
  loose record still in the buffer until the batch drains it, and *a sync
  policy with no file to sync says so rather than pretending* pins the writer
  built without one.
- Breaking: `Writer.Error` gained `error.SyncFailed`, so a caller that
  switches exhaustively over it has one more arm to write. `writeLine` is
  unchanged: its policy is the default one and it cannot sync.

No test or example waits on a task that could have failed. A producer on a
task that fails leaves a consumer waiting for lines that will never be written,
and a wait with nothing to wait for does not end: the suite hung on the Windows
runner rather than failing on it. The producer is the caller's own thread now
and the follower is the task, so a write that fails is a failed test; the
logbook example appends its records itself instead of from a task; the rotation
tests check that the system really does call the two files different files,
since a follower with nothing to notice waits; and every CI job has
`timeout-minutes: 20`, so a wait that never ends fails the run.

A file's length is asked of a handle that is open for reading. Reading a
file's attributes is read access, and Windows refuses the query on a handle
opened only for writing, so the logbook example measured the end of the log
through the handle it reads with rather than the one it appends with. `Opener`
says the same thing about the file it hands over: the follower reads it and
asks the system which file it is, and both need read access.

`Tail` in `.pretty` mode was looked at and refused, and the reason is now on
`Tail.Options` rather than left as a line in the documents. Joining lines needs
an answer to "is this the whole of a value, or only part of one". Forwards
there is one: `std.json` reports `error.UnexpectedEndOfInput` when a value is
cut off at the end, and `Reader` joins on that failure and on no other.
Backwards there is no mirror of it — `std.json` has no notion of a valid tail
of a value, so a lone `}` is a syntax error exactly as `not json` is — and a
backwards join would have to treat every failure as "not the beginning yet".
That is sound on a file this package wrote, since no line-aligned proper suffix
of an indented record is itself a complete value, and it is unbounded on
anything else: one damaged line would prepend lines until `max_line_bytes`,
which over thirty-byte lines and the default megabyte is tens of thousands of
parse attempts over ever longer slices, ending in one malformed record that has
swallowed every good record inside it. Forwards, a syntax error costs one line.
Counting brackets backwards instead of parsing would be cheap and needs to know
whether a `"` opens a string or closes one, which is a fact about everything to
its left — finding where a multi-line record begins means parsing forwards.

## 0.3.0

A pass over the package asking what a JSON Lines reader is expected to answer
and this one could not. What follows is what that pass found missing, each
entry with the test it now rests on.

- `Line.offset`, and `Reader.offset` beside it. A line number is what a person
  needs and a byte offset is what a program needs, and this package had the
  second only on `Tail`: `Reader` could say a line was bad and not where it
  was, so an index, a resume or a report that a caller could act on had nothing
  to be built out of. A byte-order mark and the terminators of earlier lines are
  counted, `Follower` seeds it from the file position so that it is a file
  offset there too, and the fuzz properties hold it to an oracle that counts
  bytes independently — and hold the forwards and backwards readers to the same
  answer about where each line is.
- `Reader.skipped` and `Tail.skipped`. `on_malformed = .skip` tolerated damage
  and then said nothing about how much, which is not a mode a log can be
  operated under. Both now count what they let past.
- `ParseOptions.duplicate_fields`, forwarded to `Reader`, `Tail` and
  `parseLine`. `std.json` refuses a repeated key, which is right, but plenty of
  writers emit one anyway and settle it by keeping one of the two — so a log
  from such a writer was unreadable here rather than merely questionable. The
  default is unchanged.
- `Writer.Options.flush`: `.never`, `.per_record` or `.per_batch`. Draining is
  the one thing about durability a line writer can offer without owning the
  stream. The destination is still the caller's and the default still touches
  it never.
- Bytes that are not UTF-8 now have a written-down answer rather than an
  implied one: **rejected, not repaired.** `std.json` validates UTF-8, so a
  truncated sequence, an overlong encoding or a lone surrogate half is
  `error.MalformedLine` naming the line, and the line after it is read. The
  asymmetry on the writing side is pinned too: a Zig `[]const u8` that is not
  valid UTF-8 is written by `std.json` as an array of byte values, which reads
  back here byte for byte and reads elsewhere as an array rather than a string.
- Behaviour that was already true and never proved, now proved: a `Reader` over
  a stream that cannot seek and hands over a byte at a time reads the same
  lines as one over a file; a record with its own `jsonStringify` is written
  through it, one line per record; `Reader(std.json.Value)` is a schemaless
  line and is bounded by `max_line_bytes` rather than by the call stack, so
  nesting costs bytes rather than frames; a file that shrinks under a `Tail`
  is `error.Truncated` rather than two files spliced together.

Out of scope, with the reasons written down rather than implied: transparent
gzip (a decompressor in front of a reader is three lines of `std`, and a gzip
stream has no end for `Tail` to start from), `Filter`/`Map` adapters (Zig has
no iterator protocol for them to compose with, and where a mapped value lives
is what `keep` answers), and an index or a seek to line *n* — though
`Line.offset` is now the ingredient one is built from.

## 0.2.0

The line layer grew the three things a log asks for once it is older than an
afternoon: read it from the end, read it while it is written, and read it
after the record has changed shape. Nothing in 0.1.0 could express any of
them — `Reader` only ever moved forwards, stopped at the end of a stream with
no way to wait, and had no opinion about a record whose fields no longer mean
what they did.

- `Tail(T)` reads a seekable file backwards, last line first, one block at a
  time: `prev` is the reverse of `next` and `last(n)` is the reason to have
  it — the last hundred lines of a gigabyte cost one block read. Line numbers
  run the other way (1 is the last line), because a backwards read never
  learns how many lines came before it, and `offset` says where in the file
  the line was.
- `Follower(T)` is `tail -f`: read to the end, wait, carry on. The two things
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
- `Versioned(T)` is the `{"v":N,"data":...}` envelope, with `T.jsonl_version`
  for what this build writes, `T.jsonlMigrate` for what it reads, and
  `T.jsonl_version_unstamped` for a line written before any of this existed.
  It is an ordinary `std.json` type — `jsonParse` and `jsonStringify` — so it
  composes with `Reader`, `Writer`, `Tail` and `Follower` without a second set
  of names. `v` before `data` parses the payload straight into `T` with the
  borrow intact; the other order falls back to a `std.json.Value`. A `T` with
  a field named `v` is a compile error rather than a quiet collision.
  README.md carries the matching recipe for a tagged union that gains an arm.
- Robustness, all of it on by default and all of it about bytes a log really
  does contain. A UTF-8 byte-order mark at the start of a stream is not part
  of the first line (`skip_bom`). A raw C0 control byte other than tab — a NUL
  above all, which is what a torn write leaves behind — is the new
  `error.ControlByte`, naming the line and the offset in `last_error_offset`
  rather than reaching `std.json` as a syntax error (`reject_control_bytes`).
  Both are options, so neither is a decision taken away.
- `Writer.Options.format` adds `.pretty`, which indents a record over several
  lines for a human, and `Reader.Options.format` adds the `.pretty` that reads
  one back by joining lines until they parse. A `.pretty` reader reads a
  minified stream too. `max_line_bytes` bounds the joined record.
- `Writer.writeAll(slice)` writes a batch, byte for byte what the loop wrote.

Breaking, both of them small:

- `Reader.NextError` gained `error.ControlByte`. A line that would have been
  `error.MalformedLine` for holding a NUL is now that instead; under
  `on_malformed = .skip` nothing changes.
- `Reader` grew `last_error_offset`, and the reader is no longer the only
  thing in the package that reads lines, so the memory rules in README.md are
  now stated for `Reader`, `Tail` and `Follower` together.

Also: `zig build bench` writes and reads a million lines and prints the
numbers, `ci/linux.sh` runs Debug and ReleaseSafe inside a container because a
cross-compile proves nothing about reading a file at an offset, and the fuzz
properties grew from four to eight — a file read backwards is the same lines
in the other order, a pretty record survives a round trip, a pretty reader
stays inside its input, and a versioned line either parses or fails the way
`std.json` fails.

## 0.1.0

First release: the line layer over `std.json`, and nothing else.

- `Reader(T)` reads a `*std.Io.Reader` as a stream of typed lines, each
  carrying its value, its raw bytes and its 1-based number. One line buffer
  and one arena are recycled per line, so the cost of a stream is the cost of
  its longest line; `keep` copies a value onto a caller's allocator when it
  has to outlive the line it came from.
- A malformed line is `error.MalformedLine` naming the line in
  `last_error_line`, with the `std.json` error in `last_error`, or is skipped
  under `on_malformed = .skip`. An over-long line is `error.LineTooLong` and
  is discarded whole. No failure desynchronizes the stream.
- Strings borrow from the line's own bytes when they need no unescaping
  (`std.json`'s `.alloc_if_needed`), and the borrow's lifetime is documented
  per field rather than implied.
- `kindOf` and `tagOf` answer what kind of line this is from the first key
  alone, allocating nothing and parsing no value; both answer `null` rather
  than guess at an escaped key.
- `Writer(T)` and `writeLine` emit one minified value per line, omitting null
  optional fields by default, and count what they wrote. `parseLine` and
  `lines` cover a buffer already in memory.
- The claims above are properties rather than examples: four
  `std.testing.fuzz` tests hold the reader, `kindOf`, `tagOf` and `lines` to
  them over generated lines and over a table of awkward inputs, with the line
  numbering checked against an index scan that shares no code with the
  package.
