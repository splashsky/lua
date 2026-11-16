## Calls: summary

- Fresh `fib(32)` is 1,901.3M threaded vs 1,640.5M reference (+15.9%). The largest identifiable excess is the `LTI`/conditional-jump path, which copies an Odin context even for integers; this belongs to loops-arith. Confidence: high for the executed instructions, lower for the achievable saving.
- Calls themselves are not uniformly slow: fib's inline CALL plus frame setup is cheaper than reference; frame re-entry is dearer, while its `RETURN1` is at parity. Do not trade either `call1` or `ncall` for fib.
- A small `math.min`/`max` prototype saved 142M/1,501M instructions without affecting those probes; a fixed-three-result RETURN prototype saved 52.5M/219.7M but regressed other returns. Both need real correctness and regression work.
- Realistic near-term targets: min/max about 1,360M; fixed-three-result return below 180M without other-return regressions. Fib below 1,850M depends primarily on loops-arith; no calls-only fib saving is demonstrated. Metamethod-sort gains from calls alone are likely modest.

## Measurements

`perf stat -e instructions:u`, three rotated, CPU-11-pinned runs, master 0738e32, Odin `-o:speed`, Lua 5.5.1 `-O2`, Linux x86-64. Counts include startup and approximately 0.16M instructions for the `taskset` wrapper; no cycles claimed. Figures are medians, millions, threaded / switch / reference. Sort counts vary with hash/GC seeds; across batches the threaded sort ranged 983.2–985.4M and switch 998.0–1000.0M.

During this analysis, main advanced to `fa170e7`, which only adds `AGENTS.md`; all measurements used the detached `0738e32` snapshot. The scratch worktree and TMPDIR were removed, and the main checkout is clean.

| Probe | Threaded | Switch | Reference |
|---|---:|---:|---:|
| `bench/micro.lua fib(32)` | 1,901.3 | 2,074.0 | 1,640.5 |
| direct `fib(22)` | 16.127 | 17.532 | 13.995 |
| `call1` / `ncall` | 384.7 / 414.7 | 476.7 / 472.7 | 388.7 / 436.6 |
| fixed three-result return, 500k | 219.7 | 239.2 | 197.7 |
| vararg all-result return, 500k | 324.7 | 321.7 | 286.7 |
| three-result return with `<close>`, 200k | 174.1 | 177.3 | 148.1 |
| new noncapturing closure, 500k | 269.4 | 262.9 | 251.0 |
| make new capturing closure, 500k | 578.5 | 568.6 | 621.4 |
| numeric min/max, 2M loop iterations | 1,500.7 | 1,610.7 | 1,232.7 |
| `__lt` sort, 100 × 1,000 objects | 983.2 | 998.0 | 830.9 |
| same object sort, Lua comparator argument | 852.6 | 880.8 | 766.7 |
| same sort, numbers/no metamethod | 180.4 | 182.1 | 224.9 |

Reproduction: `fib(n)` is `if n<2 then return n end; return fib(n-1)+fib(n-2)`. Return probes call `f(x) return x,x,x`, `f(...) return ...`, and a function with `local x <close> = obj; return arg,arg,arg`, respectively; all request three results, `__close` is an empty Lua function. Closure probes repeatedly assign `function() end`, or `make(i)` where `make(x)` returns `function() return x end`. Min/max caches both functions and does `s=s+min(i,3)+max(i,3)`. This is a newly specified probe, not the lost original 994M probe. Sort constructs each object as `{v=(j*73+k*19)%1000}`, with shared `__lt=function(a,b) return a.v<b.v end`, sorts each array, and checks its endpoints. The instrumented version reports 1,023,188 comparisons in both VMs and reference. Comparator control uses the same predicate as an explicit `table.sort` argument, with no metatable.

`callgrind --dump-instr=yes` on `fib(22)`, millions of executed instructions; setup/startup excluded from the named pieces. Its release binaries match the perf builds; the `-g` reference has the same hot code. `fib(22)` executes 57,313 Lua activations. Reference source-line mapping moves some shared jump/fetch code onto unrelated `vmbreak` lines; the reference counts below are address/source-attribution estimates, not independent counters. Threaded handler totals include dispatch; reference shared dispatch is listed separately. **Do not sum cross-row differences.**

| Piece | Threaded | Reference | Notes |
|---|---:|---:|---|
| CALL handler / frame setup | ≈1.43 / ≈2.12 | ≈1.32 / 2.75 | Threaded total CALL handler 3.553M; split ≈25/37 instructions per call, reference ≈23/48. |
| fresh entry + return re-entry | 2.292 | 1.433 | `enternew` 1.032M (18/call), `enter` 1.261M (22/call); both include fetch. Reference entry is ~25/call. |
| RETURN1 | 1.662 | ≈1.662 | ~29 per one-result return here; includes fresh-status test, not entry. |
| LTI + conditional jump | 3.553 | ≈1.404 | Reference excludes shared dispatch; threaded includes it. |
| ADDI for `n-1`/`n-2` | 1.777 | ≈1.605 | Lua compiles both subtractions as ADDI, not SUB. |
| ADD | 1.003 | ≈0.774 | One per non-leaf. |
| GETUPVAL | 1.605 | ≈0.860 | Odin supports open/closed upvalues through different representation. |
| shared reference fetch/dispatch | already in handlers | ≈1.519 | Source/debug locations are approximate; loops-arith owns this sequence. |

## Causes

- `objdump` shows `vm_thread_LTI` unconditionally saves a stack frame and copies a 120-byte context before testing the integer tag; it also reloads the frame trap after the comparison. The integer path runs 57,313 times in fib(22). Removing ~15–20 instructions each would save an **estimated** 106–141M at fib(32)'s 7,049,155 activations, before code-placement or other effects. Coordinate with loops-arith, which owns this handler and generic dispatch. `vm_thread_enter` repeatedly resolves frame index × 56, stack base, closure, prototype, saved PC and hooks; reference holds a `CallInfo *`, so not all of the ~15/activation gap is safely removable.
- For a 10k-iteration callgrind run of fixed three-result returns, threaded `vm_thread_RETURN` costs 76 and `moveresults_other` 77 instructions/call. Reference `luaD_poscall` alone costs 66/call; VM-side code is additional. Vararg adds `VARARGPREP` 93 and `VARARG` 130/call in threaded; reference `luaT_adjustvarargs` ~61 and `luaT_getvarargs` 80/call, plus its opcode work. With `<close>`, `func_close` costs 105/call threaded vs 67 reference, plus lookup, a fresh Lua activation and close-list bookkeeping; these figures are not solely RETURN cost.
- For 10k noncapturing closures, threaded `CLOSURE` costs 68 and `pushclosure` 63 instructions/allocation, with malloc/free/GC substantial. Capturing costs `CLOSURE` 68 plus `pushclosure` 122, plus close/upvalue and GC; reference wins the former total but loses the latter. One profile cannot isolate an allocator-only improvement. Do not repeat the rejected contextless allocation wrapper; preserve emergency-GC anchoring and the upvalue barrier.
- For two arrays/21,385 `__lt` calls, threaded exclusive instructions per comparison are approximately `callbinTM` 67 (includes inlined result setup), `tm_gettmbyobj` 34, `ccall` 55, `do_precall` 56, and frame entry 22. Reference is ~27 + `luaT_callTMres` 43, lookup ~27, `luaD_callnoyield` 22, and Lua precall ~48. Boundaries/inlining differ. The re-entered Lua comparator costs 321 threaded vs 232 reference **inclusive of its field reads and return**, so its ~89-instruction difference is also material. Plain-comparator control confirms the overhead is not solely metamethod lookup.
- The default sort path is `api_compare → tm_callorderTM → callbinTM → do_callnoyield → ccall → vm_execute`; the explicit-comparator control instead uses `api_call → do_call → vm_execute`. `ccall` disassembly copies the context on every fresh VM activation. The context belongs to a live activation, and a pointer must never escape across return, yield or longjmp.
- Numeric min/max callgrind (10k iterations, two calls each): threaded math bodies plus `index2value` ~155 instructions/call vs reference math/gettop/compare/lessthan/push ~103. `vm_thread_CALL_lcf` is ~79 exclusive instructions/call vs reference `luaD_precall` + `luaD_poscall` ~71, excluding VM CALL code. The much larger library-side excess comes from default-context setup and general checked argument translation, not metamethod calls in this numeric probe.

## Levers

1. **Contextless positive-index min/max** — `src/stdlib/mathlib.odin`, `src/kernel/api_native.odin`: use checked positive-index compare/push helpers, exact `LTnum` for numbers, ordinary contextful comparison for strings/metamethods, and re-resolve indices after any re-entry. Scratch prototype measured threaded 1,500.7→1,358.7M and switch 1,610.7→1,484.7M; three-run `call1`/`ncall` unchanged in both modes. Integer/float/NaN, strings, tie identity, no arguments, table `__lt`, GC/re-entry, errors and a no-yield boundary passed small differential smoke tests. Risk: API assertion policy, mutation/relocation, custom types and error behavior; this is not full validation. Different from generic native-call fallback dead ends: no change to CALL or precall.
2. **Metamethod operand stack-base hoist** — `src/kernel/tm.odin`: load `L.stack` once only while copying function and two operands before the call; never retain it across `do_call`. Against the same min/max prototype, measured `__lt` sort 984.6→982.5M threaded and 999.4→997.4M switch, with direct comparator and both call guards unchanged; `tmcmp` saves 2 instructions/comparison. Small deterministic local win, subject to seed/code-placement checks. Separately skipping the same-slot result copy saved another ~5M on sort, but caused **switch** `call1` 476.7→482.7M and `ncall` 472.7→474.7M and comparator sort +3.1M; reject that version unless an independently measured layout-safe alternative eliminates all regressions.
3. **Multiple-result RETURN fast path** — `src/kernel/vm.odin`, `tools/generate_threaded/`, generated handler and tests: for no hook/interrupt/close/vararg, try contextless direct result movement, preserving overlap and arbitrary wanted/result counts with exact slow fallback. A scratch *exactly three given/three wanted* fast arm measured 219.7→167.2M threaded and kept `call1`/`ncall` fixed, but regressed varargs 324.7→328.7M, `<close>` 174.1→176.1M and captured closures 578.5→582.5M. It is not acceptable as written. Aim to isolate the fast path without penalizing other RETURNs; measured 52.5M is an upper bound for this shape, not a general gain.
4. **Fresh native→Lua re-entry, research only** — `src/kernel/do.odin`, `vm.odin`, `tm.odin` and possibly explicit-context internal helpers. Investigate passing an already-owned context pointer through an internal contextless boundary rather than copying on each fresh activation; a direct `&context` prototype does **not compile** in Odin, so an explicit-pointer lifetime/ABI design is required. About 14 context-copy instructions × 1.023M comparisons gives an **estimated** ceiling of ~14M on this sort, not a measured improvement. This differs from the rejected direct *Lua CALL fresh entry* and native-tail-transition experiments; leave their CALL fast paths alone. Preserve C-call counts, no-yield rules, hooks, `CIST_FRESH`, error unwinding and fresh activation lifetime. Abandon if complexity or either call guard regresses.
5. **Entry/closure investigation, lower priority** — entry-only code generation changes could theoretically save 1–3 instructions per re-entry, ~7–21M on fib(32), but none measured; reject frame pointers surviving relocation, 64-byte frames, and prior direct-entry/ncall tradeoffs. Profile no-upvalue closure allocation, GC and call entry separately before proposing an allocation change. Coordinate closure/GC work with strings-gc and field lookup with tables-globals.

## Work packages

- `calls/minmax-native`: implement lever 1, add `tests/mathlib_test.odin` differential cases for mixed huge ints/floats, NaN, signed-zero/tie identity, strings and embedded NUL, zero/one/many args, metamethod lookup order, stack/frame growth, GC, hooks, errors and forbidden yields. Acceptance: ≤1,370M threaded and ≤1,500M switch on the specified probe; `call1`/`ncall` no increase beyond measurement noise in either VM.
- `calls/tm-stack`: implement only lever 2, with `tests/do_test.odin` coverage for both operands' metamethods, result destination overlap, metamethod yield/resume from Lua and rejection from native, hooks, growth and OOM. Acceptance: paired ≥1M saving on the specified sort, no established regression for explicit-comparator sort or either call guard in either VM. Independent of min/max; measure isolated and combined.
- `calls/multireturn`: implement lever 3 only if fallback regressions are removed; touch generator/guard hashes and regenerate, `vm.odin`, relevant tests. Cover fixed 0/1/2/3/many, MULTRET, trimming/nil padding, overlap, fresh frames, vararg, hooks, TBC/close yield and relocation. Acceptance: fixed-three ≤180M, vararg ≤324.8M, TBC ≤174.3M, captured closure ≤579M threaded, no `call1`/`ncall` regression; switch no regression.
- `calls/reentry-study`: isolate `ccall` context ownership and compare both sort controls, a direct Lua metamethod comparison, and native `ncall`; prototype only if the pointer lifetime is provable. Acceptance for implementation: ≥10M saved on metamethod sort, no call-guard or comparator-control regression, differential hooks/yield/error/relocation tests. Keep separate from loop/arithmetic work.
- `calls/entry-closure-study`: after loops-arith's LTI result, profile residual fib entry and both closure shapes with allocation/GC separated; no precommitted optimization. Acceptance for any implementation: paired fib reduction ≥10M without call-guard regressions, or closure reduction ≥10M on noncapturing without a captured-closure regression; add GC emergency-retry/barrier and relocation tests.

For production work, run the repository's full `AGENTS.md` gates, both interpreters and stress/ASan as required, generated-source drift checks, and the PUC suite; scratch prototypes above ran only targeted smoke tests. Treat cycle wins as unproven on this loaded host.

## Open questions

None. The 100-array and min/max scripts above specify fresh probes because the historical scripts were not retained; if exact historical comparability is required, recover those scripts before using their reported 983M/994M numbers as acceptance baselines.
