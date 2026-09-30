#!/usr/bin/env bash
# Interleaved codec rows: every trial runs each side once, in an order that
# rotates per trial, each run waiting until the 1-minute load is under
# BENCH_MAX_LOAD (default 4). Best (lowest ns) of BENCH_RUNS (default 7).
#
#   ./alternate.sh label=binary:side ...
#   e.g. ./alternate.sh chronicle=build/codec-bench-28e76dc:chronicle strand-28e76dc=build/codec-bench-28e76dc:strand
#
# Raw rows with the load at each run go to BENCH_RAW (default build/alternate.raw.tsv).
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
max_load=${BENCH_MAX_LOAD:-4}
trials=${BENCH_RUNS:-7}
corpus="${BENCH_CORPUS:-$build/synthetic_events.jsonl}"
"${PYTHON:-python3}" src/tycho_corpus.py "$corpus"
raw="${BENCH_RAW:-$build/alternate.raw.tsv}"
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() { while awk -v l="$(load1)" -v m="$max_load" 'BEGIN{exit !(l>=m)}'; do sleep 20; done; }
sides=("$@")
n=${#sides[@]}
: > "$raw"
echo "start $(date '+%F %T') load $(load1)" >&2
for s in "${sides[@]}"; do spec=${s#*=}; "${spec%%:*}" "${spec##*:}" "$corpus" >/dev/null; done
for (( t = 0; t < trials; t++ )); do
  for (( k = 0; k < n; k++ )); do
    s=${sides[$(( (k + t) % n ))]}
    label=${s%%=*}; spec=${s#*=}
    wait_quiet
    before=$(load1)
    now=$(date +%T); "${spec%%:*}" "${spec##*:}" "$corpus" | awk -v b="$before" -v l="$label" -v t="$t" -v w="$now" 'BEGIN{FS=OFS="\t"} {$1 = l; print $0, b, t, w}' >> "$raw"
  done
done
echo "end $(date '+%F %T') load $(load1)" >&2
awk 'BEGIN{FS=OFS="\t"} {k=$2 FS $3 FS $1; if (!(k in best) || $4 < best[k]) best[k]=$4; n[k]++}
  END {for (k in best) {split(k,f,FS); print f[1], f[2], f[3], best[k], n[k]}}' "$raw" | sort -t $'\t' -k1,1 -k2,2 -k3,3 | column -t -s $'\t'
