#!/usr/bin/env bash
#
# zjsonl — the suite on Linux, for real.
#
# macOS and Linux differ in the places this package actually touches: how a
# file is read at an offset, what a growing file looks like through an open
# handle, and which `std.Io` backend the threaded implementation picks. A
# cross-compile proves none of that. This runs the tests, on Linux, in a
# container built from the same Zig the manifest names.
#
# Usage:
#   ci/linux.sh              # Debug and ReleaseSafe, plus the Windows check
#   ci/linux.sh --rebuild    # rebuild the image first
#
# The image is cached under the name below; the Zig caches live inside the
# container, so a run leaves nothing in the working tree but the temporary
# directories the tests already clean up after themselves.

set -euo pipefail
cd "$(dirname "$0")/.."

image=${ZJSONL_LINUX_IMAGE:-zjsonl-zig-0.16.0}

if [ "${1:-}" = "--rebuild" ]; then
  docker image rm -f "$image" >/dev/null 2>&1 || true
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "==> building $image"
  docker build -f ci/linux.Dockerfile -t "$image" ci
fi

# The container runs as the invoking user so that anything the tests create
# under .zig-cache belongs to the person who ran them, not to root.
exec docker run --rm \
  --volume "$PWD:/src" \
  --workdir /src \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  "$image" \
  bash -euo pipefail -c '
    caches="--cache-dir /tmp/zc --global-cache-dir /tmp/zg"

    echo "==> $(zig version) on $(uname -s -m)"

    echo "==> zig fmt"
    zig fmt --check src examples build.zig

    echo "==> test — Debug"
    zig build test -Doptimize=Debug $caches

    echo "==> test — ReleaseSafe"
    zig build test -Doptimize=ReleaseSafe $caches

    # Compile-only, because this host cannot run it. The behaviour is the
    # `test` steps above; this is the claim that the sources are portable.
    echo "==> check — x86_64-windows-gnu"
    zig build check -Dtarget=x86_64-windows-gnu $caches

    echo "==> all green on linux"
  '
