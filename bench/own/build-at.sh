#!/usr/bin/env bash
# The bench branch's harness against each named library commit. Library
# sources are exported with git archive; the repository is only read.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/../.." && pwd)}"
for commit in "$@"; do
  short="$(git -C "$repo" rev-parse --short "$commit")"
  source_dir="$build/source-$short"
  bench_dir="$build/harness-$short"
  mkdir -p "$source_dir" "$bench_dir"
  git -C "$repo" archive "$commit" | tar -x -C "$source_dir"
  cp "$here/build.zig" "$bench_dir/build.zig"
  sed 's|.path = "../.."|.path = "strand-src"|' "$here/build.zig.zon" > "$bench_dir/build.zig.zon"
  ln -sfn "$here/src" "$bench_dir/src"
  ln -sfn "$source_dir" "$bench_dir/strand-src"
  (cd "$bench_dir" && ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global-cache}" "${ZIG:-zig}" build -j1 --prefix "$bench_dir/out" --cache-dir "$bench_dir/cache" -Doptimize=ReleaseFast)
  cp "$bench_dir/out/bin/strand-own-bench" "$build/bench-$short"
done
