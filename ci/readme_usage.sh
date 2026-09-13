#!/usr/bin/env bash
#
# strand — a README.md code block, extracted from an example.
#
# A code snippet in a README is a claim about how the library is used, and
# nothing compiles it. These are regions of examples that `zig build examples`
# builds AND runs, so `ci/check-readme.sh` comparing this output against the
# document is what keeps the two the same thing.
#
# Usage: ci/readme_usage.sh [source] [region] [--no-import]
#
#   ci/readme_usage.sh                              # examples/usage.zig, "usage"
#   ci/readme_usage.sh examples/logbook.zig tail    # a named region of another
#
# A region is the text between two `// --- README:<region> ---` markers. The
# `const strand = @import(...)` line is taken from the file and printed above
# the region, because it is the one line a reader needs that cannot live
# inside a function; `--no-import` leaves it out of a block that is not the
# first one in the document.

set -uo pipefail
cd "$(dirname "$0")/.."

exec python3 - "${1:-examples/usage.zig}" "${2:-usage}" "${3:-}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
region = sys.argv[2]
want_import = sys.argv[3] != "--no-import"
text = source.read_text(encoding="utf-8")

marker = "// --- README:%s ---" % region
parts = text.split(marker)
if len(parts) != 3:
    sys.exit(
        "%s: expected exactly two %s markers, found %d"
        % (source, marker, len(parts) - 1)
    )

# The import is the one line a reader needs that cannot live inside a
# function, so it is read from the file too rather than written out here.
imports = [
    line for line in text.splitlines() if line.startswith('const strand = @import(')
]
if len(imports) != 1:
    sys.exit("%s: expected exactly one `const strand = @import(...)` line" % source)

# The region sits inside a function; the README shows it at the left margin,
# which means removing the indentation the whole region shares and no more.
lines = parts[1].splitlines()
indents = [len(l) - len(l.lstrip(" ")) for l in lines if l.strip()]
strip = min(indents) if indents else 0
body = [l[strip:] if l.strip() else "" for l in lines]

print("```zig")
if want_import:
    print(imports[0])
    print()
print("\n".join(body).strip("\n"))
print("```")
PY
