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

By default A is the last first-parent main commit before **2026-09-30 00:00:00
+0100**, and B is current local main. The explicit time and offset enforce the
midnight boundary (Git's date-only `--before=2026-09-30` can inherit the current
time of day). `--before REV --after REV` selects other immutable snapshots.
Each job runs A, B, then its existing same-job tools, repeating that order five
times (`BENCH_RUNS`). One warm-up per side precedes those trials; all raw samples
are retained and summaries use medians. A and B share the exact harness sources
and deterministic input. Strand's workload APIs required no adaptation.

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
files are ignored. Scratch is removed on success or failure; tool caches remain
under `bench/build/quiet-cache`. Each pass builds fresh binaries, so smoke/full
mode and changed harnesses cannot accidentally reuse a stale executable.

Allow roughly **15–30 minutes** for the default full pass on an Apple Silicon
Mac with cached dependencies, plus first-time downloads/builds. This is a
planning estimate, not a measurement from this preparation. Have at least
5 GiB free for scratch and caches. `ZIG`, `GO`, `CARGO`, `CC`, `PYTHON`, `TAIL`
and standard tool cache environment variables can select installed tools/caches.
The specialized `run.sh`, `build-at.sh`, `own/` and `codec/` scripts remain for
individual investigations; `quiet.sh` is the complete pass entry point.
