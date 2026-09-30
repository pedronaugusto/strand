#!/usr/bin/env bash
# strand's own bench rows, interleaved: each trial runs every build once in
# a rotating order, each run waiting for the 1-minute load to fall under
# BENCH_MAX_LOAD (default 4). Best of BENCH_RUNS (default 7): lowest
# ns/line or µs, highest lines/s.
#   ./alternate.sh label=binary ...
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
max_load=${BENCH_MAX_LOAD:-4}; trials=${BENCH_RUNS:-7}
raw="${BENCH_RAW:-$build/alternate.raw.txt}"
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() { while awk -v l="$(load1)" -v m="$max_load" 'BEGIN{exit !(l>=m)}'; do sleep 20; done; }
sides=("$@"); n=${#sides[@]}
: > "$raw"
echo "start $(date '+%F %T') load $(load1)" >&2
for s in "${sides[@]}"; do "${s#*=}" >/dev/null; done
for (( t = 0; t < trials; t++ )); do
  for (( k = 0; k < n; k++ )); do
    s=${sides[$(( (k + t) % n ))]}
    wait_quiet; before=$(load1)
    { echo "=== ${s%%=*} trial $t load $before $(date +%T)"; "${s#*=}"; } >> "$raw"
  done
done
echo "end $(date '+%F %T') load $(load1)" >&2
