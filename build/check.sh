#!/usr/bin/env bash
#
# check.sh -- linker-free verification for lua-odin (macOS/Linux side).
#
# `odin check` type-checks a package without invoking a native linker, so this
# works even on a machine with no full toolchain. It's our quick "does everything
# still compile?" gate. Library packages need -no-entry-point (they have no
# `main`); the two executables are checked as-is.
#
# Usage:
#     ./build/check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_ROOT/src"
COLLECTION="-collection:luao=$SRC_DIR"

# "path:is_library" pairs. Library packages have no `main`, so pass -no-entry-point.
check_one() {
    local path="$1" is_lib="$2"
    echo "==> check $path"
    if [[ "$is_lib" == "1" ]]; then
        odin check "$REPO_ROOT/$path" "$COLLECTION" -no-entry-point
    else
        odin check "$REPO_ROOT/$path" "$COLLECTION"
    fi
}

check_one src        0
check_one src/luac   0
check_one src/lua    1
check_one src/stdlib 1
check_one tests      1

echo "All packages check clean."
