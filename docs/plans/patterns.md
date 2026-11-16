## Patterns: summary

- `micro/strpattern`: 5,077.25M threaded / 5,112.45M switch versus 3,803.42M reference instructions; the workload is repeated `gmatch("%a+")`.
- High confidence: matcher dispatch/index checks and zeroed captures dominate that gap; byte-at-a-time plain search and replacement copying create much larger gaps on other inputs. Class classification itself is not the main headline problem.
- A combined scratch prototype reaches 4,300.03M threaded / 4,335.23M switch, about 13–14% above reference. Treat ~4,300M as a realistic first target, not a parity guarantee; gains from separate packages overlap.
- **Correctness first:** the baseline mishandles position-capture back-references; `("abc"):match("()%1")` returns `1` instead of nil, and `"()%1a"` can abort on a negative subject index. Fix this before relaxing any bounds check.

## Measurements

Linux x86-64, Odin dev-2026-11-nightly, `-o:speed`, C locale, isolated processes; `perf stat -e instructions:u`, median of 3 rotated runs. Millions of instructions, including startup, shared probe setup, Lua loop and printing. Default/threaded and switch binaries are explicit builds; reference is `/tmp/opencode/refbuild/src/lua`. `master` was `fa170e7`, whose only difference from `0738e32` is `AGENTS.md`. Probe: `docs/plans/patterns-probes.lua`; pass the case and N shown. Cycles on this shared machine are not decision metrics.

| Case | N | Threaded | Switch | Reference |
|---|---:|---:|---:|---:|
| loop | 100000 | 7.84 | 8.34 | 7.05 |
| find_plain_short | 100000 | 76.84 | 76.74 | 62.75 |
| find_auto_short | 100000 | 75.54 | 74.84 | 61.85 |
| find_plain_long_miss | 2000 | 100.79 | 100.86 | 3.32 |
| find_plain_long_candidates | 2000 | 330.13 | 330.20 | 436.77 |
| find_auto_long_miss | 2000 | 100.76 | 100.82 | 3.30 |
| find_plain_empty | 100000 | 59.94 | 59.84 | 57.55 |
| find_plain_binary | 2000 | 37.73 | 37.73 | 57.12 |
| find_pattern | 100000 | 276.14 | 281.34 | 227.25 |
| match_nocap | 100000 | 199.84 | 205.84 | 168.15 |
| match_capture | 100000 | 261.24 | 267.33 | 208.55 |
| match_backref | 100000 | 206.84 | 212.74 | 161.65 |
| match_empty | 100000 | 70.64 | 77.13 | 61.05 |
| gmatch_short | 30000 | 187.56 | 185.01 | 136.52 |
| gmatch_long | 2 | 52.39 | 52.75 | 39.47 |
| gsub_string | 30000 | 185.71 | 186.41 | 134.20 |
| gsub_table | 30000 | 193.69 | 194.27 | 141.34 |
| gsub_function | 30000 | 213.95 | 215.60 | 156.10 |
| gsub_copy_miss | 1000 | 246.25 | 246.27 | 153.68 |
| gsub_long_replacement | 10000 | 153.76 | 154.01 | 15.50 |
| gsub_empty | 30000 | 60.20 | 60.86 | 48.91 |
| classes | 30000 | 131.59 | 138.41 | 109.24 |
| sets | 100000 | 168.44 | 174.34 | 140.45 |
| quantifiers | 100000 | 175.64 | 181.54 | 126.35 |
| backtrack | 10000 | 19.24 | 19.83 | 14.65 |
| balance_frontier | 30000 | 165.28 | 168.89 | 125.62 |
| class_long | 2000 | 513.47 | 513.60 | 489.40 |
| class_long_fail | 250 | 196.38 | 196.39 | 139.84 |

The longer setup in the final probe script adds negligible startup work to these numbers. Most cases were stable to 0.01M; capture/interning cases varied up to several million with seeds. Do not compare cases as equal work or blindly subtract `loop`.

**Callgrind attribution.** Self instructions in millions; optimized port and the symbolized optimized `/tmp/opencode/refdbg/src/lua`. Counts include setup, not comparable directly to hardware perf. C and Odin inline differently, so compare groups, not individual function names. `match'2`/`match_default'2` are compiler clones; expansions and capture helpers are often inlined.

| Profile and non-overlapping self costs | Port | Reference counterpart |
|---|---:|---:|
| `gmatch_long`, N=1: `match` + clone | 3.862 | `match` + clone 4.418 |
| same: `match_default` | 3.374 | inlined into C `match` |
| same: `singlematch` | 3.248 | `singlematch` 1.160 |
| same: `match_class` | 2.900 | `match_class` + ctype call sites/helpers 4.640 |
| same: `classend` | 0.900 | `classend` 0.650 |
| same: `gmatch_aux` | 2.042 | `gmatch_aux` 1.238 + `lua_touserdata` 0.625 |
| same: `push_captures` + `get_onecapture` | 1.232 | `push_onecapture` 0.256 + `luaL_checkstack` 0.192 |
| same: `api_checkstack` / `api_pushlstring` | 0.448 / 0.624 | `lua_checkstack` 0.224 / `lua_pushlstring` 0.384 |
| same: `string_newlstr` | 1.671 | `internshrstr` 1.680, plus `luaS_newlstr` 0.051 and comparison helpers |
| `match_capture`, N=5000: `match` + default + single + class + classend | 7.650 | C match + single + class/ctype + classend 5.855 |
| `quantifiers`, N=5000: match + default + single + classend | 4.975 | C match + single + classend 2.865 |
| `gsub_string`, N=2000: `str_gsub` / `prepbuffsize` | 1.826 / 0.676 | `str_gsub` 1.054 / `prepbuffsize` 0.072, plus `luaL_addlstring` 0.194 |
| `gsub_long_replacement`, N=1000: `str_gsub` / `prepbuffsize` | 5.253 / 8.580 | `str_gsub` 0.142 / `luaL_addlstring` 0.025 |

In `gmatch_long` the port also spends 0.697M in the libc memset implementation, substantially from capture initialization. `str_find_aux` self for 5,000 plain short finds is 1.585M versus 0.460M, but Odin inlines argument access/search/pushes while reference attributes them to separate `luaL_checklstring`, `lua_tolstring`, `lua_tointegerx`, `lua_pushinteger` and libc; the self numbers are **not** per-call overhead alone. `str_find`/`str_match` each build a Context, 145k self per 5,000 calls including wrapper work; the historical Context cost is ~19 instructions/call. Result-string creation is measurable but not a license to bypass allocation, GC or stack checks.

## Causes

- `strlib.odin:lmemfind` checks each subject byte and compares a candidate byte-by-byte. `lstrlib.c:lmemfind` uses `memchr` on the first byte then `memcmp` on candidates. Misses with rare first bytes are pathological; dense candidates/binary input already beat reference and need protection.
- `match`/`match_default`/`singlematch` use indices, slices and an `(int, bool)` result where C uses pointers and NULL. Optimized disassembly of `singlematch` shows a signed end comparison, a second unsigned slice bounds branch, separate pattern-index checks, and `pb` lookahead. The caller passes an output slot for the pair. These checks/extra control flow, call boundaries and repeated class parsing explain the measured matcher excess; do not infer each individual cost from self symbols alone.
- `Match_State` contains 32 captures (512 bytes). Odin zeroes the array on each `str_find_aux` pattern call, `gmatch_aux` iterator call and `str_gsub` call; reference initializes live fields only. `gmatch_aux` disassembly calls `memset(..., 512)` and constructs the default Context before scanning. `matchdepth` is decremented on every real recursive `match` entry and restored on non-throw returns; tail transitions must not consume depth. Reference resets its budget at each candidate; the port relies on restoration across candidates.
- `match_class` computes C-locale predicates directly; reference calls libc ctype functions. The `gmatch_long` class group is actually cheaper here, not slower. Sets invoke `classend` then `matchbracketclass`; classes, complement/unknown escapes, NUL and locale behavior remain observable. A lookup/predecoded class is only an experiment, not an established win.
- `add_s` appends every literal replacement byte via `aux_addchar`; `prepbuffsize` runs even when capacity exists. C scans to the next `%` and appends spans. The no-match `gsub` path similarly appends subject bytes one at a time; it must still return the original when no replacement changed it.

## Levers

1. **Fix the capture bug, then specialize the matcher** (`strlib.odin`). In the prior combined patch, headline threaded 5,077.25 → 4,300.03M; switch 5,112.45 → 4,335.23M. From the combined build, individually *removing* no-bounds checks costs 388M, removing `match_default` inlining 304M, and restoring zero initialization 96M; these leave-one-out numbers overlap and are not additive. `class_long` 513.47 → 390.41M; `match_nocap` 199.84 → 166.34M; `gmatch_long` 52.39 → 44.63M. Compiler layout changes also moved the plain-candidate probe. Full prototype is not a landable change without isolated commits and the gates below.
   - `check_capture` accepts a position capture (`len=-2`); C casts that to unsigned and its size check fails. Return no match for negative length after its existing unfinished-capture/index error check. Test direct and nested `%1`, empty input, later pattern bytes and all four APIs.
   - Selectively elide checks in `singlematch`: after the negative-length fix, every caller supplies `0 <= s <= len(src)` and checks `s < len(src)` before reading; candidate starts, successful consumption and back-reference ranges preserve this. `match` calls `match_default` only at a real pattern class, `classend` checks it, and expansions reuse that same `p`, so `0 <= p < len(pat)`. For `%` the successful `classend` has already rejected a trailing escape, proving `p+1 < len(pat)`. Keep virtual-NUL `pb`/`sb` checks wherever the index can equal the end; never disable bounds globally.
   - A separate candidate: `classend`'s `pat[p]` after the `p == len(pat)` error is valid because scanning starts in range and advances by at most to the end; bracket-class `pat[p]` is valid only after `p < ec`, with `ec` the validated closing bracket. Prove each access and measure before changing it. For scalar `lmemfind`, after `l2 > 0 && l2 <= len(s)`, `0 <= i <= len(s)-l2` and `0 <= k < l2` prove `i+k < len(s)` and `k < len(p)`.
   - `ms: Match_State = ---` is plausible only if `L/src/pat/matchdepth` are assigned before any call, `level=0` before each candidate, and each capture's `init` and `len` are written before `level` exposes it. Backtracking only reads levels previously opened, and every new opening overwrites reused slots. Audit error/re-entry, position and unfinished captures, both VMs and optimized sanitizer runs. Never read uninitialized capture slots for diagnostics or serialization.
   - Inline `match_default` only if code size/other probes remain acceptable. A single `NO_MATCH`-sentinel result instead of the Odin pair is an unmeasured follow-up: preserve every recursion-depth decrement/restore, error timing and invalid-index behavior. Do not cache a stack/frame pointer across allocation or a callback.
2. **Plain search** (`lmemfind`): a scratch hybrid using standard-library `core:bytes.index_byte` cut 100.79 → 6.13M on long misses, but on top of the original prototype regressed dense candidates 305.56 → 338.33M and binary 36.70 → 39.81M; reject that version. A more aggressive version made those 387.38M and 94.24M. Design a genuinely candidate-aware, bounded vector/word scan with cheap scalar paths and bounded verification; standard `bytes.index_byte` is portable and freestanding-compatible in principle, but measure and cross-check generated code. Embedded NUL, empty/long needles, init clipping and first-match semantics must match reference. No speculative overread at slice ends.
3. **Replacement/buffer fast paths** (`strlib.odin`, `auxlib.odin`): the prior prototype's in-capacity `aux_addchar` avoids `prepbuffsize`; leave-one-out `gsub_long_replacement` 63.52 → 152.64M, and `gsub_copy_miss` 167.33 → 197.03M. `B.n < B.size` proves the single byte store is in the current buffer; preserve the exact slow spill/to-be-closed/OOM path. A separate length-gated `%`-scan + span-copy scratch experiment on top of the prototype reduced long replacement 63.52 → 19.83M, while `gsub_string` 153.95 → 154.64M and `gsub_empty` 53.21 → 53.69M. It is exploratory, not independently validated for landing. Preserve `%%`, `%0`, `%1..%9`, trailing/invalid `%` errors, numeric/position captures, and buffer rooting through spill and callback re-entry.
4. **Boundary and class experiments, lower priority.** A contextless *plain find* path can use `api_native_*` only for exclusively contextless argument reads, bounded search and primitive pushes, routing coercion/errors to existing contextful slow helpers. Pattern matching, result strings, buffer growth and table/function replacements can allocate, throw or re-enter: they cannot simply omit Context. At ~19 instructions × 3.2M headline iterator calls, even an impossible-to-eliminate-all Contexts upper estimate is ~61M, before fast-path costs; successful `gmatch` needs string creation. Coordinate native boundary work with **calls** and result-string/GC work with **strings-gc**. Class lookup/predecoding needs its own distribution and 256-byte/class differential; don't assume it wins or change C-locale semantics.

## Work packages

1. **`patterns/capture-correctness`** — `src/stdlib/strlib.odin`, `tests/strlib_test.odin`: fix negative position-capture back-references independently. Compare exact results and error messages for invalid, unfinished and position captures, nested/backtracking and subsequent bytes across find/match/gmatch/gsub. Run both interpreters and stress+ASan; correctness has priority over speed.
2. **`patterns/matcher-hotpath`** — same files plus `docs/ARCHITECTURE.md` in its own docs commit. Separate proof-backed `singlematch` checks, `match_default` inlining and capture initialization into reviewable changes. Add bounds/end/NUL, malformed `%`, `[`, `%b`/`%f`, 32/33 captures, 199/200+ recursive depth, greedy/lazy backtracking and re-entrant/error-recovery tests. Acceptance: target ≤4,300M threaded headline and ≤4,336M switch for the combined equivalent, no reproducible >1% regressions in the case matrix, exact errors, and no uninitialized reads; revise the target if independent commits/code layout differ.
3. **`patterns/plain-search`** — `strlib.odin`, `tests/strlib_test.odin`; bounded sparse scan with candidate-dense scalar fallback. Acceptance: long-miss ≤10M for this probe in each VM; no >1% reproducible instruction regression on short, dense, binary and empty cases against the then-current build. Differential-test starts/ends, negative/huge init, every byte including NUL, random needles, long repeated prefixes and needle > subject; validate freestanding/Windows/arm64 builds.
4. **`patterns/replacement-spans`** — `strlib.odin`, `auxlib.odin`, `tests/strlib_test.odin`, `tests/auxlib_test.odin`; separate capacity-inline and span-copy changes. Acceptance: long replacement ≤25M, no >1% reproducible short/string/table/function regression against the then-current build. Test `%` at each boundary, repeated/invalid escapes, embedded NUL, stack relocation, empty matches, max substitutions, nil/false, table metamethods, callbacks that re-enter and collect, buffer spill/OOM and unchanged-result identity.
5. **`patterns/boundary-eval`** — only after coordination with calls/strings-gc; measure an exact-string plain-find contextless split, with conversion and error paths unchanged. Require both VMs, no call/other-library regressions and disassembly showing no Context on the actual fast path. Class predecode and sentinel-return experiments are separately gated, not promised packages.

For every package follow repository worktree/commit rules. Run `build/check.sh` and `build/test.sh` in both modes per commit. Before landing stdlib-only changes run the complete `AGENTS.md` stdlib gates (including all default PUC/test stress and ASan combinations, clitest, rebrand and builds; switch check, plain and stress+ASan test and PUC). For any kernel/generator change run the full kernel gates in both modes. Keep vendored PUC unchanged, and update future-work measurements separately.

## Open questions

- The prior prototype plus the scratch search/replacement variants matched reference for all 65,536 subject-byte/class-byte combinations, 3,000 deterministic generated patterns, and targeted error/NUL/capture/recursion cases in both VMs. The combined experimental tree also passed all 366 unit tests and standalone PUC `pm.lua`, plain and stress+ASan, both VMs; differential edges/fuzz passed under stress+ASan. `build/check.sh` and the freestanding object build passed. These are **not** the full merge gates or a proof of initialized-memory safety.
- Memcheck could not start: this system's stripped dynamic loader lacks the mandatory `memcmp` redirection symbol / glibc debuginfo. Use a working Memcheck or another uninitialized-memory tool before approving `= ---`; ASan detects bounds/use-after-free, not uninitialized reads.
- Can sparse search hit the long-miss target without losing dense-candidate performance and without an overread on Windows, arm64 or freestanding? Can one reduce pair-return or dispatch overhead without changing `pattern too complex` timing? Both remain unproven.
