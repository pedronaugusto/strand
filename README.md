# strand

[![CI](https://github.com/pedronaugusto/strand/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/strand/actions/workflows/ci.yml)

Typed [JSON Lines](https://jsonlines.org) for Zig: one JSON value per line,
read and written on top of `std.json`, for append-only logs, line protocols and
event streams. `std.json` parses and emits the values; this is the line layer
over it, forwards over a stream, backwards from the end of a seekable file, or
along a file that is still being appended to.

## Usage

The code blocks are regions of the examples, which `zig build examples` builds
and runs: this one from [`examples/usage.zig`](examples/usage.zig), the three
below from [`examples/logbook.zig`](examples/logbook.zig). `.fixed` is what
makes this one self-contained; in a program the source is a file or a socket,
and any `*std.Io.Reader` will do.

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
    // Defaults, spelled out: a line the reader does not fully understand
    // is still a line, and one it cannot parse at all names itself.
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

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/strand
```

```zig
const strand_dep = b.dependency("strand", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("strand", strand_dep.module("strand"));
```

`std` is the only dependency. There is nothing to link and no build options to
match.

## The API

| | |
|---|---|
| `Reader(T)` | A `*std.Io.Reader` as a stream of typed lines. `next` returns a `Line(T)`: the value, the raw bytes, the 1-based number, the byte offset. |
| `Reader(T).resumeAt` | The same, starting at an offset with a line count behind it, so an index entry reads back as the line it named. |
| `Reader.nextRaw`, `Reader.parse` | A line's bytes with no type for them, and the value when the caller decides it wants one. This is how a stream is routed: `kindOf` or `tagOf` on the bytes, and a parse only for the lines worth parsing. |
| `Reader.keep` | A copy of a value that outlives the line it came from. |
| `Reader.fault`, `Reader.skipped` | Which line the reader last refused and why, and how many it has passed over. |
| `Writer(T)`, `Writer(T).initFile` | One value per line, minified or indented, counted. `initFile` is the one with a file to sync. |
| `Writer.flush`, `Writer.sync` | The one-off, beside `Options.flush` and `Options.sync`, which are the policy. |
| `writeLine` | One value, one line, nothing to count. |
| `Tail(T)` | A seekable file read backwards: `prev` for one line, `last(n)` for the end of the log. |
| `Follower(T)` | Read to the end, wait, carry on. `Opener` and `PathOpener` are how it follows a path across a rotation, and `Identity` is what makes two handles the same file. |
| `Follower.checkpoint`, `Follower.resumeFrom` | Where a follower stands, and a follower that carries on from there. |
| `Versioned(T)` | The `{"v":N,"data":...}` envelope, with a migration hook for an older shape. |
| `parseLine`, `lines` | One line, and a buffer of lines, already in memory. |
| `kindOf`, `tagOf` | The first key of an object, and the union arm it names, without parsing the value. |
| `indexOfControl`, `separator` | The first byte that must not appear raw in a line, and the one that marks where a record starts. |

## Memory

Three rules, the same for `Reader`, `Tail` and `Follower`.

1. **A value borrows from the reader.** `Line.line` is a slice of the
   stream's own buffer when the whole line was already sitting in it, and of
   the reader's line buffer when it was not; the value's strings point into
   that line when they needed no unescaping, and into the reader's arena when
   they did.
2. **The next line takes it back.** `next` reads the stream, clears the line
   buffer and resets the arena before it parses, so a stream costs what its
   longest line costs.
3. **`keep` is how a value outlives its line.** It copies every string onto an
   allocator you give it. Pass an arena and drop it whole; `Tail.last` is
   `keep` over a batch.

`parseLine` is the same without a reader. `lines`, `kindOf` and
`indexOfControl` allocate nothing; every allocation anywhere here is on an
allocator you passed in.

## Reading backwards

`Tail` walks a seekable file from its end towards its beginning, one block at a
time, and reads no further back than the lines it is asked for: the last ten
lines of a gigabyte cost one block read.

<!-- BEGIN GENERATED ci/readme_usage.sh examples/logbook.zig tail --no-import -->
```zig
// The last two lines, read off the end of the file. A backwards read
// touches the blocks those lines are in and nothing before them, so this
// costs the same on a file of three lines and a file of three million.
{
    const file = try dir.openFile(io, "log.jsonl", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    var tail: strand.Tail(strand.Versioned(Entry)) = try .init(gpa, &file_reader, .{});
    defer tail.deinit();

    // In file order, on an arena, borrowing nothing from the reader.
    for (try tail.last(arena, 2)) |entry| {
        std.debug.print("near the end: {s} at {d}\n", .{ entry.value.kind, entry.value.at });
    }
}
```
<!-- END GENERATED -->

A backwards read cannot count, so `Line.number` counts back from the end, 1
being the last line; `Line.offset` is an offset in the file and means the same
thing in both directions. A file that shrinks under a `Tail` is
`error.Truncated`. The rest is what `Reader` does.

## Following

`Follower` reads to the end of a file, waits, and carries on.

<!-- BEGIN GENERATED ci/readme_usage.sh examples/logbook.zig follow --no-import -->
```zig
// Following: read to the end of the file, wait for it to grow, carry on.
// There is no end to a file being appended to, so a follower stops when
// the `std.Io` cancels it — or, as here, when the caller stops asking.
var follower: strand.Follower(strand.Versioned(Entry)) = .init(gpa, io, &file_reader, .{
    .wait = .{ .poll = .fromMilliseconds(5) },
});
defer follower.deinit();

for (0..appended) |_| {
    const line = try follower.next();
    std.debug.print("followed: {s} at {d}\n", .{ line.value.value.kind, line.value.value.at });
}
```
<!-- END GENERATED -->

There is no `null`: a file being appended to has no end, so a follower stops
when the `std.Io` cancels it, or when the caller stops asking.

**The half-written line.** A reader that reaches the end of a growing file
mid-record must not hand that record over and must not lose the bytes.
`Follower` reads with `Reader.Options.require_terminator`, so a line the writer
has not finished is not a line, and rewinds the file to where it began. The
option is on a plain `Reader` too.

**Waiting.** `Follower` waits through the `std.Io` it was given — an
`Io.sleep`, or an `Io.Event` you set from a filesystem watch (`Wait.wake`) — so
cancelling the task cancels the wait. `error.Canceled` is how a follower ends,
including when the cancellation lands inside a read.

**Rotation** is handled when the follower is given an `Opener`, one call
returning the file a path names now, and is a contract when it is not:

| What happened | Without `Options.reopen` | With `Options.reopen` |
|---|---|---|
| Truncated in place | `error.Truncated`, and `truncated()` is true; `restart()` is what to do | Begun again at the top of the file, `rotations` counting it |
| Renamed and recreated | Nothing at all — the handle still refers to the old file, which stops growing | Followed across: the old file read to its end first, then the new one from its start, numbering from 1 again |

The follower asks the opener only once the file it holds has stopped growing,
which is what puts the old file first, and it closes handles it opened and
never the one it was given. `PathOpener` is the `Opener` over a directory and a
path. I made it an interface so a test can stage the two files itself instead
of racing a filesystem.

**Which file is which.** `Options.identity` is what makes two handles the same
file. The default is the number the system gives it — the inode, or the file
index on Windows — which is one call and no reading, and which a filesystem
may reuse for a new file or change for one it did not replace. `.fingerprint`
hashes the first bytes of the file instead: a log's opening lines are written
once and not written again, so they name the file in a way the filesystem
cannot take back, and a rotation that copies the log away and writes the same
file again from the top is a rotation rather than a silence. A file with fewer
bytes than the window is compared by number until it is long enough.

**Starting again.** `Follower.checkpoint` is where a follower stands: which
file, how far into it, what the next line is numbered, how many files it has
been through. `Follower.resumeFrom` builds a follower from one. The file it is
given is not necessarily the file the checkpoint was taken on, since a log can
rotate while nothing is following it, so the two are told apart by
`Options.identity`: the same file carries on at the recorded offset with the
recorded numbering, and a different one is read from its start and counted as
a rotation. A `Checkpoint` is a struct of integers, so a registry of them is a
JSON Lines file like any other.

## Durability

The writer does not own the destination and drains it only when told to.
`Writer.Options.flush` is `.never`, `.per_record`, `.per_batch` or
`.per_records`, so how often to drain is said once rather than at every call
site; `Writer.Options.sync` is the same four settings one level down.
`Writer.flush` and `Writer.sync` are the one-off, for a barrier at a
checkpoint or at the end of a run.

| | Survives the process | Survives the machine | Costs |
|---|---|---|---|
| `flush` | yes, from the record it drained | no — the operating system may hold the bytes as long as it likes | a write |
| `sync` | yes | yes, to the last record it synced | a disk write and a wait, and the slowest thing a log does |

`.per_records` is the setting a stream of records wants: one drain, or one
sync, for every *n* records however they arrive. The cost divided by *n*,
against losing up to *n*.

A sync drains first, whatever `flush` says, and needs a file, so
`Writer.initFile` is the constructor that can do it. What it calls depends on
the platform, because the platforms do not agree about what `fsync` promises:

| Platform | What a sync calls |
|---|---|
| Linux | `fsync`, which the filesystems in ordinary use turn into a write the drive has acknowledged |
| macOS | `fcntl(F_FULLFSYNC)`, because `fsync` there hands the bytes to the drive without waiting for the drive to write them down. A filesystem that has no such call gets `fsync`, which is then the strongest thing on it |
| Windows | the system's own flush of the file's buffers |

There is no `fdatasync` on any of them: it skips the timestamp writeback and
is the cheaper call for a log, and `std.Io.File` does not expose one.

A sync that fails is `error.SyncFailed`, and that writer takes no more
records. A failed sync is not a thing to try again — the kernel may drop the
error along with the data, so a second call can come back clean over a log
that has lost a record — and it is not a thing to write past either. Deal with
the file, then build a writer over it.

The directory entry is not covered — a file synced under a name its directory
has not recorded may not be there after a crash — because creating and opening
are the caller's.

`Writer.Options.max_line_bytes` is the other half of `Reader`'s bound: with no
bound a writer will emit a record no reader with the matching bound will read
back, and with one the record is refused where it is written and none of it
reaches the log. It costs a second encoding pass, so there is no bound unless
one is asked for.

## Schema over time

Adding a field is easy: a reader that defaults its missing fields copes. When a
field changes meaning, splits in two or moves, the line has to say which shape
it is in, and `Versioned(T)` is the `{"v":N,"data":...}` envelope that says it.
`T.jsonl_version` is what this build writes; `T.jsonlMigrate` is the hook an
older line goes through, taking the version and a `std.json.Value` and
returning today's shape. `payloadOf` parses the old shape inside the hook.

<!-- BEGIN GENERATED ci/readme_usage.sh examples/logbook.zig versioned --no-import -->
```zig
// The record, as this build understands it. Version 1 had no `scope` and
// wrote `at` as a string, so a line stamped 1 goes through the hook.
const Entry = struct {
    scope: []const u8 = "app",
    kind: []const u8,
    at: u64 = 0,

    pub const jsonl_version: u32 = 2;

    pub fn jsonlMigrate(
        allocator: std.mem.Allocator,
        from: u32,
        data: std.json.Value,
    ) std.json.ParseFromValueError!@This() {
        if (from != 1) return error.UnknownField;
        const old = try strand.payloadOf(struct {
            kind: []const u8,
            at: []const u8 = "0",
        }, allocator, data);
        return .{
            .scope = "app",
            .kind = old.kind,
            .at = std.fmt.parseInt(u64, old.at, 10) catch return error.InvalidNumber,
        };
    }
};

// A log with one line of the old shape on it, and two of the new.
var out: std.Io.Writer.Allocating = .init(arena);
try out.writer.writeAll(
    \\{"v":1,"data":{"kind":"open","at":"1"}}
    \\
);
var log: strand.Writer(strand.Versioned(Entry)) = .init(&out.writer, .{});
try log.writeAll(&.{
    .{ .value = .{ .scope = "net", .kind = "retry", .at = 2 } },
    .{ .value = .{ .kind = "close", .at = 3 } },
});

// Reading it back: every line arrives in today's shape, and says which
// shape it was written in.
var source: std.Io.Reader = .fixed(out.written());
var entries: strand.Reader(strand.Versioned(Entry)) = .init(gpa, &source, .{});
defer entries.deinit();
while (try entries.next()) |line| {
    std.debug.print("line {d}: v{d}{s} {s}/{s} at {d}\n", .{
        line.number,
        line.value.from,
        if (line.value.migrated()) " (migrated)" else "",
        line.value.value.scope,
        line.value.value.kind,
        line.value.value.at,
    });
}
```
<!-- END GENERATED -->

`v` first and `data` second, with the whole record inside `data`, so the
envelope cannot collide with it — a `T` with a field named `v` is a compile
error. `Versioned(T)` is an ordinary `std.json` type and composes:
`Reader(Versioned(T))`, `Writer(Versioned(T))`, `Tail(Versioned(T))`,
`Follower(Versioned(T))`. A line with no `v` is version
`T.jsonl_version_unstamped`, which defaults to 0; no `jsonl_version` may be 0,
so an unstamped line is always recognisable in the hook. A version no hook
accepts is `error.UnknownField`, which through a `Reader` is
`error.MalformedLine` with the line number. A tagged union grows without an
envelope instead: `std.json` writes `{"open":{...}}`, so the arm is the first
key, `tagOf` reads it without parsing the payload, and an
`unknown: std.json.Value` arm gives a line from a newer writer somewhere to
land. `examples/logbook.zig` has both recipes in full.

## What a line may contain

- **A UTF-8 byte-order mark** at the start of the stream is not part of the
  first line (`skip_bom`). Editors and Windows tooling put one there.
- **`\r\n`** is a terminator, and the `\r` is not part of the line.
- **A raw C0 control byte** other than tab — a NUL above all, which is what a
  torn write leaves behind — is `error.ControlByte` naming the line and the
  offset (`reject_control_bytes`). JSON forbids these raw in a string and has
  no use for them between tokens, so this refuses nothing that was valid. It
  is also the check that catches an interleaved append: `O_APPEND` makes the
  seek and the write one step against other appenders and promises nothing
  about the bytes of the write itself, so two processes appending to one log
  can leave half a record inside another.
- **A line past `max_line_bytes`** is discarded to the next newline, so the
  reader resynchronises instead of giving up on the stream. A `Writer` can be
  given the same bound, and then it refuses the record rather than writing a
  log that will not read back.
- **A blank line** is skipped and counted (`skip_blank`). The specification
  says blank lines are not acceptable; a log that has been through an editor
  or a shell redirect has them anyway, and losing the rest of the file over
  one is not an improvement.
- **A record separator** — ASCII RS, 0x1E — in front of every record is RFC
  7464's framing, and `record_separator` on the writer and on both readers is
  how to use it. It is the only byte that cannot appear unescaped inside a
  JSON value, so it is the only unambiguous "a record starts here" there is:
  with it, a torn record is bytes before a separator and is dropped, and a
  line carrying no record at all is `error.MissingSeparator` rather than a
  line that might have been meant. Without it, a line that does not parse is
  either damage or a record from a writer that knows something this reader
  does not, and nothing in JSON Lines tells the two apart.
- **A newline inside a string** cannot break the framing: `std.json` escapes
  it, and `Writer` refuses no value on these grounds.
- **Bytes that are not UTF-8** are a malformed line: this package rejects, it
  does not repair, and it does not substitute U+FFFD. Going the other way, a
  Zig `[]const u8` that is not valid UTF-8 is written by `std.json` as an array
  of byte values, which reads back here byte for byte and reads elsewhere as an
  array — a field carrying arbitrary bytes wants base64 or hex.
- **A key that appears twice** is `error.MalformedLine` by default, which is
  `std.json`'s position. Encoders elsewhere keep one of the two, so a log from
  one of them may need `duplicate_fields = .use_last` or `.use_first`.
- **A line with no schema** is `Reader(std.json.Value)`. `std.json` builds a
  `Value` on a heap stack rather than by recursing, so nesting depth is bounded
  by `max_line_bytes` and not by the call stack.
- **A record over several lines** is what `Writer`'s `.pretty` format emits. A
  `Reader` in `.pretty` mode joins lines until they parse, and reads minified
  lines too.

## Errors

| Error | Meaning |
|---|---|
| `error.MalformedLine` | This line is not a `T`. |
| `error.ControlByte` | This line holds a raw control byte. |
| `error.MissingSeparator` | This line carries no record, and the reader was told every line would (`record_separator`). |
| `error.LineTooLong` | The line ran past `max_line_bytes`. It is discarded whole. |
| `error.ReadFailed` | The underlying `std.Io.Reader` failed; ask it for diagnostics. |
| `error.OutOfMemory` | The allocator failed. |

`Reader.fault` says which line the last of those was on (`fault.line`), what
`std.json` made of it (`fault.err`, `null` for a line it was never shown), and
where in the line it was (`fault.offset`: the control byte itself, or the byte
`std.json` gave up at). `Reader.skipped` counts the lines passed over under
`on_malformed = .skip`, which is the number a stream that tolerates damage is
judged by. `Reader.offset` is where the line `next` last returned or refused
began.

The first four do not desynchronize the stream: the offending line has been
consumed in full, so `next` can be called again. The other two can arrive
mid-line and leave the stream where they found it. `Tail.prev` adds
`error.SeekFailed` and `error.Truncated`; `Follower.next` adds those,
`error.ReopenFailed` and `error.Canceled`. Blank lines are skipped by default
and still counted, so a line number is the line a text editor shows.

## Concurrency

A `Reader`, a `Tail` and a `Follower` each hold their own buffers and share
nothing else, so two of them over two streams run on two threads without
arrangement. One `Reader` is not shared between threads.

## Performance

`zig build bench -Doptimize=ReleaseFast` writes and reads a million small lines
and prints the numbers. On an Apple M-series laptop, Zig 0.16.0:

| | |
|---|---|
| write | 16.5M lines/s, 0.76 GB/s, 60 ns/line |
| read | 5.9M lines/s, 0.27 GB/s, 169 ns/line, 1000000 of 1000000 strings borrowed |
| `writeAll` | 16.6M lines/s |
| `Tail.last(100)` of 1M lines | 939 µs, 8.19 kB of 45.89 MB touched |
| one 100 MB line | 144 ms, borrowed, 232 bytes of arena |

Those are one uniform line shape. Over mixed lines — five kinds, one in seven
carrying a note with escapes in it — the same read is nearer 180 ns; what does
not change is where the time goes, which is `std.json`. The suite holds the
line layer to that: *a line costs what the parse under it costs, within a
tenth* times this reader against the same parse with no line layer over it at
all, and fails if the gap opens up.

The borrowed count is how many string fields pointed into the line rather than
into the arena; a line that is already whole in the stream's buffer is not
copied anywhere before it is parsed. The arena figure is what one 100 MB line
cost beyond the line buffer.

## Scope

- It does not parse JSON. `std.json` does, and every parse option that matters
  is forwarded. `std.json` has no multi-document mode — a scanner given a
  second top-level value refuses it — so a line layer is not a convenience
  here, it is how a stream of values is read at all.
- It does not own, buffer or lock a stream, and opens a file only through an
  `Opener` you hand it.
- It does not index a log or seek to line *n*. `Line.offset` and
  `Reader.resumeAt` are the two halves an index is built from.
- It does not read a `.pretty` file backwards. `Tail.Options` says why.
- It does not decompress. Put `std.compress.flate.Decompress` in front of a
  `Reader`; `Tail` and `Follower` cannot help, because a gzip stream has no end
  to start from.
- It does not watch the filesystem. `Follower` polls, or waits on an event you
  set.
- It does not drain on a timer. A writer is only called when there is a
  record; a caller that has a task has `flush` and `sync` to call from it.

## Platforms

| Platform | What it uses there | Tested |
|---|---|---|
| Linux | `std.Io.File` positional reads and seeks; the inode from `stat` identifies a file across a rotation; `fsync` for a sync | Suite on the Ubuntu CI runner in all four optimize modes, and in a Debian container by `ci/linux.sh` |
| macOS | the same, except that a sync is `fcntl(F_FULLFSYNC)` | Suite on the macOS CI runner in all four optimize modes |
| Windows | the same; the file index from `stat` stands in for the inode, and a sync is the system's own flush | Suite on the Windows CI runner in all four optimize modes |

CI also compiles the suite without running it for x86_64 and aarch64 Linux (gnu,
plus musl on x86_64), x86_64 and aarch64 Windows (gnu), and x86_64 and aarch64
macOS.

## Testing

`zig build test` runs 124 tests, every one under `std.testing.allocator`, in
Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. `ci/linux.sh` runs Debug and
ReleaseSafe in a container, because a cross-compile says nothing about reading
a file at an offset or about what a growing file looks like through an open
handle. `ci/check-readme.sh` regenerates the code blocks from the examples and
fails on a difference.

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
  test`, twenty thousand in CI on every push.

A `std.testing.Smith` can be driven from any bytes at all, which is what lets
one set of properties take input from either.

## Requirements

Zig 0.16.0.

## License

MIT. See [LICENSE](LICENSE).
