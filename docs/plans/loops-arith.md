## Loops, arithmetic and dispatch: summary

At `0738e32`, `intloop` is 6,061.6M instructions threaded versus 4,953.0M
reference (+22.4%); empty is +10.6%, and `floatloop` +4.2%. High confidence:
dispatch materializes the table address on each fetch, and K-division fast paths
pay for their cold callouts. A carried table pointer alone saves 2.3% on intloop;
a combined prototype saves 5.8%, but regresses float division/modulo. Target
2–5% on intloop without significant regressions; the larger gain is conditional.
During analysis master advanced to `fa170e7`, changing only `AGENTS.md`; all
measurements used the detached `0738e32` source.

## Measurements

Linux x86-64, CPU 11, Odin dev-2026-11 nightly, `-o:speed`, PIE, reference
5.5.1 `-O2`. Three fresh isolated, rotated `perf stat instructions:u` runs;
numbers below are medians, millions, including startup and taskset. Counts were
stable to <0.004M except seeded controls. Cycles on this shared host are too
noisy to rank small changes. Threaded / switch / reference:

| Workload | Threaded | Switch | Reference |
|---|---:|---:|---:|
| empty, 2M | 62.722 | 68.722 | 56.700 |
| add, 2M | 132.728 | 146.728 | 120.706 |
| il, 50M | 4,250.732 | 4,750.733 | 4,000.710 |
| micro/intloop, 20M | 6,061.607 | 6,421.611 | 4,953.006 |
| micro/floatloop, 10M | 7,519.933 | 8,339.933 | 7,217.024 |
| move, 2M | 100.728 | 112.730 | 96.707 |
| call1, 2M | 384.733 | 476.733 | 388.712 |

`callgrind --dump-instr=yes` on the same intloop body scaled to 200k
iterations, with reference `-g -O2`: counts below **include each handler's
dispatch**. Reference's arithmetic helpers were inlined into `luaV_execute`;
its counts are attributed from the executed instruction blocks, not function
totals. MODK depends on remainder distribution (here `i % 7`).

| Operation | Occurrences/iteration | Threaded | Reference |
|---|---:|---:|---:|
| ADD | 2 | 35 | 32 |
| SUB | 1 | 35 | 32 |
| MULK | 1 | 36 | 32 |
| IDIVK | 1 | 64 | 45 |
| MODK | 1 | 67 | 46.57 |
| FORLOOP, taken | 1 | 31 | 28 |
| Total | | 303 | 247.57 |

Callgrind totals including startup: threaded 61.21M, switch 64.81M,
reference 50.04M. Switch's `vm_execute` accounts for 64.20M; reference's
`luaV_execute` 49.51M. This is not a per-handler breakdown of the switch.

Throwaway prototypes, 3 alternating runs, million instructions:

* Table pointer carried as a tenth threaded argument: empty 62.722→60.722,
  add 132.728→128.728, il 4,250.732→4,100.733, intloop 6,061.607→5,921.612,
  floatloop 7,519.930→7,489.933, call1 384.732→378.733, ncall 414.729→414.731,
  fib 1,901.363→1,876.695. `array_insert` was flat at 613.5M. Seed-sensitive
  gtab baseline 192.731M in all three; prototype 186.732, 186.731, 206.733M.
* Splitting integer MODK/IDIVK from the existing float/error handler, alone:
  intloop 6,061.608→5,767.324M (−294.3M, 4.9%); callgrind IDIVK 64→56,
  MODK 67→60.29 per iteration. Float `x//2` 330.743→342.744M and `x%7`
  424.743→436.744M, each 2M iterations; metamethod `//`, 300k iterations,
  149.253→151.053M. A separate float-only fallback reduced, not eliminated,
  these regressions: 338.743M, 430.743M, and 150.753M respectively.
* Both prototypes together: intloop 6,061.609→5,707.327M (−354.3M, 5.8%),
  not the sum of individual wins. ADD/SUB/MULK/FORLOOP became 34/34/35/30,
  IDIVK 57 and MODK 61.29; 2M float `//`/`%` were 344.744/438.745M,
  versus table-pointer-only 328.745/422.745M. Do not land this tradeoff as is.
* A separate integer-only ADD/SUB/MUL split improved intloop 5,767→5,207M,
  but worsened floatloop 7,520→7,830M; rejected. An inline mixed-number
  rewrite also worsened both intloop and floatloop. Merely reordering the
  existing trap/context/instruction arguments was flat; rejected.

Prototype differential samples matched baseline and reference for integer
extremes, signs, zero divisors, floats including NaN/infinity, metamethods and
a count hook. Direct targeted stress+ASan tests passed for float-loop edges,
constant division/modulo, deep frames/hooks/yield/resume and control-tag repair.
These are not full validation, and prototypes edited generated text directly;
no production changes or complete test matrix were made.

## Causes

* x86-64 ordinary threaded MOVE/ADD fetch: `test edx,edx; je` (or trace),
  `mov r8d,[r13]; add r13,4; mov eax,r8d; and eax,127; lea rdx,[rip+table];
  mov rax,[rdx+rax*8]; xor edx,edx; jmp rax`. That's 10 instructions on this
  no-trap path. FORLOOP fetches its back-edge instruction before polling and
  dispatches it only if neither poll nor trace is needed.
* Reference hot ADD ends with a jump to shared `test r9d; je fetch`, followed
  by `lea rbx,[r14+4]; mov r14d,[r14]; mov eax,r14d; and eax,127; jmp
  [r12+rax*8]`: 8 including that shared jump. Its table base is kept in r12;
  a memory-indirect jump combines target load and branch. Other paths merge
  differently, so this is not a universal per-op saving.
* The nine-argument preserve/none mapping here is L/PC/regs/closure in
  r12–r15, code rdi, frame index rsi, trap edx, context rcx, instruction r8d.
  Simple handlers do not copy the context or shuffle all arguments. LLVM
  re-materializes zero in edx after the trap check; it also uses edx for table
  address and division remainder. MODK/IDIVK have push/sub and restore/pop on
  their integer hit because float/error paths call out. The extra table
  argument occupies r9: simple dispatch loses the `lea`, but CALL gains a
  push/pop from register pressure. Its modest net wins and flat ncall were
  measured, not assumed. Text size increased 992 bytes in this prototype.
* arm64 object inspection only: PC x21, regs x22, trap w26, context x27,
  instruction w28. MOVE's no-trap fetch uses `cbz`, post-indexed `ldr`,
  `adrp; add` table address, `and`, indexed `ldr`, `br`. Carrying the table in
  x0 removes `adrp; add` on MOVE/ADD; callouts may need to preserve x0. No
  arm64 execution or speed claim. Cross-compiled combined MODK/IDIVK keep
  `sdiv`/remainder correction and indirect tail branches.
* `lvm.c` op_arith/op_arithK test integer operands and otherwise promote
  numbers; success skips MMBIN. The port's generic ADD integer path tests
  float first and shares destination/tag logic. K operations reload `cl.p.k`;
  unlike reference, they do not carry a constant-table base. MODK/IDIVK also
  save PC/top, check zero/−1, divide, correct floor signs, and handle float or
  non-number paths. Signed divide uses rdx, competing with the trap. FORLOOP
  additionally repairs both integer tags and polls the async hint; reference
  changes values only. Tag repair is intentional after `debug.setlocal`.

## Levers

1. **Carry the dispatch table base** through every threaded transition, set
   once at activation entry. Measured −1 instruction per ordinary x86 fetch,
   −140M intloop; inspect arm64's −2 static instructions, but do not infer its
   runtime result. The tenth live register increases callout pressure; validate
   calls, tables, errors and hooks across all supported ABIs. This differs from
   the rejected second generated-file split: it changes dispatch state, not file
   placement. Preserve 128-entry invalid-opcode coverage and trace/poll edges.
2. **Separate K integer floor arithmetic from float/error callouts**, retaining
   saved PC/top on every path. Standalone measured −294M intloop, incremental
   −214M after lever 1, but float and metamethod regressions above make the
   current design unacceptable. Try a tailored float fallback or reduced
   duplicated decoding; keep constant tag checks even for unvalidated chunks,
   integer wrapping, MIN/−1, zero errors and mixed-sign floor semantics.
   This is distinct from the already-landed contextless K helper: it removes
   stack-frame pressure, not a Context copy. Highest correctness/codegen risk.
3. **Explore arithmetic hot-path layout and constant-base carrying**, not the
   rejected integer-only split. A carried `k` could avoid one closure→proto
   dereference per K instruction, at most ~60M instructions on intloop if it
   saves one per K operation; estimate only, before spill/entry costs. Any
   extra argument competes with the table register and CALL; refresh on every
   frame entry/resume. Inline int/float layout requires a genuinely different
   codegen result from both failed rewrites. Keep tags, aliasing, mixed floats,
   MMBIN skip, metamethod/yield and malformed-constant behavior. Lower priority.
4. **FORLOOP**: retain existing general prefetch, poll and tag stores. The
   3-instruction gap is small and not proven removable without altering those
   semantics; no empty-loop-only specialization or unguarded value-only stores.

## Work packages

1. `bench/arith-dispatch-probes`: add stable positive/negative, register/K,
   float `//`/`%`, mixed-number and metamethod probes under `bench/probes/`;
   verify actual opcodes with `luac -l`, check results, and report 3–5-run
   distributions with `build/vm-compare.sh`. No kernel changes. Existing
   `micro/floatloop` alone does not cover the observed K-float regression.
2. `perf/threaded-dispatch-table`: update `tools/generate_threaded/main.odin`,
   regenerate `src/kernel/vm.odin`, and keep threaded-only helpers out of that
   file. Extend `tests/vm_test.odin` for invalid opcodes, hook/poll at back
   edges, fresh/re-entered frames, yielding metamethods and forced relocation.
   Accept if intloop ≤5,930M, add ≤129M, call1 ≤380M, ncall no material
   regression, and switch deterministic probes stay within 0.1% of baseline;
   rerun seed-sensitive table controls as distributions. Coordinate with calls
   and tables analysts because the ABI touches every handler. Inspect x86-64
   and arm64 objects; Windows/macOS/arm64 runtime validation belongs to the
   validation analyst. Prototype's switch empty/add/intloop remained flat.
3. `perf/threaded-floor-k`: independently develop the K split in the generator
   and `vm_threaded_fast.odin`, then remeasure on top of package 2; update
   `tests/arith_test.odin` and `tests/vm_test.odin`. Target intloop ≤5,720M
   after package 2, **and** ≤0.5% regression on each new float/modulo and
   metamethod probe; otherwise defer rather than accept the prototype. Test all
   sign/zero/MIN/−1 combinations, mixed float/NaN/infinity, nonnumeric K,
   error PC/top, hooks and yielding fallback under HARDSTACKTESTS.
4. `perf/threaded-arith-layout`: exploratory, after packages 1–3. Touch the
   generator and threaded-only helpers; test ADD/SUB/MUL register/K aliasing,
   wraparound, float bits and yielding metamethods. Require a reproducible
   ≥200M intloop reduction versus its immediate parent, no >0.5% floatloop or
   dedicated float/K regression, and no switch degradation; abandon if not met.
   Recheck frame-entry and call regressions with the calls analyst.

For any landed kernel/generator package, run the repository's full two-mode
check, normal/stress/ASan/stress+ASan unit and PUC gates, clitest, rebrand and
hosted/freestanding builds; regenerate and review guarded hashes. Run heavy
gates one at a time. Full cross-platform runtime validation remains separate.

## Open questions

None requiring a user decision now. Do not accept the measured K-float
regression without an explicit decision to trade float performance for integer
performance; the proposed gate instead requires eliminating it.
