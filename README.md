# strand

[![CI](https://github.com/pedronaugusto/strand/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/strand/actions/workflows/ci.yml)

strand reads and writes [JSON Lines](https://jsonlines.org) as a stream of
typed values: one JSON value per line, for append-only logs, line protocols
and event streams. strand decodes ordinary typed values directly and uses
`std.json` as its compatibility oracle and extension path; `std.json` emits
the values. The line layer runs forwards over a stream, backwards from the
end of a seekable file, or along a file that is still being appended to.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs. CI compares the two.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const strand = @import("strand");

// Write: one JSON value per line, minified, null optionals left out.
var out: std.Io.Writer.Allocating = .init(arena);
var log: strand.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

// Read: a stream of typed lines, each with its number and its bytes.
var source: std.Io.Reader = .fixed(out.written());
var events: strand.Reader(Event) = .init(std.heap.page_allocator, &source, .{
    // Spelled out rather than left to the defaults: a line the reader
    // does not fully understand is still a line, and one it cannot
    // parse at all names itself.
    .ignore_unknown_fields = true,
    .max_line_bytes = 64 * 1024,
    .on_malformed = .fail,
});
defer events.deinit();

var warnings: u32 = 0;
var last_open: ?Event = null;
while (try events.next()) |line| {
    // `line.value` is valid until the next `next`: its strings point into
    // `line.line`, which the reader reuses. `keep` copies one out.
    if (std.mem.eql(u8, line.value.kind, "open")) {
        last_open = try events.keep(arena, line);
    }
    if (line.value.level == .warn) warnings += 1;
    std.debug.print("line {d}: {s}\n", .{ line.number, line.line });
}

// Route a line by its first key, without parsing the value.
const kind = strand.kindOf("{\"kind\":\"open\",\"at\":1}");
```
<!-- END GENERATED -->

[`examples/logbook.zig`](examples/logbook.zig) is built and run by the same
command and carries the longer recipes: the end of a log read backwards, a
follower checkpointed and resumed into a second follower, a record migrated
from an older shape, a tagged union routed by its arm, and a torn record in
front of a separated stream.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/strand
```

```zig
const strand_dep = b.dependency("strand", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("strand", strand_dep.module("strand"));
```

`std` is the only dependency: nothing to link and no build options to match.
Every allocation anywhere here is on an allocator you passed in.

## The API

| | |
|---|---|
| `Reader(T)` | A `*std.Io.Reader` as a stream of typed lines. `next` returns a `Line(T)`: the value, the raw bytes, the 1-based number, the byte offset. |
| `Reader.resumeAt` | The same, starting at an offset with a line count behind it, so an index entry reads back as the line it named. |
| `Reader.nextRaw`, `Reader.parse` | A line's bytes with no type for them, and the value when the caller decides it wants one. This is how a stream is routed: `kindOf` or `tagOf` on the bytes, and a parse only for the lines worth parsing. |
| `Reader.keep`, `Tail.keep` | A copy of a value that outlives the line it came from. |
| `Reader.fault`, `Reader.skipped` | Which line the reader last refused and why, and how many it has passed over. |
| `Writer(T)`, `Writer.initFile` | One value per line, minified or indented, counted. `initFile` is the one with a file to sync. |
| `Writer.write`, `Writer.writeAll` | One record, and a batch written byte for byte as the loop would have written it. |
| `Writer.flush`, `Writer.sync` | The one-off, beside `Options.flush` and `Options.sync`, which are the policy. |
| `writeLine` | One value, one line, nothing to count. |
| `Tail(T)` | A seekable file read backwards: `prev` for one line, `last(n)` for the end of the log. |
| `Follower(T)` | Read to the end, wait, carry on. `Opener` and `PathOpener` are how it follows a path across a rotation, and `Identity` is what makes two handles the same file. |
| `Follower.checkpoint`, `Follower.resumeFrom` | Where a follower stands, and a follower that carries on from there. |
| `Versioned(T)`, `payloadOf` | The `{"v":N,"data":...}` envelope, with a migration hook for an older shape and the parse of that older shape inside it. |
| `parseLine`, `lines` | One line, and a buffer of lines, already in memory. |
| `kindOf`, `tagOf` | The first key of an object, and the union arm it names, without parsing the value. |
| `indexOfControl`, `separator` | The first byte that must not appear raw in a line, and the one that marks where a record starts. |

## Design

**A value borrows from the reader, and the next line takes it back.**
`Line.line` is a slice of the stream's own buffer when the whole line was
already sitting in it, and of the reader's line buffer when it was not; the
value's strings point into that line when they needed no unescaping, and into
the reader's arena when they did. `next` clears the line buffer and resets the
arena before it parses, so a stream costs what its longest line costs. `keep`
is how a value outlives its line: it copies every string onto an allocator you
give it, so pass an arena and drop it whole. The three rules are the same for
`Reader`, `Tail` and `Follower`, and `parseLine` is the first two without a
reader.

**Backwards is one block at a time.** `Tail` walks a seekable file from its
end towards its beginning and reads no further back than the lines it is asked
for, so the last ten lines of a gigabyte cost one block read; `last(n)` is
`keep` over a batch. A backwards read cannot count, so `Line.number` counts
back from the end, 1 being the last line, while `Line.offset` is an offset in
the file and means the same thing in both directions. A file that shrinks
under a `Tail` is `error.Truncated`.

**A follower has no end.** `Follower` reads to the end of a file, waits, and
carries on, so `next` never answers null: it stops when the `std.Io` cancels
it, or when the caller stops asking. Waiting goes through that `std.Io` — an
`Io.sleep`, or an `Io.Event` you set from a filesystem watch (`Wait.wake`) —
so cancelling the task cancels the wait, and `error.Canceled` is how a
follower ends, including when the cancellation lands inside a read.

**A half-written line is not a line.** A reader that reaches the end of a
growing file mid-record must neither hand that record over nor lose the bytes,
so `Follower` reads with `Reader.Options.require_terminator` and rewinds the
file to where the unfinished line began. The option is on a plain `Reader`
too.

**Rotation is handled when the follower is given an `Opener`, and is a
contract when it is not.** An `Opener` is one call returning the file a path
names now.

| What happened | Without `Options.reopen` | With `Options.reopen` |
|---|---|---|
| Truncated in place | `error.Truncated`, and `truncated()` is true; `restart()` is what to do | Begun again at the top of the file, `rotations` counting it |
| Renamed and recreated | Nothing at all — the handle still refers to the old file, which stops growing | Followed across: the old file read to its end first, then the new one from its start, numbering from 1 again |

The follower asks the opener only once the file it holds has stopped growing,
which is what puts the old file first, and it closes handles it opened and
never the one it was given. `PathOpener` is the `Opener` over a directory and
a path. I made it an interface so a test can stage the two files itself
instead of racing a filesystem.

**Which file is which is a setting.** `Options.identity` decides when two
handles are the same file. The default is the number the system gives it — the
inode, or the file index on Windows — which is one call and no reading, and
which a filesystem may reuse for a new file or change for one it did not
replace. `.fingerprint` hashes the first bytes of the file instead: a log's
opening lines are written once and not written again, so they name the file in
a way the filesystem cannot take back, and a rotation that copies the log away
and writes the same file again from the top is a rotation rather than a
silence. A file with fewer bytes than the window is compared by number until
it is long enough.

**Starting again is four integers.** The thing that crashes is the follower.
`Follower.checkpoint` says which file it stands in, how far into it, what the
next line is numbered and how many files it has been through; take it after
`next` has returned a line, which is when the offset in it is a line boundary.
The file handed to `Follower.resumeFrom` is not necessarily the file the
checkpoint names, since a log can rotate while nothing is following it, so the
two are told apart under `Options.identity`: the same file carries on at the
recorded offset with the recorded numbering, a different one is read from its
start and counted as a rotation. A `Checkpoint` is a struct of integers, so a
registry of them is a JSON Lines file like any other.

**Draining and syncing are policy, stated once.** The writer does not own the
destination and drains it only when told to. `Writer.Options.flush` is
`.never`, `.per_record`, `.per_batch` or `.per_records`, and
`Writer.Options.sync` is the same four settings one level down, so how often
to drain is said once rather than at every call site; `Writer.flush` and
`Writer.sync` are the one-off, for a barrier at a checkpoint or at the end of
a run.

| | Survives the process | Survives the machine | Costs |
|---|---|---|---|
| `flush` | yes, from the record it drained | no — the operating system may hold the bytes as long as it likes | a write |
| `sync` | yes | yes, to the last record it synced | a disk write and a wait, and the slowest thing a log does |

`.per_records` is the setting a stream of records wants: one drain, or one
sync, for every *n* records however they arrive — the cost divided by *n*,
against losing up to *n*. A sync drains first, whatever `flush` says, and
needs a file, so `Writer.initFile` is the constructor that can do it.

**A sync is the call the platform means by it.** The platforms do not agree
about what `fsync` promises, and on one of them it is not the cheapest call
that keeps the promise.

| Platform | What a sync calls |
|---|---|
| Linux | `fdatasync`, by syscall, which the filesystems in ordinary use turn into a write the drive has acknowledged. It writes the record and the length that finds it and leaves out the timestamps, which `fsync` would write back as a second metadata write per record for a time no reader of this log consults. A file that declines the call gets `fsync` |
| macOS | `fcntl(F_FULLFSYNC)`, because `fsync` there hands the bytes to the drive without waiting for the drive to write them down. A filesystem that has no such call gets `fsync`, which is then the strongest thing on it |
| Windows | the system's own flush of the file's buffers |

A sync that fails is `error.SyncFailed`, and that writer takes no more
records. A failed sync is not a thing to try again — the kernel may drop the
error along with the data, so a second call can come back clean over a log
that has lost a record — and it is not a thing to write past either. Deal with
the file, then build a writer over it. The directory entry is not covered —
a file synced under a name its directory has not recorded may not be there
after a crash — because creating and opening are the caller's.

**A writer can be given the reader's bound.** With no bound a writer will emit
a record no reader with the matching bound will read back; with
`Writer.Options.max_line_bytes` the record is refused where it is written and
none of it reaches the log. It costs a second encoding pass, so there is no
bound unless one is asked for.

**A record that changes shape says so.** Adding a field is easy, since a
reader defaults its missing fields. When a field changes meaning, splits in
two or moves, the line has to say which shape it is in, and `Versioned(T)` is
the `{"v":N,"data":...}` envelope that says it: `T.jsonl_version` is what this
build writes, `T.jsonlMigrate` is the hook an older line goes through, taking
the version and a `std.json.Value` and returning today's shape, and
`payloadOf` parses the old shape inside the hook. `v` comes first and `data`
second, with the whole record inside `data`, so the envelope cannot collide
with it — a `T` with a field named `v` is a compile error. `Versioned(T)` is
an ordinary `std.json` type and composes with `Reader`, `Writer`, `Tail` and
`Follower`. A line with no `v` is version `T.jsonl_version_unstamped`, which
defaults to 0, and no `jsonl_version` may be 0, so an unstamped line is always
recognisable in the hook; a version no hook accepts is `error.UnknownField`,
which through a `Reader` is `error.MalformedLine` with the line number. A
tagged union grows without an envelope instead: `std.json` writes
`{"open":{...}}`, so the arm is the first key, `tagOf` reads it without
parsing the payload, and an `unknown: std.json.Value` arm gives a line from a
newer writer somewhere to land.

**What a line may contain.**

- A UTF-8 byte-order mark at the start of the stream is not part of the first
  line (`skip_bom`).
- `\r\n` is a terminator, and the `\r` is not part of the line.
- A raw C0 control byte other than tab — a NUL above all, which is what a torn
  write leaves behind — is `error.ControlByte` naming the line and the offset
  (`reject_control_bytes`). JSON forbids these raw in a string and has no use
  for them between tokens, so this refuses nothing that was valid. It is also
  the check that catches an interleaved append, since `O_APPEND` makes the
  seek and the write one step against other appenders and promises nothing
  about the bytes of the write itself.
- A line past `max_line_bytes` is discarded to the next newline, so the reader
  resynchronises instead of giving up on the stream.
- A blank line is skipped and counted (`skip_blank`). The specification says
  blank lines are not acceptable; a log that has been through an editor or a
  shell redirect has them anyway, and losing the rest of the file over one is
  not an improvement.
- Bytes that are not UTF-8 are a malformed line: this package rejects, it does
  not repair, and it does not substitute U+FFFD. Going the other way, a Zig
  `[]const u8` that is not valid UTF-8 is written by `std.json` as an array of
  byte values, which reads back here byte for byte and reads elsewhere as an
  array — a field carrying arbitrary bytes wants base64 or hex.
- A key that appears twice is `error.MalformedLine` by default, which is
  `std.json`'s position. Encoders elsewhere keep one of the two, so a log from
  one of them may need `duplicate_fields = .use_last` or `.use_first`.
- A line with no schema is `Reader(std.json.Value)`. `std.json` builds a
  `Value` on a heap stack rather than by recursing, so nesting depth is
  bounded by `max_line_bytes` and not by the call stack.
- A record over several lines is what `Writer`'s `.pretty` format emits. A
  `Reader` in `.pretty` mode joins lines until they parse, and reads minified
  lines too.

**A record separator says where a record begins.** JSON Lines has no resync
marker, so a line that does not parse is either damage or a record from a
writer that knows something this reader does not, and nothing tells the two
apart. `record_separator` on the writer and on both readers is RFC 7464's
framing: ASCII RS, 0x1E, in front of every record, the only byte that cannot
appear unescaped inside a JSON value. What lies before the first separator on
a line is the tail of a torn record and is dropped; a line carrying no record
at all is `error.MissingSeparator` rather than a line that might have been
meant. A reader in this mode does not read a stream without separators, and a
reader not in it does not read one with them — the byte is then a raw control
byte. It is a decision both ends make together, like the schema.

**Every refusal is a named error.**

| Error | Meaning |
|---|---|
| `error.MalformedLine` | This line is not a `T`. |
| `error.ControlByte` | This line holds a raw control byte. |
| `error.MissingSeparator` | This line carries no record, and the reader was told every line would. |
| `error.LineTooLong` | The line ran past `max_line_bytes`. A reader discards it whole; a writer refuses the record. |
| `error.ReadFailed` | The underlying `std.Io.Reader` failed; ask it for diagnostics. |
| `error.OutOfMemory` | The allocator failed. |

`Reader.fault` says which line the last of those was on (`fault.line`), what
`std.json` made of it (`fault.err`, null for a line it was never shown), and
where in the line it was (`fault.offset`: the control byte itself, or the byte
`std.json` gave up at). `Reader.skipped` counts the lines passed over under
`on_malformed = .skip`, and `Reader.offset` is where the line `next` last
returned or refused began. The first four do not desynchronize the stream: the
offending line has been consumed in full, so `next` can be called again. The
other two can arrive mid-line and leave the stream where they found it.
`Tail.prev` adds `error.SeekFailed` and `error.Truncated`; `Follower.next`
adds those, `error.ReopenFailed` and `error.Canceled`. Blank lines are skipped
by default and still counted, so a line number is the line a text editor
shows.

**A reader is not shared, and two readers need no arrangement.** A `Reader`, a
`Tail` and a `Follower` each hold their own buffers and share nothing else, so
two of them over two streams run on two threads as they are. One `Reader` is
not shared between threads.

**What a line costs.** `zig build bench -Doptimize=ReleaseFast` writes and
reads a million small lines and prints the numbers. On an Apple M3 Max, Zig
0.16.0:

| | |
|---|---|
| write | 44.7M lines/s, 2.05 GB/s, 22 ns/line |
| read | 13.7M lines/s, 0.63 GB/s, 72 ns/line, 1000000 of 1000000 strings borrowed |
| `writeAll` | 43.8M lines/s |
| `Tail.last(100)` of 1M lines | 67 µs, 65.54 kB of 45.89 MB touched |
| one 100 MB line | 66 ms, borrowed, 0 bytes of arena |

The borrowed count is how many string fields pointed into the line rather than
into the arena; a line that is already whole in the stream's buffer is not
copied anywhere before it is parsed. The arena figure is what one 100 MB line
cost beyond the line buffer. Those are one uniform line shape. Over mixed
lines — five kinds, one in seven carrying a note with escapes in it — the read
is 78 ns/line against a floor of 75 for the same parse with no line layer
over it at all. The suite holds the line layer to that floor rather than to an
absolute: *a line costs what the parse under it costs, within a tenth* times
this reader against that parse, and fails if the gap opens up.

## Scope

- Its decoder implements `std.json`'s typed field rules. Types with a custom
  `jsonParse` method use `std.json`'s token parser directly.
- It does not own, buffer or lock a stream, and opens a file only through an
  `Opener` you hand it.
- It does not index a log or seek to line *n*. `Line.offset` and
  `Reader.resumeAt` are the two halves an index is built from.
- It does not read a `.pretty` file backwards. `Tail.Options` says why.
- It does not decompress. Put `std.compress.flate.Decompress` in front of a
  `Reader`; `Tail` and `Follower` cannot help, because a compressed stream has
  no end to start from.
- It does not watch the filesystem and it does not drain on a timer.
  `Follower` polls, or waits on an event you set.

## Platforms

| Platform | What it uses there | Tested |
|---|---|---|
| Linux | The inode from `stat` identifies a file across a rotation; a sync is the `fdatasync` syscall | `ubuntu-latest` in CI, four optimize modes |
| macOS | The same, except that a sync is `fcntl(F_FULLFSYNC)` | `macos-latest` in CI, four optimize modes |
| Windows | The file index from `stat` stands in for the inode, and a sync is the system's own flush | `windows-latest` in CI, four optimize modes |

CI also compiles the suite without running it for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.
[`ci/linux.sh`](ci/linux.sh) runs Debug and ReleaseSafe in a Debian container
from a machine that is not Linux; it is a local script and no CI job calls it.

## Testing

`zig build test` runs 124 tests and the examples, every one under
`std.testing.allocator`, so a leak or an invalid free fails the test rather
than the process. CI runs that four times, in Debug, ReleaseSafe, ReleaseFast
and ReleaseSmall, with `zig fmt --check` beside it, and
[`ci/check-readme.sh`](ci/check-readme.sh) regenerates the code blocks above
from the examples and fails on a difference.

Eleven of the tests are properties over generated lines: every line is
reported under its own number and at its own byte offset, a reader resumed at
an offset agrees with one that read the whole stream, a bad line does not cost
the reader its place, a file read backwards is the same lines in the other
order and in the same places, a follower reads a replaced file in the right
order, a record written over several lines comes back as one, and a separated
stream gives up every record that was written to it whatever is torn in front
of them.

They run over a corpus in `src/corpus` and over a table of awkward inputs on
every `zig build test`, and over generated input two ways:

- `zig build test --fuzz` hands them to the compiler's fuzzer, which steers
  the next input by the coverage the last one reached and writes what it finds
  under `.zig-cache/f`. It runs until it is stopped, so it is the one to leave
  running rather than the one CI waits on. The test build turns error return
  tracing off, which is what it takes to compile the test runner the compiler
  links in fuzz mode on 0.16.0.
- `-Dcampaign=N` rounds of seeded input, `-Dseed=N` choosing which, driven
  through the same properties by the same generator with no coverage to steer
  it. This one ends, and a failure prints both numbers so the run repeats, so
  it is the mode a build can wait on: thirty-two rounds on a plain `zig build
  test`, twenty thousand in CI.

A `std.testing.Smith` can be driven from any bytes at all, which is what lets
one set of properties take input from either.

## Requirements

Zig 0.16.0.

## Licence

MIT. See [LICENSE](LICENSE).
