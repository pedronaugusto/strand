#!/usr/bin/env bash
# Interleave old and new strand builds for every workload in the harness.
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
old=${BENCH_OLD:-28e76dc}
new=${BENCH_NEW:-5fb576f}
trials=${BENCH_RUNS:-7}
max_load=${BENCH_MAX_LOAD:-4}
raw=${BENCH_RAW:-$build/alternate.raw.tsv}
regular="$build/fixtures/regular.jsonl"
long="$build/fixtures/long.jsonl"
[[ -f "$regular" && -f "$long" ]] || "${PYTHON:-python3}" src/generate.py "$build/fixtures"
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() { while awk -v l="$(load1)" -v m="$max_load" 'BEGIN{exit !(l>=m)}'; do sleep 20; done; }
: > "$raw"
echo "start $(date '+%F %T') load $(load1)" >&2
workloads=("$@")
if (( ${#workloads[@]} == 0 )); then
  workloads=(read-regular read-long raw-regular raw-long write write-flush tail)
fi
for workload in "${workloads[@]}"; do
  mode=${workload%%-*}
  case "$workload" in
    read-regular|raw-regular|tail) input="$regular" ;;
    read-long|raw-long) input="$long" ;;
    write|write-flush) mode=$workload; input="$build/write-output.jsonl" ;;
  esac
  [[ "$workload" == tail ]] && mode=tail
  for side in "$old" "$new"; do "$build/strand-bench-$side" "$mode" "$input" >/dev/null; done
  for ((trial=0; trial<trials; trial++)); do
    if (( trial % 2 )); then order=("$new" "$old"); else order=("$old" "$new"); fi
    for side in "${order[@]}"; do
      wait_quiet
      before=$(load1)
      "$build/strand-bench-$side" "$mode" "$input" | awk -F '\t' -v OFS='\t' -v s="$side" -v w="$workload" -v l="$before" -v t="$trial" '{print s,w,$2,$3,$4,$5,l,t}' >> "$raw"
    done
  done
done
echo "end $(date '+%F %T') load $(load1)" >&2
