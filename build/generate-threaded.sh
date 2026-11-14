#!/usr/bin/env bash
# Regenerate the threaded VM, or verify it with --check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$REPO_ROOT/build/out"
mkdir -p "$OUT_DIR"
odin build "$REPO_ROOT/tools/generate_threaded" "-out:$OUT_DIR/generate-threaded"
"$OUT_DIR/generate-threaded" "$REPO_ROOT" "$@"
