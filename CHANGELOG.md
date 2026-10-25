# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- None for a program: `json.Format`, `json.capabilities` and `json.Raw.StrandRawFormat` are the type and the value they were, now declared once for JSON's three dialects (a `Raw` read from JSON, JSONC or JSON5 is branded `json.Format`). They are named here because the release check compares declarations by how they are spelled.

### Added

- `strand.dotenv`: .env files read as python-dotenv reads them (its parser, step for step) through the one core: `KEY=value` and `export KEY=value` lines, comments, values unquoted, trimmed and cut at a `#` after white space, or in single or double quotes across lines with python-dotenv's escapes, keys unquoted or in single quotes, a key with no `=` a null; a line end inside quotes reads as a line feed, as Python reads a text file. Nothing is interpolated (`$NAME` is text). A file is a struct or a map of its keys, its values typed as INI's are, an empty value empty text. A line python-dotenv skips as an error is a syntax error, and a key given twice is refused. The writer quotes a key or a value only where it must to read back as itself. Held to python-dotenv's own parser cases, each read as it reads a file of it, to round trips over generated files, and fuzzed. `bench/dotenv.zig` measures it.
- `strand.json.json5`: JSON5 read through the JSON reader in a third dialect, with JSON's options and promises (`parse`, `parseOwned`, `parseLeaky`): JSONC's comments and trailing commas, keys as ECMAScript identifier names (Unicode's letters and digits, `\u` escapes) or strings in either quote, single-quoted strings, strings continued across lines, ECMAScript's escapes, control characters in strings, hexadecimal numbers, a plus, a bare point, `Infinity` and `NaN`, and Unicode's space separators as white space. A key given twice is refused however it is spelled, unless `duplicates` says otherwise. `json.Value` keeps each number as written. `json.json5.write` writes JSON but for the floats JSON cannot spell, `Infinity`, `-Infinity` and `NaN`, and checks a `Value`'s number and a `Raw` as JSON5. Held to json5-tests, each case read as JSON5's reference implementation reads it, to properties over generated JSON and JSON5, and fuzzed. `bench/json5.zig` measures it.
- `strand.ini`: INI read and written through the one core, in a `Dialect`, Python configparser's by default: `#` and `;` comment lines, `=` and `:` delimiters, values continued on indented lines, keys lowercased by Unicode's full mapping (`optionxform`), section names as written; `inline_comment_prefixes`, `continuation`, `lowercase_keys` and `keys_without_values` change it. A document is a struct or a map: the keys before its first section, then each section, a struct or map of its keys; lines are read as configparser reads them, and a key or a section given twice is refused, as its strict mode does. A value is text until the type asks: a number in JSON's spelling, a boolean as `getboolean` reads one, a null where it is empty and the type takes one. No interpolation, and `[DEFAULT]` is a section like any other. `ini.Value` holds any document in order. The writer puts keys before sections and refuses what would not read back as itself, a map's key or section given twice among it (past the 128th, a map's names are remembered in `WriteOptions.scratch`). Held to configparser's reading by its own cases, to round trips over generated documents in three dialects, and fuzzed.

### Fixed

- A value passed over rather than read (a `Raw`, an ignored field) refuses an object with a key given twice when one of the two is spelled with an escape (`{"a":1,"\u0061":2}`), as reading the value does; it compared the keys as written, and took them for two.
- Development: the W3C XML suite's hash, taken from a copy that had lost the tarball's two empty directories, is the one Zig computes for the tarball itself, and its documents are read where Zig puts them (without the tarball's top `xmlconf/` directory), so a fresh fetch (CI's) builds. A consumer never fetches the suite.

### Changed

- Development: the rival programs and comparison drivers (quick-xml, Go's encoding/xml, expat, toml_edit, ruamel.yaml, jsonc-parser) moved to the private trials repository; `bench/xml.zig` and `bench/edit.zig` measure strand alone. The aegis lint pack (A001, A002, A003, A005) gates with A004.

## [0.14.0] - 2026-10-25

### Breaking

- Every byte limit and bound strand is given is an aegis `Bytes(usize)`, read and written in aegis's text form and logged with `{f}`: `core.Limits`' `input_bytes`, `output_bytes`, `string_bytes`, `key_bytes`, `numeric_bytes` and `allocation_bytes` (its counts, `depth`, `items`, `container_items` and `work`, stay counts), and the `max_line_bytes`, `recovery_bytes`, `max_row_bytes` and `block_bytes` of the JSON Lines readers, decoder, line reader and tail and the CSV reader. Write `.literal("64KiB")` or `.fromRaw(65536)` where a number was, and read one with `.raw()`.

### Added

- `strand.xml`: XML 1.0 read and written through the one core. `parse`, `parseOwned` and `parseLeaky` read a document's root element as a type: a field named `@name` is an attribute, `$text` the element's text, any other name a child element; children of one name read into a slice wherever they stand; an element read as a number, a boolean or a string is its text, in XML Schema's forms; a union is the element named for its arm, at the root the root's name. `xml.Element` holds any element, its content in order. `write` streams a document from a value (`WriteOptions.root`, `declaration`, `whitespace`, `namespaces`). `xml.Scanner` reads a document's tokens. Safe by construction: the doctype's own entities are expanded within the operation's limits, each expansion charged as it is made (a billion laughs is refused); an external entity or DTD is never fetched, and a reference to one is `UnsupportedValue`; namespaces are checked (`ParseOptions.namespaces`); UTF-8, and UTF-16 by its byte-order mark. The W3C XML Conformance Test Suite (xmlts20130923) runs in the tests: 1,725 of the 1,727 tests that apply pass, the two left named with their reasons.
- Comment-preserving editing: `toml.Edit`, `yaml.Edit` and `json.jsonc.Edit` hold a document as its text and change it in place by JSON Pointer (RFC 6901): `set` replaces a value where it is written or adds a key or an element, `insert` puts an element before another, `remove` takes a member with its line, and `bytes` is the text. Every byte a change does not replace stays as it was: comments, blank lines, key order, quoting, number spelling. Where to change is found by the format's own reader, recording where each part is written, and what to write is spelled by the format's own writer. Each edit is read back whole before it is kept, and that read finds the next edit's place; a change that would leave text the reader refuses is an error, the text as it was. A TOML key goes after its section's last `key = value` line, inside its braces or under its dotted prefix, a table is a section of its own, and a table only a removal made (`[a.b.c]` for `a.b`) stays, empty; a YAML key goes at its mapping's column, in flow style inside a flow collection, and a node replaced takes its anchor with it (an alias left naming none is refused). Held to toml-test, yaml-test-suite and JSONTestSuite (every leaf set, every member removed, each read back as exactly that change) and fuzzed over mutated commented documents. Against toml_edit, ruamel.yaml and jsonc-parser, `bench/edit.zig` and `bench/rivals/edit`.
- `yaml.WriteOptions.flow`: every collection in flow style (`{a: 1, b: [2]}`), the document on one line.
- `.as = .text_or_bytes`, a field policy for bytes an operating system gives (file names, paths): written as text when they are UTF-8 and otherwise as bytes, or in JSON, which has none, as the array of their byte values, as `std.json` writes them; read in any of those forms. The same bytes always take the same form. On a list of byte strings it spells each of them so; so do `.text` and `.bytes`.
- `core.Limits.sized(bytes)`: the defaults raised where a document of that size needs more, for a reader that bounds what it reads by its size alone (chronicle's journal, lookout's checkpoints).
- `core.Diagnostics.locate`: the line and column of a diagnostic's offset in the text read. TOML, YAML and ZON set them through it, in place of a copy each.

### Changed

- A union is read by asking its format for a union; a format that spells a union as a record of one member answers with that record, as before. A type with a codec of its own asks its format for nothing in particular (it asked for its Zig shape: a union-shaped `Value` asked for a union), so a format whose reading depends on what is asked for reads such a type by what its codec then reads.
- `names = .fold_case` folds every letter by Unicode's simple case folding, code point by code point, as Go's `encoding/json` matches names: `É` finds a field named `é`, and `Σ`, `σ` and `ς` find one another. Before, only ASCII letters, `ſ` and the Kelvin sign folded. The folding is xenoglyph's (`case.simpleFold`), a new dependency (xenoglyph 0.4.2).
- A charge an operation takes before allocating (`Context.alloc`, `allocPointer`, the scratch allocator) is given back if the allocation fails and consumed once it succeeds (aegis 0.1.14's `Reservation.consume`), so the reservation is discharged on every path where it was left held.
- aegis 0.1.18 (from 0.1.14). Development: preflight 0.17.0 (from 0.6.2) and shakedown 0.4.17 (from 0.4.6).

### Fixed

- An aegis scalar from a program pinning another aegis version than strand's was refused, a `Ranged` as a non-exhaustive enum with no numeric codec: strand recognized aegis's scalars by rebuilding them with its own copy of aegis, and two versions under a plain `zig build` are two copies whose types are never equal. It now reads the `aegis_scalar` declaration each carries (aegis 0.1.18), the same in every copy, at contract 1: its integer and range come from it, a value is made only through the type's own checked functions, and a later contract does not compile, named by its number.

## [0.13.1] - 2026-10-18

### Changed

- airlock 0.5.0 (from 0.3.5).
- Development: the suite runs under the release tier's hardened profile (`bay hardened`, `bay hardened-fuzz`, `bay hardened-tsan`), which takes the place of the `thread-sanitizer` build option and its declared ThreadSanitizer job. The ZON token-soup property holds a type with a byte slice or a float to soundness (a byte slice is text, never the tuple of numbers std also reads it from, and a float past its type is an error, never infinity), and counts what both readers accept only on its seeded run, not per fuzzing input.

## [0.13.0] - 2026-10-17

### Breaking

- The markers strand's own types declare follow Zig's naming, one convention with `strand_nullable` and `strand_json_schema`: the values `strandBytes`, `strandScalar` and `strandNamedShape` are `strand_bytes`, `strand_scalar` and `strand_named_shape`; the types `strandKeyType` and `strandRawFormat` are `StrandKey` and `StrandRawFormat`. A type of your own that declared one renames it.

## [0.12.0] - 2026-10-17

### Breaking

- `json.go` is removed: it was a second type mapper beside the core's. What it did is now reading choices on the one decode path, below.
- `json.ParseOptions.reject_duplicates` is `duplicates: ?core.Duplicates` (`.reject` by default; `null` is the old `false`, each type's own policy). `core.Acceptance.reject_duplicates` is `duplicates` likewise.

### Added

- Reading choices in `json.ParseOptions` and `core.Acceptance`: `duplicates = .merge` (a member given again read into what the first left; also a type's `strand.duplicates`), `.first` and `.last` for every record and map; `names = .fold_case`; `nulls = .keep`; `integers = .digits`; `invalid_unicode = .replace`. With unknown fields ignored they read as Go's `encoding/json` does, held to Go 1.27 over 120 000 random documents.
- `strand_nullable`, declared by a type whose values include null (each format's `Value`): it reads null itself under `nulls = .keep`.
- `json.parsePrefixLeaky` and `json.Prefix` on the JSON surface: one value read off the front, and where it ended.

## [0.11.2] - 2026-10-17

### Added

- `json.go`: JSON read into a type as Go's `encoding/json` reads it into the matching Go type (`parseLeaky`, `parseIntoLeaky`, `decodeInto`, `repaired`): members by exact name, then Go's case folding; `null` as Go takes it; a member given twice read into what the first left; integers and floats by `strconv`'s rules; invalid UTF-8 and unpaired surrogate escapes as U+FFFD; `.rest = .any` for a `json.Decoder`'s one value; `strandGoDecode` for a type of its own.

## [0.11.1] - 2026-10-17

### Added

- `json.schema.of(T, options)`: the JSON Schema (2020-12) of the JSON strand reads (`.decode`) or writes (`.encode`) for `T`, a compile-time string built from the type's `strand` declaration (names, casing, aliases, defaults, skips, ranges, tagging, aegis scalars); a recursive type goes under `$defs`. A type with a codec of its own declares `strand_json_schema`.
- A `description` in a type's or a field's `strand` declaration, which `json.schema` writes and the codecs ignore.

### Changed

- Pins aegis 0.1.9 and airlock 0.3.5.

## [0.11.0] - 2026-10-14

### Breaking

- `json.leadingIntMembers`, `json.intMembersAt`, `json.trailingIntMember`, `json.IntMembers` and `json.TrailingInt` are removed. They read integers off a line only in one exact spelling and answered null for any other, so a reader needed a second reader for the rest; `json.Members` reads every spelling.

### Added

- `json.Members`: an object's members read one at a time, on demand, off its bytes, with nothing allocated: each member's name as written, its value's bytes and offsets (the member's start, the value's span, the `,` before it), `Member.is` to compare a name without unescaping a plain one, `Member.which` to say which of several names it is, `Member.nameInto` to unescape one, and `finish` to read to the end and check the bytes are one object. It runs on the decoder every parse uses, with the parser's grammar and limits, for any spelling JSON allows. Property-tested against the parser over objects in every spelling and over any bytes, fuzzed, and held to the parser at each limit's edge.

### Changed

- Every value a parse passes over (an ignored field, a `Raw`, a member `json.Members` is not asked about) is passed over by the decoder itself, checked and charged as before, without an event per token and without unescaping its strings into the operation's storage: a parse that ignores most of a record is faster, and allocates nothing for what it ignores.
- `json.intOf` reads an integer in one pass over its digits.
- A string's end is looked for in its first eight bytes in line before the vector search is called, and a number's digits are read eight at a time: keys and short strings, the bulk of a record's tokens, cost less in every JSON read.
- Dev pins preflight 0.5.3.

### Fixed

- The test of framing's vector lane searches is skipped on a machine with no vectors (riscv64 without V), where framing reads a byte at a time and there are no lanes to count; it failed there.

## [0.10.4] - 2026-10-14

### Added

- `json.intMembersAt`: integer members read off a line's bytes from any offset, each after a `,` (`,"bf":3,"bl":5`), as `leadingIntMembers` reads them from the start.
- `json.trailingIntMember`: the integer member a line closes with (`,"c":42}`), read off the end, with where it begins.
- `json.intOf`: a JSON value's bytes (a `json.Raw` member) as an integer only where they are one written as one.
- `json.IntMembers` is named at the root, beside `leadingIntMembers`.

### Changed

- Pins airlock 0.3.3.

## [0.10.3] - 2026-10-14

### Added

- `strand.yaml`: YAML 1.2 under the core schema, on the core. `parse`, `parseOwned` and `parseLeaky` read a stream's one document, `parseStream` and its owned and arena forms every document, `write` and `writeStream` write them. Block and flow collections, every scalar style, directives, multi-document streams, anchors and aliases are read; aliases' expansion is held to the item limit before anything is read. A plain scalar is what the field reading it asks for where its spelling is one, otherwise the core schema's null, boolean, integer, float or string, and never a YAML 1.1 form. A tag the core schema lacks and a key given twice are refused. `yaml.Value` holds any document, keys of any kind. The writer writes block style and quotes a string only where it would read back as something else. Checked against all 402 cases of yaml-test-suite (data-2022-01-17): events for every valid case, every invalid one refused, and values and a written round trip for every valid case with JSON but the 16 with tags outside the core schema, which are refused.
- `bench/yaml.zig`: YAML observations of strand's own, smoke-run by the tests.

### Fixed

- A map's key read through an access (`Pairs`, a format's `Value`) is asked for as its own type; it was asked for as whatever value came before it, which a format whose events follow the type (YAML's plain scalars) read as that.

## [0.10.2] - 2026-10-14

### Added

- `strand.toml`: TOML 1.1.0, and 1.0.0 with `.version = .v1_0`, on the core. Every rule about defining a table is checked as the document is read; integers are TOML's signed 64 bits and floats binary64, refused past their range; `toml.OffsetDateTime`, `toml.LocalDateTime`, `toml.LocalDate` and `toml.LocalTime` are types of their own (their RFC 3339 text in another format); TOML has no null, so a write refuses one unless `.nulls = .omit`; `toml.Value` holds any document. The writer puts a table's values before its tables, arrays of tables as `[[sections]]`, and its output reads as TOML 1.0 and 1.1. Checked against toml-test's 1.0.0 and 1.1.0 lists (decoder, encoder and invalid documents, nothing skipped).
- `core.Context.scratch`: working storage on an allocator of the format's choosing, charged to the operation's allocation budget and given back before it ends, apart from the result.
- `Access.Format` on both directions: a codec whose spelling is a format's own asks which format it is in.
- Fuzz properties for the JSON value read from the front of a buffer (it ends inside the bytes, and alone reads again), for the bridge to `std.json.Value` (it reads exactly what strand's own `Value` reads), for a number in a CSV field or a form value (it reads as its JSON spelling says) and for percent-decoding: the parsers of untrusted input preflight reported without one.

### Changed

- Pins aegis 0.1.6.

## [0.10.1] - 2026-10-14

### Added

- `strand.msgpack`: MessagePack on the core, every format family read and each value
  written in its smallest format, with `msgpack.Value`, `Ext`, `Timestamp` (extension
  type -1, all three forms) and a deterministic profile. Checked against golden
  vectors for every family at its edges and kawanet's msgpack-test-suite.
- `core.widenFloat` and `core.narrowFloat`: a float to and from an event's `f128` by
  its bits, so a NaN keeps its sign and payload.

### Fixed

- A float event no longer quiets a signalling NaN: a NaN read from CBOR is the NaN
  that was written.
- CBOR's deterministic profiles report an allocation failure of their allocator as
  `OutOfMemory`, not `AllocationLimit`, and refuse a map that holds more than the
  output left (`OutputLimit`) while it is held, not after.

## [0.10.0] - 2026-10-14

### Breaking

- `core.Event` has two more variants, `tag` (a semantic tag on the value after it)
  and `simple` (a format's own simple value), so an exhaustive switch over it needs
  them.

### Added

- `strand.cbor`: CBOR (RFC 8949) on the core, every well-formed item read and
  preferred serialization written, with `cbor.Value`, `Tagged`, `Bignum`, `DateTime`,
  `Epoch` and the deterministic profiles (core, length-first). Access to tags and
  simple values for data codecs (`tag`, `simple`).
- `json.jcs.write` and `json.jcs.canonicalize`: the JSON Canonicalization Scheme
  (RFC 8785), checked against the RFC's number samples and the cyberphone corpus. A
  typed integer past ±(2^53−1) is refused.
- `strand.csv`: CSV (RFC 4180) on the core, `parse`, `parseOwned`, `parseLeaky`
  and `write` for documents and `Reader(T)` and `Writer(T)` for a row at a time, in
  a `Dialect` (delimiter, quote, header, line ending). Rows are structs by the
  header's names or tuples and arrays by position; an empty unquoted field is a
  null where the type takes one.
- `core.Request.nullable`, set where the type takes a null, for a format whose null
  depends on the type (an empty CSV field); `core.wireNames(T)`, the names a struct's
  fields are written under; `core.acquireWith` takes a decoder value with a `run`
  method, for a decoder that carries settings.

## [0.9.1] - 2026-10-13

### Added

- `json.jsonc.parse`, `parseOwned` and `parseLeaky` read JSONC: `//` and `/* */`
  comments where whitespace may be and a comma after a container's last member or
  element, with JSON's options. Writing stays plain JSON.
- `strand.urlencoded`: forms and query strings (application/x-www-form-urlencoded)
  on the core, `parse`, `parseOwned`, `parseLeaky` and `write`. Names' bracketed
  paths (`user[name]`, `tag[]`) read into nested records and sequences wherever
  their pairs stand, repeated names into a sequence; values are text, or a number,
  a boolean, a name or bytes where the type asks. It writes what the WHATWG form
  serializer writes.

## [0.9.0] - 2026-10-13

### Breaking

- `aegis.int.Checked` and `aegis.int.Saturating` are written and read as their
  integer, where they were an object of their private field (`{"value":3}`).

### Fixed

- aegis scalars are read and written in every format as what they hold, recognized
  by rebuilding each from the parameters it publishes: `units.Duration` and
  `units.Bytes` as their text (`"1m30s"`, `"64MiB"`), `int.Checked`,
  `int.Saturating`, `int.Ranged`, `units.Count`, `units.Bits`, `units.Instant`,
  `id.Id`, `id.NonZero` and `id.Counter` as their integer, with `Ranged`'s range and
  `NonZero`'s zero refused as `NumberOutOfRange`. A struct holding any other
  failed to compile, as a nonexhaustive enum.

### Changed

- Pins aegis 0.1.5 and preflight 0.4.4.

## [0.8.3] - 2026-10-13

### Changed

- Pins airlock 0.3.1, aegis 0.1.3, preflight 0.4.1 and shakedown 0.3.2.

## [0.8.2] - 2026-10-13

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.8.1] - 2026-10-12

### Changed

- Pins aegis 0.1.1, preflight 0.3.4 and shakedown 0.2.6.

## [0.8.0] - 2026-10-12

### Breaking

- The tests build airlock's seam on strand's own shakedown (airlock 0.2.0's `testing`).
- strand is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, examples, checks and benchmarks are the development build's (`bay test`, `bay check`, `bay bench`). strand ships with aegis and airlock; what a project that depends on it builds is unchanged.
- One API. strand reads and writes JSON through `strand.json` alone, and JSON Lines is
  framing around it: the second JSON codec that kept 0.7.0's root API working beside the
  core is gone, and with it every name that was only its. The root names `core`, `json`,
  `jsonl` and `zon` and nothing else.
  - `parseLine(T, arena, line, options)` is `json.parseLeaky(T, arena, line, options)`,
    under `json.ParseOptions` (`limits`, `ignore_unknown_fields`, `reject_duplicates`,
    `diagnostics`); errors are `core.DecodeError`. Unknown fields are refused unless
    ignored, every parse is bounded by `core.Limits`, and depth is `limits.depth`.
    `ParseOptions.duplicate_fields` is a type's `strand` declaration, `.duplicates =
    .first` or `.last`, with `reject_duplicates = false`. `innerParse`, `Diagnostics`,
    `DuplicateFields` and `ParseLineError` are gone.
  - `writeLine` and `writeValue(output, value, ValueOptions)` are `jsonl.Writer` and
    `json.write(output, value, json.WriteOptions)`; `writeObjectOpen` and `OpenObject`
    are `json.writeObjectOpen` and `json.OpenObject`. An optional that is null is
    written as `null` unless its field declares `.omit = .null_value` or the write
    says `.nulls = .omit` (`emit_null_optional_fields = false`, whose default was the
    reverse); `escape_unicode` is gone. Writing checks text as
    UTF-8 and refuses what is not, where a Zig string that was not UTF-8 was written
    as an array of numbers.
  - `Raw` is `json.Raw`: its `bytes`, checked when read and written back as they came.
    `Raw.null`, `Raw.encode` and `Raw.parse` stay on it; `encode(gpa, value, options)`
    takes a `json.WriteOptions` and `parse(raw, T, arena, options)` a `json.ParseOptions`,
    and their errors are `json.WriteError` and `json.ParseError`.
  - `copyOwned` and `freeOwned` are `core.clone`, a checked, bounded copy in an owner of
    its own. `Reader.keep`, `Tail.keep` and `Follower.keep` return `core.Parsed(T)`, and
    `Decoder.keep(gpa, record)` takes the allocator and the record; `Tail.last(gpa, n)`
    returns `core.Parsed([]T)`, the lines copied into the owner and parsed there.
  - `Reader`, `LineReader`, `Writer`, `Tail`, `Follower`, `Versioned`, `Line`, `RawLine`,
    `Format`, `Fault`, `lines`, `separator`, `Identity`, `Opener`, `PathOpener`, `FileId`
    and `Reached` are under `strand.jsonl`; `kindOf`, `tagOf`, `memberOf`,
    `memberStringOf`, `leadingIntMembers`, `IntMembers` and `indexOfControl` are under
    `strand.json`.
  - `Reader.Options` and `Tail.Options` take `parse: json.ParseOptions` in place of
    `ignore_unknown_fields`, `duplicate_fields` and `max_depth`; `Fault.err` is
    `?core.DecodeError`. `Writer.Options` takes `limits`, `scratch` and `nulls` in place of
    `emit_null_optional_fields` and `escape_unicode`, and `Writer(T).Error` is
    `json.WriteError(T)` with `SyncFailed`, `LineTooLong` and `OutOfMemory`.
  - A union tagged inside its object declares `pub const strand = .{ .tag = "type",
    .other = "unknown" }` in place of `jsonl_tag` and `jsonl_other`; the arm a name
    that is no arm's is read as holds the record as a `json.Raw`. `tagOf` reads the
    same declaration.
  - A type with `std.json`'s `jsonParse` or `jsonStringify` is refused when it is
    compiled; its meaning is a `strandDeserialize` and `strandSerialize` pair, which
    every format honours. `std.json.Value` is read with `json.parseStdValue`, and
    `json.Value` is the value of any shape the core reads.
  - `Versioned(T)`'s hook is `jsonlMigrate(from: u32, payload: anytype)
    @TypeOf(payload.*).Error!T`: `payload.read(Old)` parses the payload as an older
    shape where it lies, `payload.alloc` and `payload.reject` bound and refuse as the
    line does. `payloadOf` is gone. A version with no hook to read it is
    `error.UnknownVariant`; a repeated `v` or `data` is `DuplicateField` and any other
    envelope key `UnknownField`.
- `strand` is one build module. `strand.core`, `strand.json`, `strand.jsonl` and `strand.zon` are no longer modules to import by name (`b.dependency("strand", ...).module("strand.json")` and the like); use them as namespaces of `@import("strand")`. Every user fetched aegis and airlock whichever part they took, no part links anything and Zig analyzes only what a program names, so the separate modules bought nothing.
- strand.core depends on [aegis](https://github.com/pedronaugusto/aegis) (pinned to a commit), which is `std` alone.
  `core.Context` keeps its input, output, work and requested-allocation totals as `aegis.bounded.Budget`s, so its public
  `work`, `input_bytes`, `output_bytes` and `allocation_requested` fields are the methods `workUsed`, `outputUsed` and
  `allocationRequested`, and `adopt` takes over what another operation has charged. `core.Diagnostics.path` is an
  `aegis.err.Context` of `Step`s with escaped names of at most 32 bytes in place of `path`, `count`, `names` and `used`;
  `Checkpoint` records the number of steps. A field name from the input appeared in diagnostics as raw bytes, a newline
  and a terminal escape among them; it is now escaped.
- A core backend's `replay(into, start, end)` starts a decoder in place, and the JSON and
  ZON decoders and the JSON encoder are started with `init` on storage the caller
  holds: their frames and keys are kilobytes a struct literal built elsewhere and copied.
- `core.Event` has the `number` lexeme alternative; exhaustive backend event
  switches must handle it. `core.EncodeError` adds `DuplicateField` for checked
  dynamic object keys.
- strand requires Zig 0.17.0.
- `Follower` keeps no `std.Io`: `init(gpa, source, options)` takes none, and `next`, `checkpoint`, `truncated` and `deinit` take the `io` they block on. `resumeFrom(gpa, io, source, point, options)` takes `point` before `options`.
- `Reader.resumeAt` and `LineReader.resumeAt` take `start` before `options`.
- Opener callbacks take `io` before `context`.
- Bounded writers use `initBounded(gpa, output, max_line_bytes, options)` or `initFileBounded(gpa, file_writer, max_line_bytes, options)` instead of `Options.max_line_bytes`, require `deinit`, encode once into reusable owned scratch and emit the bytes measured; unbounded `init` and `initFile` keep streaming without scratch.
- The benchmark moved from `examples/bench.zig` to `bench/`; `zig build bench` runs it in strand's own tree and is not there in a project that depends on strand.
- `Identity.inode` is now `Identity.file_id`, including serialized policy tags; the old `inode` tag is refused with `error.UnknownField`, with no compatibility path, and followers start fresh.
- `Identity.Taken.id` holds the full `FileId` instead of `inode` and optional `volume`; old checkpoints are refused with `error.MissingField`, with no conversion or fallback, and callers choose where to restart.
- `max_line_bytes` counts JSON payload bytes everywhere, excluding the separator, terminator and discarded torn prefix; writer and tail boundary acceptance changes.
- `Reader(T)` is a `LineReader` with a parse on top, and keeps it as `Reader.lines`. The reader's place in the stream is kept there: `reader.number`, `reader.offset`, `reader.skipped`, `reader.fault` and `reader.input` are now `reader.lines.number`, `reader.lines.offset`, `reader.lines.skipped`, `reader.lines.fault` and `reader.lines.input`. `Reader.Joined` is `LineReader.Joined`.

### Added

- `strand.core`: recursive descriptors over any plain Zig type, options declared on the
  type in one `pub const strand` declaration (names, aliases, renaming, defaults,
  omission, representations, codecs, tags), immediate semantic mapping, bounded
  arena owners, checked `clone`, generic ordered maps, an explicit standard list
  codec, fixed-buffer paths, rollback and full wire-limit proofs, and a small
  reference backend for the tests.
- `strand.json` on the core: borrowed, owned and caller-arena parsing; JSON-native
  numeric lexemes, checked decimal integers and an exact float policy; full wire
  limits; checked writing, minified or indented (`WriteOptions.whitespace`);
  `json.Value`; an explicit bounded `parseStdValue` adapter that transfers one arena
  into the standard dynamic owner, and checked standard Value writing with explicit
  scratch. The complete pinned JSONTestSuite corpus runs in the tests.
- A format may answer the core's common requests without building an event: a
  record's next key matched against the schema's names where it lies, a container of
  the expected kind, a number, a string. JSON does.
- `jsonl.Decoder`, push decoding of JSON Lines with consumed counts, an explicit
  final-record policy, bounded persistent oversize recovery and independent retained
  owners.
- `strand.zon`, its own namespace on the core: `parse`, `parseOwned`, `parseLeaky`, `write`,
  `Raw` and `ParseOptions`, with the core's limits, ownership and field policy. It reads
  the grammar of `std.zon` in one pass with no syntax tree, so every limit is charged
  before the storage it guards exists; plain strings are borrowed from the input; a
  failure reports its line and column. It writes `std.zon`'s own layout byte for byte.
  Differences are written in the README and `docs/design.md`. Differential tests run
  against `std.zon`'s parser and stringifier over a corpus of spellings and types, a
  mutation of every byte of a document, and generated values.
- A union whose `strand` declaration names a `tag` is read and written tagged inside
  its object, `{"type":"assistant",...}`, the arm a member of the record, and `other`
  names an arm for a tag naming no arm; `json.tagOf` reads the arm from the tag member.
- `json.memberOf` and `json.memberStringOf` read one top-level member of a line by name, wherever it is, without parsing the line; the first of a repeated member is the answer.
- `jsonl.LineReader`, the line layer on its own: a `*std.Io.Reader` as a stream of lines, framed at the terminator, held to `max_line_bytes`, checked for raw control bytes and missing separators, numbered and placed, and not parsed. A line past the bound is `error.LineTooLong` with the line consumed to its end, so the caller answers it and reads on. `recordStart` and `reset` are how a file still being written is read, and `join` appends the next physical line to a record. `unfinished` says whether the stream ended in the middle of a record.
- `oversized_member` on `LineReader.Options` and `Reader.Options`: the name of a top-level member to keep from a line refused as `error.LineTooLong`, returned by `LineReader.oversizedMember` as a `json.Raw`.
- `json.writeObjectOpen` and `json.OpenObject`: a struct written but for its closing brace, members added, then closed. For a record that carries a checksum over the bytes before it.
- `json.leadingIntMembers`, the integer members a line opens with, read off its bytes as a struct of integer fields, with the offset where the line goes on (`IntMembers`).
- `jsonl.FileId`, airlock's: which file a handle is open on as the filesystem numbers it. What `Identity` compares.
- `Writer.reached`, what the writer's last sync reached (`jsonl.Reached`, airlock's). Declining is not failing, and the writer carries on.
- `crlf`, on `LineReader.Options`, `Reader.Options` and `Tail.Options`: on by default, and off for a format whose lines are checked byte for byte.
- `Tail.prevRaw`, a line read backwards as its bytes; and `Tail.Options.end`, where the file ends for the reader.
- `core.adopt`, an owner for a value built on an arena, and a record's `hold` and
  `readHeld` in a data codec, for a member whose type a later member decides.
- A line-protocol recipe in `examples/logbook.zig`.

### Changed

- The Smith fuzz tests are shakedown `check` properties. `-Dcampaign` and `-Dseed` are gone: `SHAKEDOWN_CASES` and `SHAKEDOWN_SEED` choose the cases, and the generator seed files under `src/corpus/lines` and `src/corpus/versioned` with them.
- A struct's comptime fields are written as members, an anonymous literal's
  constants among them, and a string literal is written as its text; reading a
  record with a comptime field checks the member holds that constant.
- A `json.Raw` is checked when it is written, with nothing allocated for it, and a
  line break between its tokens is written as a space, so a record stays one line.
- A float is written in the shortest spelling that reads back the same: decimals
  from 1e-7 up to 1e21, as JavaScript writes a number, and an exponent outside,
  where decimals run to hundreds of digits.
- strand depends on airlock, which makes a `Writer`'s sync and a `Follower`'s file identity. The sync is the same call at the same cost on Linux (`fdatasync`) and macOS (`F_FULLFSYNC`); on Windows NTFS it is now the data-only flush, `NtFlushBuffersFileEx(DATA_SYNC_ONLY)`.
- The fetched package holds the build files, `src` and the three documents; the examples, benchmarks, `ci/` and `.github/` stay in the repository.
- `Follower` names its error sets: `CheckpointError`, `ResumeError`, `TruncatedError` and `RestartError`; `Identity.take` returns `Identity.TakeError`.
- `Reader`, `Writer`, `Tail` and `Follower` share their policy types across record types where they do not depend on the record.
- A `.pretty` reader parses a record where it lies in the input's buffer, across its line breaks, in one pass; it joins lines only for a record that straddles a refill, or one with a blank line, a `\r` or a fault in it.
- A follower retains the identity measured when it adopts or restarts a file, so later rewrites cannot change a checkpoint of records already read.
- `Follower` rewinds a half-written record and begins again after a truncation through `LineReader.reset`.
- The logbook example owns a separate scratch directory per invocation.
- Pins aegis 0.1.0 and airlock 0.2.0.

### Fixed

- A `.pretty` reader no longer starts a record on a first line that is only whitespace (a lone carriage return with `crlf` off), and no longer parses a record that ends with the stream from a line buffer the look for the next line had moved.
- A character literal cut inside its UTF-8 sequence is refused rather than read past the end of the literal.
- An integer field narrower than four bits, such as a `u3`, did not compile on the
  path that reads a number written with a fraction or an exponent.
- A pointer to an opaque type, such as `*const anyopaque`, stopped the compile inside
  the descriptor's checks with an error about optional opaque types; it is refused as
  having no automatic data meaning, with the path to it.
- `Versioned` returned a `null` optional vector field for a record whose payload held a
  48-byte vector such as `@Vector(3, u128)` in an optional, in ReleaseSafe and ReleaseFast
  on aarch64 macOS. Zig 0.17.0 miscompiles such an optional; the envelope keeps its
  payload as a value and a flag.
- Caller-arena JSON parsing resets diagnostic format/path/offset before each
  operation, including input-limit refusal, matching owned and borrowed parsing.
- Push decoding accepts a BOM only at stream offset zero, including after
  draining an oversized first record.
- `Tail.init` refuses a pipe or socket as `error.Streaming`, as documented; it read whatever the system reported as the stream's size.
- `Writer.write` publishes a record whole: one that fails partway leaves nothing in the destination. A record that fails after outgrowing the destination's buffer sets `torn`, and the next record starts on a line of its own.
- A line refused as too long that the stream ended inside is discarded to its end when the rest arrives. A `Follower` read its tail as a malformed line, misplaced the next record and read the refused line again.
- In `record_separator` mode every separator starts a record: the record on a line is what follows its last separator, and each torn record before it is dropped, counted in `skipped` and named in `fault`.
- A `Follower` with an opener waits while the path names nothing, as it does between a rotation's rename and its create; an opener reports that moment as `error.FileNotFound`, and `PathOpener` does.
- A `.pretty` reader follows a record to where its JSON value ends and parses it there, once, where a record of n lines cost n parses; a record that is JSON but not a `T` is refused as the lines its value takes.
- Pretty-record joins count and bound only physical lines that exist, preserve subsequent line numbers after refusal, and retain an unfinished record's rewind point.
- Separated blank-line framing honors `crlf` and drops at most one final carriage return.
- A follower checks cancellation before returning a record already in its buffer.
- A separated record keeps its separator offset when physical framing fails.
- A reader that meets a stream with no byte on it yet looks for a byte-order mark when the first bytes arrive, so a file that was empty when it was first read and was then written mark first reads its first line without the mark.
- A follower tells two files apart by the volume they are on as well as by their number.

## [0.7.0] - 2026-09-24

### Added

- `Raw`, a JSON value kept as its bytes, for a line that carries something
  it does not read: another program's record passed along, a plugin's
  payload, a request handed on as it came. A field of it is checked when its
  line is read — a value that is not JSON is the line's error — and holds
  the value from its first byte to its last, whitespace inside it included,
  borrowed from the line as a string is and copied by `keep`. It is written
  back as it came, except that a line break inside it is a space in a
  minified line and `escape_unicode` escapes what is not ASCII. `Raw.parse`
  decodes it as any type when it is wanted, and `Raw.encode` makes one from
  a value. A struct or union holding one stays on the direct decoder and
  writer, where a `std.json.Value` in its place takes the whole line to
  `std.json`.

### Changed

- Passing over a value — an unknown field, or a `Raw` — checks it in the
  decoder's own loop rather than token by token through the scanner, with
  nothing allocated, to a depth of sixty-four; a deeper value goes to the
  scanner as before. In `zig build bench` on an Apple M3 Max, a line
  carrying a small object reads as a `Raw` in 105 ns rather than 165, and
  in 455 with a `std.json.Value` in the same place.

### Fixed

- A type whose largest value is one digit — `u1` to `u3`, `i2` to `i4` —
  refuses a digit it cannot hold with `error.Overflow` on every path. The
  path that names a line's error let the digit through, and every line the
  direct decoder refuses is read again on that path, so such a line
  panicked in Debug and ReleaseSafe and was undefined in the fast modes.

- `Writer` writes an integer one bit narrower than a power of two — `u1`,
  `u3`, `i7`, `u15`, `i31`, `u63` and the rest. The length of the buffer its
  digits are written into was worked out in a type too narrow to hold it,
  and a record with such a field failed to compile.

- A struct holding a packed struct decodes. Since values are decoded in
  place, each field was decoded through its address, and the fields of a
  packed struct are bits of one integer with no address of their own, so
  such a type failed to compile for `parseLine` and the readers. Its fields
  are decoded and then stored.

## [0.6.1] - 2026-09-23

### Fixed

- `parseLine` and `Writer` accept a schema too large for the compiler's
  default comptime budget. Deciding whether a type takes the direct path
  walks every field reachable from it, and a line protocol of sixty
  requests ran past a thousand steps and failed to compile.
- A line read by `Reader` costs what its parse costs on x86_64 too. It
  measured 1.06x to 1.13x the parse on GitHub's x86_64 runners, past the
  tenth the suite holds it to: the decoder copied each value out and the
  reader copied it again into its `Line`, and there a load that spans two
  recent stores waits for both to reach the cache. Values are now decoded
  in place, and the end of a line is found with a bitmask rather than a
  vector reduction. A line measures 0.95x to 0.98x its parse there, and
  `parseLine` itself is faster.

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
  `src/testing/fixtures.zig` for the scaffolding three test files were each carrying.

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

[Unreleased]: https://github.com/pedronaugusto/strand/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/pedronaugusto/strand/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/pedronaugusto/strand/compare/v0.10.0...v0.13.1
[0.10.0]: https://github.com/pedronaugusto/strand/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/pedronaugusto/strand/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/pedronaugusto/strand/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/pedronaugusto/strand/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/pedronaugusto/strand/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/pedronaugusto/strand/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/pedronaugusto/strand/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.7.0
[0.6.1]: https://github.com/pedronaugusto/strand/releases/tag/v0.6.1
[0.6.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.6.0
[0.5.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.4.0
[0.3.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/strand/releases/tag/v0.1.0
