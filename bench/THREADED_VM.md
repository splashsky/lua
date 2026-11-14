# Threaded VM measurements

The experimental interpreter is now broadly faster, but **is not ready to be
the default**. In these measurements the empty loop, string patterns and
closures still take more cycles than the switch VM. Some results, especially
allocation and I/O, are noisy. The switch-versus-master cycle results also do
not establish the requested no-regression gate for every workload. Keep the
switch as the default until those regressions and measurement uncertainties are
resolved and the other targets have been exercised at runtime.

Not every helper was converted: `GETI`, `SETI`, `SETFIELD`, arithmetic,
comparison, and concatenation still use their existing paths where applicable.
The experiment does not establish that the remaining regressions are inherent
to threaded dispatch.

## Method

Measured on 2026-11-14 on an AMD Ryzen 9 7950X, Linux x86-64, Odin
`dev-2026-11-nightly:9a69916`, with `-o:speed` PIE builds. Reference is Lua
5.5.1 from `/tmp/opencode/refbuild/src/lua`; master is commit `6f13068` built
from an unmodified source archive. Each row runs in a fresh process, with seven
rotating runs of master, switch, threaded and reference. `perf stat -x, -e
instructions:u,cycles:u` records user-space events. The minimum instructions
and cycles are reported independently, in **millions**. Harness names run in
isolation, as described in `bench/README.md`; the probe files under
`/tmp/opencode/inv` were not modified.

The machine was heavily loaded. A server restart interrupted the measurement
driver between rows; its original process continued while the resumed driver
measured some remaining rows too. Each result below still has seven alternating
runs, but that overlap adds load and makes small cycle differences particularly
uncertain. Instruction counts for hash and I/O workloads can also vary with
string hash seeds. The table is evidence of the remaining regressions, not a
proof that a small timing difference will reproduce on an idle machine.

| Workload | Master instructions / cycles | Switch instructions / cycles | Threaded instructions / cycles | Reference instructions / cycles |
|---|---:|---:|---:|---:|
| probe/empty | 74.7 / 19.5 | 74.7 / 19.6 | 66.7 / 21.6 | 56.6 / 17.4 |
| probe/move | 120.7 / 24.6 | 120.7 / 24.7 | 104.7 / 24.4 | 96.6 / 24.7 |
| probe/add | 154.7 / 28.7 | 154.7 / 28.8 | 136.7 / 26.5 | 120.6 / 30.2 |
| probe/gtab | 286.7 / 55.2 | 286.7 / 55.5 | 246.7 / 46.1 | 174.6 / 42.4 |
| probe/call0 | 492.7 / 147.7 | 492.7 / 126.0 | 434.7 / 109.0 | 344.6 / 83.5 |
| probe/call1 | 540.7 / 133.5 | 540.7 / 133.4 | 476.7 / 121.6 | 388.6 / 89.5 |
| probe/callr | 600.7 / 145.4 | 600.7 / 145.7 | 532.7 / 131.6 | 448.6 / 103.1 |
| probe/ncall | 492.7 / 99.6 | 492.7 / 99.2 | 422.7 / 79.8 | 436.6 / 100.0 |
| probe/self | 810.7 / 162.8 | 810.7 / 166.1 | 624.7 / 123.0 | 662.6 / 139.0 |
| probe/il | 5,000.7 / 953.7 | 5,000.7 / 969.0 | 4,350.7 / 834.4 | 4,000.6 / 826.5 |
| probe/calls | 30,871.1 / 6,355.5 | 30,671.1 / 6,321.1 | 26,711.1 / 5,427.5 | 25,890.9 / 6,044.0 |
| probe/w1 | 14,696.0 / 2,891.4 | 14,746.0 / 2,924.3 | 14,236.0 / 2,781.6 | 12,561.1 / 2,746.2 |
| probe/iobench | 9,536.0 / 1,939.8 | 9,536.0 / 1,947.2 | 9,501.3 / 1,920.4 | 8,011.9 / 1,757.5 |
| micro/fib(32) | 2,299.7 / 591.0 | 2,299.7 / 592.8 | 2,225.7 / 548.6 | 1,640.4 / 401.3 |
| micro/intloop | 6,601.7 / 1,242.6 | 6,601.7 / 1,232.4 | 6,661.7 / 1,225.5 | 4,952.9 / 964.1 |
| micro/floatloop | 9,067.5 / 2,432.4 | 9,067.5 / 2,434.2 | 8,157.5 / 2,335.8 | 7,216.9 / 1,733.1 |
| micro/strconcat | 913.1 / 498.2 | 913.1 / 536.2 | 924.5 / 522.0 | 879.9 / 364.6 |
| micro/strpattern | 5,209.7 / 1,031.6 | 5,209.7 / 1,038.2 | 5,302.5 / 1,057.7 | 3,803.5 / 1,066.8 |
| micro/tablechurn | 4,873.9 / 6,603.7 | 4,873.5 / 6,600.5 | 4,967.8 / 6,582.1 | 4,812.4 / 6,254.4 |
| micro/tablesort | 6,836.4 / 1,616.3 | 6,836.4 / 1,615.5 | 6,164.1 / 1,508.6 | 4,523.2 / 1,245.7 |
| micro/closures | 4,232.0 / 1,289.3 | 4,232.0 / 1,298.5 | 4,205.8 / 1,437.0 | 3,026.5 / 877.6 |
| tables/array_insert | 739.6 / 154.3 | 739.6 / 157.3 | 751.6 / 143.0 | 572.5 / 126.4 |
| tables/hash_strkey | 1,364.3 / 1,881.7 | 1,364.2 / 1,802.3 | 1,388.3 / 1,855.8 | 1,287.7 / 1,561.4 |
| tables/hash_prekey | 1,107.1 / 1,241.1 | 1,107.0 / 1,197.8 | 1,147.2 / 1,187.4 | 972.0 / 777.8 |
| tables/tablesort | 1,908.5 / 450.6 | 1,908.5 / 452.1 | 1,722.3 / 418.7 | 1,266.2 / 350.5 |
| stdlib/tostring_float | 1,170.6 / 293.2 | 1,170.7 / 330.4 | 1,161.7 / 316.1 | 3,194.8 / 821.9 |
| stdlib/tonumber_float | 574.1 / 108.9 | 574.1 / 110.3 | 558.1 / 104.4 | 714.0 / 150.2 |
| stdlib/string_format | 1,467.6 / 370.0 | 1,468.0 / 351.9 | 1,449.1 / 322.9 | 2,350.4 / 623.2 |
| stdlib/format_int | 911.0 / 227.9 | 911.0 / 219.2 | 891.4 / 221.9 | 797.4 / 191.5 |
| stdlib/math_transcend | 1,488.0 / 319.4 | 1,488.0 / 307.3 | 1,381.0 / 292.6 | 1,228.7 / 297.1 |
| stdlib/file_lines | 895.0 / 291.0 | 895.0 / 319.3 | 896.0 / 298.6 | 706.5 / 160.1 |
| stdlib/os_date | 706.2 / 165.9 | 706.9 / 166.6 | 701.3 / 162.7 | 692.1 / 207.5 |

## Experiments

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

In the final binaries, `nm -S` reports 33,889 bytes for switch `vm_execute`
plus a 512-byte relative jump table. Threaded handler, entry, trace, poll and
threaded-helper symbols total 45,523 bytes, plus a 1,024-byte address table.
Executable text is 876,856 versus 895,140 bytes; data is 62,936 versus 63,960
bytes. Reference `luaV_execute` is 15,905 bytes and reference executable text is
283,206 bytes. These symbol sizes are only rough comparisons because inlining
and helper boundaries differ.

Linux x86-64 is the only runtime-tested platform in this work. Windows x64,
Linux arm64 and macOS arm64 were type-checked and cross-compiled; their MOVE
handlers were inspected to confirm indirect tail jumps, not executed. The
freestanding amd64 Win64 and arm64 objects were also cross-compiled and their
MOVE handlers inspected; no freestanding object was run. The generator is now an
Odin tool; its guarded rewrites and the duplicated fast paths still require review
whenever the guarded source changes. See Decision 2 in `docs/ARCHITECTURE.md`.

On Linux x86-64, both interpreter modes passed the normal and single-threaded
Odin tests, the relocation-plus-AddressSanitizer tests, and the PUC-Rio suite in
normal, relocation, and relocation-plus-AddressSanitizer modes. The CLI and
rebranding checks also passed. The ordinary threaded AddressSanitizer run was
additionally used to exercise the native-call fast path, which relocation test
mode intentionally routes through the original helper.
