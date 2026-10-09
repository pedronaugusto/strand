# Serialization core and JSON formats

Strand has independent `strand.core`, `strand.json`, and `strand.jsonl` build
modules. The root is a declaration-only compatibility facade. Private build
modules give each source a single compiler owner, including when a consumer
imports all four public modules together. Gantry checks every source's layer.
Core and JSON import no airlock; JSONL owns that unchanged durability edge.
Test/tool dependencies remain lazy and outside production modules.

## Module boundaries

Bounds → semantic vocabulary/schema → mapping → ownership → core facade → JSON
wire/syntax → JSON API/facade → framing/schema → streams → tail/follow → JSONL
API/facade → root. The historical mapping policy is a core specialization over
format-supplied wire primitives, preserving its in-place and fixed-buffer hot
paths. Bounded mapping consumes immediate events, including JSON number
lexemes; it requires no DOM or token tape. JSONL framing shares its line/drain
boundary decision between the pull path and push decoder. std's historical
hooks remain confined to the legacy JSON entry points.

## JSON APIs and guarantees

`parse`, `parseOwned`, and `parseLeaky` use the same descriptor and bounded
context. `Parsed(T)` owns storage, never input or Io. Unescaped legal const spans
may borrow only in `parse`; owned decoding copies every retained span. Failed
owned acquisition rolls its arena back. Caller-arena acquisition bounds requested allocations per operation and is
leaky until reset; the caller owns its backing residency. Parsed owners and the
push decoder additionally cap arena backing residency. Dynamic `Value` uses bounded codec access and preserves number lexemes,
ordered keys, strings, arrays and null without lossy numeric conversion.

Strict parsing rejects unknown fields unless opted into validated skipping and
rejects duplicate wire keys, including unknown/skipped keys. Wire limits also
cover Raw and custom bounded access. Decimal integer conversion has no float
intermediate, and float rounding is directly to the requested destination.
Exact conversion compares decimal and binary rationals with budgeted big
integers. Legacy std hooks are refused by strict derivation unless a common
codec defines the type's bounded data meaning.

`json.parseStdValue(gpa, bytes, options)` is the explicit bounded standard
Value adapter. It keeps std's integer/float/number_string precision policies and
moves the core arena into a stable `std.json.Parsed(std.json.Value)` owner.
Use its `deinit`; managed arrays retain a valid arena allocator. `json.write`
accepts standard Value with caller-supplied scratch. Automatic core derivation
continues to exclude allocator-bearing standard containers.

`write` streams checked ordinary JSON and can publish a prefix before a sink,
value or limit failure. A caller-owned output buffer provides transactional
publication. Output, escapes and Raw validation are charged. Scratch is
caller-supplied; no global allocator is chosen. JCS is not exposed.

`jsonl.Decoder` owns one bounded buffer and a reused caller-allocator arena,
with one allocation cap over both, including arena backing overhead. Its push
API frames physical LF records. Existing pull pretty/separator modes retain
their fused zero-copy specialization and unchanged public state.
`push` reports consumption even for errors. Oversize enters drain state and
cannot reinterpret a suffix as another record, including across calls. Recovery
is capped independently of payload; zero is a zero-byte budget. Records expire
at the next advancing call. `keep` acquires an independent owner. `finish`
accepts, requires, or drops an unterminated final record according to policy.

The legacy root retains its actual defaults, std hook signatures, writer-only
errors, Raw span offsets, declaration-order/null-omission bytes, routing,
Versioned migrations and airlock checkpoint identity fields/widths. These
operations do not silently inherit strict limits or policy.

## Evidence

Existing tests continue with only mechanical module-import changes. The pinned
MIT-licensed JSONTestSuite corpus runs all y/n/i inputs in CI. Grammar mode
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
codec. Many/C pointers, volatile/allowzero/non-generic pointers, functions,
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
fragment is logged. Legacy JSON hooks retain their existing allocation and limit
contract; exposing the core does not strengthen legacy hooks implicitly.

## Manual comparison protocol

The legacy Raw driver gives both revisions an isolated schema from the same type
factory and equal parse call-site reuse. Reusing a current-only schema in other
workloads changes its inlining opportunities and invalidates the comparison.
Both sides parse the same input with the same options, compiler and build mode,
and check result equality before interleaved timing. Legacy standalone workloads
retain their own schema. Timings are manual observations, not CI acceptance tests.

Hosted observations also rebuild the same driver after restoring the previous
main's source at the current module's paths. That identical-source control keeps
the module names, nominal schemas and call sites unchanged. A slowdown reproduced
by that control is measurement specialization/layout bias, not a source regression.
Keep all interleaved samples and disclose both candidate and control spreads.

## S2 validation scope

The pinned JSONTestSuite has 95 required accepts, 188 required refusals and 35
implementation-policy inputs, with no omitted input. Compatibility tests freeze
S1 root declarations and replay its existing byte/error/Raw/checkpoint, FaultIo
and Clock cases. The unchanged Chronicle main fixture compiles and executes
against this local package without changing the published consumer pin.
Independent consumer builds check that importing all public modules preserves
nominal owner types; a pure JSON consumer imports no durability module.

Fixed 100-field schemas parse and write with a failing allocator and zero
requested allocation. Managed standard Value arrays are tested after the
adapter returns, including append, and all allocation-failure sites are swept
with NoResize. Generated typed round trips and chunk partitions use shakedown.
The JSON writer reuses the scanner's vector string-boundary primitive; derived
records rely on checked schema uniqueness, while dynamic maps still check keys.

Manual runtime rows alternate order for 31 rounds after calibration. Reported
p99 values are percentiles of batch means, not individual record latency. The
legacy pairs cover parsing, writing, reading, routing, resident tail(1000) and
following 1000 already-written records; follower waiting remains covered by
controlled Clock tests. Tail's file is approximately 1 GiB (an integral number
of 513-byte records). The ten distinct 100-field encoder comparison uses the
same checked JSON backend and budgets on both sides. Its local compiler caches
are cold; the global dependency cache is shared and build-runner/configuration
time is included. File size and native text section size are distinct metrics.

Raw rows, compiler/source pins, runner provenance, calibration and limitations
are retained in [private trials](https://github.com/pedronaugusto/trials/tree/main/strand/s2).
These observations do not certify controlled per-record latency, the full broad
corpus, matched Rust/Go/SIMD rival wins or hardened fuzz/sanitizer coverage.
There is no best-of-kind claim or canonical JSON profile. Those proof obligations
remain explicit; later format or external-consumer work is outside this batch.
