## Tables and globals: summary

On baseline `0738e32`, dense array insert/read is 613.30M instructions versus
572.38M reference; global reads and especially writes depend on hash seed.
High-confidence causes are repeated split-array pivot loads, expensive
context/ABI handling for table length and field/global writes, and extra
upvalue/constant guards. Throwaway prototypes show plausible targets of ~601M
for array_insert, ~64M for 300k `t[#t+1]` appends (63.31M reference), and near
reference for fixed-key primitive global writes. Gains are **not additive**.
During analysis master advanced to `fa170e7` (agent-conventions docs only).

## Measurements

- Linux x86-64, optimized Odin `-o:speed -debug -define:INTERNAL_ASSERTS=false`,
  reference `/tmp/opencode/refbuild/src/lua`; five rotated `perf stat -e
  instructions:u` runs, fresh processes, no pinning, medians and ranges in M.
  The debug-symbol build's 2M SETTABLE count matched a normal release build
  (172.52M each). Cycles are not used on this loaded machine. Profiles use
  `valgrind --tool=callgrind --dump-instr=yes` and the symbol reference
  `/tmp/opencode/refdbg/src/lua`; 30k iterations. Counts include startup.
- Probes use two million iterations unless specified: `x=1; for i=1,N do y=x
  end` (gtab); `x=1; for i=1,N do x=i end` (gwrite); collectable write assigns
  a rooted string; pre-existing array probes repeatedly use `t[k]`, `t[1]`,
  or `t.x`; LEN repeatedly takes `#{1}`. Append is 300k inserts into an empty
  table, `t[#t+1]=i`; grow uses `t[i]=i`. Fixed-one-key probes use an `_ENV`
  containing only `x`; `gread_open` captures it while its owner is active.

| Workload | Threaded | Switch | Reference |
|---|---:|---:|---:|
| gtab | 214.51 [192.51,214.51] | 298.51 [278.51,298.51] | 192.49 [174.49,192.49] |
| gwrite primitive | 248.52 [248.52,268.52] | 350.52 [350.52,370.52] | 198.50 [198.49,216.50] |
| gwrite collectable | 306.52 [306.52,326.52] | 376.52 [356.52,376.52] | 204.50 [204.50,222.50] |
| gread_open | 198.54 | 284.54 | 174.52 |
| array_insert, 3M | 613.30 | 712.30 | 572.38 |
| SETTABLE / GETTABLE | 172.52 / 152.52 | 192.52 / 190.52 | 154.50 / 140.50 |
| SETI / GETI | 164.52 / 144.52 | 192.52 / 172.52 | 146.50 / 136.50 |
| SETFIELD / GETFIELD | 320.52 / 244.52 | 342.52 / 278.53 | 196.50 / 170.50 |
| table LEN | 312.52 | 270.52 | 226.50 |
| append / grow, 300k | 77.30 / 29.00 | 73.70 / 32.00 | 63.31 / 27.91 |
| SELF string method | 636.51 | 814.51 [794.51,814.51] | 662.49 [662.49,680.49] |

- Callgrind handler self counts, **including threaded dispatch**, instructions
  per operation: GETTABUP 65–76, SETTABUP primitive ~93–103 (handler ~59 plus
  `table_psetshortstr` ~34 in one seed), collectable ~122 (handler ~36, collect
  handler ~52, pre-set ~34); GETTABLE 45, SETTABLE 55, GETI 41, SETI 51,
  GETFIELD 91, SETFIELD ~129, table LEN ~125 (handler 50 + lenslow 19 +
  objlen 32 + getn 24). FORLOOP is ~31. Reference per-op figures inferred from
  isolated totals minus its ~28-instruction loop: global get 59–68, primitive
  set 71–80, collectable 74–83; GETTABLE 42, SETTABLE 49, GETI 40, SETI 45,
  GETFIELD 57, SETFIELD 70, table LEN 85. Reference callgrind attributes about
  30–31/op to `luaH_psetshortstr` and 41/op to `luaH_getn` in these samples.
  Hash-chain depths differ across processes; don't interpret median differences
  as matched-key comparisons. Inline source lines are summed by function.

## Causes

- `vm_thread_SETTABUP` (`src/kernel/vm.odin`) makes an ordinary-ABI call to
  `table_psetshortstr`: objdump shows stack allocation, spills and reloads even
  for primitive existing-key hits. Collectable writes additionally tail-enter
  another handler that re-resolves operands and performs the conservative back
  barrier test. A check must not be discarded just because reference tests a
  white value: this port's `gc_barrierback` deliberately regrays any black
  container while its invariant holds.
- `upval_value` checks `UpVal.open` and resolves `(thread,index)` versus inline
  closed storage; the reference stores a direct `v.p`. Closing can occur during
  execution, the captured slot can move, and `debug.upvaluejoin` can replace the
  closure's upvalue even while active. A closed status is monotone for one
  *object*, not for an activation's upvalue vector. A cached stack pointer would
  violate the index-only rule unless all relocation, closure and debug mutation
  paths invalidate it. Estimated payoff only ~3–6 instructions per access.
- Parser-generated global keys are short strings, but unvalidated chunks can
  carry other constants and existing unit tests require this to work. Undump
  reads code before constants; a reader can expose and run a still-compiling
  prototype. Merely marking a validated Proto adds a hot per-op branch unless
  dispatch or bytecode representation also changes. Rejecting such chunks
  changes behavior; unconditionally assuming short strings is unsafe.
- Short-string chains use 24-byte nodes and relative **indices**: objdump
  recomputes 24-byte addresses at each hop and generates a conservative shift
  bound check for the hash mask. Reference traverses `Node *`. Seed variation
  changes the number of hops. `MAXHBITS=30` and allocation guards bound
  `lsizenode`; any optimized mask must prove that invariant, including dummy
  tables and supported targets.
- Split-array representation matches reference Lua 5.5 exactly, including tag
  bytes and reverse payloads. In baseline objdump, GETTABLE reloads `t.array`;
  SETTABLE additionally spills/reloads the pivot and reloads it before the
  payload store. `table_fastseti` checks the metatable before inspecting a live
  slot, exactly as reference does; a tag-first reorder is not assumed to win.
- LEN saves PC/top and calls lenslow → vm_objlen → table_getn even when a table
  has no metatable. `table_getn`/`hash_search` read the seed and update the hint
  but do not allocate or call Lua. For 30k append, callgrind attributes 29/op
  to getn itself and 101/op to LEN/objlen/lenslow around it. Growth also invokes
  rehash/resizing; 300k grow is only 1.09M above reference, so it is not shown
  to dominate the 3M insert/read gap. Layout, resize policy and hint algorithm
  already mirror `ltable.c`; avoid changing them speculatively.
- Mixed `tablechurn` and string SELF are already competitive. The much slower
  isolated field loops expose an opportunity, not a demonstrated mixed-workload
  regression; there is no reason to redo the previously failed generic SELF split.

## Levers

1. **Reuse the split-array pivot**, `table_fastgeti`/`table_fastseti` in
   `src/kernel/table.odin`. A scratch rewrite held `t.array` in a local for tag
   and payload; no call or mutation occurs while it is held. Measured in three
   runs: SETTABLE 172.52→166.52M, GETTABLE 152.52→150.52M, SETI 164.52→
   156.52M, GETI 144.52→142.52M; array_insert 613.30→601.30M threaded and
   712.30→706.30M switch. Tablechurn fell ~13M; hash_prekey/strconcat did not
   regress. Risk: shared helper codegen and aliasing; preserve tag-before-payload,
   empty-slot `__newindex`, collectable barriers, hash path, and no pointer
   across a call. Distinct from the dead-end variable-key array *dispatch* split.
2. **No-metatable table LEN**, generated LEN specialization plus
   `table_getn`/`hash_search`: contextless direct getn only for a table with no
   metatable, otherwise existing slow handler. Keep the original saved-PC/top
   writes and trap reload even on hits. Measured: LEN 312.52→224.52M; append
   77.30→64.10M; array_insert unchanged; switch LEN unchanged after the shared
   ABI change. Risk: string-LEN code placement, shared API callers, complex
   hash-border search, and `__len` yielding/errors/hooks. No known dead end.
3. **Inline existing short-string global-write hits**, keep the collectable
   color/phase test on its separate path. A scratch hit-only version measured
   fixed one-key writes 248.54→204.54M, saving 22/op. Its missing-key fallback
   re-probes and is **not shippable**: a separate 200k new-environment probe
   regressed 438.36→448.56M, reproducing the first global-write split dead end.
   Instead pass a bounded absent/node location to a cold short-string pre-set
   helper, preserving the existing fast insertion and carrying unfinished hres
   to finish, without a second chain walk. Try the collectable version only
   with the same conservative barrier behavior; extra benefit unmeasured.
4. **Targeted GETFIELD/SETFIELD hit handlers**, analogous to GETTABUP/SETTABUP,
   with real cold paths and generic-constant fallback. Prototype GETFIELD
   244.52→184.52M; primitive SETFIELD 320.52→196.52M; tablechurn, hash_prekey,
   and SELF remained within seed variation. It also re-probes cold misses, so
   use the single-lookup approach in lever 3 before shipping. Estimated net
   real-workload gain uncertain; this is not the failed generic SELF check.
5. **Hash codegen**, `hashpow2_i` and `table_Hgetshortstr`: separate scratch
   experiments using a provably bounded 32-bit mask and a local node pointer
   reduced one-key open-read 198.54→194.54M combined, and tablechurn median
   3668.91→3651.23M; hash_prekey 857.59→851.64M (five seed-varying runs).
   Mask-only and pointer-only effects varied by caller, so remeasure separately
   on both VMs and after levers 3/4. The pointer must be strictly ephemeral;
   test negative relative links, collisions, deleted/dead nodes, dummy hash,
   rehash and GC. High codegen/portability risk, modest net gain; don't alter
   the 24-byte node layout or string header without new evidence.
6. **Do not hoist `_ENV`/constant assumptions by default.** The measurable
   payoff is small relative to lifecycle and debug mutation risks. Reconsider
   only with an invalidation design that preserves non-string chunks and
   partially built prototypes, and a measured win after dispatch overhead;
   coordinate with the calls/dispatch analysts. Rehash and generic SELF are
   investigation-only, not proposed rewrites.

## Work packages

1. `perf/array-pivot`: `table.odin`, generator guards as needed, tests and docs;
   independent. Target threaded array_insert ≤602M, switch ≤707M; SETTABLE and
   GETTABLE each no worse than baseline and no sampled hash/strconcat regression.
   Test holes, nil variants, negative/hash indices, aliasing, metatables,
   incremental/generational barriers, yielding `__newindex`, forced relocation.
2. `perf/table-len`: `table.odin`, `vm_threaded_fast.odin`, generator and
   generated `vm.odin`, tests/docs; independent of 1 but remeasure after merge.
   Target LEN ≤225M, append ≤65M; protect string LEN and both switch benchmarks.
   Test empty/dense/sparse/full arrays, hash borders, changing metatables,
   yielding/erroring `__len`, hooks, relocation, and GC.
3. `perf/global-shortset`: generator/`vm.odin`, `table.odin` or threaded-only
   helpers, tests/docs; independent of 1–2. Fixed-key primitive write ≤210M,
   no more than 1% regression on new empty/full environments and deleted keys;
   no regression on collectable writes. Exercise open/closed/joined upvalues,
   table/non-table env, non-string chunk constants, barriers, hooks and yielding
   `__newindex`. Preserve saved PC/top, original context and trap reload.
4. `perf/field-hit`: same generator and helpers, tests/docs; depends on 3's
   single-lookup miss protocol. Target GETFIELD ≤190M, SETFIELD ≤205M on fixed
   hits; no material regression in tablechurn, constructors, SELF, new/missing
   keys or collecting writes. Cover aliasing and yielding `__index`/`__newindex`.
5. `perf/short-hash`: `table.odin`, guarded generator hashes, tests/docs; after
   3–4 to avoid overlapping codegen changes. Target ≥2M reduction in the fixed
   2M-read probe and no regression across seed distributions, both VMs and
   collision/churn probes. If not reproducible, record as a dead end instead.

For every package: regenerate and review guarded specializations; run repository
gates in both modes (including relocation/ASan and PUC), check switch and
cross-target codegen, and compare at least five randomized-seed runs. Scratch
prototypes passed targeted Lua smoke checks including metamethod yield, hooks,
collision/deletion and both GC modes; they did **not** run the full gates.

## Open questions

None requiring a user decision. A policy to reject or rewrite previously
accepted unvalidated bytecode would require an explicit compatibility decision;
it is not needed for the proposed packages.

Cleanup: scratch worktree and TMPDIR removed; main checkout status is clean.
