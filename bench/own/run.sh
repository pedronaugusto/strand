#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
"${ZIG:-zig}" build -j1 -Dscratch-dir="${BENCH_SCRATCH_DIR:-$build/scratch-own}" -Doptimize=ReleaseFast -Dsmoke=$([[ "${BENCH_SMOKE:-0}" == 1 ]] && echo true || echo false) --prefix "$build/out" --cache-dir "$build/cache"
"$build/out/bin/strand-own-bench"
