#!/usr/bin/env bash
#
# clitest.sh -- end-to-end tests for the standalone `lua` and `luac` CLIs (macOS/Linux side).
#
# These are honest black-box tests: they build the two executables, then drive
# them exactly as a user would (arguments, stdin, script files, bytecode dumps)
# and assert on observable output, exit codes, and -- where a reference `luac` is
# available -- byte-for-byte dump compatibility. Nothing here peeks at internals.
#
# Usage:
#     ./build/clitest.sh              # build lua + luac, run all CLI tests
#     ./build/clitest.sh --no-build   # reuse the last-built exes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=build/brand.sh
source "$SCRIPT_DIR/brand.sh"
SRC_DIR="$REPO_ROOT/src"
COLLECTION="-collection:lang=$SRC_DIR"

OUT_DIR="$REPO_ROOT/build/out"
mkdir -p "$OUT_DIR"
LUA="$OUT_DIR/$BRAND_EXE"
LUAC="$OUT_DIR/$BRAND_COMPILER_EXE"

if [[ "${1:-}" != "--no-build" ]]; then
    echo "==> Building lua + luac"
    odin build "$SRC_DIR" "$COLLECTION" -o:speed "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$LUA"
    odin build "$SRC_DIR/compiler" "$COLLECTION" -o:speed "${BRAND_DEFINES[@]+"${BRAND_DEFINES[@]}"}" "-out:$LUAC"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    # Trim trailing newlines for a stable comparison.
    expected="${expected%$'\n'}"
    actual="${actual%$'\n'}"
    if [[ "$expected" == "$actual" ]]; then
        PASSED=$((PASSED + 1)); echo "  ok   $label"
    else
        FAILED=$((FAILED + 1)); echo "  FAIL $label"
        echo "       expected: [$expected]"
        echo "       actual:   [$actual]"
    fi
}

assert_true() {
    local label="$1" cond="$2"
    if [[ "$cond" == "1" ]]; then PASSED=$((PASSED + 1)); echo "  ok   $label"
    else FAILED=$((FAILED + 1)); echo "  FAIL $label"; fi
}

echo "==> lua CLI"

out="$("$LUA" -e 'print(6*7)' 2>/dev/null)"
assert_eq 'lua -e prints 42' '42' "$out"

# A binary signature is enough to distinguish a text-mode rejection from the
# old binary loader's "truncated chunk" error (argv cannot contain NUL bytes).
err="$("$LUA" -e $'\033Lua' 2>&1)"; code=$?
[[ $code -ne 0 && "$err" == *"attempt to load a binary chunk (mode is 't')"* ]] && assert_true 'lua -e rejects binary' 1 || assert_true 'lua -e rejects binary' 0

printf '\033Lua\n' | "$LUA" -i >"$WORK/repl.out" 2>"$WORK/repl.err"
grep -Fq "attempt to load a binary chunk (mode is 't')" "$WORK/repl.err" && assert_true 'REPL rejects binary' 1 || assert_true 'REPL rejects binary' 0
printf '21*2\n' | "$LUA" -i >"$WORK/repl.out" 2>"$WORK/repl.err"
grep -Fq '42' "$WORK/repl.out" && assert_true 'REPL accepts text' 1 || assert_true 'REPL accepts text' 0

printf '\033Lua\ncont\n' | "$LUA" -e 'debug.debug()' >"$WORK/debug.out" 2>"$WORK/debug.err"
grep -Fq "attempt to load a binary chunk (mode is 't')" "$WORK/debug.err" && assert_true 'debug.debug rejects binary' 1 || assert_true 'debug.debug rejects binary' 0
printf 'print("debug ok")\ncont\n' | "$LUA" -e 'debug.debug()' >"$WORK/debug.out" 2>"$WORK/debug.err"
grep -Fq 'debug ok' "$WORK/debug.out" && assert_true 'debug.debug accepts text' 1 || assert_true 'debug.debug accepts text' 0

out="$("$LUA" -v 2>/dev/null)"
[[ "$out" == *"Lua 5.5"* ]] && assert_true 'lua -v shows Lua 5.5 banner' 1 || assert_true 'lua -v shows Lua 5.5 banner' 0

HELLO="$WORK/hello.lua"
printf 'print("hello", 1+1); print(arg[1])' > "$HELLO"
out="$("$LUA" "$HELLO" world 2>/dev/null)"
assert_eq 'lua script + arg' $'hello\t2\nworld' "$out"

out="$(printf 'print(40+2)' | "$LUA" - 2>/dev/null)"
assert_eq 'lua - reads stdin' '42' "$out"

out="$("$LUA" -e 'io.write("a")' -e 'io.write("b")' 2>/dev/null)"
assert_eq 'lua chained -e' 'ab' "$out"

"$LUA" -e "error('boom')" >/dev/null 2>&1; [[ $? -ne 0 ]] && assert_true 'lua error -> nonzero exit' 1 || assert_true 'lua error -> nonzero exit' 0

"$LUA" -Z >/dev/null 2>&1; [[ $? -ne 0 ]] && assert_true 'lua bad option -> nonzero exit' 1 || assert_true 'lua bad option -> nonzero exit' 0

echo "==> luac CLI"

srcout="$("$LUA" "$HELLO" X 2>/dev/null)"
DUMP="$WORK/hello.luac"
"$LUAC" -o "$DUMP" "$HELLO" >/dev/null 2>&1
[[ -f "$DUMP" ]] && assert_true 'luac -o creates a dump' 1 || assert_true 'luac -o creates a dump' 0
dumpout="$("$LUA" "$DUMP" X 2>/dev/null)"
assert_eq 'dumped chunk runs like source' "$srcout" "$dumpout"

printf 'print("binary ok")' > "$WORK/binary.lua"
"$LUAC" -o "$WORK/binary.luac" "$WORK/binary.lua" >/dev/null 2>&1
out="$("$LUA" -e "dofile([[$WORK/binary.luac]])" 2>/dev/null)"
assert_eq 'dofile accepts binary' 'binary ok' "$out"
out="$("$LUA" -e "package.path=[[$WORK/?.luac]]; require('binary')" 2>/dev/null)"
assert_eq 'require accepts binary' 'binary ok' "$out"

"$LUAC" -p "$HELLO" >/dev/null 2>&1; [[ $? -eq 0 ]] && assert_true 'luac -p exits 0' 1 || assert_true 'luac -p exits 0' 0

lout="$("$LUAC" -l "$HELLO" 2>/dev/null)"
[[ "$lout" == *"main <"* ]] && assert_true 'luac -l disassembles' 1 || assert_true 'luac -l disassembles' 0

FULL="$WORK/full.luac"; STRIP="$WORK/strip.luac"
"$LUAC" -o "$FULL" "$HELLO" >/dev/null 2>&1
"$LUAC" -s -o "$STRIP" "$HELLO" >/dev/null 2>&1
fsize=$(wc -c < "$FULL"); ssize=$(wc -c < "$STRIP")
[[ "$ssize" -lt "$fsize" ]] && assert_true 'stripped dump is smaller' 1 || assert_true 'stripped dump is smaller' 0
stripout="$("$LUA" "$STRIP" X 2>/dev/null)"
assert_eq 'stripped chunk still runs' "$srcout" "$stripout"

REFLUAC="${REFLUAC:-}"
if [[ -n "$REFLUAC" && -x "$REFLUAC" ]]; then
    OURS="$WORK/ours.luac"; REF="$WORK/ref.luac"
    "$LUAC" -o "$OURS" "$HELLO" >/dev/null 2>&1
    "$REFLUAC" -o "$REF" "$HELLO" >/dev/null 2>&1
    if cmp -s "$OURS" "$REF"; then assert_true 'luac dump byte-identical to reference' 1
    else assert_true 'luac dump byte-identical to reference' 0; fi
else
    echo "  skip reference byte-compat (set REFLUAC to a reference luac to enable)"
fi

echo ""
echo "CLI tests: $PASSED passed, $FAILED failed."
[[ "$FAILED" -eq 0 ]]
