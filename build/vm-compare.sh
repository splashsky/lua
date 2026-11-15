#!/usr/bin/env bash
#
# Compare both VMs and optionally reference Lua using Linux perf counters.
# Usage: REFLUA=/path/to/lua CPU=12 ./build/vm-compare.sh [runs]
# Each cell is minimum/median instructions; minimum/median cycles, in millions.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="${VM_COMPARE_SRC:-$REPO_ROOT/src}"
BENCH_DIR="$REPO_ROOT/bench"
RUNS="${1:-3}"
if [[ $# -gt 1 || ! "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: [REFLUA=/path/to/lua] [CPU=number] $0 [positive-runs]" >&2
    exit 1
fi
if [[ "$(uname -s)" != Linux ]]; then echo "vm-compare requires Linux perf." >&2; exit 1; fi
if [[ -n "${REFLUA:-}" && ! -x "$REFLUA" ]]; then
    echo "Reference lua is not executable: $REFLUA" >&2; exit 1
fi
if [[ -n "${REFLUA:-}" ]]; then REFLUA="$(realpath "$REFLUA")"; fi
SRC_DIR="$(cd "$SRC_DIR" && pwd)"

TEMP_BASE="${TMPDIR:-${XDG_RUNTIME_DIR:-$HOME}}"
if [[ "$TEMP_BASE" =~ [[:space:]] ]]; then
    echo "Set TMPDIR to a space-free directory for Odin." >&2; exit 1
fi
WORK="$(mktemp -d "$TEMP_BASE/lang-vm-compare.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PIN=()
if [[ -n "${CPU:-}" ]]; then
    if [[ ! "$CPU" =~ ^[0-9]+$ ]]; then echo "CPU must be a non-negative CPU number." >&2; exit 1; fi
    PIN=(taskset -c "$CPU")
fi

# Check permissions and event availability before spending time building.
if ! perf stat -x, -e instructions:u,cycles:u -o "$WORK/perf-check" -- "${PIN[@]}" true; then
    cat "$WORK/perf-check" >&2
    echo "perf could not count user instructions and cycles." >&2
    exit 1
fi
if ! awk -F, '$3 == "instructions:u" && $1 ~ /^[0-9]+$/ {i=1}
              $3 == "cycles:u" && $1 ~ /^[0-9]+$/ {c=1}
              END {exit !(i && c)}' "$WORK/perf-check"; then
    cat "$WORK/perf-check" >&2
    echo "perf did not return usable instruction and cycle counts." >&2
    exit 1
fi

# Ignore only the VM selection from the wrapper; both builds are explicit.
DEFINES=()
for define in "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}"; do
    if [[ "$define" != -define:VM_THREADED=* ]]; then DEFINES+=("$define"); fi
done
for mode in switch threaded; do
    value=false
    [[ "$mode" != threaded ]] || value=true
    echo "==> Building $mode interpreter" >&2
    odin build "$SRC_DIR" "-collection:lang=$SRC_DIR" -o:speed \
        "${DEFINES[@]+"${DEFINES[@]}"}" "-define:VM_THREADED=$value" "-out:$WORK/lua-$mode"
done
MODES=(switch threaded)
EXES=("$WORK/lua-switch" "$WORK/lua-threaded")
if [[ -n "${REFLUA:-}" ]]; then
    MODES+=(reference)
    EXES+=("$REFLUA")
fi

# Independently summarize each counter; even-sized medians average the middle pair.
summary() {
    sort -n "$1" | awk '{ a[NR]=$1 } END {
        if (NR == 0) exit 1
        med = NR % 2 ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1])/2
        printf "%.1f/%.1f", a[1]/1000000, med/1000000
    }'
}

measure() {
    local label="$1" file="$2" name="${3:-}" run offset index mode exe
    local perf_file="$WORK/perf.csv" ins cyc
    echo "==> $label ($RUNS runs per interpreter)" >&2
    for mode in "${MODES[@]}"; do
        : >"$WORK/$mode.instructions"
        : >"$WORK/$mode.cycles"
    done
    for ((run=0; run<RUNS; run++)); do
        # Rotate the first interpreter to spread load drift across modes.
        for ((offset=0; offset<${#MODES[@]}; offset++)); do
            index=$(((run + offset) % ${#MODES[@]}))
            mode="${MODES[index]}"; exe="${EXES[index]}"
            local args=("$file")
            [[ -z "$name" ]] || args+=("$name")
            if ! (cd "$BENCH_DIR" && perf stat -x, -e instructions:u,cycles:u \
                    -o "$perf_file" -- "${PIN[@]}" "$exe" "${args[@]}" >/dev/null); then
                cat "$perf_file" >&2
                echo "Measurement failed: $label ($mode)." >&2; exit 1
            fi
            ins="$(awk -F, '$3 == "instructions:u" {print $1}' "$perf_file")"
            cyc="$(awk -F, '$3 == "cycles:u" {print $1}' "$perf_file")"
            if [[ ! "$ins" =~ ^[0-9]+$ || ! "$cyc" =~ ^[0-9]+$ ]]; then
                cat "$perf_file" >&2
                echo "Missing or unsupported perf counts: $label ($mode)." >&2; exit 1
            fi
            printf '%s\n' "$ins" >>"$WORK/$mode.instructions"
            printf '%s\n' "$cyc" >>"$WORK/$mode.cycles"
        done
    done
    printf '| %s ' "$label"
    for mode in "${MODES[@]}"; do
        printf '| %s; %s ' "$(summary "$WORK/$mode.instructions")" "$(summary "$WORK/$mode.cycles")"
    done
    if [[ ${#MODES[@]} -eq 2 ]]; then printf '| — '; fi
    printf '|\n'
}

echo "Instructions and approximate cycles in millions: min/median instructions; min/median cycles."
echo "Runs: $RUNS per interpreter; hash seeds vary; cycles are load-sensitive."
echo '| Workload | Switch | Threaded | Reference |'
echo '|---|---:|---:|---:|'
for file in micro.lua tables.lua stdlib.lua scaling.lua; do
    # The harness itself is the inventory, so new workloads are not missed.
    names="$(cd "$BENCH_DIR" && "${EXES[0]}" "$file" --list)"
    while IFS= read -r name; do
        [[ -z "$name" ]] || measure "${file%.lua}/$name" "$file" "$name"
    done <<<"$names"
done
for probe in "$BENCH_DIR"/probes/*.lua; do
    name="$(basename "$probe" .lua)"
    measure "probe/$name" "probes/$name.lua"
done
