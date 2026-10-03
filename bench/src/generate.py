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

def make_lines(name, count, line):
    path = os.path.join(OUT, name)
    expected = os.path.join(OUT, name + ".count")
    if os.path.exists(path) and os.path.exists(expected):
        with open(expected) as f:
            if int(f.read()) == count:
                return
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        for i in range(count):
            f.write(line(i + 1))
    os.replace(tmp, path)
    with open(expected, "w") as f:
        f.write(str(count))

def compact(value):
    return json.dumps(value, separators=(",", ":"))

def damaged(i):
    """Every 97th line cut short (not JSON), every 1009th with a raw control byte."""
    line = compact(record(i, 72))
    if i % 97 == 0:
        return line[:-5] + "\n"
    if i % 1009 == 0:
        return line.replace("abcdefghij", "abcd\x01fghij", 1) + "\n"
    return line + "\n"

def tagged(i):
    arm = i % 3
    if arm == 0:
        return compact({"open": {"at": i, "who": f"user-{i % 10000:04d}"}}) + "\n"
    if arm == 1:
        return compact({"retry": {"at": i, "attempt": i % 5}}) + "\n"
    return compact({"close": {"at": i, "code": -(i % 3)}}) + "\n"

def carried(i):
    return compact({"kind": "mark", "at": i, "data": {"who": "ada", "beat": i % 7, "tags": ["a", "b"]}}) + "\n"

SMOKE = os.environ.get("BENCH_SMOKE") == "1"
make("regular.jsonl", 1 if SMOKE else 1_000_000, 72)
make("long.jsonl", 1 if SMOKE else 200_000, 1024)
make_lines("damaged.jsonl", 2200 if SMOKE else 1_000_000, damaged)
make_lines("pretty.jsonl", 3 if SMOKE else 200_000, lambda i: json.dumps(record(i, 72), indent=2) + "\n")
make_lines("seq.jsonl", 3 if SMOKE else 1_000_000, lambda i: "\x1e" + compact(record(i, 72)) + "\n")
make_lines("tagged.jsonl", 3 if SMOKE else 1_000_000, tagged)
make_lines("carried.jsonl", 3 if SMOKE else 1_000_000, carried)
