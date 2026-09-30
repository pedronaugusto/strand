#!/usr/bin/env bash
# strand's own `"${ZIG:-zig}" build -j1 bench` (examples/bench.zig) at each named commit,
# into build/bench-<commit>. Exported with `git archive`; the repository is
# only read.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/../.." && pwd)}"
for c in "$@"; do
  short=$(git -C "$repo" rev-parse --short "$c")
  out="$build/bench-$short"
  [[ -x "$out" ]] && continue
  src="$build/src-$short"; rm -rf "$src"; mkdir -p "$src"
  git -C "$repo" archive "$c" | tar -x -C "$src"
  (cd "$src" && "${ZIG:-zig}" build-exe -OReleaseFast --dep strand -Mroot=examples/bench.zig -Mstrand=src/strand.zig --cache-dir "$src/cache" -femit-bin="$out")
done
