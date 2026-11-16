#!/usr/bin/env bash
#
# check.sh -- linker-free type checks (macOS/Linux side).
#
# `odin check` type-checks packages without linking. Both interpreter modes,
# including freestanding, are checked regardless of VM_THREADED. The generated
# source drift check runs in test.sh, which already needs a linker.
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

# Check both modes explicitly regardless of the wrapper's selection or default.
CHECK_DEFINES=()
for define in "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}"; do
    if [[ "$define" != -define:VM_THREADED=* ]]; then CHECK_DEFINES+=("$define"); fi
done

# "path:is_library" pairs. Library packages have no `main`, so pass -no-entry-point.
check_one() {
    local path="$1" is_lib="$2"
    echo "==> check $path"
    if [[ "$is_lib" == "1" ]]; then
        odin check "$REPO_ROOT/$path" "$COLLECTION" \
            "${CHECK_DEFINES[@]+"${CHECK_DEFINES[@]}"}" -define:VM_THREADED=false -no-entry-point
    else
        odin check "$REPO_ROOT/$path" "$COLLECTION" \
            "${CHECK_DEFINES[@]+"${CHECK_DEFINES[@]}"}" -define:VM_THREADED=false
    fi
}

check_one src        0
check_one src/compiler   0
check_one src/kernel    1
check_one src/stdlib 1
check_one tests      1

# The generator imports no kernel packages and uses none of their defines.
echo "==> check tools/generate_threaded"
odin check "$REPO_ROOT/tools/generate_threaded"

# The bare-metal build selects a different set of files via `#+build freestanding`,
# so the hosted checks above cannot catch a break in it. Check it explicitly, or the
# platform split rots silently. Linker/codegen flags (-no-crt, -build-mode:obj) are
# not accepted by `odin check` and are not needed to type-check.
FREESTANDING_TARGET="${FREESTANDING_TARGET:-freestanding_amd64_sysv}"
echo "==> check src/freestanding ($FREESTANDING_TARGET)"
odin check "$REPO_ROOT/src/freestanding" "$COLLECTION" \
    "${CHECK_DEFINES[@]+"${CHECK_DEFINES[@]}"}" -define:VM_THREADED=false \
    "-target:$FREESTANDING_TARGET" -default-to-nil-allocator -no-entry-point

echo "==> check threaded interpreter"
odin check "$REPO_ROOT/src" "$COLLECTION" \
    "${CHECK_DEFINES[@]+"${CHECK_DEFINES[@]}"}" -define:VM_THREADED=true
echo "==> check threaded freestanding interpreter ($FREESTANDING_TARGET)"
odin check "$REPO_ROOT/src/freestanding" "$COLLECTION" \
    "${CHECK_DEFINES[@]+"${CHECK_DEFINES[@]}"}" -define:VM_THREADED=true \
    "-target:$FREESTANDING_TARGET" -default-to-nil-allocator -no-entry-point

echo "All packages check clean."
