# Serialization core and its formats

Strand is one build module, `strand`, whose namespaces are `strand.core`,
`strand.json`, `strand.jsonl`, `strand.zon`, `strand.urlencoded`, `strand.csv`,
`strand.cbor`, `strand.msgpack`, `strand.toml` and `strand.yaml`; the root names only
those ten.
There is one API per thing: JSON is parsed and written by `strand.json` alone,
and JSON Lines is framing around it, not a codec of its own. A separate build
module buys something only where it keeps dependencies from users who do not need
that part, or keeps a part from linking something. Here it bought neither: the
parts need the same two packages, aegis for the core's checked work and airlock
for JSONL's sync and file identity, so every user fetches both whichever part
they take; nothing is linked; and Zig's lazy analysis leaves out whatever a
program does not name, so a program that names only `strand.json` analyses no
JSON Lines or airlock code (`ci/json-consumer.zig` is that program).

The layering inside the module is Gantry's, checked at file level by `ci/layers.zig`:
every source has one named layer and imports only downward. Core and JSON import no
airlock; JSONL owns that durability edge. Test/tool dependencies remain lazy
and outside the module.

## Module boundaries

Bounds → semantic vocabulary/schema → mapping → ownership → core facade → JSON
text primitives → JSON wire → JSON API/facade → JSONL schema and records →
framing → streams → tail/follow → JSONL API/facade → root. ZON sits beside JSON
on the core, wire/syntax → ZON API/facade, and imports neither JSON nor JSONL.
URL-encoded forms sit beside them too, text → wire → API/facade; they import
JSON's number grammar alone, since a form's number is spelled as JSON spells one.
CSV is laid out the same way and reads rows on JSONL's line reader. CBOR and
MessagePack are bytes → wire → values → API/facade each, and share one kernel below
them, the map sorting of their deterministic profiles (`src/binary/sorted.zig`); no
grammar is shared. TOML is text → syntax → wire → values → API/facade, and imports
JSON's exact number kernels alone. YAML is text (characters and the core schema) →
events → nodes → wire → values → API/facade, and imports JSON's exact number kernels
alone.
Mapping consumes immediate events, including JSON number lexemes; it requires no
DOM or token tape. JSONL framing shares its line/drain boundary decision between
the pull reader and the push decoder, and both parse a record with `json`.

## JSON APIs and guarantees

`parse`, `parseOwned`, and `parseLeaky` use the same descriptor and bounded
context. `Parsed(T)` owns storage, never input or Io. Unescaped legal const spans
may borrow only in `parse`; owned decoding copies every retained span. Failed
owned acquisition rolls its arena back. Caller-arena acquisition bounds requested allocations per operation and is
leaky until reset; the caller owns its backing residency. Parsed owners and the
push decoder additionally cap arena backing residency. Dynamic `Value` uses bounded codec access and preserves number lexemes,
ordered keys, strings, arrays and null without lossy numeric conversion.

Parsing rejects unknown fields unless opted into validated skipping and
rejects duplicate wire keys, including unknown/skipped keys. Wire limits also
cover Raw and custom bounded access. Decimal integer conversion has no float
intermediate, and float rounding is directly to the requested destination.
Exact conversion compares decimal and binary rationals with budgeted big
integers. A type with `std.json`'s `jsonParse` or `jsonStringify` is refused when
it is compiled: its meaning belongs in a strand data codec, which every format
then honours.

`json.parseStdValue(gpa, bytes, options)` is the explicit bounded standard
Value adapter. It keeps std's integer/float/number_string precision policies and
moves the core arena into a stable `std.json.Parsed(std.json.Value)` owner.
Use its `deinit`; managed arrays retain a valid arena allocator. `json.write`
accepts standard Value with caller-supplied scratch. Automatic core derivation
continues to exclude allocator-bearing standard containers.

`write` writes checked JSON, minified or indented, and can publish a prefix
before a sink, value or limit failure: output is staged in the writer's own
unused buffer and published a stage at a time, so a value that fits there and
fails leaves nothing, and a caller-owned output buffer provides transactional
publication whatever the size. Output, escapes and Raw validation are charged.
Scratch is caller-supplied; no global allocator is chosen.
`writeObjectOpen` leaves a struct's closing brace unwritten, for members the
caller computes over the bytes so far.

`json.Members` reads an object's members on demand, in the spirit of simdjson's
On-Demand API: a reader of a few fields of a long line pays for the members up to
the last one it wants, and nothing after. It is not a tokenizer of its own. It
drives the JSON decoder every parse uses, in its checking mode (strings validated
where they lie, never unescaped, keys not remembered), so its grammar and limits are
the parser's: a member's value is passed over exactly as an ignored field is
(`Decoder.pass`, which `core.Cursor.skip` takes for every ignored value and `Raw`),
and the object's punctuation, keys and scalar values are read in one step
(`Decoder.passMember`) whose position stays in a register. Nothing is allocated: the
context's allocator fails, nesting is held to the decoder's 128 inline frames
(`Members.max_depth`), and duplicate names are handed over rather than remembered.
Names come as written; `Member.is` compares one with a name without unescaping a
plain one (the decoder says whether a name has an escape as it finds its end),
`Member.which` picks among names known at compile time with a length check per name,
and `nameInto` unescapes into the caller's buffer. Offsets are part of
the answer (the member's start, the value's span, the separator before it), so a
format that checksums a record up to its last member reads the record once.
Property tests hold it to the parser: an object generated in every spelling yields
the members the parser reads, any bytes are taken as an object exactly where a
parse passing over every member takes them, and each limit holds at its edge as the
parser's does.

The routing readers (`kindOf`, `tagOf`, `memberOf`, `memberStringOf`,
`indexOfControl`) look at a line's bytes without parsing it. They allocate nothing
and answer with views into the line; an answer is not a claim that the line is
valid. `tagOf` reads the same `strand` declaration the
parse does: a `tag` member, the arms' names and aliases, and `other`.

JSONC is a dialect of the same decoder, not a codec of its own: the decoder is made
for a dialect at compile time, and in JSONC's the whitespace between tokens may hold
`//` and `/* */` comments and a comma may end an object or an array. `json.jsonc` has
its own entry points rather than a parse option, because a runtime choice between the
two at JSON's entry measured 3-4% on a 512-byte record (the branch and its call kept
the context out of registers); JSON's code is the same as before JSONC. A comment
that never ends stops at its `/`, which the next token then refuses. A `Raw` taken from JSONC is its
source, comments included, and so is JSONC; writing is always plain JSON, and a `Raw`
with a comment in it is refused there as any invalid one is.

`json.jcs` is RFC 8785. Canonical form needs every object's members sorted, which a
stream cannot do, so it reads the value as a `json.Value` (numbers as their lexemes,
members in order) and writes that: members sorted by UTF-16 code units, which put a
name past U+FFFF before one in U+E000 to U+FFFF, a number as the double nearest its
lexeme spelled as ECMAScript's `Number.prototype.toString` spells it (Ryu's shortest
digits, placed by ECMA-262's rules), a string with only what `JSON.stringify` escapes
escaped. JSON text has one kind of number, and every one is a double here, as JCS
says; a typed value knows its integers, and `write` refuses one past ±(2^53−1) before
writing anything, through a backend of the core that only looks at integers. The RFC's
Appendix B samples and the cyberphone corpus are the evidence; a property checks that a
double's spelling reads back as itself and that canonical form is a fixed point.

## JSON Lines on the core

`jsonl.Reader` frames a line with `LineReader` and parses it with
`json.parseLeaky` on its per-line arena, under `Options.parse`. A refused parse is
`MalformedLine`, with the parse's error in `lines.fault.err` and its place found
by parsing the line again with diagnostics on, so a good line pays nothing for
them. A pretty record is parsed where it lies in the input's buffer when it can be
(`json` reads a value from the front of some bytes and says where it ended);
otherwise its lines are joined as far as a scan follows its value, then parsed
once. `Tail` parses the same way backwards, and `Tail.last` copies the lines into
one owner and parses them there. `keep` on every reader is `core.clone`: checked,
bounded and owned.

`jsonl.Writer` writes each record with `json.write` into the destination's unused
buffer and publishes it whole; a bounded writer encodes into owned scratch and
measures before publishing. `Versioned(T)` is a type with a data codec of its
own: `{"v":N,"data":...}`, the payload parsed straight into `T` when `v` comes
first and is current, and otherwise held where it lies and read once `v` is known,
by `T` or by the type's `jsonlMigrate` as an older shape.

`jsonl.Decoder` owns one bounded buffer and a reused caller-allocator arena,
with one allocation cap over both, including arena backing overhead. Its push
API frames physical LF records. BOM acceptance is restricted to stream offset
zero even after oversized-record recovery.
`push` reports consumption even for errors. Oversize enters drain state and
cannot reinterpret a suffix as another record, including across calls. Recovery
is capped independently of payload; zero is a zero-byte budget. Records expire
at the next advancing call. `keep` acquires an independent owner. `finish`
accepts, requires, or drops an unterminated final record according to policy.

Checkpoints keep airlock's file identity, `{volume:u64,file:u128}`, with those
field names and widths: a follower's checkpoint is a wire format.

## Evidence

The JSON Lines behaviour the earlier codec was tested for (framing, offsets,
resumes, separators, pretty records, sync policies, tail and follow) is tested on
the one API. The pinned MIT-licensed JSONTestSuite corpus runs all y/n/i inputs in CI. Grammar mode
permits duplicates; strict rejection has separate tests. Numeric i cases retain
lexemes; invalid encodings and lone surrogates reject. Bounds, exact arithmetic,
truncations, every small framing split, independent lifetimes and allocation
failures have focused tests. Timings and comparisons belong in private trials;
CI never gates variable wall-clock performance.

## Mapping and schema policy

`describe(T, capabilities)` inspects types without instantiating an operation.
It returns supported, conditional, or unsupported with encode/decode direction,
a field path and a reason. Operations reject excluded schemas at compile time.
Recursive inspection uses a visited-type set; traversal limits apply separately.

The mapping kernels specialize into direct backend calls. Immediate semantic
visits preserve text versus bytes, integer magnitude and sign, Unicode scalar,
none versus some, unit, sequence, tuple, map, record and variant. `NamedUnit`,
`Newtype` and `NamedTuple` carry nominal shapes. `Bytes` and bounded byte access
let custom codecs retain arbitrary bytes without a text interpretation. `Pairs(K,V)` preserves entry order
and duplicates. The maintained unmanaged `ArrayList(T)` field codec uses the
standard library's public owned-slice API; other resource-owning containers need
an explicit data codec. No container capacity or hash internals are serialized.

Booleans, arbitrary-width integers, floats, exhaustive enums, tagged unions,
plain structs (including packed/extern), tuples, arrays, vectors, safe single
pointers and slices have derived meaning. Nonexhaustive enums need a numeric
codec. aegis scalars are what they hold, recognized by the `aegis_scalar` literal each
declares, never by its shape, so one made by another copy of aegis (a program
pinning another aegis version than strand's) is taken alike:
`units.Duration` and `units.Bytes` read and write their exact text form (`1m30s`,
`64MiB`), and refuse a bare number, whose unit the text would not state; the
other units, `int.Checked`, `int.Saturating`, `int.Ranged`, and the ids and
counters are their representation's integer, a `Ranged` out of its range and a
`NonZero` zero refused as `NumberOutOfRange`. Many/C pointers, volatile/allowzero/non-generic pointers, functions,
native errors, allocators, Io, files, locks and secret-bearing values are excluded
from automatic derivation. Pointer-bearing sentinels are excluded. Valid initialized
values and readable pointers remain the caller's Zig obligations.

A type's `strand` declaration supplies field names/aliases, casing, defaults,
skip/omit, text/byte representation, codecs, borrow policy, maximum length,
numeric ranges and predicates. Missing uses a default once; null is a value.
Aliases share a duplicate slot. Omission compares values structurally or uses an
explicit equality predicate, never padding or pointer identity. External tags
are the default; internal and adjacent tags require unique discriminants and
exact payload boundaries. Unknown capture is explicit format-branded Raw.
Caller acceptance can tighten unknown-field and duplicate policy.

A reading may also accept more than a type declares, as a reader that must take
what a lenient writer's reader takes needs to (Go's `encoding/json` is the one held
to): every choice is a field of `core.Acceptance` that the one mapping kernel or the
format's own text reading honours, never a second mapper beside them. `duplicates`
overrides each record's own policy for the whole reading; its `merge` reads a member
given again into what the earlier one left (`Cursor.readInto`): a record member by
member, an optional's value, a pointer's, a sequence's elements by position (the rest
read afresh), an array's, a map's entries with a key given again taking its later
value read afresh; anything else, a type with a codec of its own among them, is read
afresh and replaces it. A map's keys follow the same choice (`first`, `last`, `merge`)
where the reading names one, and are all kept where it leaves it to the types.
`names = .fold_case` matches a key no name spells exactly by case folding, the first
of the record's names in declaration order (fields, then aliases) it folds to, code
point by code point under Unicode's simple case folding (xenoglyph's `case.simpleFold`),
as Go's `encoding/json` matches names: `É` with `é`, the three sigmas with one another,
`ſ` and the Kelvin sign with `s` and `k`; `ß` folds to no `ss`, which is full folding,
and a sequence that is not UTF-8 matches only the same bytes. `nulls = .keep` takes a null where the type has none: a record's
field keeps what it held (its default, or an earlier member's value), a sequence and a
map are emptied, a value read fresh (an element, a map's value, the root) is its type's
zero (false, 0, empty, null, a record of its defaults; a type with none refuses it). The
check is made before a type's own codec, which therefore never sees such a null and needs
no prior value to keep; a type whose values include null reads it itself: an optional, a
raw value, and a type that declares `strand_nullable` (each format's dynamic `Value`).
JSON adds two of its text: `integers = .digits` takes an integer only as written as one
(no fraction or exponent, a minus only for a signed type), and `invalid_unicode =
.replace` reads a byte that begins no UTF-8 sequence and a surrogate escape without its
pair as U+FFFD, in values, keys and passed-over values alike, a byte at a time as Go's
decoder does; a `Raw` keeps its bytes as written. Every choice costs a strict reading
one predictable branch where it is checked; a string is rewritten only on the slow path
an escape already takes. `json.parsePrefixLeaky` reads one value off the front of its
input and says where it ended, as a stream decoder leaves the rest.

`json.schema` derives a JSON Schema (2020-12) from the same descriptor at compile
time, per direction: what `parse` accepts (`required` is the fields without a default,
aliases are properties, unknown members refused unless the parse ignores them) and what
`write` writes (`required` is the fields always written). It never guesses a codec's
shape: a type or field codec declares `strand_json_schema`, and one that does not is a
compile error. A type reachable from itself is emitted once, under `$defs` (the root as
`#`). A property test writes values drawn for each test type and holds them to both
schemas with a checker of the keywords the derivation emits (test support only; a
validator is not part of strand's API).

## Ownership and failure

`acquire`/`acquireWith` run one decode callback into a bounded result arena and
return `Parsed(T)`. Borrowed results may retain stable input spans: keep input
alive and unchanged while they are used. Transient scratch spans always copy.
Owned acquisition copies input references; mutable, aligned and sentinel spans
also require independent typed storage. `borrow.require` conflicts with owned
acquisition at compile time and fails when a borrow is unavailable at runtime.

`Parsed.take` transfers ownership and invalidates its source. Deinitialize the
live owner exactly once; do not separately deinitialize arena-backed field
containers. Acquisition uses errdefer to release all arena storage on failure.
Requested storage, retained reservations and actual backing residency are
reported separately. `acquireLeaky` uses a caller arena: failed allocations remain
until the caller resets it. Checked `clone` copies reflected plain data into a
new owner, excludes resource owners and bounds cycles by depth.

The core's accounting is aegis where aegis fits. The totals that are charged once
and never returned (input, output, work, requested allocation) are `bounded.Budget`s,
a refused request is a released reservation, and size arithmetic is `int.Checked`;
the budget's own compare-then-add replaced four functions that ran with runtime
safety forced on, which cost a record's strict parse and write a double-digit
share in the paired timings. The node count, which a hint type hands back, the two nesting
depths, which are entered and left in pairs on every level, and the allocator
wrapper's live bytes, which fall as it frees, stay plain counters: a budget has no
way to give back. `Limits` stays plain numbers because the core takes their
minimum and their difference as well as comparing against them. A diagnostic's path
is an `err.Context` of closed frames, so a field name that the input chose is escaped
text, never raw bytes. `Parsed` keeps its own liveness check, which is always on; an
`own.Owned` tracks use only in Debug. `input.Untrusted` has no place where the parser
is the boundary and nothing else sees the raw bytes, and it refuses a parse whose
result is the bytes' own type, such as a string. The JSON Lines readers keep
plain `u64` and `usize` counts for lines, offsets and skips: they are positions in
a stream, not budgets.

Limits cover input/output bytes, wire depth and independently capped hook
delegation depth, total and per-container items, text/key
length, numeric length, allocation and work. Skipped fields, unknown payloads,
Raw validation and custom access still traverse and charge the whole wire value.
Tag routing may replay validated spans; replay charges additional work without
charging the same wire bytes and nodes twice. Fixed-schema writing needs no heap.
A failed fixed-buffer write publishes no usable result; discard its partial bytes.
Encoding detects active-path pointer cycles within depth/work limits.

## Backend and custom codec contract

A backend supplies `next(context, request)`, `offset` and `endInput`; Raw and tag
routing additionally require validated span access and bounded replay. Typed
requests provide expected shape, numeric width, exactness and borrow policy.
They do not override wire grammar. Visits must preserve numeric information
until checked conversion; a format unable to do that returns a named refusal.
Formats validate syntax and advertised root, numeric, null and byte capabilities.
The common traversal rejects unsupported indefinite and nonfinite visits even
when skipping. Length hints are checked against actual payload and caller limits.

Backends meter reads, writes and scratch before doing the work. A borrowed span
must refer to stable input, a transient span to temporary scratch, and an owned
span to this operation's storage. Borrow capability describes what the backend
can supply; it never permits labelling scratch as input. Canonical Raw emission
must normalize or refuse; the core refuses unnormalized Raw in canonical mode.
The binary `testing/Reference.zig` backend exists only to exercise these contracts.

Hooks and field codecs consume one value through bounded access that carries
the enclosing field's representation, borrow policy, exactness and length limit.
A container codec can expose a pure `length(value) usize` to validate constructed
defaults; the maintained ArrayList codec does so. Compounds must
finish exactly their payload. Allocation goes through access/context, and errors
are explicit named sets. Predicate hooks are pure bool functions over their
field type. All custom codecs must return initialized plain data, allocate only
through context and perform no I/O or hidden resource acquisition. Zig has no
effect system: those obligations require review of a codec, not a claim that its
function signature mechanically proves purity. The guarantees do not cover a
callback violating this contract.

Diagnostics use fixed inline field/index storage and copy unknown names. Overflow
marks the path truncated. Common mapping supplies offsets and expected kinds;
text backends supply format identity and line/column when available. No input
fragment is logged.

## ZON

ZON is its own namespace on the core and imports no other format. `std.zon` is the
grammar and typed-value oracle, and reading it needs a tree: a tokenizer, a syntax
tree and a Zoir for the whole document before a byte of the result exists, none of
it bounded by anything but memory. strand reads a document in one pass instead. A
small state machine turns the tokens `std` itself defines (its number literal
grammar, string and character escapes) into the core's immediate events, so the
core's depth, node, string, key, number, work and allocation limits are charged
before the storage they guard exists, and an ignored value, a `Raw` value and an
escape in a name cost what they cost anywhere else. Nothing but data is syntax: an
identifier other than `true`, `false`, `null`, `inf` and `nan` is an error, and so
are calls, imports, operators and a doc comment. A field name given twice in one
struct is refused, whether or not anyone asked for it, as the grammar requires.

A struct is `.{ .name = value }` and a tuple, array and slice is `.{ value }`, which
the first member decides. A union is the arm's name when it holds nothing and a
struct of one field when it does. An enum is its name, which the type asked for as a
symbol and not as text, so that a string is never a name and a name is never a
string; the core asks formats for that by an `Expected.symbol` request and a `symbol`
hook on the encoder, which a format that does not spell names apart ignores. A
character literal is a number to everything but a Unicode scalar. A plain string
with no escape is borrowed from the input; with an escape, or across lines, it is
unescaped into the result's arena after its length is known and limited.

The encoder is the core's emission with `std.zon`'s spelling: containers of more
than two members wrap one to a line with a trailing comma, shorter ones stay on
their line, a one-element tuple has no inner space, an arm with no payload is
`.arm`. It stages its output and counts it against the output limit a stage at a
time, because a member is a few tiny pieces and counting each costs more than the
piece. A constant field name is written with its `.name = ` as one piece.

What `std.zon` accepts and strand does not: a number whose literal does not fit its
type is an error, never infinity (`1e999` as `f64`); a `[]const u8` is a string, so a
tuple of numbers is not one and a string with bytes that are not UTF-8 needs
`.as = .bytes`; untagged unions, nested optionals and names (`NamedUnit`, `Newtype`,
`NamedTuple`) have no representation and are refused when the type is compiled. A
float is rounded to its width once, from its decimal digits, where `std.zon` rounds to
`f128` first. What strand accepts and `std.zon` does not: integers of any width, and
a document of any size, within the limits.

## URL-encoded forms

A form is a flat list of `name=value` pairs, split and decoded as the WHATWG URL
standard's application/x-www-form-urlencoded parser splits them, with one
difference: a `%` that two hexadecimal digits do not follow is refused, where the
parser keeps it, since no encoder writes one. The structure is in the names: a
first segment, then `[segment]` for each level, `[]` adding to a sequence; a name
that breaks that grammar is a syntax error, and the brackets are found after
percent-decoding, so `a%5Bb%5D` is `a[b]`.

The decoder reads the pairs once into the operation's arena and then presents them
as the tree the paths make, as the type asks. A record's members are the pairs under
its path, wherever they stand in the list, its key the next segment; a member asked
for as a record opens a frame for that path, one asked for as a sequence collects the
pairs at that path (`tag=a`) and with `[]` after it (`tag[]=a`). A frame scans the
pairs from the first one that opened it and takes each pair once, charging its work,
so a form's cost is bounded by the work limit even when its pairs interleave. A name
repeated where one value belongs is a second key in its record, which the core's
duplicate policy refuses by default. Values are text, validated as UTF-8, unless the
type asks for bytes, a number (a lexeme in JSON's grammar, converted by JSON's exact
kernels), a boolean (`true` or `false`) or a unit (an empty value). A union tagged
inside its record would need a value read twice, which flat pairs cannot be: such a
type does not compile for this format.

The encoder keeps the current path, percent-encoded, in a buffer of its own (scratch
past 4 KiB), and writes a pair for each value: `name=value`, members as
`outer%5Binner%5D`, a sequence by repeating its name. A null, an empty sequence and a
record of nothing write no pair and read back through their defaults; a sequence of
records or of sequences has no spelling here and is `UnsupportedValue`. The output is
exactly the WHATWG form serializer's: every byte but ASCII letters, digits and `*-._`
percent-encoded in uppercase hex, a space as `+`.

## CSV

CSV is RFC 4180 in a dialect: the delimiter and the quote are any two bytes but line
breaks, the header is there or not, and the line ending written is CRLF or LF; either
ends a record read. The decoder reads a document as a sequence of rows, a row as a
record whose keys are the header's names, in the order the columns stand (the core
matches them to fields, refuses a name given twice and an unknown one by default), or,
asked for a tuple or an array, as a sequence by position. Every row has the header's
field count. A field is borrowed when it holds no doubled quote, and copied with its
quotes made single when it does.

CSV has no null and no types: a field is text, read as what the type asks for. A
number is a lexeme in JSON's grammar, converted by JSON's exact kernels. A null is the
one thing a field cannot say for itself, so the core tells the format where one is
taken: `Request.nullable` is set for an optional, and there an empty unquoted field
is null; anywhere else it is empty text, or for a number a refusal. The writer quotes
empty text, so null and empty text read back as they were. A field holds one value:
a record, a sequence or a union in one has no spelling and is refused, so a document
is a table and not a tree.

`Reader(T)` frames rows on JSON Lines' `LineReader`, with its CRLF handling off so
that a row keeps its `\r` and a quoted field its line breaks byte for byte: a row is
a physical line joined with the next while its quotes are odd, a byte-order mark at
the start is skipped, blank lines are passed over, and a row is held to
`max_row_bytes`. The header is the first row; each row after it is parsed on an arena
kept for it alone. `Writer(T)` writes the header before its first row. The header's
names are the struct's, as the core writes them (`core.wireNames`), so a field the
core leaves out of a row is an empty field in its column. A document's dialect reaches
its decoder inside the acquisition, which takes a decoder value with a `run` method
for a decoder that carries settings.

## CBOR

The decoder reads RFC 8949 in one pass and makes an event of every well-formed item:
an integer as its magnitude and sign (so -2^64 reaches a wide enough destination
exactly), a float of any width, a byte or text string borrowed where it is definite
and joined in the arena where chunked (each chunk a definite string of the same type,
text chunks each UTF-8), arrays and maps of either length, and two events the core has
for formats that need them: `tag`, before the item it tags, and `simple`, for a simple
value that is no boolean or null (`undefined` among them). A typed destination never
asks for either, so it refuses them where they stand; `cbor.Value` and the tag codecs
ask through their access (`tag()`, `simple()`). A definite length is checked against
the input left (every item is a byte at least) before the core counts it or anything
is allocated; reserved additional information, an indefinite integer or tag, a break
with nothing open, a two-byte simple value under 32 and an odd indefinite map are not
well-formed.

The encoder writes preferred serialization: the shortest head for every argument, the
shortest float that holds the value exactly, a NaN as half precision, definite lengths
(the core always knows them). The deterministic profiles (4.2.1 bytewise, 4.2.3
length-first) hold each map's encoded entries on an allocator until it closes, sort
them by their encoded keys (a tag's head is part of its key), refuse a key given twice,
and write them out; nested maps are sorted inside out.

## MessagePack

The decoder reads the specification's formats in one pass and makes an event of each
value: an integer as its magnitude and sign, from either family, so a non-negative
int 8 and a positive fixint are the same integer; a float of either width; str (UTF-8,
checked as it is read, so mapping does not look at it again) and bin as text and
bytes, borrowed; arrays and maps with their lengths. An extension is the core's
`tag` event holding its type, sign-extended to 64 bits, followed by its data as
`bytes`: a typed destination never asks for a tag, so it refuses an extension where it
stands, and `msgpack.Ext`, `msgpack.Timestamp` and `msgpack.Value` ask for one through
their access. A length is checked against the input left (every item is a byte at
least) before the core counts it or anything is allocated; 0xc1 is not MessagePack.

The encoder writes the smallest format for every value, the specification's
recommendation: the shortest integer family for the value (non-negative values always
unsigned), float 32 wherever it holds the value's bits exactly, float 64 otherwise,
the shortest length header, fixext for 1, 2, 4, 8 and 16 bytes of extension data. A
float is compared by its bits, so a negative zero, an infinity and a NaN's payload
survive; a typed `f32` is float 32. A tag given to the encoder sets the extension type
of the bytes written next; anything else after it is refused. The deterministic
profile is strand's own: MessagePack defines none. It holds each map until it closes
and writes its entries sorted by their encoded keys, bytewise, refusing a key given
twice, with the shared map-sorting kernel CBOR's deterministic profiles use
(`src/binary/sorted.zig`). That kernel is the only code the two binary formats share:
their grammars have nothing in common. A held map is refused once it holds more than
the output left.

Float events are `f128`, and the core widens and narrows them by their bits
(`core.widenFloat`, `core.narrowFloat`), not by conversion, which would quiet a
signalling NaN: a NaN read from the wire is written back as it came.

The evidence: golden vectors derived from the specification for every format family at
each of its edges, read and written back and refused when cut short anywhere;
[msgpack-test-suite](https://github.com/kawanet/msgpack-test-suite) (MIT, vendored at
`src/corpus/msgpack`), every encoding of each of its 85 values read and ours the
shortest of each kind; properties over generated values (round trip, every truncation,
the deterministic profile twice the same) and over arbitrary bytes (read, written in
no more bytes, read again as the same value). A cross-check against rmpv decoded 200,000
generated and damaged inputs: both read 71,016 to the same values and the same bytes,
both refused 128,917, and every disagreement was 0xc1, which rmpv reads as nil.

## TOML

A TOML table is not written in one piece: `[a]` then `[b]` then `[a.c]`, dotted keys
that add to a table line by line, arrays of tables that each header extends. A value
cannot be handed on before its table is complete, so the decoder reads the whole
document first (`src/toml/syntax.zig`) into one array of 28-byte nodes linked into a
tree (a container's first member and count, each node's next sibling) and walks it.
The rules for defining tables are checked as it is read, and refused as syntax whatever
the type asks: a key given twice; a table defined by a second header, or by a header
after dotted keys made it; dotted keys reaching into a table a header defined; anything
added to an inline table or to a static array. Every key is found through one index of
(table, key), each lookup charged as work, so dotted keys and implicit tables cost what
they reach. The nodes, the index and the decoded strings are working storage on the
caller's allocator (the caller's arena in `parseLeaky`), charged to the operation's
allocation budget through `core.Context.scratch` and given back when the parse ends: a
decoded string is a transient span, which the core copies into the result where it
keeps it, and a plain one is borrowed from the input. A document is held below 4 GiB,
the reach of a node's 32-bit positions.

A place in the walk is a node and a step at it (its key, its value, the text of its
date, its end), so a union tagged inside its table is read by walking from its place
again; a failure's offset is where its node was written. A string is text, an integer
or a float its spelling with `+` and `_` taken out, converted by the format's
`parseInteger` and `parseFloat` (TOML's signed 64 bits; a decimal float rounded once,
into its destination, by JSON's exact kernels), and a date or a time the core's `tag`
naming its kind, then its spelling as text. A typed destination never asks for a tag,
so a date is refused where text belongs; `toml.OffsetDateTime`, `toml.LocalDateTime`,
`toml.LocalDate` and `toml.LocalTime` ask for theirs, and in another format, which the
access names (`Access.Format`), read and write their RFC 3339 text. TOML 1.0 is the same
reader with four differences turned off: inline tables across lines and with a
trailing comma, `\e` and `\xHH`, times without seconds; and it lets a lone carriage
return stand in a multiline string, which 1.1 refuses.

The encoder holds the document as a tree on the allocator the write is given, since a
table's values must come before the tables under it and a type's members come in
declaration order, and writes it when the root closes: values as `key = value` lines,
then each table under its header (one with no values of its own but tables under it is
left to their headers), an array of tables alone as `[[sections]]`, anything else
inline on one line. Strings are basic strings with every control character escaped,
floats the shortest spelling that reads back as the same binary64, with a fraction or
an exponent, dates and times RFC 3339's spelling with seconds. All of it reads as TOML
1.0 and 1.1. A null is refused unless the write leaves null optionals out.

The evidence is toml-test (vendored at `src/corpus/toml` with its MIT license), every
file its 1.0.0 and 1.1.0 lists name, nothing skipped: each valid document read as the
value its JSON says, each invalid one refused, and each valid document's value written
and read back as TOML 1.0 to the same value. Properties write generated documents and
read them back in both versions, cut them anywhere, and read any bytes (examples with
a few edits) and write back whatever is read.

## YAML

YAML 1.2 is read in three steps. The scanner (`src/yaml/scanner.zig`) makes tokens of
the text in libyaml's shape: indentation becomes the starts and ends of block
collections, and an implicit key is found when the `:` after it is, then put before
the tokens it was made of. It is held to YAML 1.2 where libyaml reads 1.1: an anchor is
any characters but white space and flow indicators; a `:` inside a plain scalar in a
flow collection is text unless a space or a flow indicator follows it; a `:` right
after a JSON-like key (a quoted scalar, a flow collection) is a value indicator even
with no space after it; a tab is white space between tokens and never indentation (no
block collection starts after one, and a line's indentation is its spaces alone); a
block collection starts only at the start of a line or after `- `, `? ` or a `: ` that
starts its line, never after `key: ` or `---`; the lines of a quoted or plain scalar
and of a flow collection inside a block are indented past it; a block scalar's leading
empty line is never indented past its first line of content. The parser
(`src/yaml/parser.zig`) makes events of the tokens in libyaml's shape too, a stack of
states, with the rules for documents of YAML 1.2: a bare document after `...`, no
directive after a document that did not end with `...`, a key in a flow mapping that
runs over lines and its `:` on a line of its own. Every case of yaml-test-suite reads
as the events its `test.event` gives, and every invalid one is refused.

The events are read into nodes (`src/yaml/document.zig`) before the first value is
handed on, because an alias repeats a node that came before: a collection is followed
by its members and knows where they end, and an alias names the node its anchor is on,
so the walk repeats that node by going back to it. A node is 20 bytes; the nodes and
the decoded bytes are working storage charged through `core.Context.scratch` and given
back when the parse ends, and a decoded string is a transient span the core copies
where it keeps it. Each collection also knows how many nodes a walk of it reads with
its aliases repeated, so the whole stream's expansion is held to the item limit as it
is read: a document whose aliases of aliases would make a billion nodes is refused
before anything is made, and walking an alias charges its weight as work before it is
walked. An alias to an anchor never set, or set on a node still open (which would
repeat itself without end), is refused, and anchors are a document's own. A place in
the walk is a node, so a union tagged inside its mapping is read by walking from its
place again, through an alias as well.

What the core schema lacks is refused as the stream is read. A tag must be one of its
own, `!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq` and `!!map`, however it is
spelled (through a `%TAG` handle, or verbatim), or the non-specific `!`: a local tag
such as `!Ref` or YAML 1.1's `!!binary`, `!!set` and `!!omap` would make a value of a
type strand does not read, and dropping it would read the value as something it is
not. A tagged scalar must be what its tag says. A mapping's scalar keys are each given
once, compared as the values they are (`a` and `"a"`, `1` and `0x1`, `~` and `null` are
the same key; `1` and `"1"` are not); a key that is a collection is not compared.

A plain scalar is resolved where it is read, as YAML lets an application resolve one:
when the type asks for text, a number, a boolean or a unit and the spelling is one, it
is that; otherwise it is what the core schema says (null, a boolean, an integer, a
float, else a string), which is also what `yaml.Value` and a skipped value get. A
quoted or block scalar is always a string. So a string field reads `1.10` as written
and a float field as 1.1, a null is null only where an optional is read, and `yes` is
never a boolean. The core asks a map's key for the key's own type (`Pairs(u16, ...)`
reads `0x10` as 16), which the core now sets before it looks at the key. A number is
handed on as its spelling and converted by the format's `parseInteger` and
`parseFloat`: decimal, `0o` and `0x` integers of any width the type has, and floats
rounded once by JSON's exact kernels; a `!!float` written as an integer is given a
float's spelling as it is read, so that it reads as a float.

`parse` reads a stream's one document (none is an empty document, null; a second is
refused where it starts) and `parseStream` reads every document as one element of a
slice. The writer is streaming: block mappings and sequences indented by two, the
first member of a collection inside a sequence's entry on the entry's line, an empty
collection as `{}` or `[]`, a key that is a collection in flow style after `? `, as is a
key too long for an implicit one. A string is plain only where it reads back as the
same string under the core schema (and in block or flow context as it stands), and
double-quoted otherwise, every character that is not printable escaped. A float is the
shortest spelling that reads back as the same binary64, with a fraction or an
exponent, or `.inf`, `-.inf`, `.nan`. A map's keys are checked for one given twice as
the reader compares them. The writer allocates nothing unless a value nests past 64
levels or a map has more than 128 keys; then it needs `WriteOptions.allocator`.

The evidence is yaml-test-suite (the data-2022-01-17 release, vendored at
`src/corpus/yaml` with its MIT license): all 402 cases, each valid one read as its
events and each invalid one refused; each valid case with JSON read as `yaml.Value` as
its JSON says (263), written and read back as the same values, apart from the 16 whose
tags the core schema lacks, which are refused (`UnsupportedValue`) and listed by name.
Properties write generated values (keys of any kind) and read them back, cut them
anywhere, and read any bytes (examples with a few edits) in all three ownerships and
write back whatever is read.

## Format accelerators

A format may answer the core's most common requests without building an event:
`memberOf` reads a record's next key and matches it against the names the
schema spells, looking first for the one a writer that keeps declaration order
puts next, quotes and all, where it lies; `open` opens a container of the
expected kind; `number` and `text` read one kind of value. Each returns `null`
for anything else, which the event path then reads and refuses or takes, so an
accelerator changes no outcome, only its cost. A format that checks text as UTF-8
while it reads or writes it says so (`utf8_text`, `validates_text`), and mapping
does not look at the bytes again. A typed record's keys are checked by mapping,
with `seen` flags for known fields and a short list for ignored ones; the format
remembers keys only where mapping cannot, in maps and skipped values.

Decoders and encoders are built in place, field by field: their frames and keys
are kilobytes a struct literal would build elsewhere and copy.

## Measurements

Timings are manual observations in private trials, never CI acceptance tests. The
repository's own drivers are `bench/bench.zig` (JSON Lines write, read, tail,
follow, carried values, syncs), `bench/s2.zig` (JSON parse and write against
`std.json`), `bench/zon.zig`, `bench/schema.zig` (ten 100-field encoders against
hand-written ones) and `bench/core.zig` (the reference backend). Earlier releases'
rows and the comparison against them are in
[private trials](https://github.com/pedronaugusto/trials/tree/main/strand).
