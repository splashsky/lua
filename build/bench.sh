#!/usr/bin/env bash
#
# bench.sh -- run the reproducible lua-odin benchmark harness (macOS/Linux side).
#
# Only same-session, back-to-back runs are honest comparisons. Machine load
# varies enough that archived timings from separate sessions are not evidence.
#
# Usage:
#     ./build/bench.sh
#     ./build/bench.sh tables.lua
#     ./build/bench.sh --no-build
#     ./build/bench.sh --no-build --isolated micro.lua
#     REFLUA=/path/to/lua ./build/bench.sh
#     REFLUA=/path/to/lua ./build/bench.sh --in-process

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="$REPO_ROOT/src"
BENCH_DIR="$REPO_ROOT/bench"
COLLECTION="-collection:lang=$SRC_DIR"

# Prefer the platform's configured temporary/runtime directory, but fall back to
# a private directory under HOME. Odin requires this output path to contain no
# spaces, so fail clearly instead of silently producing a mis-tokenized command.
TEMP_BASE="${TMPDIR:-${XDG_RUNTIME_DIR:-$HOME}}"
OUT_DIR="$TEMP_BASE/lang-bench"
if [[ "$OUT_DIR" =~ [[:space:]] ]]; then
    echo "Benchmark output path contains whitespace: $OUT_DIR" >&2
    echo "Set TMPDIR to a space-free directory and try again." >&2
    exit 1
fi
mkdir -p "$OUT_DIR"
LUA_EXE="$OUT_DIR/$BRAND_EXE"

NO_BUILD=0
ISOLATED=0
IN_PROCESS=0
FILE=""
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        --isolated) ISOLATED=1 ;;
        --in-process) IN_PROCESS=1 ;;
        micro.lua|tables.lua|stdlib.lua|scaling.lua) FILE="$arg" ;;
        *) echo "Unknown argument '$arg'." >&2; exit 1 ;;
    esac
done
if [[ "$ISOLATED" -eq 1 && "$IN_PROCESS" -eq 1 ]]; then
    echo "Choose either --isolated or --in-process, not both." >&2
    exit 1
fi

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building lua -> $LUA_EXE"
    odin build "$SRC_DIR" "$COLLECTION" -o:speed "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$LUA_EXE"
fi

if [[ ! -x "$LUA_EXE" ]]; then
    echo "lua not found at $LUA_EXE -- run without --no-build first." >&2
    exit 1
fi
if [[ -n "${REFLUA:-}" && ! -x "$REFLUA" ]]; then
    echo "Reference lua is not executable: $REFLUA" >&2
    exit 1
fi

FILES=(micro.lua tables.lua stdlib.lua scaling.lua)
if [[ -n "$FILE" ]]; then FILES=("$FILE"); fi

run_benchmark() {
    local exe="$1" file="$2" label="$3" benchmark="${4:-}"
    local usage_file="$OUT_DIR/resource-usage.txt"
    local mode="all-in-one process"
    local command=("$exe" "$file")
    if [[ -n "$benchmark" ]]; then
        mode="isolated process : $benchmark"
        command+=("$benchmark")
    fi
    rm -f "$usage_file"

    echo "===== $label : $file [$mode] ====="
    if [[ -x /usr/bin/time ]] && /usr/bin/time -v true >/dev/null 2>&1; then
        (
            cd "$BENCH_DIR"
            /usr/bin/time -v -o "$usage_file" "${command[@]}"
        )
        local peak
        peak="$(awk -F: '/Maximum resident set size/ {gsub(/^[ \t]+/, "", $2); print $2}' "$usage_file")"
        echo "peakRSS ${peak:-unknown} KiB"
    elif [[ -x /usr/bin/time ]] && /usr/bin/time -l true >/dev/null 2>&1; then
        (
            cd "$BENCH_DIR"
            # BSD time has -l but not GNU time's -o. Its report follows the
            # command's stderr, so capture that stream while leaving the
            # benchmark result on stdout for us to see.
            /usr/bin/time -l "${command[@]}" 2>"$usage_file"
        )
        local peak_bytes
        peak_bytes="$(awk '/maximum resident set size/ {print $1}' "$usage_file")"
        if [[ "$peak_bytes" =~ ^[0-9]+$ ]]; then
            echo "peakRSS $((peak_bytes / 1024)) KiB"
        else
            echo "peakRSS unavailable"
        fi
    else
        # POSIX does not standardize a maximum-RSS field. Preserve benchmark
        # output and state the limitation rather than inventing a measurement.
        (cd "$BENCH_DIR" && "${command[@]}")
        echo "peakRSS unavailable (/usr/bin/time lacks -v and -l)"
    fi
    echo ""
}

# A reference comparison opts into isolation unless the caller explicitly asks
# for the old interaction-sensitive protocol. Standalone runs stay all-in-one,
# preserving the quick, familiar behavior of invoking this script casually.
USE_ISOLATION="$ISOLATED"
if [[ -n "${REFLUA:-}" && "$IN_PROCESS" -eq 0 ]]; then USE_ISOLATION=1; fi

for file in "${FILES[@]}"; do
    if [[ "$USE_ISOLATION" -eq 1 ]]; then
        # Ask the Lua file for its names so this runner never carries a second,
        # inevitably stale copy of the suite inventory.
        # macOS still ships Bash 3.2, which predates mapfile. Command
        # substitution plus this small read loop keeps the runner portable.
        benchmark_list="$(cd "$BENCH_DIR" && "$LUA_EXE" "$file" --list)"
        benchmarks=()
        while IFS= read -r benchmark; do
            benchmarks+=("$benchmark")
        done <<< "$benchmark_list"
        for benchmark in "${benchmarks[@]}"; do
            run_benchmark "$LUA_EXE" "$file" "lua-odin" "$benchmark"
            if [[ -n "${REFLUA:-}" ]]; then
                run_benchmark "$REFLUA" "$file" "reference Lua" "$benchmark"
            fi
        done
    else
        run_benchmark "$LUA_EXE" "$file" "lua-odin"
        if [[ -n "${REFLUA:-}" ]]; then
            run_benchmark "$REFLUA" "$file" "reference Lua"
        fi
    fi
done

echo "Benchmarks finished."
