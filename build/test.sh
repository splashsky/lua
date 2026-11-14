#!/usr/bin/env bash
#
# test.sh -- verify generated handlers and run the Odin tests (macOS/Linux).
#
# Odin's built-in test runner compiles a directory's @(test) procs and runs
# them. We point it at tests/ with the same `lang` collection the build uses so
# the tests can import `lang:kernel` and `lang:stdlib`.
#
# The generated threaded handlers are checked before running the unit tests.
# Both steps require a native linker. The PUC-Rio suite is run by puc.sh.
#
# Usage:
#     ./build/test.sh                  # run all Odin unit tests
#     ./build/test.sh foo              # run only tests matching a name
#     ./build/test.sh --stress --asan  # force stack moves under AddressSanitizer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="$REPO_ROOT/src"
TESTS_DIR="$REPO_ROOT/tests"

COLLECTION="-collection:lang=$SRC_DIR"

ARGS=("$TESTS_DIR" "$COLLECTION" "-define:INTERNAL_ASSERTS=true" "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}")
for arg in "$@"; do
    case "$arg" in
        --stress) ARGS+=("-define:HARDSTACKTESTS=true") ;;
        --asan) ARGS+=("-sanitize:address") ;;
        --*) echo "Unknown argument '$arg'." >&2; exit 1 ;;
        *) ARGS+=("-define:ODIN_TEST_NAMES=tests.$arg") ;;
    esac
done

bash "$REPO_ROOT/build/generate-threaded.sh" --check

echo "==> Running Odin tests in $TESTS_DIR"
odin test "${ARGS[@]}"

echo "All tests passed."
