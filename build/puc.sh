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
#     STRESS=1 ASAN=1 ./build/puc.sh  # force stack moves under AddressSanitizer
#
# Notes:
#   * `-e "_U=true"` enables the suite's "user tests" mode. The internal C test
#     library `T` is intentionally absent (we ship no ltests build); every suite
#     file guards its `T` usage with `not T or ...`, so those checks are skipped
#     cleanly rather than failing.
#   * Unlike Windows, /dev/null exists here, so files.lua gets past the test that
#     aborts the suite on Windows. /dev/full is a Linux-only device, though: on
#     macOS and the BSDs it does not exist, so files.lua still fails at that block
#     there -- reference Lua fails identically on the same machine. Only Linux
#     runs files.lua to completion. See tests/puc/README.md for every deviation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="$REPO_ROOT/src"
PUC_DIR="$REPO_ROOT/tests/puc"

COLLECTION="-collection:lang=$SRC_DIR"

OUT_DIR="$REPO_ROOT/build/out"
mkdir -p "$OUT_DIR"
LUA_EXE="$OUT_DIR/$BRAND_EXE"

NO_BUILD=0
STRESS="${STRESS:-0}"
ASAN="${ASAN:-0}"
FILE=""
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        --stress) STRESS=1 ;;
        --asan) ASAN=1 ;;
        *) FILE="$arg" ;;
    esac
done

if [[ "${VM_THREADED:-0}" == "1" ]]; then LUA_EXE+="-threaded"; fi
if [[ "$STRESS" == "1" ]]; then LUA_EXE+="-stress"; fi
if [[ "$ASAN" == "1" ]]; then LUA_EXE+="-asan"; fi

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building lua -> $LUA_EXE"
    TEST_FLAGS=()
    if [[ "$STRESS" == "1" ]]; then
        TEST_FLAGS+=("-define:HARDSTACKTESTS=true")
    fi
    if [[ "$ASAN" == "1" ]]; then TEST_FLAGS+=("-sanitize:address"); fi
    if [[ "$STRESS" == "1" || "$ASAN" == "1" ]]; then TEST_FLAGS+=("-define:INTERNAL_ASSERTS=true"); fi
    odin build "$SRC_DIR" "$COLLECTION" -o:speed "${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"}" "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$LUA_EXE"
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
