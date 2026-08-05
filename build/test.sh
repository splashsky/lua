#!/usr/bin/env bash
#
# test.sh -- run the lua-odin test suite (macOS/Linux side).
#
# Odin's built-in test runner compiles a directory's @(test) procs and runs
# them. We point it at tests/ with the same `luao` collection the build uses so
# the tests can import `luao:lua` and `luao:stdlib`.
#
# Later phases will also invoke the vendored PUC-Rio Lua 5.5 suite from here;
# for now this runs whatever Odin unit tests exist.
#
# Usage:
#     ./build/test.sh                  # run all Odin unit tests
#     ./build/test.sh foo              # run only tests matching a name

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_ROOT/src"
TESTS_DIR="$REPO_ROOT/tests"

COLLECTION="-collection:lang=$SRC_DIR"

ARGS=("$TESTS_DIR" "$COLLECTION")
if [[ -n "${1:-}" ]]; then
    # Odin filters tests by fully-qualified name via -define:ODIN_TEST_NAMES.
    ARGS+=("-define:ODIN_TEST_NAMES=tests.$1")
fi

echo "==> Running Odin tests in $TESTS_DIR"
odin test "${ARGS[@]}"

echo "All tests passed."
