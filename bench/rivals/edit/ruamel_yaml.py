"""ruamel.yaml 0.19.1 (round-trip mode, which is pure Python: its C loader drops comments) on
the stacks strand's bench/edit.zig writes (`strand-edit-bench --inputs DIR`,
about 4 KiB and 256 KiB):
opened, one value set and the text taken, and the session of three edits (a
value set, a key added, an entry removed) and the text taken. Rows as
strand's: median of 31 samples of at least 100 ms each, in nanoseconds per
document. Each session's text is written to DIR/ruamel-SIZE.yaml for
`strand-edit-bench --check DIR`.

Run: uv run --no-project --with ruamel.yaml==0.19.1 python -I ruamel_yaml.py DIR
"""
import io
import json
import sys
import time

from ruamel.yaml import YAML


def row(name, f):
    batch = 1
    while True:
        start = time.perf_counter_ns()
        for _ in range(batch):
            f()
        if time.perf_counter_ns() - start >= 100_000_000:
            break
        batch *= 2
    samples = []
    for _ in range(31):
        start = time.perf_counter_ns()
        for _ in range(batch):
            f()
        samples.append((time.perf_counter_ns() - start) / batch)
    samples.sort()
    print(json.dumps({"row": name, "median": round(samples[15]), "best": round(samples[0])}))


yaml = YAML()  # round-trip
yaml.width = 4096


def dump(doc):
    out = io.StringIO()
    yaml.dump(doc, out)
    return out.getvalue()


def set_one(doc):
    doc["services"]["mid"]["replicas"] = 5


def session(doc):
    set_one(doc)
    doc["services"]["mid"]["env"]["TRACE"] = "on"
    del doc["services"]["old"]


def main():
    directory = sys.argv[1]
    for size in ("4k", "256k"):
        with open(f"{directory}/input-{size}.yaml") as f:
            text = f.read()
        doc = yaml.load(text)
        session(doc)
        with open(f"{directory}/ruamel-{size}.yaml", "w") as f:
            f.write(dump(doc))

        def set_row():
            doc = yaml.load(text)
            set_one(doc)
            return dump(doc)

        def session_row():
            doc = yaml.load(text)
            session(doc)
            return dump(doc)

        row(f"ruamel.yaml.open.{size}", lambda: yaml.load(text))
        row(f"ruamel.yaml.set.{size}", set_row)
        row(f"ruamel.yaml.session.{size}", session_row)


main()
