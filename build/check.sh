#!/usr/bin/env bash
#
# check.sh -- type checks and threaded-source verification (macOS/Linux side).
#
# `odin check` type-checks packages without linking; this wrapper also builds
# the generator for its drift check, which requires a native linker. Library
# packages need -no-entry-point (they have no `main`); the two executables are
# checked as-is.
#
# Usage:
#     ./build/check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="$REPO_ROOT/src"
COLLECTION="-collection:lang=$SRC_DIR"

# The switch is the source of the generated threaded handlers. Refuse stale
# output rather than allowing changes to one interpreter to miss the other.
bash "$REPO_ROOT/build/generate-threaded.sh" --check

# "path:is_library" pairs. Library packages have no `main`, so pass -no-entry-point.
check_one() {
    local path="$1" is_lib="$2"
    echo "==> check $path"
    if [[ "$is_lib" == "1" ]]; then
        odin check "$REPO_ROOT/$path" "$COLLECTION" \
            "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" -no-entry-point
    else
        odin check "$REPO_ROOT/$path" "$COLLECTION" \
            "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}"
    fi
}

check_one src        0
check_one src/compiler   0
check_one src/kernel    1
check_one src/stdlib 1
check_one tests      1

# The bare-metal build selects a different set of files via `#+build freestanding`,
# so the hosted checks above cannot catch a break in it. Check it explicitly, or the
# platform split rots silently. Linker/codegen flags (-no-crt, -build-mode:obj) are
# not accepted by `odin check` and are not needed to type-check.
FREESTANDING_TARGET="${FREESTANDING_TARGET:-freestanding_amd64_sysv}"
echo "==> check src/freestanding ($FREESTANDING_TARGET)"
odin check "$REPO_ROOT/src/freestanding" "$COLLECTION" \
    "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" \
    "-target:$FREESTANDING_TARGET" -default-to-nil-allocator -no-entry-point

# Keep the optional interpreter type-checked even during the default check.
if [[ "${VM_THREADED:-0}" != "1" ]]; then
    echo "==> check threaded interpreter"
    odin check "$REPO_ROOT/src" "$COLLECTION" \
        "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" -define:VM_THREADED=true
    echo "==> check threaded freestanding interpreter ($FREESTANDING_TARGET)"
    odin check "$REPO_ROOT/src/freestanding" "$COLLECTION" \
        "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" -define:VM_THREADED=true \
        "-target:$FREESTANDING_TARGET" -default-to-nil-allocator -no-entry-point
fi

echo "All packages check clean."
