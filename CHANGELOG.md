# Changelog

Each entry says what the old shape could not express, so a port has the reason
and not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

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
