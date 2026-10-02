#!/usr/bin/env python3
"""Fixed-seed invented events from aggregate structural and byte-length recipes.

Recipes contain no text, numeric values, identifiers, or event ordering.
The full corpus has 571 events, the same body frequencies and string-size
mix as the shape profile. All values are invented, including identity fields.
"""
import argparse, json, random
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", nargs="?", default="build/synthetic_events.jsonl")
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    rng = random.Random(0x5EED)
    def invent(shape):
        kind = shape[0]
        if kind == "object": return {k: invent(v) for k, v in shape[1]}
        if kind == "array": return [invent(v) for v in shape[1]]
        if kind == "null": return None
        if kind == "bool": return bool(rng.getrandbits(1))
        if kind == "float": return rng.randrange(1, 1000) / 1000
        if kind == "int":
            value = rng.randrange(10 ** (shape[1] - 1), 10 ** shape[1])
            return -value if shape[2] else value
        # Include quotes, slashes, newlines and non-ASCII without changing
        # the encoded string length. No source string is a generator input.
        remaining, parts = shape[1], []
        while remaining:
            char = rng.choice('abcdefghijklmnopqrstuvwxyz "\\\né')
            width = len(json.dumps(char, ensure_ascii=False).encode()) - 2
            if width > remaining: char, width = 'x', 1
            parts.append(char); remaining -= width
        return ''.join(parts)
    profiles = json.loads((Path(__file__).parent / "corpus_shapes.json").read_text())
    rows = [invent(shape) for count, shape in profiles for _ in range(count)]
    rng.shuffle(rows)
    if args.smoke:
        # One event is sufficient for the raw and typed codec paths.
        rows = [next(row for row in rows if "text" in row["body"])]
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + "\n")

if __name__ == "__main__": main()
