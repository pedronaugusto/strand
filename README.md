# strand

strand reads and writes typed JSON Lines in Zig. Records carry their line number and
byte offset, and damaged lines can be refused or skipped while reading continues.

## Install

Requires Zig 0.16.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/strand`, then obtain the `strand` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

## Usage

[examples/usage.zig](examples/usage.zig) uses an `Event` struct with `kind`, `at`,
optional `note` and defaulted `level` fields. `arena` is released after the retained
values are used.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const strand = @import("strand");

var out: std.Io.Writer.Allocating = .init(arena);
var log: strand.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

var source: std.Io.Reader = .fixed(out.written());
var events: strand.Reader(Event) = .init(std.heap.page_allocator, &source, .{
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
    std.debug.print("line {d}: {s}\n", .{ line.number, line.line });
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
Oversized records are consumed before the next read. `lines.fault` records the last
refusal's line, byte offset and parse cause; `on_malformed = .skip` counts skipped
lines. Unknown fields are ignored by default and duplicate fields are errors by default.

`Writer(T)` writes to a caller-owned `*std.Io.Writer`. `init` and `initFile` stream
records without owned scratch. `initBounded` and `initFileBounded` take an allocator and
byte limit, encode into reusable owned storage and refuse an oversized record before
emitting it; these writers require `deinit`. Flush and sync policies are set separately
to never, per record, per batch or every specified number of records. Sync requires a
file writer, drains it first and latches a failure so later records are refused.
Directory durability remains the caller's responsibility.

`Tail(T)` reads a seekable file backwards. `Follower(T)` waits for complete terminated
records and stops with `error.Canceled` when its `std.Io` is cancelled. A supplied
`Opener` lets it follow replacement files after draining the old one, waiting while the
path names nothing between a rotation's rename and its create. File identity can
use the platform's file identifier or an opening-byte fingerprint; checkpoints retain
that identity, the byte offset and line numbering.

`kindOf` and `tagOf` route a line by its first key without parsing it. `memberOf` and
`memberStringOf` read one top-level member's scalar value wherever it sits, as a view
into the line.

`Raw` retains a JSON value's bytes for later parsing or forwarding. `Versioned(T)` wraps
records with a version and a migration hook. Both compose with the readers and writer.
Parsing a `Raw` checks JSON syntax and UTF-8 before returning its bytes.
Pretty records span physical lines; ASCII record separators provide optional RFC 7464
framing when enabled at both ends. [examples/logbook.zig](examples/logbook.zig)
exercises file following, tailing and a line protocol.

## Scope

- It does not lock or own the supplied stream.
- It does not open files except through a supplied `Opener`.
- It does not index a log or seek to a line by number.
- It does not read pretty records backwards or decompress a stream.
- It does not watch the filesystem or flush on a timer.

<!-- performance: quiet pass -->

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap in `ci/cache.sh`; run `sh ci/cache.sh` before direct Zig builds (only a rebuild is lost).

`zig build test` runs the unit suite, scratch tests and examples in Debug by default.
The suite covers framing, codec agreement with `std.json`, owned copies, rotation,
cancellation and malformed records. Properties run from corpus inputs and 32 seeded
rounds by default; `-Dcampaign=N` and `-Dseed=N` select a generated-input run. `zig
build test --fuzz` runs the coverage-guided targets until stopped. CI also runs
`ci/check-readme.sh`.

[CI](.github/workflows/ci.yml) runs tests and examples in Debug and ReleaseSafe on
`ubuntu-latest`, `macos-latest` and `windows-latest`, plus ReleaseFast on Ubuntu.
ReleaseSmall is compile-only on Ubuntu. Separate Ubuntu jobs run ThreadSanitizer in
Debug and a 20,000-round property campaign in ReleaseSafe, and check formatting and cast
reasons.

`zig build check` compiles without running. CI uses it for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
