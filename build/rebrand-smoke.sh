#!/usr/bin/env bash
#
# rebrand-smoke.sh -- prove that a rebranded build is really rebranded.
#
# The default profile is validated by build/test.sh, build/puc.sh and
# build/clitest.sh: those are the "did we break Lua 5.5.0?" gates. This script is
# the other half -- it builds the runtime under a *different* brand and checks
# that every user-visible name actually followed the `-define:` flags.
#
# Usage:
#     ./build/rebrand-smoke.sh              # brand "moon" (.moon / MOON_*)
#     BRAND=zig ./build/rebrand-smoke.sh
#     NO_BUILD=1 ./build/rebrand-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_ROOT/src"

BRAND="${BRAND:-moon}"
if [[ "$BRAND" == "lua" ]]; then
    echo "rebrand-smoke needs a brand other than the default 'lua'." >&2
    exit 1
fi

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"

DISPLAY_NAME="$(printf '%s%s' \
    "$(printf '%s' "${BRAND:0:1}" | tr '[:lower:]' '[:upper:]')" "${BRAND:1}")"
EXT=".$BRAND"
ENV_PFX="$(printf '%s' "$BRAND" | tr '[:lower:]' '[:upper:]')"

COLLECTION="-collection:lang=$SRC_DIR"
OUT_DIR="${TMPDIR:-/tmp}/lang-rebrand-$BRAND"
WORK="${TMPDIR:-/tmp}/lang-rebrand-work-$BRAND"
mkdir -p "$OUT_DIR"
rm -rf "$WORK"; mkdir -p "$WORK/mods"

EXE="$OUT_DIR/$BRAND_EXE"
CEXE="$OUT_DIR/$BRAND_COMPILER_EXE"

if [[ "${NO_BUILD:-0}" != "1" ]]; then
    echo "==> Building the '$BRAND' profile"
    odin build "$SRC_DIR" "$COLLECTION" -o:speed \
        "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$EXE"
    odin build "$SRC_DIR/compiler" "$COLLECTION" -o:speed \
        "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$CEXE"
fi

PASSED=0
FAILED=0
assert_equal() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok   $label"; PASSED=$((PASSED + 1))
    else
        echo "  FAIL $label"
        echo "         expected: '$expected'"
        echo "         actual:   '$actual'"
        FAILED=$((FAILED + 1))
    fi
}
assert_true() {
    local label="$1" cond="$2"
    if [[ "$cond" == "1" ]]; then echo "  ok   $label"; PASSED=$((PASSED + 1))
    else echo "  FAIL $label"; FAILED=$((FAILED + 1)); fi
}

echo "==> '$BRAND' branding"

banner="$("$EXE" -v 2>&1 || true)"
[[ "$banner" == "$DISPLAY_NAME 5.5.0"* ]] && assert_true 'version banner shows the brand' 1 \
    || assert_true 'version banner shows the brand' 0

assert_equal '_VERSION follows the brand' "$DISPLAY_NAME 5.5" \
    "$("$EXE" -e 'io.write(_VERSION)')"
assert_equal 'getinfo().what follows the brand' "$DISPLAY_NAME" \
    "$("$EXE" -e 'io.write(debug.getinfo(function() end).what)')"

path="$("$EXE" -e 'io.write(package.path)')"
[[ "$path" == *"?$EXT"* ]] && assert_true 'package.path uses the new extension' 1 \
    || assert_true 'package.path uses the new extension' 0
[[ "$path" == *"/$BRAND/"* ]] && assert_true 'package.path uses the brand directory' 1 \
    || assert_true 'package.path uses the brand directory' 0

printf 'return function() return "hi" end' > "$WORK/mods/greet$EXT"
assert_equal "require loads a $EXT module" 'hi' \
    "$(cd "$WORK" && "$EXE" -e "package.path = 'mods/?$EXT'; io.write(require('greet')())")"

assert_equal "${ENV_PFX}_INIT is honoured" 'init!' \
    "$(env "${ENV_PFX}_INIT=io.write(\"init!\")" "$EXE" -e '')"

echo "==> '$BRAND' precompiled chunks"
printf 'io.write("compiled ok")' > "$WORK/hello$EXT"
"$CEXE" -o "$WORK/hello.dump" "$WORK/hello$EXT" >/dev/null
[[ -f "$WORK/hello.dump" ]] && assert_true 'the compiler produced a dump' 1 \
    || assert_true 'the compiler produced a dump' 0

sig="$(head -c $((1 + ${#DISPLAY_NAME})) "$WORK/hello.dump" | tail -c ${#DISPLAY_NAME})"
assert_equal 'dump signature is ESC + brand' "$DISPLAY_NAME" "$sig"
assert_equal 'the dump runs' 'compiled ok' "$("$EXE" "$WORK/hello.dump")"

DEFAULT_EXE="$REPO_ROOT/build/out/lua"
if [[ -x "$DEFAULT_EXE" ]]; then
    if "$DEFAULT_EXE" "$WORK/hello.dump" >/dev/null 2>&1; then
        assert_true 'the default profile rejects a rebranded dump' 0
    else
        assert_true 'the default profile rejects a rebranded dump' 1
    fi
else
    echo "  skip cross-brand rejection (build/out/lua not built)"
fi

echo ""
echo "Rebrand smoke tests: $PASSED passed, $FAILED failed."
[[ "$FAILED" -eq 0 ]]
