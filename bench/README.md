# Strand benchmarks

Run `./bench/quiet.sh` from the repository on an idle Mac. It builds immutable
library snapshots, then runs the complete pass: every public operation, the
codec and the own operations.
All harness files and history live on `bench`; merge current main into this
branch before a later pass. No benchmark build step is required in either
library snapshot.

`./bench/quiet.sh --smoke` runs each job/side once with tiny fixtures and no
warm-up. It checks encoded records across the tools, codec byte/value agreement, record
counts, string borrowing, every job's cross-side checksums and tails.
`codec-bench strand CORPUS --check-only` runs codec agreement checks without
executing any timing loop (use a full build/corpus for the full cross-check).
Smoke stdout is consumed and discarded; reports retain no timing, rate or ratio
values. A successful smoke run supports no performance claim.

`revisions.json` fixes A at `5fb576f145aad1a3e033222e7408770bdbcc4b66` and B at
`6dc4dc9cdc234e76bf4b3fb4a6419c65972a388d`, main when this pass was prepared. A
retains the original **2026-09-30 00:00:00 +01:00** cutoff. `--before REV --after REV`
selects other immutable snapshots; refresh the pins when main advances.

Every public operation has a job. Line layer: typed read and raw framing over
regular and long lines, `keep` (owned values) and `copyOwned`/`freeOwned`, reading
past damaged lines (`on_malformed = .skip`), pretty records (`.pretty`, joined),
record-separated (RFC 7464) read and write, `resumeAt`, over-long lines refused
with and without `oversized_member`. Writers: write, per-record flush, pretty,
bounded (`initFileBounded`), `writeObjectOpen` with a member appended, per-record
sync. Bytes: `kindOf`, `tagOf`, `leadingIntMembers`, `indexOfControl`, `lines`.
Hooks and shapes: `innerParse` in a custom `jsonParse`, `Versioned` write and
migrating read, `Raw` carried, `Raw.parse`, `Raw.encode`. Files: `Tail.last`,
`Tail.prev`/`prevRaw` over a whole file, `Follower` catch-up, appended-line latency
(woken and polling), rotation, checkpoint/`resumeFrom`, `FileId.of`/`ofPath`,
`Identity.take` (file id and fingerprint), `syncFile` at both levels, `syncDir`.
The codec (four shapes) and the own operations (write/read/batch, tail, big
line, Raw versus std.json.Value, mixed-line reader versus parse alone, with its
fifteen interleaved samples and 1.10 target, reported, never asserted) remain.

Comparisons, where the tool has the operation: Zig std.json (and std.mem, std
stat, `File.sync`), Rust serde_json 1.0.145 (borrowed `Cow` strings over lines
framed with `read_until` into one reused buffer, owned values for `keep`,
`RawValue` for carried values, the reader-based stream deserializer as a
labelled extra), Go encoding/json and encoding/json/v2 from the Go 1.27 standard
library, Rust and Go std for the non-JSON operations, system `tail` (`-n`, `-r`,
`-F`), and the copied Chronicle codec from `bde5a26`. Each new job prints
`checksum` rows (counts and sums over its input); the harness refuses a job whose
sides disagree, in smoke and in the timed pass. Writers are compared by the record
they wrote (smoke), `writeObjectOpen` byte for byte. What has no equivalent is
listed as unavailable in the report, with the reason; operations new since the
before pin run on the after side only. serde 1.0.228 and serde_json 1.0.145
(`raw_value`) are pinned in Cargo.toml/Cargo.lock. `src/generate.py` writes the
fixed fixtures (regular, long, damaged, pretty, separated, tagged, carried) and
`codec/src/synthetic_corpus.py` creates 571 fixed-seed invented events.

Equivalence notes, for reading the ratios. Rust reads lines with `read_until`
(it has no borrowing line API), so each line is copied once; Go encoding/json
copies every string and v1 validates a value in a separate pass before decoding
it. `keep` copies into a caller's arena on the strand and std.json sides and
allocates per string in Rust and Go. `route-kind` on serde_json finishes the
object after the first key (serde has no peek); serde's `route-tag` parses the
arm; `leading-ints` alternatives parse the line into a struct holding only `id`.
`resume` seeks last place first, so no side reuses what it buffered. `sync` is
`F_FULLFSYNC` on every compared side on macOS (Rust `sync_data`/`sync_all`, Go
`File.Sync`); Zig's `File.sync` is plain `fsync` and is reported as
`sync-fsync`, a weaker durability. `tail` and `tail -F` are processes writing
bytes through a pipe; BSD `tail -F` looks for a rotation once a second, the
follower every 20 ms.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Prepared scratch and compiler caches persist; tool caches remain
under `bench/build/quiet-cache`. Smoke builds separate full/smoke binaries and checks correctness. The full
pass reuses them after checking source identity and prepared artifacts.

Quiet-only planning estimate: **15–25 minutes** after successful smoke preparation. See [QUIET-PREP.md](QUIET-PREP.md) for invocation counts, sizes and assumptions. This is a
planning estimate: one diagnostic trial of every job on a shared machine, times
six (a warm-up and five trials), with margin; it is not a published figure. Have
at least 5 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `CC`, `PYTHON`, `TAIL`
and standard tool cache environment variables can select installed tools/caches.
The specialized `run.sh`, `build-at.sh`, `own/` and `codec/` scripts remain for
individual investigations; `quiet.sh` is the complete pass entry point.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
