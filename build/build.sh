#!/usr/bin/env bash
#
# build.sh -- cross-platform build wrapper for lua-odin (macOS/Linux side).
#
# Odin builds a whole directory as one package. We wire in the `luao` collection
# (mapping the name "luao" to the src/ tree) so packages import each other as
# `luao:lua`, `luao:stdlib`, etc. regardless of where the repo lives on disk.
#
# Usage:
#     ./build/build.sh              # build the standalone `lua` CLI (default)
#     ./build/build.sh luac         # build the `luac` compiler
#     ./build/build.sh all          # build both
#     DEBUG=1 ./build/build.sh lua   # debug build
#
# Output lands in build/out/.

set -euo pipefail

# Resolve the repo root from this script's location so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$REPO_ROOT/build/out"
SRC_DIR="$REPO_ROOT/src"

mkdir -p "$OUT_DIR"

TARGET="${1:-lua}"

# The collection makes cross-package imports stable and path-independent.
COLLECTION="-collection:luao=$SRC_DIR"
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
    odin build "$package_dir" "$COLLECTION" "$OPTIMIZE" "-out:$out_path"
}

case "$TARGET" in
    lua)  build_one lua  "$SRC_DIR" ;;
    luac) build_one luac "$SRC_DIR/luac" ;;
    all)
        build_one lua  "$SRC_DIR"
        build_one luac "$SRC_DIR/luac"
        ;;
    *)
        echo "Unknown target '$TARGET' (expected: lua | luac | all)" >&2
        exit 1
        ;;
esac

echo "Done."
