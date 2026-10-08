# Serialization core

The framework is work in progress. `strand.core` is a std-only module and the
root `strand.core` declaration is its facade. Existing JSON Lines code continues
to use the existing typed JSON implementation and `std.json` hooks. Core format
adapters for JSON, JSONL, ZON, CBOR, MessagePack and TOML are later work.

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
