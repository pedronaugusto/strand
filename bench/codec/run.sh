#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
args=()
[[ "${BENCH_SMOKE:-0}" != 1 ]] || args+=(--smoke)
corpus="${BENCH_CORPUS:-$build/synthetic_events.jsonl}"
"${PYTHON:-python3}" src/tycho_corpus.py "$corpus" "${args[@]}"
"${ZIG:-zig}" build -j1 -Doptimize=ReleaseFast -Dsmoke=$([[ "${BENCH_SMOKE:-0}" == 1 ]] && echo true || echo false) --prefix "$build/out" --cache-dir "$build/cache"
for side in chronicle strand; do "$build/out/bin/codec-bench" "$side" "$corpus"; done
