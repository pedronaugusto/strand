# strand

strand reads and writes Zig values as JSON, JSON Lines and ZON, through one
mapping core that every format shares. Zig 0.17.0 is required.

A value of any plain Zig type is parsed straight into that type, borrowed from
the input, copied into an owner of its own, or put on an arena the caller holds,
and every parse is bounded: its input, depth, items, strings, numbers, memory
and work all have finite limits a hostile document cannot get past. How a type
is written and read is declared on the type, in one `pub const strand`
declaration that every format honours: field names and aliases, renaming,
defaults, omission, unions tagged inside their objects, and codecs of the
type's own.

JSON Lines sits on the same JSON: a stream of typed records read and written
with their line numbers and byte offsets, read backwards off the end of a file,
followed as the file grows and across rotations, and synced as often as the log
needs it.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/strand`, then obtain the `strand` module through
`b.dependency` and add it to your executable's imports. Forward your target and optimize
settings.

The build exposes one module, `strand`, whose namespaces are `strand.core`,
`strand.json`, `strand.jsonl` and `strand.zon`. Zig analyses only what a program
names, so a program that names only `strand.json` compiles no JSON Lines or
airlock code.

## Usage

[examples/usage.zig](examples/usage.zig) writes a log of `Event`s, a struct with
`kind`, `at`, optional `note` and defaulted `level` fields, and reads it back. Its
`note` declares `.omit = .null_value`, so a null note is left off the line.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const strand = @import("strand");

var out: std.Io.Writer.Allocating = .init(arena);
var log: strand.jsonl.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

var source: std.Io.Reader = .fixed(out.written());
var events: strand.jsonl.Reader(Event) = .init(arena, &source, .{
    .parse = .{ .ignore_unknown_fields = true },
    .max_line_bytes = 64 * 1024,
    .on_malformed = .fail,
});
defer events.deinit();

var warnings: u32 = 0;
// A kept value has an owner of its own, here on the arena.
var last_open: ?strand.core.Parsed(Event) = null;
while (try events.next()) |line| {
    if (std.mem.eql(u8, line.value.kind, "open")) {
        last_open = try events.keep(arena, line);
    }
    if (line.value.level == .warn) warnings += 1;
    std.log.info("line {d}: {s}", .{ line.number, line.line });
}

const kind = strand.json.kindOf("{\"kind\":\"open\",\"at\":1}");
```
<!-- END GENERATED -->

[examples/logbook.zig](examples/logbook.zig) keeps a log on disk: versioned records
migrated as they are read, the last lines of a file read off its end, a follower
over a file being appended to and one resumed from a checkpoint, a union that
gained an arm, separated records, and a line protocol.

## JSON

`strand.json.parse(T, gpa, bytes, options)` returns a `Parsed(T)` whose strings
borrow from `bytes` where they need no unescaping: keep `bytes` alive and
unchanged while the value is used. `parseOwned` copies everything and is
independent of the input. `parseLeaky` puts the value on an arena the caller
owns and resets. `deinit` an owner exactly once.

Parsing is strict: an unknown field and a key given twice are refused unless the
options say otherwise, every string must be UTF-8, and an integer is converted
from its decimal digits with no float in between, so a number that does not fit
its type is refused rather than rounded. Ignored fields and `Raw` values are
checked like the rest. The default limits are 16 MiB of input or output, 128
levels, 1,048,576 items, 8 MiB strings, 64 KiB keys, 1,024 digits, 32 MiB of
memory and 128 Mi units of work; `ParseOptions.limits` raises or lowers them.
`json.Value` is a value of any shape, its numbers kept as written; `parseStdValue`
reads into `std.json.Value` under the same limits.

`strand.json.write(output, value, options)` writes checked JSON, minified or
indented. Output is published a stage at a time, so a failure can leave a prefix
in a destination that drains: write into a fixed or allocating writer first where
nothing must reach the sink unless all of it does. `writeObjectOpen` writes a
struct but for its closing brace, for a member computed over the bytes before it,
such as a checksum. `json.Raw` is one JSON value kept as its bytes: checked when it
is read, written back as it came (a line break between its tokens as a space, so a
record stays a line), `Raw.null` as a default, `Raw.encode` to make one from a value
and `raw.parse(T, arena, options)` to read one as a type.

A line can be routed without parsing it: `kindOf` reads its first key, `tagOf` the
arm of a union it holds, `memberOf` and `memberStringOf` one member wherever it
is, and `leadingIntMembers` the integers a line opens with, each as a view into
the line.

## JSON Lines

`strand.jsonl.Reader(T)` reads records off a `*std.Io.Reader`. A record and its
value last until the next read: `keep` copies one into an owner of its own.
Lines are numbered from 1 and placed by byte offset, `max_line_bytes` bounds each
one (a longer line is consumed whole and refused, and reading carries on), a raw
control byte marks a line as damaged, and `on_malformed = .skip` passes over bad
lines while counting them. `lines.fault` says which line was refused last, why
and where. `LineReader` is the same framing with nothing parsed, for a caller
with its own reading of a line; `Decoder(T)` is the same framing over chunks the
caller pushes.

`Writer(T)` writes one record a line and asks the destination to drain, and the
file to sync, as often as its policies say: never, per record, per batch or every
`n` records. A sync is [airlock](https://github.com/pedronaugusto/airlock)'s
`syncFile` at level `.data`, and `Writer.reached` says what the last one reached;
a failed sync stops the writer. A bounded writer refuses a record past its bound
before any of it is written. Pretty records span lines, and an ASCII record
separator in front of every record (RFC 7464) makes a torn write visible to the
reader.

`Tail(T)` reads a seekable file backwards, and `last(gpa, n)` hands back the last
`n` records in one owner. `Follower(T)` reads a file to its end and then as it
grows, on the `std.Io` each blocking call is given, follows a path across
rotations through an `Opener`, and takes a checkpoint to resume from: the file's
identity, the offset and the line number. `Versioned(T)` wraps a record as
`{"v":2,"data":{...}}` and hands an older one to the type's `jsonlMigrate`.

## ZON

`strand.zon` reads and writes ZON, the notation Zig writes its data in, with
`parse`, `parseOwned`, `parseLeaky` and `write` and the limits, ownership and
field policy of JSON. The grammar is `std.zon`'s, read in one pass with no syntax
tree, so a document is bounded before anything is allocated for it, and what is
not data (an import, a call, an operator, a name but `true`, `false`, `null`,
`inf` and `nan`) is not read. `write` produces `std.zon`'s own layout, byte for
byte, or only the whitespace the syntax needs with `.whitespace = false`.
[examples/zon.zig](examples/zon.zig) reads a settings file.

<!-- BEGIN GENERATED zig build docs -- zon -->
```zig
const strand = @import("strand");

const source =
    \\// What to run, and how hard to try.
    \\.{
    \\    .name = "nightly build",
    \\    .mode = .careful,
    \\    .tags = .{ "linux", "release" },
    \\    .limit = 0x10_000,
    \\}
;

// `name` and the tags are spans of `source`: nothing was copied for them.
var settings = try strand.zon.parse(Settings, gpa, source, .{});
defer settings.deinit();

// Written back in Zig's own layout; a default is a field like any other.
var out: std.Io.Writer.Allocating = .init(gpa);
try strand.zon.write(&out.writer, settings.value, .{});

// A mistake is an error that says where it was.
var diagnostics: strand.core.Diagnostics = .{};
const bad = ".{ .name = \"x\",\n   .retries = 300 }";
if (strand.zon.parse(Settings, gpa, bad, .{ .diagnostics = &diagnostics })) |_| {
    unreachable; // unreachable: 300 does not fit a u8.
} else |err| {
    std.log.info("{s}, line {d}", .{ @errorName(err), diagnostics.line.? });
}
```
<!-- END GENERATED -->

It differs from `std.zon` where strand's promises differ: a number past the width of
its type is an error and never infinity; a byte slice is text, or arbitrary bytes with
`.as = .bytes`, and a tuple of numbers is a list of numbers; an untagged union and a
nested optional have no meaning in ZON and are refused when the type is compiled.

## Design

[docs/design.md](docs/design.md) says how the parts are layered, what the core
promises and what each format adds. A type declares its mapping once and every
format reads the same declaration; a format supplies only its syntax. The core
uses `std` and [aegis](https://github.com/pedronaugusto/aegis), which is `std`
alone; JSON Lines adds airlock for syncs and file identity.

A type that holds resources (an allocator, a file, a lock) or memory with no safe
data meaning (many-item and C pointers) is refused when it is compiled, with the
path to the field that is the problem. A type with a meaning of its own declares
`strandSerialize` and `strandDeserialize`.

## Scope

- It does not lock or own the supplied stream.
- It does not open files except through a supplied `Opener`.
- It does not index a log or seek to a line by number.
- It does not read pretty records backwards or decompress a stream.
- It does not watch the filesystem or flush on a timer.
- CBOR, MessagePack, TOML, YAML, CSV and URL-encoded forms are later work.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library.
- [aegis](https://github.com/pedronaugusto/aegis) supplies the core's finite budgets,
  checked arithmetic, closed diagnostics text and always-on contracts.
- [airlock](https://github.com/pedronaugusto/airlock) syncs the file under a `Writer`
  and numbers files for a `Follower`.
- [shakedown](https://github.com/pedronaugusto/shakedown) supplies the tests' doubles:
  faulted and counted `Io` calls and allocators, and airlock's syncs through
  `airlock.testing`, its test seam. Shakedown is a test dependency.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.

## Testing

`zig build test` runs the unit suite, scratch tests and examples in Debug by default.
The suite covers framing, codec agreement with `std.json`, owned copies, rotation,
cancellation and malformed records. Properties run from corpus inputs and 32 seeded
rounds by default; `-Dcampaign=N` and `-Dseed=N` select a generated-input run. `zig
build test --fuzz` runs the coverage-guided targets until stopped. CI also runs
`zig build lint`.

[CI](.github/workflows/ci.yml) has three tiers. Fast runs the source checks,
Linux Debug tests and examples, and cross-target compilation. Merge adds the
configured macOS/Windows SDK links and native Debug test replay. Release adds
optimized configurations, full configured cross coverage and Linux ThreadSanitizer.
Merge/release also try Zig master in a non-blocking job. The profile job refreshes
recorded test durations; it does not execute a larger generated-input campaign.
Run a larger campaign explicitly with `zig build test -Dcampaign=20000 -Doptimize=safe`.

Zig 0.17.0 on aarch64 macOS miscompiles a vector whose size is not a power of two,
such as `@Vector(3, u128)` (48 bytes), held in an optional or in an aggregate inside
one: in ReleaseSafe and ReleaseFast the payload can read back as `null`, Debug is
right. It shows without strand in a dozen lines. `Versioned` keeps its payload as a
value and a flag so that a record with such a field survives it, and the tests compare
these vectors as arrays. Types you hold in an optional yourself are yours to check.

`zig build bench` times the benchmarks in [bench/](bench/) in ReleaseFast. `zig build
test` runs them once with `--smoke`, over tiny inputs and without reading a clock.
Regular correctness gates compile or smoke-run the comparison drivers. The
`Manual indicative observations` workflow takes hosted observations when
dispatched; variable wall-clock performance never gates correctness.

`zig build check` compiles without running. CI uses it for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
