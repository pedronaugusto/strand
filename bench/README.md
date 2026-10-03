# Strand benchmarks

Run `./bench/quiet.sh` from the repository on an idle Mac. It builds immutable
library snapshots, then runs the complete line, codec and own-operation pass.
All harness files and history live on `bench`; merge current main into this
branch before a later pass. No benchmark build step is required in either
library snapshot.

`./bench/quiet.sh --smoke` runs each job/side once with tiny fixtures and no
warm-up. It checks encoded records across the existing tools, codec byte/value
agreement, record counts, string borrowing, carried-record checksums and tails.
`codec-bench strand CORPUS --check-only` runs codec agreement checks without
executing any timing loop (use a full build/corpus for the full cross-check).
Smoke stdout is consumed and discarded; reports retain no timing, rate or ratio
values. A successful smoke run supports no performance claim.

`revisions.json` fixes A at `5fb576f145aad1a3e033222e7408770bdbcc4b66` and B at
`fe8b1e0f470e890073288b7b72a6ef309e37e972`, the final main. A retains the original
**2026-09-30 00:00:00 +01:00** cutoff. `--before REV --after REV` selects other
immutable snapshots; refresh the pins when main advances.

The jobs are typed read and raw framing over regular and long lines, write,
per-record flush, backwards tail, four codec shapes (including generated raw
and typed events), and own operations: write/read/batch, tail, big line, Raw
versus std.json.Value, and mixed-line reader versus parse alone. The mixed-line
job retains its fifteen internal interleaved reader/floor samples and 1.10
ratio target; the target is reported, never asserted.

The existing comparisons remain Zig std.json, Rust serde_json line/stream
readers and backwards reader, Go encoding/json and line framing, system tail,
and the copied Chronicle codec from `bde5a26`. They do different work where
noted by the job labels: framing avoids parsing; backwards tail returns values
in the library/Rust readers while system tail returns bytes. The codec envelope
decode is Strand-only. The old simd-json placeholder remains unavailable; no new
comparison tool is added. serde 1.0.228 and serde_json 1.0.145 are pinned in
Cargo.toml/Cargo.lock. Installed standard libraries and system tail are recorded
with machine/toolchain information. `codec/src/synthetic_corpus.py` creates 571
fixed-seed invented events from structural and string-length recipes.

Reports are plain `results.md` and `results.json` under
`bench/results/<UTC-date>/<UTC-start>/`; smoke uses `smoke.md` and `smoke.json`.
They include revision hashes, harness hash, machine/power information, tool
versions, execution order, samples and status. Results and owned scratch/cache
files are ignored. Prepared scratch and compiler caches persist; tool caches remain
under `bench/build/quiet-cache`. Smoke builds separate full/smoke binaries and checks correctness. The full
pass reuses them after checking source identity and prepared artifacts.

Quiet-only planning estimate: **6–15 minutes** after successful smoke preparation. See [QUIET-PREP.md](QUIET-PREP.md) for invocation counts, sizes and assumptions. This is a
planning estimate, not a measurement from this preparation. Have at least
5 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `CC`, `PYTHON`, `TAIL`
and standard tool cache environment variables can select installed tools/caches.
The specialized `run.sh`, `build-at.sh`, `own/` and `codec/` scripts remain for
individual investigations; `quiet.sh` is the complete pass entry point.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
