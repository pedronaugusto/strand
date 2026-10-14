# strand

strand reads and writes Zig values as JSON, JSON Lines, ZON, URL-encoded forms,
CSV, CBOR, MessagePack, TOML and YAML, through one mapping core that every format shares. Zig 0.17.0 is required.

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
`strand.json`, `strand.jsonl`, `strand.zon`, `strand.urlencoded`, `strand.csv`,
`strand.cbor`, `strand.msgpack`, `strand.toml` and `strand.yaml`. Zig analyses only what a program
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
reads into `std.json.Value` under the same limits. `json.jsonc.parse`, `parseOwned`
and `parseLeaky` read JSONC, the JSON of editors' settings and `tsconfig.json`: `//`
and `/* */` comments wherever whitespace may be, and a comma after a container's last
member or element, with JSON's options and promises. Writing is plain JSON whatever
was read. `json.jcs.write` and `json.jcs.canonicalize` write the JSON Canonicalization
Scheme (RFC 8785), one spelling for every value, for hashing and signing: members sorted
by their names' UTF-16 code units, numbers as ECMAScript writes doubles, no whitespace; a
name given twice, and a typed integer past ±(2^53−1), are refused.

`strand.json.write(output, value, options)` writes checked JSON, minified or
indented. A null optional is written as `null`, or left off with `.nulls = .omit`
(one field says the same for itself with `.omit = .null_value`). Output is published a stage at a time, so a failure can leave a prefix
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

## URL-encoded forms

`strand.urlencoded` reads and writes application/x-www-form-urlencoded: the
bodies of HTML forms and the query strings of URLs (without the `?`), with
`parse`, `parseOwned`, `parseLeaky` and `write` and the limits, ownership and
field policy of the other formats. Pairs are split as the WHATWG URL standard
splits them, `+` is a space and `%XX` a byte; a `%` not followed by two
hexadecimal digits is refused rather than kept. A name's bracketed path makes
the flat pairs a tree, read as the type asks wherever the pairs stand:
`user[name]` is a member of a record, `tag=a&tag=b` and `tag[]=a&tag[]=b` are a
sequence of values. Every value is text until the type asks for a number (in
JSON's spelling), a boolean (`true`, `false`), a name or raw bytes. A form has no
null and no sequence of records: `write` leaves out a null, an empty sequence and
a record of nothing, so those fields read back through their defaults, and refuses
a sequence of records. It writes what a browser's form serializer writes, every
byte but letters, digits and `*-._` percent-encoded, brackets included.
[examples/form.zig](examples/form.zig) reads a search query.

<!-- BEGIN GENERATED zig build docs -- form -->
```zig
const strand = @import("strand");

// `+` is a space, `%XX` a byte; the brackets may come encoded or not.
const query = "q=zig+serde&tag=json&filter%5Blang%5D=zig&tag=toml&filter[stars]=100";
var search = try strand.urlencoded.parse(Search, gpa, query, .{});
defer search.deinit();
std.debug.assert(std.mem.eql(u8, search.value.q, "zig serde"));
std.debug.assert(search.value.tag.len == 2);
std.debug.assert(search.value.filter.stars.? == 100);

// Written as a browser's form serializer writes it.
var out: std.Io.Writer.Allocating = .init(gpa);
try strand.urlencoded.write(&out.writer, search.value, .{});
std.debug.assert(std.mem.eql(u8, out.written(), "q=zig+serde&page=1&tag=json&tag=toml&filter%5Blang%5D=zig&filter%5Bstars%5D=100"));

// A name given twice where one value belongs is refused.
if (strand.urlencoded.parse(Search, gpa, "q=a&q=b", .{})) |_| {
    unreachable; // unreachable: `q` holds one value.
} else |err| std.debug.assert(err == error.DuplicateField);
```
<!-- END GENERATED -->

## CSV

`strand.csv` reads and writes CSV as RFC 4180 has it, with `parse`, `parseOwned`,
`parseLeaky` and `write` for a whole document and `Reader(T)` and `Writer(T)` for a
row at a time, and the limits, ownership and field policy of the other formats. A
document is a slice of rows: a struct, read by the header's names in whatever order
the columns stand, or a tuple or an array, read by position where there is no header.
A `Dialect` names the delimiter, the quote, whether there is a header and the line
ending written; CRLF and LF both end a record read. A field holding the delimiter, the
quote or a line break is quoted, its quotes doubled; a quote anywhere else, a field
count that is not the header's, and a lone carriage return are refused. Every field
is text until the type asks for a number (in JSON's spelling), a boolean, a name or
bytes; an empty unquoted field is a null where the type takes one, and the writer
quotes empty text so it reads back as text. A field holds a value alone: a nested
record or sequence is refused. `Reader` frames rows on JSON Lines' line reader,
joining lines while a quoted field is open, held to `max_row_bytes`; a row that is not
a `T` is `error.MalformedRow`, and the reader reads on.
[examples/table.zig](examples/table.zig) reads a table of readings.

<!-- BEGIN GENERATED zig build docs -- csv -->
```zig
const strand = @import("strand");

// Columns in any order; a quoted field may hold commas, quotes and lines.
const table =
    "celsius,station,note\r\n" ++
    "21.5,\"Lisbon, PT\",\r\n" ++
    "-3,Oslo,\"wind \"\"strong\"\"\"\r\n";
var readings = try strand.csv.parse([]const Reading, gpa, table, .{});
defer readings.deinit();
std.debug.assert(std.mem.eql(u8, readings.value[0].station, "Lisbon, PT"));
// An empty field is a null where the type takes one.
std.debug.assert(readings.value[0].note == null);

// Written in the struct's order, with RFC 4180's quoting.
var out: std.Io.Writer.Allocating = .init(gpa);
try strand.csv.write(&out.writer, readings.value, .{});
std.debug.assert(std.mem.startsWith(u8, out.written(), "station,celsius,note\r\n\"Lisbon, PT\",21.5,\r\n"));

// A row at a time off a reader, numbered, in a dialect of its own.
var source: std.Io.Reader = .fixed("station;celsius\nRome;30\n");
var rows: strand.csv.Reader(Reading) = .init(gpa, &source, .{ .parse = .{ .dialect = .{ .delimiter = ';' } } });
defer rows.deinit();
while (try rows.next()) |row| {
    std.debug.assert(row.number == 1);
    std.debug.assert(row.value.celsius == 30);
}
```
<!-- END GENERATED -->

## CBOR

`strand.cbor` reads every well-formed RFC 8949 item and writes preferred
serialization: the shortest heads, the shortest float that holds a value exactly,
definite lengths. `parse`, `parseOwned`, `parseLeaky` and `write` keep the other
formats' limits, ownership and field policy; a definite string is borrowed, a chunked
one joined. Text and byte strings stay apart, integers run from -2^64 to 2^64 - 1, and
a length past the input is refused before anything is counted for it. A typed value
takes what it asked for: a tag it did not ask for, `undefined` and a simple value are
refused. `cbor.Value` holds any item with its distinctions (tags, simple values,
`undefined`, keys of any kind); `cbor.Tagged(T, n)`, `cbor.Bignum` (tags 2 and 3),
`cbor.DateTime` (tag 0) and `cbor.Epoch` (tag 1) ask for their tags by name.
`.profile = .deterministic` writes RFC 8949's core deterministic encoding (map keys
sorted by their encodings) and `.length_first` its length-first ordering, each on an
allocator, refusing a key given twice.

## MessagePack

`strand.msgpack` reads every format family of the MessagePack specification and
writes each value in its smallest format, as the specification asks: the shortest
integer family, float 32 wherever it holds a float's bits (a NaN's payload included),
the shortest length header. `parse`, `parseOwned`, `parseLeaky` and `write` keep the
other formats' limits, ownership and field policy; strings, binaries and extension
data are borrowed from the input. str is strict UTF-8 and stays apart from bin,
integers run from -2^63 to 2^64 - 1 and never become floats or enum names, the
reserved byte 0xc1 is refused, and a length past the input is refused before anything
is counted for it. `msgpack.Value` holds any value with its distinctions;
`msgpack.Ext` any extension with its type and data, and `msgpack.Timestamp` the
timestamp extension (type -1) in all three forms, nanoseconds checked.
`.profile = .deterministic` sorts each map's entries by their encoded keys, on an
allocator, and refuses a key given twice: strand's own profile, as MessagePack defines
none. A tuple of scalars is read and written with no allocation at all.

## TOML

`strand.toml` reads TOML 1.1.0, or 1.0.0 with `.version = .v1_0`, and writes documents
both read. `parse`, `parseOwned`, `parseLeaky` and `write` keep the other formats'
limits, ownership and field policy. A document is read whole before its first value is
handed on, since TOML writes a table in parts (headers, dotted keys, arrays of tables),
and every rule about defining a table is checked as it is read: a key given twice, a
table defined twice, a table added to an inline one, a static array extended by
`[[...]]` are refused whatever the type asks. Integers are TOML's signed 64 bits and
floats binary64, both refused past their range rather than rounded; an integer reads
where a float belongs. The four kinds of date and time are types of their own,
`toml.OffsetDateTime`, `toml.LocalDateTime`, `toml.LocalDate` and `toml.LocalTime`,
never one read as another or as text, a fraction kept to the nanosecond (finer digits
truncated, as TOML says); in another format each is its RFC 3339 text. TOML has no
null: an optional is absent, and a write refuses a null unless `.nulls = .omit` leaves
it out. `toml.Value` holds any document with its distinctions. The writer, on the
allocator given, puts a table's values before its tables, each table under its
`[header]`, an array of tables as `[[sections]]`, anything else inline.
[examples/config.zig](examples/config.zig) reads a service's configuration.

<!-- BEGIN GENERATED zig build docs -- toml -->
```zig
const strand = @import("strand");

const text =
    \\name = "relay"
    \\started = 2026-10-14 09:30:00+01:00
    \\listen = { host = "0.0.0.0", port = 8_443 }
    \\
    \\[[jobs]]
    \\kind = "backup"
    \\path = "/var/relay"
    \\
    \\[[jobs]]
    \\kind = "report"
    \\to = "ops@example.com"
;
var config = try strand.toml.parse(Config, gpa, text, .{});
defer config.deinit();
std.debug.assert(config.value.listen.port == 8443);
std.debug.assert(config.value.started.offset_minutes == 60);
std.debug.assert(config.value.jobs[0].backup.keep == 7);

// Written back: values first, then each table under its header. TOML
// has no null, so a null optional is left out only when asked.
var out: std.Io.Writer.Allocating = .init(gpa);
try strand.toml.write(&out.writer, config.value, .{ .allocator = gpa, .nulls = .omit });
std.debug.assert(std.mem.startsWith(u8, out.written(), "name = \"relay\"\nstarted = 2026-10-14T09:30:00+01:00\n\n[listen]\n"));

// Any document as a value, its four kinds of date and time kept apart.
var value = try strand.toml.parse(strand.toml.Value, gpa, "day = 2026-10-14\nat = 07:30", .{});
defer value.deinit();
std.debug.assert(value.value.get("day").? == .local_date);
std.debug.assert(value.value.get("at").?.local_time.hour == 7);
```
<!-- END GENERATED -->

## YAML

`strand.yaml` reads YAML 1.2 under its core schema and writes block-style documents.
`parse`, `parseOwned` and `parseLeaky` read a stream's one document (no document is an
empty one, null; a second is refused), `parseStream` and its owned and arena forms read
every document, and `write` and `writeStream` write them, all with the other formats'
limits, ownership and field policy. Block and flow collections, every scalar style,
directives and multi-document streams are read, and so are anchors and aliases: an
alias is its anchor's node again. Their expansion is held to the item limit before
anything is read, so aliases of aliases cannot grow a small document past it. A plain
scalar is what the field reading it asks for, where its spelling is one (`version: 1.10`
reads into a string as `1.10` and into a float as 1.1), and otherwise what the core
schema says: null, a boolean, an integer, a float, else a string. No YAML 1.1 forms:
`yes`, `on` and `0b1` are strings. A tag the core schema lacks (`!foo`, `!!binary`) is
refused rather than read with its meaning dropped, and so is a key given twice in a
mapping. `yaml.Value` holds any document, mapping keys of any kind included. The writer
quotes a string only where it would read back as something else.
[examples/deploy.zig](examples/deploy.zig) reads a stream of services.

<!-- BEGIN GENERATED zig build docs -- yaml -->
```zig
const strand = @import("strand");

const text =
    \\name: api
    \\image: registry.example/api
    \\version: 1.10        # a string field: read as written
    \\replicas: 3
    \\requests: {cpu: 0.25, memory: 128Mi}
    \\limits: {cpu: 1, memory: 512Mi}
    \\ports: [8080, 9090]
    \\---
    \\name: worker
    \\image: registry.example/worker
    \\version: 2.0
    \\requests: &small {cpu: 0.5, memory: 256Mi}
    \\limits: *small       # the anchor's mapping again
    \\debug: true
;
var services = try strand.yaml.parseStream(Service, gpa, text, .{});
defer services.deinit();
std.debug.assert(services.value.len == 2);
std.debug.assert(std.mem.eql(u8, services.value[0].version, "1.10"));
std.debug.assert(services.value[1].limits.cpu == 0.5);
std.debug.assert(services.value[1].replicas == 1);

// Written back, one document after another: a string that would read
// as something else is quoted.
var out: std.Io.Writer.Allocating = .init(gpa);
try strand.yaml.writeStream(&out.writer, services.value, .{});
std.debug.assert(std.mem.startsWith(u8, out.written(), "name: api\nimage: registry.example/api\nversion: \"1.10\"\n"));

// Any document as a value, by the core schema: no YAML 1.1 booleans.
var value = try strand.yaml.parse(strand.yaml.Value, gpa, "on: yes\nretries: 0x10\nratio: .5", .{});
defer value.deinit();
std.debug.assert(std.mem.eql(u8, value.value.field("on").?.string, "yes"));
std.debug.assert(value.value.field("retries").?.integer == 16);
```
<!-- END GENERATED -->

## Design

[docs/design.md](docs/design.md) says how the parts are layered, what the core
promises and what each format adds. A type declares its mapping once and every
format reads the same declaration; a format supplies only its syntax. The core
uses `std` and [aegis](https://github.com/pedronaugusto/aegis), which is `std`
alone; JSON Lines adds airlock for syncs and file identity.

A type that holds resources (an allocator, a file, a lock) or memory with no safe
data meaning (many-item and C pointers) is refused when it is compiled, with the
path to the field that is the problem. A type with a meaning of its own declares
`strandSerialize` and `strandDeserialize`. An aegis scalar is what it holds: a
duration or a size its text (`"1m30s"`, `"64MiB"`), any other its integer, range
and nonzero checks included.

## Scope

- It does not lock or own the supplied stream.
- It does not open files except through a supplied `Opener`.
- It does not index a log or seek to a line by number.
- It does not read pretty records backwards or decompress a stream.
- It does not watch the filesystem or flush on a timer.
- It reads no application type from a YAML tag, and does not merge YAML 1.1's `<<` keys.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library.
- [aegis](https://github.com/pedronaugusto/aegis) supplies the core's finite budgets,
  checked arithmetic, closed diagnostics text and always-on contracts.
- [airlock](https://github.com/pedronaugusto/airlock) syncs the file under a `Writer`
  and numbers files for a `Follower`.
- [shakedown](https://github.com/pedronaugusto/shakedown) supplies the tests' doubles:
  faulted and counted `Io` calls and allocators, and airlock's syncs through
  `airlock.testing`, its test seam. Shakedown is a dev dependency.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI. It is a dev dependency too: with [bay](https://github.com/pedronaugusto/bay),
  shakedown and preflight belong to strand's own development, and a project that
  depends on strand never sees them.

## Testing

Development runs through bay.

`bay test` runs the unit suite, scratch tests and examples in Debug by default.
The suite covers each format's own standard suite (JSONTestSuite, RFC 8785's and the
cyberphone vectors, RFC 8949's Appendix A, msgpack-test-suite, toml-test, yaml-test-suite), round trips
through every reader and writer, framing, checked copies, rotation, cancellation and
malformed records. Properties are shakedown `check` runs of seeded
cases; `SHAKEDOWN_CASES` and `SHAKEDOWN_SEED` select a larger or a repeated run. `zig
build test --fuzz` runs the coverage-guided targets until stopped. CI also runs
`bay lint`.

[CI](.github/workflows/ci.yml) has three tiers. Fast runs the source checks,
Linux Debug tests and examples, and cross-target compilation. Merge adds the
configured macOS/Windows SDK links and native Debug test replay. Release adds
optimized configurations, full configured cross coverage and Linux ThreadSanitizer.
Merge/release also try Zig master in a non-blocking job. The profile job refreshes
recorded test durations; it does not run a larger set of generated cases.
Run one explicitly with `SHAKEDOWN_CASES=20000 bay test -Doptimize=safe`.

Zig 0.17.0 on aarch64 macOS miscompiles a vector whose size is not a power of two,
such as `@Vector(3, u128)` (48 bytes), held in an optional or in an aggregate inside
one: in ReleaseSafe and ReleaseFast the payload can read back as `null`, Debug is
right. It shows without strand in a dozen lines. `Versioned` keeps its payload as a
value and a flag so that a record with such a field survives it, and the tests compare
these vectors as arrays. Types you hold in an optional yourself are yours to check.

`bay bench` times the benchmarks in [bench/](bench/) in ReleaseFast. `bay test` runs them once with `--smoke`, over tiny inputs and without reading a clock.
Regular correctness gates compile or smoke-run the comparison drivers. The
`Manual indicative observations` workflow takes hosted observations when
dispatched; variable wall-clock performance never gates correctness.

`bay check` compiles without running. CI uses it for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`, `aarch64-windows-gnu`,
`x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
