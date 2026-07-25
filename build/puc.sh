#!/usr/bin/env bash
#
# puc.sh -- drive the vendored PUC-Rio Lua 5.5 test suite against our `lua` (macOS/Linux side).
#
# The PUC-Rio suite (tests/puc/) is the project's final, un-fitted correctness
# oracle: real Lua's own regression tests, run verbatim against our interpreter.
# This script builds the standalone `lua` CLI and then runs the suite's master
# driver `all.lua` from inside tests/puc (the tests use relative `dofile` paths,
# so the working directory must be that folder).
#
# Usage:
#     ./build/puc.sh                  # build, then run the whole suite (all.lua)
#     ./build/puc.sh math.lua         # run a single suite file standalone
#     ./build/puc.sh --no-build       # skip the build, reuse the last binary
#
# Notes:
#   * `-e "_U=true"` enables the suite's "user tests" mode. The internal C test
#     library `T` is intentionally absent (we ship no ltests build); every suite
#     file guards its `T` usage with `not T or ...`, so those checks are skipped
#     cleanly rather than failing.
#   * Unlike Windows, /dev/null and /dev/full exist here, so files.lua runs to
#     completion. See tests/puc/README.md for the full list of deviations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_ROOT/src"
PUC_DIR="$REPO_ROOT/tests/puc"

COLLECTION="-collection:luao=$SRC_DIR"

OUT_DIR="$REPO_ROOT/build/out"
mkdir -p "$OUT_DIR"
LUA_EXE="$OUT_DIR/lua"

NO_BUILD=0
FILE=""
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        *) FILE="$arg" ;;
    esac
done

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building lua -> $LUA_EXE"
    odin build "$SRC_DIR" "$COLLECTION" -o:speed "-out:$LUA_EXE"
fi

if [[ ! -x "$LUA_EXE" ]]; then
    echo "lua not found at $LUA_EXE -- run without --no-build first." >&2
    exit 1
fi

cd "$PUC_DIR"
if [[ -n "$FILE" ]]; then
    echo "==> Running suite file '$FILE' standalone"
    "$LUA_EXE" -e "_soft=true; _port=true; _nomsg=true" "$FILE"
else
    echo "==> Running full PUC-Rio suite (all.lua, _U=true)"
    "$LUA_EXE" -e "_U=true" all.lua
fi

echo "PUC suite finished."
