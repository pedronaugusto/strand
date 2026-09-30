#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
results="${BENCH_RESULTS:-$build/results.tsv}"

smoke=${BENCH_SMOKE:-0}
export BENCH_SMOKE="$smoke"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global-cache}"
export CARGO_HOME="${CARGO_HOME:-$build/cargo-home}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build/cargo-target}"
export GOCACHE="${GOCACHE:-$build/go-cache}"
"${PYTHON:-python3}" src/generate.py "$build/fixtures"
"${ZIG:-zig}" build -j1 --prefix "$build/zig-out" --cache-dir "$build/zig-cache" -Doptimize=ReleaseFast -Dsmoke=$([[ "$smoke" == 1 ]] && echo true || echo false)
"${CARGO:-cargo}" build -j1 --release --locked
"${GO:-go}" build -p=1 -ldflags='-s -w' -o "$build/go-bench" ./src/go_bench.go
"${CC:-cc}" -O2 -o "$build/tail-command" src/tail_command.c

raw=$(mktemp "$build/results.raw.XXXXXX")
trap 'rm -f "$raw"' EXIT
trials=${BENCH_RUNS:-5}
[[ "$smoke" != 1 ]] || trials=1
if ! [[ "$trials" =~ ^[1-9][0-9]*$ ]]; then
  echo "BENCH_RUNS must be a positive integer" >&2
  exit 2
fi

bench() {
  local suffix=$1
  shift
  [[ "$smoke" == 1 ]] || "$@" >/dev/null
  local i=0
  while (( i < trials )); do
    "$@" | awk -v s="$suffix" 'BEGIN{FS=OFS="\t"} NF==5{$2=$2 s; print}' >> "$raw"
    ((i += 1))
  done
}

regular="$build/fixtures/regular.jsonl"
long="$build/fixtures/long.jsonl"
output="$build/write-output.jsonl"

for fixture in regular long; do
  path=${!fixture}
  bench "-$fixture" "$build/zig-out/bin/strand-bench" read "$path"
  bench "-$fixture" "$build/zig-out/bin/zig-stdjson-bench" read "$path"
  bench "-lines-$fixture" "$CARGO_TARGET_DIR/release/strand-rival-bench" read "$path"
  bench "-$fixture" "$CARGO_TARGET_DIR/release/strand-rival-bench" stream "$path"
  bench "-$fixture" "$build/go-bench" read "$path"
  bench "-$fixture" "$build/zig-out/bin/strand-bench" raw "$path"
  bench "-$fixture" "$CARGO_TARGET_DIR/release/strand-rival-bench" raw "$path"
  bench "-$fixture" "$build/go-bench" raw "$path"
done

bench "" "$build/zig-out/bin/strand-bench" write "$output"
bench "" "$build/zig-out/bin/zig-stdjson-bench" write "$output"
bench "" "$CARGO_TARGET_DIR/release/strand-rival-bench" write "$output"
bench "" "$build/go-bench" write "$output"
bench "" "$build/zig-out/bin/strand-bench" write-flush "$output"
bench "" "$build/zig-out/bin/zig-stdjson-bench" write-flush "$output"
bench "" "$CARGO_TARGET_DIR/release/strand-rival-bench" write-flush "$output"
bench "" "$build/go-bench" write-flush "$output"

bench "" "$build/zig-out/bin/strand-bench" tail "$regular"
bench "" "$CARGO_TARGET_DIR/release/strand-rival-bench" tail "$regular"
bench "" "$build/tail-command" "$regular"

for fixture in regular long; do
  for work in typed-read raw-frame; do
    printf 'simd-json\t%s-%s\tn/a\tn/a\tn/a\n' "$work" "$fixture" >> "$raw"
  done
done

body=$(mktemp "$build/results.best.XXXXXX")
awk 'BEGIN{FS=OFS="\t"}
  $4=="n/a" { na[$1 FS $2 FS $3 FS $5]=1; next }
  { k=$1 FS $2 FS $3 FS $5; if (!(k in value) || ($5=="ms" ? $4<value[k] : $4>value[k])) value[k]=$4 }
  END {
    for(k in value) print k, value[k]
    for(k in na) print k, "n/a"
  }' "$raw" | awk 'BEGIN{FS=OFS="\t"}{print $1,$2,$3,$5,$4}' | sort -t $'\t' -k2,2 -k1,1 > "$body"
{
  printf 'side\tworkload\tmetric\tvalue\tunit\n'
  cat "$body"
} > "$results"
rm -f "$body"

if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$results"
else
  cat "$results"
fi
