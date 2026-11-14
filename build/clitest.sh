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

# Linux has a real SIGINT handler. Check both a bare back-edge and repeated Lua
# calls, and let pcall catch the interrupt; continuing afterward proves that the
# request and its hook were consumed rather than delivered a second time.
if [[ "$(uname -s)" == Linux ]]; then
    # Check actual resident memory, independently of Lua's GC accounting. The
    # long environment value exercises the allocating fallback; TZ=UTC loads a
    # TZif file, and the invalid format exercises the Lua error path.
    cat > "$WORK/host-memory.lua" <<'EOF'
local pagesize = assert(tonumber(arg[1]))
local function rss()
  local f = assert(io.open('/proc/self/statm'))
  local s = assert(f:read('*l')); f:close()
  return assert(tonumber(s:match('^%S+%s+(%S+)'))) * pagesize
end
for i = 1, 50 do
  os.getenv('LEAK_TEST_LONG'); os.date('%c %Z', 1700000000)
end
collectgarbage('collect')
local before = rss()
for i = 1, 10000 do
  assert(#os.getenv('LEAK_TEST_LONG') == 4096)
  os.date('%c %D %T %F %R %Z', 1700000000)
  assert(not pcall(os.date, '%Q', 1700000000))
end
for i = 1, 600000 do os.getenv('LEAK_TEST_SMALL') end
collectgarbage('collect')
assert(rss() - before < 4 * 1024 * 1024, 'host memory grew without bound')
EOF
    printf -v long_value '%*s' 4096 ''
    long_value="${long_value// /x}"
    env TZ=UTC LEAK_TEST_SMALL=small-value LEAK_TEST_LONG="$long_value" "$LUA" "$WORK/host-memory.lua" "$(getconf PAGESIZE)" >/dev/null 2>"$WORK/host-memory.err" && \
        assert_true 'OS calls keep host memory bounded' 1 || assert_true 'OS calls keep host memory bounded' 0

    # POSIX TZ names can exceed the stack abbreviation buffer. They must be
    # copied intact into Lua before the timezone file/env arena is released.
    printf -v long_zone '%*s' 200 ''
    long_zone="${long_zone// /A}"
    env TZ="${long_zone}0" "$LUA" -e '
        os.date("%Y", 1700000000)
        collectgarbage("collect"); collectgarbage("stop")
        local before = collectgarbage("count")
        for i=1,1000 do os.date("%Y", 1700000000) end
        assert(collectgarbage("count") - before < 8)
        collectgarbage("restart")
        for i=1,100 do assert(os.date("%Z", 1700000000) == string.rep("A", 200)) end
    ' >/dev/null 2>&1 && \
        assert_true 'long POSIX timezone name survives cleanup' 1 || assert_true 'long POSIX timezone name survives cleanup' 0

    # Pin TZ in the child rather than changing the test runner's environment.
    env TZ='EST5EDT,M3.2.0,M11.1.0' "$LUA" -e '
        assert(os.date("%F %T %z %Z", 1710053999) == "2024-03-10 01:59:59 -0500 EST")
        assert(os.date("%F %T %z %Z", 1710054000) == "2024-03-10 03:00:00 -0400 EDT")
        assert(os.date("!%Z", 0) == "GMT")
    ' >/dev/null 2>&1 && \
        assert_true 'os.date follows explicit TZ transitions' 1 || assert_true 'os.date follows explicit TZ transitions' 0
    env TZ=':/definitely/no/such/zone' "$LUA" -e '
        assert(os.date("%Z|%z", 0) == "|+0000")
    ' >/dev/null 2>&1 && \
        assert_true 'os.date invalid TZ abbreviation' 1 || assert_true 'os.date invalid TZ abbreviation' 0
    env TZ='ABC25:99:99' "$LUA" -e '
        assert(os.date("%F %T %z %Z", 0) == "1969-12-30 23:00:01 -2459 ABC")
        assert(not pcall(os.date, "%Y", 67768036191676800))
    ' >/dev/null 2>&1 && \
        assert_true 'os.date glibc oversized TZ offset' 1 || assert_true 'os.date glibc oversized TZ offset' 0
    for zone_length in 249 250; do
        printf -v long_zone '%*s' "$zone_length" ''
        long_zone="${long_zone// /A}"
        env TZ="${long_zone}0" DATE_ZONE_LENGTH="$zone_length" "$LUA" -e '
            local expected = os.getenv("DATE_ZONE_LENGTH") == "249" and string.rep("A", 249) or ""
            assert(os.date("[%Z]", 0) == "[" .. expected .. "]")
        ' >/dev/null 2>&1 && \
            assert_true "os.date $zone_length-byte zone conversion" 1 || assert_true "os.date $zone_length-byte zone conversion" 0
    done

    for kind in loop calls; do
        if [[ "$kind" == loop ]]; then body='while true do end'
        else body='local function f() end; while true do f() end'; fi
        cat > "$WORK/interrupt.lua" <<EOF
local ok, msg = pcall(function()
  print('ready'); io.stdout:flush()
  $body
end)
assert(not ok and string.find(msg, 'interrupted!', 1, true))
for i = 1, 1000 do local x = i end
print('consumed once')
EOF
        "$LUA" "$WORK/interrupt.lua" >"$WORK/interrupt.out" 2>"$WORK/interrupt.err" &
        pid=$!
        ready=0
        for ((i=0; i<200; i++)); do
            if grep -qx ready "$WORK/interrupt.out"; then ready=1; break; fi
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            sleep 0.05
        done
        if [[ "$ready" -eq 1 ]]; then kill -INT "$pid" 2>/dev/null || true; fi
        for ((i=0; i<200; i++)); do
            if ! kill -0 "$pid" 2>/dev/null; then break; fi
            sleep 0.05
        done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
        wait "$pid"; code=$?
        out="$(cat "$WORK/interrupt.out")"
        [[ "$ready" -eq 1 && "$code" -eq 0 && "$out" == $'ready\nconsumed once' ]] && \
            assert_true "SIGINT $kind is caught once" 1 || assert_true "SIGINT $kind is caught once" 0
    done
fi

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
