#!/usr/bin/env bash
# Build codec-bench against strand at each named commit, into
# build/codec-bench-<commit>. The strand source is exported with
# `git archive` (the strand repository is only read), under build/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/../.." && pwd)}"
# `wt` builds the working tree as it stands, always afresh, as codec-bench-wt.
for c in "$@"; do
  if [[ "$c" == wt ]]; then short=wt; else short=$(git -C "$repo" rev-parse --short "$c"); fi
  out="$build/codec-bench-$short"
  [[ -x "$out" && "$c" != wt ]] && continue
  src="$build/strand-$short"
  rm -rf "$src"; mkdir -p "$src"
  if [[ "$c" == wt ]]; then
    (cd "$repo" && tar -c --exclude .zig-cache --exclude zig-out --exclude .git --exclude bench . ) | tar -x -C "$src"
  else
    git -C "$repo" archive "$c" | tar -x -C "$src"
  fi
  bench_dir="$build/bench-$short"
  mkdir -p "$bench_dir"
  cp "$here/build.zig" "$bench_dir/"
  sed "s|.path = \"../..\"|.path = \"../strand-$short\"|" "$here/build.zig.zon" > "$bench_dir/build.zig.zon"
  ln -sfn "$here/src" "$bench_dir/src"
  (cd "$bench_dir" && "${ZIG:-zig}" build -j1 --prefix "$build/out-$short" --cache-dir "$build/zig-cache" -Doptimize=ReleaseFast)
  cp "$build/out-$short/bin/codec-bench" "$out"
done
