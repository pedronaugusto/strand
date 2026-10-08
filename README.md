# strand

strand's serialization framework is work in progress. The JSON Lines API below
is implemented. The provisional std-only `strand.core` module adds type-declared
field policy, semantic mapping, bounded allocation and traversal, and explicit
borrowed or owned results. Its small reference backend exercises those contracts;
it is a test format. See [the core design](docs/design.md) for supported types,
ownership and backend obligations.

JSON and JSONL migration onto this core, ZON, CBOR, MessagePack and TOML belong to
later phases and are not implemented here. Existing JSON Lines users continue to
use the API below.

strand reads and writes typed JSON Lines in Zig. Records carry their line number and
byte offset, and damaged lines can be refused or skipped while reading continues.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/strand`, then obtain the `strand` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/usage.zig](examples/usage.zig) uses an `Event` struct with `kind`, `at`,
optional `note` and defaulted `level` fields. `arena` is released after the retained
values are used.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const strand = @import("strand");

var out: std.Io.Writer.Allocating = .init(arena);
var log: strand.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

var source: std.Io.Reader = .fixed(out.written());
var events: strand.Reader(Event) = .init(arena, &source, .{
    .ignore_unknown_fields = true,
    .max_line_bytes = 64 * 1024,
    .on_malformed = .fail,
});
defer events.deinit();

var warnings: u32 = 0;
var last_open: ?Event = null;
while (try events.next()) |line| {
    if (std.mem.eql(u8, line.value.kind, "open")) {
        last_open = try events.keep(arena, line);
    }
    if (line.value.level == .warn) warnings += 1;
    std.log.info("line {d}: {s}", .{ line.number, line.line });
}

const kind = strand.kindOf("{\"kind\":\"open\",\"at\":1}");
```
<!-- END GENERATED -->

## Design

strand uses only `std`. Readers take an allocator for a reusable line buffer and
per-record arena; unescaped strings can borrow from the input. A returned line and its
value last until the next read or `deinit`. `keep` copies the value through `copyOwned`,
preserving edits without parsing again; release the copy with `freeOwned` or its arena.
The owned-copy contract rejects unsupported pointer shapes at compile time. Separate
readers have independent state; one reader is not shared between threads.

`LineReader` frames and checks bytes without parsing. `Reader(T)` decodes them into `T`,
following `std.json`'s typed rules and custom hooks. `max_line_bytes` bounds the JSON
payload, excluding its terminator, optional separator and discarded torn prefix.
An oversized record is consumed to its end before the next record is framed, also
when its end arrives later in a growing file. With `record_separator`, every separator
starts a record: a torn record is dropped and counted, and the record after it on the
same line is read. `lines.fault` records the last refusal's line, byte offset and parse
cause; `on_malformed = .skip` counts skipped lines. Unknown fields are ignored by default and duplicate fields are errors by default.

`Writer(T)` writes to a caller-owned `*std.Io.Writer`. `init` and `initFile` stream
records without owned scratch. `initBounded` and `initFileBounded` take an allocator and
byte limit, encode into reusable owned storage and refuse an oversized record before
emitting it; these writers require `deinit`. Flush and sync policies are set separately
to never, per record, per batch or every specified number of records. Sync requires a
file writer, drains it first and latches a failure so later records are refused. A
sync is [airlock](https://github.com/pedronaugusto/airlock)'s `syncFile` at level
`.data`: `fdatasync` on Linux, `F_FULLFSYNC` on macOS, a data-only flush on Windows
NTFS. A filesystem that declines it gets the strongest call it takes, and
`Writer.reached` says what the last sync reached. Directory durability remains the
caller's responsibility.

`Tail(T)` reads a seekable file backwards. `Follower(T)` waits for complete terminated
records on the `std.Io` each blocking call is given (`next`, `checkpoint`, `truncated`
and `deinit`; it keeps none), and stops with `error.Canceled` when that `std.Io` is
cancelled. A supplied
`Opener` lets it follow replacement files after draining the old one, waiting while the
path names nothing between a rotation's rename and its create. File identity can
use the platform's file identifier or an opening-byte fingerprint; checkpoints retain
that identity, the byte offset and line numbering.

`kindOf` and `tagOf` route a line by its first key without parsing it. `memberOf` and
`memberStringOf` read one top-level member's scalar value wherever it sits, the first of
a repeated one, as a view into the line. A union that declares
`pub const jsonl_tag = "type"` is read and written tagged inside its object
(`{"type":"assistant",...}`), the arm a member of the record; `jsonl_other` names the arm
for a tag no arm has, holding nothing or the record as a `Raw`. A missing, repeated or
non-string tag is refused, and `tagOf` reads the arm from the tag member.

`Raw` retains a JSON value's bytes for later parsing or forwarding. `Versioned(T)` wraps
records with a version and a migration hook. Both compose with the readers and writer.
Parsing a `Raw` checks JSON syntax and UTF-8 before returning its bytes.
Pretty records span physical lines; ASCII record separators provide optional RFC 7464
framing when enabled at both ends. [examples/logbook.zig](examples/logbook.zig)
exercises file following, tailing and a line protocol.

For a caller that frames its own lines, `writeValue` and `writeObjectOpen` write one
value's JSON without a terminator, `lines` walks the lines of a buffer already in
memory, `indexOfControl` finds a raw control byte, and `memberOf`, `kindOf` and
`leadingIntMembers` read members of a line without parsing it. `FileId` is airlock's,
a file named by its volume and number, as `Follower` uses it to notice a rotation.

## Scope

- It does not lock or own the supplied stream.
- It does not open files except through a supplied `Opener`.
- It does not index a log or seek to a line by number.
- It does not read pretty records backwards or decompress a stream.
- It does not watch the filesystem or flush on a timer.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [airlock](https://github.com/pedronaugusto/airlock) syncs the file under a `Writer`
  and numbers files for a `Follower`.
- [shakedown](https://github.com/pedronaugusto/shakedown) supplies the tests' doubles:
  faulted and counted `Io` calls and allocators, and airlock's syncs through
  `airlock.testing`, its test seam. Only the tests import them, so a project
  depending on strand never fetches them.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.

## Testing

`zig build test` runs the unit suite, scratch tests and examples in Debug by default.
The suite covers framing, codec agreement with `std.json`, owned copies, rotation,
cancellation and malformed records. Properties run from corpus inputs and 32 seeded
rounds by default; `-Dcampaign=N` and `-Dseed=N` select a generated-input run. `zig
build test --fuzz` runs the coverage-guided targets until stopped. CI also runs
`zig build lint`.

[CI](.github/workflows/ci.yml) has three tiers. The fast tier runs the source checks and
the Debug suite with the examples on `ubuntu-latest`, and compiles the macOS and Windows
test binaries. The merge tier also runs those binaries on `macos-latest` and
`windows-latest`. The release tier runs Debug and ReleaseSafe on all three hosts,
ReleaseFast on Ubuntu, ReleaseSmall compile-only, every cross target and
ThreadSanitizer. The merge and release tiers add a 20,000-round property campaign in
ReleaseSafe on Ubuntu, and run the Debug suite on Ubuntu with Zig master, a job that
reports and never blocks.

`zig build bench` times the benchmarks in [bench/](bench/) in ReleaseFast. `zig build
test` runs them once with `--smoke`, over tiny inputs and without reading a clock; CI
times nothing.

`zig build check` compiles without running. CI uses it for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
