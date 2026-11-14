# Threaded VM measurements

The experimental interpreter is broadly faster, but **is not ready to be the
default**. The integer-loop regression was removed. An empty numeric loop is
still slower than with the switch, although loops with a body are faster. String
construction and closures still have slower minima; string patterns, table
churn and fresh string keys remain uncertain. Allocation and I/O results are
noisy. Keep the switch as the default until the remaining regressions and
measurement uncertainties are resolved and the other targets have been
exercised at runtime.

Not every helper was converted: `GETI`, `SETI`, `SETFIELD`, register-operand
division and modulo, comparisons, and concatenation still use existing paths
where applicable.
The experiment does not establish that the remaining regressions are inherent
to threaded dispatch.

## Method

Measured on 2026-11-14 on an AMD Ryzen 9 7950X, Linux x86-64, Odin
`dev-2026-11-nightly:9a69916`, with `-o:speed` PIE builds. Reference is Lua
5.5.1 from `/tmp/opencode/refbuild/src/lua`; master is commit `6f13068` built
from an unmodified source archive. Each row runs in a fresh process, with seven
rotating runs of switch, threaded and reference; the probes also include master.
Harness rows were not remeasured on master. Only one measurement driver ran at
a time, after the test matrix completed. `perf stat -x, -e instructions:u,cycles:u`
records user-space events. The minimum instructions and cycles are reported
independently, in **millions**. Harness names run in isolation, as described in
`bench/README.md`; the probe files under `/tmp/opencode/inv` were not modified.

The machine was heavily loaded. Hash seeds and I/O also change instruction counts,
so small cycle differences and individual minima are not proof of a regression on
an idle machine. Master and switch instruction distributions overlap on every
probe: for example, master/switch `self` ranges were 810.6–830.6M and
810.6–850.6M, `calls` ranges 30,871.0–30,971.0M and 30,671.0–30,871.0M, and
`w1` ranges 14,696.0–14,946.0M for both. The non-hash loops differed by at most
about 2,000 instructions in median startup cost. The switch executable's `.text`
is also byte-identical to the switch build before this follow-up, though master
has different code placement. A separate 14-run `ncall` comparison gave master
and switch minima of 99.55M / 99.57M cycles and medians of 101.84M / 101.80M;
an earlier seven-run comparison had 100.2M / 114.0M minima. Cycle differences
against master are therefore not settled by instruction counts alone.

| Workload | Master instructions / cycles | Switch instructions / cycles | Threaded instructions / cycles | Reference instructions / cycles |
|---|---:|---:|---:|---:|
| probe/empty | 74.6 / 20.0 | 74.6 / 19.9 | 66.6 / 21.6 | 56.5 / 17.4 |
| probe/move | 120.6 / 24.6 | 120.6 / 24.8 | 104.6 / 24.4 | 96.5 / 25.0 |
| probe/add | 154.6 / 28.8 | 154.6 / 29.0 | 136.6 / 27.4 | 120.5 / 29.9 |
| probe/gtab | 286.6 / 56.2 | 286.6 / 56.2 | 246.6 / 46.3 | 174.5 / 45.6 |
| probe/call0 | 492.6 / 125.7 | 492.6 / 124.9 | 418.6 / 103.2 | 344.5 / 84.6 |
| probe/call1 | 540.6 / 133.7 | 540.6 / 133.8 | 460.6 / 117.8 | 388.5 / 90.8 |
| probe/callr | 600.6 / 145.6 | 600.6 / 145.2 | 516.6 / 127.8 | 448.5 / 103.2 |
| probe/ncall | 492.6 / 99.3 | 492.6 / 100.1 | 422.6 / 79.8 | 436.5 / 103.8 |
| probe/self | 810.6 / 160.3 | 810.6 / 160.6 | 624.6 / 122.8 | 662.5 / 144.8 |
| probe/il | 5,000.6 / 952.9 | 5,000.6 / 951.4 | 4,350.6 / 832.3 | 4,000.5 / 828.5 |
| probe/calls | 30,871.0 / 6,377.0 | 30,671.0 / 6,356.2 | 26,421.0 / 5,300.6 | 25,890.8 / 6,183.8 |
| probe/w1 | 14,696.0 / 2,921.6 | 14,696.0 / 2,898.3 | 14,286.0 / 2,805.6 | 12,561.0 / 2,757.4 |
| probe/iobench | 9,535.9 / 1,955.6 | 9,535.9 / 1,953.4 | 9,501.2 / 1,920.6 | 7,817.1 / 1,704.7 |
| micro/fib(32) | — | 2,299.7 / 585.2 | 2,169.2 / 537.3 | 1,640.3 / 401.9 |
| micro/intloop | — | 6,601.6 / 1,202.0 | 6,101.6 / 1,141.2 | 4,952.8 / 968.0 |
| micro/floatloop | — | 9,067.4 / 2,426.9 | 8,157.4 / 2,340.5 | 7,216.8 / 1,740.7 |
| micro/strconcat | — | 913.0 / 438.0 | 924.3 / 464.1 | 879.8 / 310.5 |
| micro/strpattern | — | 5,209.6 / 1,037.6 | 5,164.8 / 1,038.3 | 3,803.4 / 1,071.8 |
| micro/tablechurn | — | 4,873.3 / 5,468.1 | 4,967.6 / 5,670.7 | 4,812.2 / 5,513.3 |
| micro/tablesort | — | 6,836.3 / 1,635.2 | 6,164.0 / 1,544.6 | 4,523.1 / 1,286.3 |
| micro/closures | — | 4,229.1 / 1,068.0 | 4,171.0 / 1,079.7 | 3,028.6 / 682.5 |
| tables/array_insert | — | 739.5 / 156.0 | 751.5 / 142.0 | 572.4 / 124.9 |
| tables/hash_strkey | — | 1,364.1 / 1,461.4 | 1,388.3 / 1,423.9 | 1,287.8 / 1,271.2 |
| tables/hash_prekey | — | 1,106.9 / 834.7 | 1,148.2 / 820.6 | 972.2 / 553.3 |
| tables/tablesort | — | 1,908.4 / 445.6 | 1,722.2 / 422.0 | 1,266.1 / 342.0 |
| stdlib/tostring_float | — | 1,170.6 / 288.6 | 1,144.5 / 283.1 | 3,197.0 / 787.5 |
| stdlib/tonumber_float | — | 574.1 / 110.3 | 558.1 / 104.7 | 714.0 / 152.9 |
| stdlib/string_format | — | 1,467.5 / 348.4 | 1,442.7 / 337.0 | 2,352.1 / 630.0 |
| stdlib/format_int | — | 911.2 / 219.2 | 874.4 / 215.4 | 797.1 / 191.1 |
| stdlib/math_transcend | — | 1,488.0 / 309.4 | 1,366.0 / 286.1 | 1,228.7 / 296.5 |
| stdlib/file_lines | — | 895.9 / 288.8 | 896.9 / 291.3 | 713.6 / 159.5 |
| stdlib/os_date | — | 707.0 / 165.2 | 697.8 / 162.1 | 691.9 / 203.2 |

## Experiments

### Follow-up: loop entry, string length and frame entry

Each comparison below uses seven alternating runs, in millions of user-space
instructions / cycles. The machine was heavily loaded, so minima and medians
can differ substantially; these comparisons do not prove every small cycle
change. The historical 14-run follow-ups in the bullets predate the
constant-division change; the later confirmation uses the finished code. The
code remains PIE.

* The empty-loop profile put most samples in `FORLOOP`, including its
  instruction-dependent back edge and the next opcode's table lookup. The
  threaded empty probe stays at 66.6 / 21.6 against 74.6 / 19.9 for switch:
  fewer instructions, more cycles. A dedicated handler for an integer loop
  whose `FORLOOP` jumps to itself, selected once at `FORPREP`, took the probe
  to 24.6 / 6.5. It was removed again: it helps only loops with an empty body,
  which real code does not contain, and it hid the back-edge cost this probe
  exists to measure. Loops with a body are faster threaded (`il`, `add`,
  `intloop`, `floatloop`).
* The `strpattern` inner loop uses `LEN` on strings. Its old threaded handler
  copied the Odin context, spilled state and called `vm_objlen` for every word.
  The new string path preserves the saved PC and top updates but avoids that
  call; other types still use `vm_objlen` with the original context. In one
  comparison `strpattern` went from 5,302.4 / 1,062.6 to 5,164.8 / 1,049.4
  (switch 5,209.6 / 1,054.4); the respective cycle ranges were 1,062.6–1,130.1,
  1,049.4–1,129.4 and 1,054.4–1,126.0. The instruction win is clear; the small
  cycle differences overlap between runs. Its iterator's `TFORCALL` still enters
  the ordinary C-call boundary, including the C-call limit and yield handling.
  A 14-run follow-up had switch/threaded medians of 1,060.0M / 1,063.8M cycles.
* The old frame-entry handler reserved a context-sized native stack frame even
  with hooks off. Moving the hook branch into a separate tail transition lets
  the compiler omit that prologue on the common path. `call1` fell from
  476.6 / 122.0 to 460.6 / 117.9; `closures` fell from 4,203.0 to 4,171.0
  instructions, but its cycle improvement is not established. In another
  comparison its minima were 1,070.6 threaded versus 1,056.4 switch. A 14-run
  follow-up had medians of 1,101.4M threaded versus 1,096.2M switch.
  A 929-sample threaded cycle profile before that change attributed about 15%
  to frame entry, about 3% to `CLOSURE`, and over 40% to allocator procedures.
  The closure handler copies the context and spills VM state around allocation;
  its upvalue wiring also tests the GC barrier. These observations do not prove
  which part causes the residual timing difference.
* On `hash_strkey`, samples were dominated by allocation, string interning and
  hash-node loads. String-key writes fall back to the original set path, whose
  miss can allocate and needs the original context and GC barrier. A seven-run
  comparison had overlapping ranges of 1,290.2–1,666.8 threaded and
  1,384.9–1,660.3 switch, reversing the earlier minimum ordering. No new
  string-write shortcut was retained without a reliable win and a reviewed
  miss/barrier path. In 14 additional runs switch/threaded medians were
  1,546.5M / 1,600.5M cycles, so the remaining difference cannot be dismissed.
* Before the constant-division change, `intloop` had equal threaded instruction
  counts in two layouts but minima of 1,199.4M and 1,225.7M cycles, versus
  1,191.5M for switch. The compiler placed several arithmetic handlers at
  different addresses; that is evidence of a layout-sensitive difference, not
  proof of its exact cause.
* A later 982-sample profile attributed 37.3% to `ADD`, 20.6% to `IDIVK`,
  17.4% to `FORLOOP` and 9.9% to `MODK`. Disassembly showed `IDIVK` and `MODK`
  copied the whole context even for successful arithmetic. `raw_arith_to` is
  already contextless and reports division by zero as a status. The new handlers
  keep the original saved-PC/top updates and send only zero-divisor errors to a
  no-inline helper with the original context. In seven alternating runs
  `intloop` improved from 6,661.6 / 1,230.9 to 6,101.6 / 1,135.0, versus
  switch at 6,601.6 / 1,195.6.
  The layout change made `add` move from 136.6 / 26.6 to 136.6 / 27.5, still
  below switch's 154.6 / 28.8. The `il`, native-call and float-loop wins remained.
* Before the constant-division change, `strconcat` measured 406.5M switch versus
  441.1M threaded cycles. In 14 additional alternating runs the minima were
  456.8M and 488.6M, with medians 487.0M and 504.5M; the ranges overlap.
  The threaded `CONCAT` handler copies the context and spills VM state, but
  numeric coercion, allocation, GC and metamethods require an ordinary context.
  The 460-sample threaded profile was dominated by allocation, string interning
  and GC rather than the handler alone. No safe, measured replacement was retained.
* `tablechurn` uses both integer arrays and string hashes. Its threaded profile
  had 4,906 samples, led by string interning (26.9%), `GETTABLE` (10.8%),
  allocation and numeric conversion. In 14 alternating runs switch/threaded
  minima were 5,926.8M / 6,032.0M cycles, but medians were 6,153.2M / 6,148.6M.
  These results do not isolate a reliable dispatch regression from allocation
  and hash-layout variation.

After the constant-division change, 14 more alternating switch/threaded runs
gave `strconcat` minima of 408.6M / 438.5M and medians of 457.8M / 483.8M
cycles; its ranges were 408.6–905.8M / 438.5–910.1M. `closures` minima were
1,062.6M / 1,087.5M and medians 1,087.5M / 1,100.6M. `strpattern` minima were
1,032.4M / 1,044.0M and medians 1,091.1M / 1,071.6M. Fresh-string hash minima
were 1,556.8M / 1,776.8M and medians 2,160.4M / 2,203.9M; `tablechurn` minima
were 5,934.1M / 5,964.8M and medians 6,606.9M / 6,439.1M. These heavily loaded
ranges overlap and do not establish that the smaller differences are resolved.

Seven alternating runs before/after that change retained the existing wins:
for example, `gtab` minima were 45.6M / 46.3M cycles, `calls` 5,318.5M /
5,336.0M, and `tablesort` 1,525.0M / 1,505.2M. Their instruction counts were
unchanged apart from hash-seed variation. The `add` probe's small layout-related
cost is recorded above rather than hidden in the full-table minima.

### Earlier experiments

These are separate seven-run alternating comparisons; each pair is a different
step, not a comparison across dates. Values are instructions / cycles in
millions. Some improvements trade a small cost on other paths for a larger win;
the complete table above is needed to evaluate them.

* Contextless global/field hits with the original context on the miss reduced
  `gtab` from 318.7 / 62.6 to 248.7 / 45.6. A first generic `SELF` check was
  dropped: string method calls increased from 882.7 / 173.9 to 900.7 / 178.8.
* The variable-key read fast path reduced `array_insert` from 874.6 / 172.1 to
  835.6 / 157.6. The integer-key, non-collectable write fast path then reduced it
  from 835.6 / 157.9 to 766.6 / 142.9. Hash-key writes can pay extra dispatch;
  a more general write variant was measured and dropped.
* Inline Lua-closure call setup reduced `call1` from 556.7 / 132.7 to
  474.7 / 121.2. Native fallback initially got more expensive; specializing native
  frame setup and the common zero/one-result return later reduced `ncall` from
  496.7 / 105.8 to 422.7 / 80.3 and `math_transcend` from 1,474.1 / 341.1 to
  1,381.1 / 286.6. `RETURN0` and `RETURN1` already had inline fast paths in the
  prototype and were retained.
* Deriving constants from the closure rather than carrying them between
  handlers reduced `call1` from 482.7 to 476.7 instructions and `array_insert`
  from 766.6 / 145.1 to 751.6 / 139.8. The original context pointer remains
  necessary for cold paths and the embedding contract.
* A string method hit in a table-valued `__index` reduced `self` from
  832.7 / 171.6 to 698.7 / 141.6, while preserving the original non-table
  saved-PC and stack-top updates. The native-call change subsequently brought
  the combined result to 624.7 / 121.6 in a separate comparison.
* Moving the whole closure-allocation operation into a contextless wrapper was
  tried and dropped: `closures` increased from 4,205.8 / 1,097.5 to
  4,241.8 / 1,107.2. Allocation still needs the original context; this wrapper
  did not reduce the overall cost.
* Threaded-only declarations in `vm.odin` changed the switch binary's code
  placement. On `move`, 14 alternating runs had a 35.7M-cycle switch median,
  versus 24.8M on master. Moving those helpers into `vm_threaded_fast.odin`
  restored a 24.9M median and 24.6M minimum, versus master at 24.8M and 24.5M;
  the threaded instruction counts were unchanged. The full table still does
  not prove no switch regression across every workload. The prototype-switch
  and final-switch executable `.text` sections are byte-identical in these
  builds (SHA-256 `d8ec9a0414fba637f7492930a2cd67a231cfaede3054cbfe68b4356e232c7a5d`);
  Master was built from a separate source archive and its `.text` differs; the
  difference remained when master and prototype were built from the same scratch
  source path.
* Splitting the generated region into a second file was also tried in a scratch
  build. It still did not reproduce master `.text` and its timing effects were
  mixed: in seven alternating runs `strconcat` fell from 408.0M to 404.0M
  minimum cycles, but `intloop` median rose from 964.1M to 966.0M. It was not
  kept without a demonstrated broad benefit to justify changing the generator.

A follow-up of 14 alternating master, prototype-switch and final-switch runs
illustrates the timing uncertainty. For `strconcat`, master/final minima were
411.2M / 417.8M cycles while medians were 433.3M / 426.4M. For
`tostring_float`, minima were 285.8M / 285.5M and medians 291.2M / 289.5M.
For `self`, minima were 160.0M / 160.7M and medians 170.3M / 165.6M. These
follow-ups do not establish that the switch is no slower on every workload.

A cycle profile of an earlier threaded `closures` build had 879 samples; heap
allocator procedures and frame entry accounted for substantial portions of
the samples. That points to work beyond the closure opcode itself, but is not
proof of an inherent limit to this dispatch design.

In the follow-up binaries, `nm -S` reports 33,889 bytes for switch `vm_execute`
plus a 512-byte relative jump table. Threaded handler, entry, trace, poll and
threaded-helper symbols total 45,419 bytes, plus a 1,024-byte address table.
GNU `size` reports text totals of 876,856 versus 895,132 bytes and data of
62,936 versus 63,960 bytes. Reference `luaV_execute` is 15,905 bytes and its
`size` text total is 283,206 bytes. These are rough comparisons because inlining
and helper boundaries differ.

Linux x86-64 is the only runtime-tested platform in this work. Windows x64,
Linux arm64 and macOS arm64 were type-checked and cross-compiled; their MOVE
handlers were inspected to confirm indirect tail jumps, not executed. The
freestanding amd64 Win64 and arm64 objects were also cross-compiled and their
MOVE handlers inspected; no freestanding object was run. The generator is now an
Odin tool; its guarded rewrites and the duplicated fast paths still require review
whenever the guarded source changes. See Decision 2 in `docs/ARCHITECTURE.md`.

On Linux x86-64, both interpreter modes passed all 314 normal and single-threaded
Odin tests, the relocation-plus-AddressSanitizer tests, and the PUC-Rio suite in
normal, relocation, and relocation-plus-AddressSanitizer modes (`final OK !!!`
in each). CLI tests passed 31/31, including SIGINT during the empty numeric loop
and byte comparison with reference `luac`; rebranding passed 11/11. The ordinary
threaded AddressSanitizer run also passed all 314 tests and exercised the native
call fast path, which relocation mode routes through the original helper.
