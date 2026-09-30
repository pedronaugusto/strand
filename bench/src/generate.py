#!/usr/bin/env python3
"""Generate deterministic JSONL fixtures once, without retaining records."""
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/fixtures"
os.makedirs(OUT, exist_ok=True)

def record(i, payload_len):
    return {
        "id": i,
        "name": f"user-{i % 10000:04d}",
        "count": (i * 17) % 1000000,
        "meta": {"region": ("eu", "us", "ap")[i % 3], "score": i % 101},
        "tags": ["jsonl", "benchmark", f"g{i % 97:02d}"],
        "message": ("abcdefghij" * ((payload_len + 9) // 10))[:payload_len],
    }

def make(name, count, payload_len):
    path = os.path.join(OUT, name)
    expected = os.path.join(OUT, name + ".count")
    if os.path.exists(path) and os.path.exists(expected):
        with open(expected) as f:
            if int(f.read()) == count:
                return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        for i in range(count):
            f.write(json.dumps(record(i + 1, payload_len), separators=(",", ":")))
            f.write("\n")
    os.replace(tmp, path)
    with open(expected, "w") as f:
        f.write(str(count))

make("regular.jsonl", 1 if os.environ.get("BENCH_SMOKE") == "1" else 1_000_000, 72)
make("long.jsonl", 1 if os.environ.get("BENCH_SMOKE") == "1" else 200_000, 1024)
