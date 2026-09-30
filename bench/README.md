# strand benchmarks

Compares JSON Lines read/frame/write/flush/tail with Zig std.json, Rust
serde_json and a backwards reader, Go encoding/json, and system tail.
`codec/` compares the Chronicle codec from `bde5a26` with strand; `own/`
measures strand operations, Raw versus std.json.Value, and the mixed-line
reader against a parse with framing removed (best of fifteen interleaved
samples, with a 1.10 ratio target reported rather than asserted). Its harness
lives here on the bench branch, not in the library examples. `own/build-at.sh`
builds this harness against named library commits, including ones with no
benchmark build step. Each invocation owns and removes its scratch directories.

From `bench/`, run `./run.sh`, `./codec/run.sh`, or `./own/run.sh` on a quiet
machine. `BENCH_SMOKE=1` selects one tiny iteration without warm-up. Full
cross-language runs warm up once and take five trials (`BENCH_RUNS`);
codec operations run for at least 200 ms. The package is this repository.

Rust serde 1.0.228/serde_json 1.0.145 are exact in `Cargo.toml`, with
transitive pins in `Cargo.lock`. Go's language version is in `go.mod`, Zig's
minimum in `build.zig.zon`; standard libraries and tail use installed tools.
The copied Chronicle codec's source directory names its revision.
`codec/src/tycho_corpus.py` generates 571 fixed-seed invented events from
aggregate schemas and string lengths, retaining no original values or order.

`BENCH_BUILD_DIR` and `BENCH_RESULTS` select generated outputs (default
`build/`); `BENCH_CORPUS` selects the synthetic codec corpus. Tool overrides:
`ZIG`, `GO`, `CARGO`, `CC`, `PYTHON`, `TAIL`. Snapshot scripts take commit
arguments and `BENCH_REPO` (this repository by default). All generated files
are ignored. Record installed toolchain versions with full results.
