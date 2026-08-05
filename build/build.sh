#!/usr/bin/env bash
#
# build.sh -- cross-platform build wrapper for lua-odin (macOS/Linux side).
#
# Odin builds a whole directory as one package. We wire in the `lang` collection
# (mapping the name "lang" to the src/ tree) so packages import each other as
# `lang:kernel`, `lang:stdlib`, etc. regardless of where the repo lives on disk.
#
# Usage:
#     ./build/build.sh              # build the standalone interpreter (default)
#     ./build/build.sh compiler     # build the bytecode compiler
#     ./build/build.sh all          # build both
#     ./build/build.sh freestanding # build the bare-metal object
#     DEBUG=1 ./build/build.sh lua  # debug build
#
# The language this runtime presents is a build-time choice (see
# src/kernel/brand.odin). BRAND selects it and names the binaries:
#
#     ./build/build.sh all              # lua  / luac   (default)
#     BRAND=moon ./build/build.sh all   # moon / moonc
#
# Output lands in build/out/.

set -euo pipefail

# Resolve the repo root from this script's location so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$REPO_ROOT/build/out"
SRC_DIR="$REPO_ROOT/src"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"

mkdir -p "$OUT_DIR"

TARGET="${1:-lua}"

# The collection makes cross-package imports stable and path-independent.
COLLECTION="-collection:lang=$SRC_DIR"

# On Linux/macOS the default main-thread stack (~8 MiB) comfortably holds the
# MAXCCALLS (200) nested native `vm_execute` frames the language permits, so its
# own C-stack guard turns runaway recursion into a catchable error. Windows only
# reserves 1 MiB by default, so build.ps1 additionally passes /STACK to the linker;
# no such flag is needed here.
if [[ "${DEBUG:-0}" == "1" ]]; then
    OPTIMIZE="-debug"
else
    OPTIMIZE="-o:speed"
fi

build_one() {
    local name="$1"
    local package_dir="$2"
    local out_path="$OUT_DIR/$name"
    echo "==> Building $name -> $out_path"
    odin build "$package_dir" "$COLLECTION" "$OPTIMIZE" \
        "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$out_path"
}

build_freestanding() {
	# There is no executable or process entry point on bare metal. Emit one
	# relocatable object containing the kernel and pure libraries. Odin's native
	# freestanding build tag removes io/os/package/stream and the hosted mains.
	#
	# The interpreter state still allocates through the kernel.Allocator callback
	# supplied by its embedder. The nil Odin default makes any accidental implicit
	# allocation fail honestly instead of assuming a nonexistent platform heap.
	local target="${FREESTANDING_TARGET:-freestanding_amd64_sysv}"
	local out_path="$OUT_DIR/$BRAND-freestanding.o"
	local abi_flags=()
	if [[ "$target" == "freestanding_amd64_win64" ||
	      "$target" == "freestanding_amd64_mingw" ]]; then
		# Freestanding is the OS for both triples; this tells the assembly jump
		# shim to preserve the larger Win64 nonvolatile-register set.
		abi_flags+=("-define:FREESTANDING_WIN64_ABI=true")
	fi
	echo "==> Building freestanding object ($target) -> $out_path"
	odin build "$SRC_DIR/freestanding" "$COLLECTION" "$OPTIMIZE" \
		"-target:$target" -no-crt -default-to-nil-allocator \
		-no-entry-point -build-mode:obj -use-single-module \
		"${abi_flags[@]}" "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$out_path"
}

case "$TARGET" in
    lua)  build_one "$BRAND_EXE" "$SRC_DIR" ;;
    luac|compiler) build_one "$BRAND_COMPILER_EXE" "$SRC_DIR/compiler" ;;
    all)
        build_one "$BRAND_EXE" "$SRC_DIR"
        build_one "$BRAND_COMPILER_EXE" "$SRC_DIR/compiler"
        ;;
	freestanding) build_freestanding ;;
    *)
        echo "Unknown target '$TARGET' (expected: lua | compiler | all | freestanding)" >&2
        exit 1
        ;;
esac

echo "Done."
