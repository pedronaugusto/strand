# zjsonl

[![CI](https://github.com/pedronaugusto/zjsonl/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zjsonl/actions/workflows/ci.yml)

Typed [JSON Lines](https://jsonlines.org) for Zig: one JSON value per line,
read and written on top of `std.json`. For append-only logs, line protocols
and event streams.

JSON Lines is the format a log already wants to be — a complete JSON value,
then `\n`, and nothing else on the line — because it stays greppable,
tailable and appendable, and frames a stream without a length prefix.
`std.json` has every piece needed to parse and emit the values. What it does
not have is the line layer, and a program that keeps a log ends up writing
that layer itself, usually three times:

- **A line is a unit of failure.** One bad line in a million-line log should
  name itself and be skippable, not abort the read. `zjsonl.Reader` reports
  `error.MalformedLine` with the line number and the underlying `std.json`
  error, and can be told to skip instead (`on_malformed = .skip`).
- **A line is a unit of memory.** A reader that allocates per line and frees
  per stream is a leak with a slow fuse. This reader recycles one line buffer
  and one arena, so a stream of any length costs what its longest line costs,
  and `keep` is the one call that copies a value out.
- **Strings should not be copied twice.** `std.json`'s `.alloc_if_needed`
  lets a string field point into the line's own bytes when it needs no
  unescaping, which is the common case for a log. `zjsonl` reads that way by
  default and documents exactly how long the borrow lasts.
- **A line has a kind.** `kindOf` reads the first key of the object, and
  `tagOf` turns it into the tag of a tagged union, without parsing the value —
  so a dispatcher can route a line to the right type before committing to it.
- **A log is read from its end.** `Tail` reads a seekable file backwards, last
  line first, touching the blocks those lines are in and nothing before them.
- **A log is read while it is written.** `Follower` reads to the end, waits on
  an `std.Io`, and carries on — and a half-written line is not a line.
- **A log outlives the program that wrote it.** `Versioned` puts a schema
  version on a record and brings an older one forward through a hook.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds
and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a
README is a claim about how the library is used, and this one is a claim
something executes. So are the three below it.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const zjsonl = @import("zjsonl");

// Write: one JSON value per line, minified, null optionals left out.
var out: std.Io.Writer.Allocating = .init(arena);
var log: zjsonl.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

// Read: a stream of typed lines, each with its number and its bytes.
var source: std.Io.Reader = .fixed(out.written());
var events: zjsonl.Reader(Event) = .init(std.heap.page_allocator, &source, .{
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
const kind = zjsonl.kindOf("{\"kind\":\"open\",\"at\":1}");
```
<!-- END GENERATED -->

`std.Io.Reader.fixed` above is what makes the example self-contained; in a
program the source is a file or a socket, and any `*std.Io.Reader` will do.

## Reading backwards

A log answers most questions from its end: what happened last, what the last
hundred events were, when the process stopped. `Tail` walks a seekable file
from its end towards its beginning, one block at a time, and stops as soon as
you do — so the last ten lines of a gigabyte cost one block read.

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

    var tail: zjsonl.Tail(zjsonl.Versioned(Entry)) = try .init(gpa, &file_reader, .{});
    defer tail.deinit();

    // In file order, on an arena, borrowing nothing from the reader.
    for (try tail.last(arena, 2)) |entry| {
        std.debug.print("near the end: {s} at {d}\n", .{ entry.value.kind, entry.value.at });
    }
}
```
<!-- END GENERATED -->

The one thing a backwards read cannot do is count: it never learns how many
lines came before the ones it read. `Line.number` therefore counts back from
the end, 1 being the last line of the file, and `Tail.offset` gives the byte
offset of the line just returned. Everything else — the borrow rule, `keep`,
`\r\n`, blank lines, control bytes, `max_line_bytes` — is what `Reader` does.

## Following

<!-- BEGIN GENERATED ci/readme_usage.sh examples/logbook.zig follow --no-import -->
```zig
// Following: read to the end of the file, wait for it to grow, carry on.
// There is no end to a file being appended to, so a follower stops when
// the `std.Io` cancels it — or, as here, when the caller stops asking.
var follower: zjsonl.Follower(zjsonl.Versioned(Entry)) = .init(gpa, io, &file_reader, .{
    .wait = .{ .poll = .fromMilliseconds(5) },
});
defer follower.deinit();

for (0..appended) |_| {
    const line = try follower.next();
    std.debug.print("followed: {s} at {d}\n", .{ line.value.value.kind, line.value.value.at });
}
```
<!-- END GENERATED -->

Two hard parts, and neither is parsing.

**The half-written line.** A reader that reaches the end of a growing file
mid-record must not hand that record over, and must not lose the bytes
either. `Follower` reads with `Reader.Options.require_terminator`, so a line
the writer has not finished is not a line, and rewinds the file to where that
line began. The same option is there on a plain `Reader` for anyone following
a file by other means.

**Waiting.** A follower that spins burns a core, and one that blocks forever
cannot be stopped. `Follower` waits on the `std.Io` it was given — an
`Io.sleep`, or an `Io.Event` you set from a filesystem watch
(`Wait.wake`) — so cancelling the task cancels the wait. `error.Canceled` is
the ordinary way a follower ends, including when the cancellation lands inside
a read rather than inside the wait.

**Rotation** is a contract rather than a feature, because this package does
not open files:

| What happened | What the follower sees | What to do |
|---|---|---|
| Truncated in place | `error.Truncated`, and `truncated()` is true | `restart()`: the file is being written again from the top |
| Renamed and recreated | Nothing at all — the handle still refers to the old file, which stops growing | Reopen the path yourself and make a new `Follower` |

## Schema evolution

Adding a field is easy: a reader that defaults its missing fields already
copes. The day a field changes meaning, splits in two, or moves, the defaults
stop being enough and the line has to say which shape it is in.

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
        const old = try zjsonl.payloadOf(struct {
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
var log: zjsonl.Writer(zjsonl.Versioned(Entry)) = .init(&out.writer, .{});
try log.writeAll(&.{
    .{ .value = .{ .scope = "net", .kind = "retry", .at = 2 } },
    .{ .value = .{ .kind = "close", .at = 3 } },
});

// Reading it back: every line arrives in today's shape, and says which
// shape it was written in.
var source: std.Io.Reader = .fixed(out.written());
var entries: zjsonl.Reader(zjsonl.Versioned(Entry)) = .init(gpa, &source, .{});
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

`v` first, `data` second, and everything the record holds inside `data`, so
the envelope can never collide with the record — a `T` with a field named `v`
is a compile error rather than a quiet mistake. `Versioned(T)` is an ordinary
`std.json` type, so it composes with the rest: `Reader(Versioned(T))`,
`Writer(Versioned(T))`, `Tail(Versioned(T))`, `Follower(Versioned(T))`.

A line with no `v` on it is version `T.jsonl_version_unstamped`, which
defaults to 0 — no `jsonl_version` may be 0, so an unstamped line is always
recognisable in the hook. A version no hook accepts is `error.UnknownField`,
which through a `Reader` is `error.MalformedLine` with the line number.

### Arms added over time

A tagged union is the other way a schema grows, and it grows without an
envelope: `std.json` writes `{"open":{...}}`, so the arm is the first key and
`tagOf` reads it without parsing the payload. What an old reader needs is
somewhere for an arm it has never heard of to land:

<!-- BEGIN GENERATED ci/readme_usage.sh examples/logbook.zig arms --no-import -->
```zig
const Message = union(enum) {
    open: struct { path: []const u8 },
    close: struct { code: u8 },
    /// Every arm this build does not know. Keep the bytes, not a guess.
    unknown: std.json.Value,
};

// Route on the tag, and give an unknown one the line rather than an error.
const message: Message = if (zjsonl.tagOf(Message, line)) |_|
    try zjsonl.parseLine(Message, arena, line, .{})
else
    .{ .unknown = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) };
```
<!-- END GENERATED -->

The rule is the same one `Versioned` follows: a reader that cannot understand
a record should say so and keep going, not stop the stream and not pretend.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/zjsonl
```

```zig
const zjsonl_dep = b.dependency("zjsonl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zjsonl", zjsonl_dep.module("zjsonl"));
```

There is nothing to link and nothing to configure: pure Zig, `std` only, no
build options, no C.

## Memory

Three rules, and they are the whole of it. They hold for `Reader`, for `Tail`
and for `Follower` alike.

1. **A line's value borrows from the reader.** `Line.line` is the reader's
   own line buffer, and the value's string fields point either into that
   buffer (when they needed no unescaping) or into the reader's arena (when
   they did).
2. **The next line takes it back.** `next` clears the line buffer and resets
   the arena before it parses, so everything the previous `Line` pointed at is
   gone by the time the next one is returned — which is exactly why the cost
   of a stream does not grow with its length.
3. **`keep` is how a value outlives its line.** It returns a copy allocated on
   an allocator you give it, with every string copied, borrowing nothing from
   the reader. Pass an arena and drop it when you are done. `Tail.last` is
   `keep` applied to a batch.

`parseLine` follows the same shape without a reader: allocations land on the
allocator you pass (use an arena), and strings borrow from the line you pass
unless you ask for `copy_strings`. `lines`, `kindOf` and `indexOfControl`
allocate nothing at all and return views into the buffer they were given.

## Errors

`Reader.next` has five failure modes, and only two of them are about the
content of a line:

| Error | Meaning |
|---|---|
| `error.MalformedLine` | This line is not a `T`. `last_error_line` says which line, `last_error` says what `std.json` made of it. |
| `error.ControlByte` | This line holds a raw control byte. `last_error_offset` says where in the line. |
| `error.LineTooLong` | The line ran past `max_line_bytes`. It is discarded whole. |
| `error.ReadFailed` | The underlying `std.Io.Reader` failed; ask it for diagnostics. |
| `error.OutOfMemory` | The allocator failed. |

The first three do not desynchronize the stream: the offending line is
consumed in full, so `next` can simply be called again. The other two can
arrive in the middle of a line and leave the stream wherever they found it.
Blank lines are skipped by default and still counted, so a line number always
means the line a text editor would show. `Tail.prev` adds `error.SeekFailed`
and `error.Truncated`; `Follower.next` adds those and `error.Canceled`.

## What a line may contain

The format is one value and a newline, and the awkward cases are the ones a
hand-rolled line layer gets wrong:

- **A UTF-8 byte-order mark** at the start of the stream is not part of the
  first line (`skip_bom`). Editors and Windows tooling put one there;
  `std.json` has no idea what it is.
- **`\r\n`** is a terminator, and the `\r` is not part of the line.
- **A raw C0 control byte** other than tab — a NUL above all, which is what a
  torn write leaves behind — is `error.ControlByte` naming the line and the
  offset rather than whatever `std.json` would have made of it. JSON forbids
  these bytes raw in a string and has no use for them between tokens, so this
  refuses nothing that was valid (`reject_control_bytes`).
- **A line past `max_line_bytes`** is discarded to the next newline, so the
  reader resynchronises rather than giving up on the stream.
- **A newline inside a string** cannot break the framing, because `std.json`
  escapes it. `Writer` refuses no value on these grounds and has no check to
  skip: *write escapes every terminator that could break the framing* in the
  suite writes every byte that could, and counts the newlines.
- **A record over several lines** is what `Writer`'s `.pretty` format emits,
  for a human to read; a `Reader` in `.pretty` mode joins lines until they
  parse and reads it back. A `.pretty` reader reads minified lines too.

## Concurrency

There is no global state, no lock and no allocator of its own, so two readers
on two streams are independent and run on two threads without arrangement.
One `Reader` is not shared between threads.

`Follower` is where `std.Io` matters: it waits through the `Io` it was given,
which makes cancellation the way a follower stops. The suite proves it with a
producer task writing a file a few bytes at a time while a consumer task
follows it, and with a follower on a file that never grows being stopped by
`Future.cancel`.

## Performance

`zig build bench -Doptimize=ReleaseFast` writes and reads a million small
lines and prints the numbers. On one laptop (Apple M-series, Zig 0.16.0):

| | |
|---|---|
| write | 17.1M lines/s, 0.79 GB/s, 58 ns/line |
| read | 5.7M lines/s, 0.26 GB/s, 176 ns/line, 1000000 of 1000000 strings borrowed |
| `writeAll` | 17.2M lines/s — the loop, not another format |
| `Tail.last(100)` of 1M lines | 780 µs, 8.19 kB of 45.89 MB touched |
| one 100 MB line | 173 ms, borrowed, 232 bytes of arena |

Two claims in that table are the ones worth checking rather than quoting.
*Every string borrowed*: nothing was copied out of the line, which is
`.alloc_if_needed` doing its job. *232 bytes of arena for a hundred
megabytes*: the reader allocated nothing per line — the suite holds it to
that too, in *a long stream stops allocating once its buffers have grown*,
which reads twenty thousand lines and counts the allocations after the first
thousand.

## What this package does not do

- It does not parse JSON. `std.json` does; this is the line layer over it,
  and every parse option that matters is forwarded rather than reinvented.
- It does not own, buffer, open, close, flush, lock or rotate a stream. It
  takes a `*std.Io.Reader`, a `*std.Io.Writer` or a `*std.Io.File.Reader` and
  leaves the rest to the caller — which is why rotation is a documented
  contract and not a feature.
- It does not index a log or seek to line *n*. `Tail` reads backwards from
  the end; it does not build a map of where lines are.
- It does not read a `.pretty` file backwards: finding where a multi-line
  record begins means parsing forwards.
- It does not validate a line it is not asked to parse: `kindOf` answering is
  not a claim that the line is valid JSON.
- It does not decode escapes in `kindOf`/`tagOf`. A first key containing a
  `\` is answered with `null` rather than a wrong guess; parse the line if
  you need it.
- It does not watch the filesystem. `Follower` polls, or waits on an event
  you set; the watch itself is yours.
- It has no global state, no threads of its own, no allocator of its own, and
  no dependency beyond `std`.

## Requirements

Zig 0.16.0. `zig build test` runs the suite — 65 tests, every one under
`std.testing.allocator`, in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall
on Linux, macOS and Windows. `ci/linux.sh` runs Debug and ReleaseSafe inside
a container, because a cross-compile proves nothing about reading a file at an
offset or about what a growing file looks like through an open handle.

Eight of the tests are `std.testing.fuzz` properties over generated lines:
nothing panics, nothing leaks, every line is reported under its own number, a
line that cannot be parsed does not cost the reader its place, a file read
backwards is the same lines in the other order, and a record written over
several lines comes back as one. A plain `zig build test` checks them over a
corpus and a table of awkward inputs, which is quick; `zig build test --fuzz`
runs them as a campaign.

## License

MIT. See [LICENSE](LICENSE).
