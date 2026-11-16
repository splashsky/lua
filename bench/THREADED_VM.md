# Threaded VM measurements

> **Status (November 2026):** threaded dispatch is the default on amd64 and
> arm64. The switch is retained as the handler source, as an explicit opt-out,
> and as the automatic choice elsewhere. Runtime validation is Linux x86-64
> only; Windows x64, Linux arm64 and macOS arm64 were cross-compiled to objects
> but not run by the user's decision. The remaining work is in
> [docs/FUTURE_WORK.md](../docs/FUTURE_WORK.md).

Default-mode object builds succeeded for Linux arm64, Windows x64, macOS arm64,
and freestanding amd64 SysV, amd64 Win64 and arm64. The generated `MOVE`
handler ends in an indirect `jmp` on amd64 and `br` on arm64 in those objects.
Inspecting the object code is not runtime validation.

## Current comparison: 2026-11-15

On an AMD Ryzen 9 7950X, Linux x86-64, Odin `dev-2026-11-nightly:9a69916`,
`REFLUA=/tmp/opencode/refbuild/src/lua CPU=12 bash build/vm-compare.sh 5` builds
both `-o:speed` PIE modes explicitly and rotates them with reference Lua 5.5.1
(`-O2`). The source is 368b850 plus the default flip c9db250. The explicit
threaded build is byte-identical in `.text` to the unset
default on this host. Each isolated workload starts a fresh process; counts
from `perf stat -e instructions:u,cycles:u` include startup and harness setup.
The local-time probe used `TZ` unset, with `/etc/localtime` pointing to
`America/Chicago`.

Immediately before the run, a five-second sample found CPU 12 / sibling 28 at
0.2% / 0.4% utilization; the load average was 15.21. Other work and the PUC
stress/ASan matrix were active during the comparison. Cycles are **approximate**
and small differences need a quiet-machine rerun. Instruction counts are the
primary evidence, but randomized hashes, GC and temporary-file I/O can vary.

Each cell is **minimum/median instructions; minimum/median cycles**, in millions.
The two counters are summarized independently.

| Workload | Default threaded | Switch | Reference |
|---|---:|---:|---:|
| micro/fib(32) | 2063.4/2063.4; 502.5/503.6 | 2074.0/2074.0; 542.2/548.6 | 1640.5/1640.5; 426.0/431.4 |
| micro/intloop | 6101.5/6101.6; 1086.0/1089.4 | 6461.6/6461.6; 1150.1/1151.0 | 4952.9/4952.9; 961.6/961.8 |
| micro/floatloop | 8117.4/8117.4; 2291.1/2299.0 | 8857.4/8857.4; 2357.9/2375.4 | 7217.0/7217.0; 1755.5/1792.1 |
| micro/strconcat | 657.7/657.7; 291.4/294.8 | 673.4/673.4; 292.8/294.9 | 880.0/880.0; 292.1/294.4 |
| micro/strpattern | 5094.6/5094.6; 1026.6/1048.9 | 5129.8/5129.8; 998.8/1010.9 | 3803.6/3803.6; 1180.5/1192.1 |
| micro/tablechurn | 3751.9/3752.3; 3813.0/4056.2 | 3914.0/3914.4; 3759.4/3910.4 | 4812.5/4813.0; 4532.6/4730.0 |
| micro/tablesort | 6167.9/6167.9; 1521.1/1537.6 | 6827.2/6837.2; 1603.8/1639.9 | 4523.3/4523.3; 1234.1/1290.1 |
| micro/closures | 3015.5/3015.5; 884.2/978.2 | 2985.5/2985.5; 714.5/975.1 | 3024.7/3026.6; 797.9/930.5 |
| tables/array_insert | 649.5/649.5; 127.2/127.9 | 724.5/724.5; 141.9/142.7 | 572.5/572.5; 122.9/123.5 |
| tables/hash_strkey | 1025.8/1026.1; 732.2/802.0 | 1053.9/1053.9; 725.5/833.2 | 1287.9/1288.1; 780.8/884.2 |
| tables/hash_prekey | 877.1/877.2; 458.5/467.7 | 893.1/893.3; 448.9/453.8 | 972.0/972.2; 465.3/482.9 |
| tables/tablesort | 1720.4/1723.4; 422.7/425.8 | 1905.7/1905.7; 445.3/450.1 | 1266.3/1269.0; 341.4/346.0 |
| stdlib/tostring_float | 1093.7/1097.7; 261.8/263.0 | 1126.5/1130.7; 266.7/267.8 | 3194.5/3194.9; 770.8/774.1 |
| stdlib/tonumber_float | 545.6/545.6; 104.3/104.4 | 568.8/568.8; 111.5/112.1 | 714.2/717.8; 150.7/151.1 |
| stdlib/string_format | 1325.9/1326.3; 292.9/293.5 | 1348.9/1350.7; 309.8/311.8 | 2350.6/2352.8; 642.8/645.2 |
| stdlib/format_int | 675.0/675.0; 153.2/153.3 | 707.8/707.8; 159.5/163.0 | 799.4/799.5; 214.8/214.8 |
| stdlib/math_transcend | 1359.9/1359.9; 281.8/282.8 | 1457.9/1457.9; 298.9/307.5 | 1228.9/1228.9; 291.9/293.9 |
| stdlib/file_lines | 770.1/772.1; 201.6/203.5 | 767.1/769.0; 199.9/201.9 | 708.0/712.7; 162.9/164.5 |
| stdlib/os_date | 667.6/668.3; 151.0/153.6 | 675.8/676.5; 153.1/155.4 | 692.3/692.5; 214.3/227.9 |
| scaling/scale_12500 | 32.3/32.3; 12.8/12.9 | 32.4/32.4; 12.8/12.8 | 37.1/37.1; 13.9/14.0 |
| scaling/scale_25000 | 62.4/62.4; 24.0/24.4 | 62.7/62.7; 24.0/24.1 | 71.8/71.8; 26.1/26.3 |
| scaling/scale_50000 | 125.8/125.8; 51.3/51.7 | 126.5/126.5; 51.5/51.6 | 145.1/145.1; 55.4/55.6 |
| scaling/scale_100000 | 255.1/255.2; 106.9/108.4 | 256.4/256.4; 108.0/108.3 | 285.3/285.5; 112.0/112.9 |
| probe/add | 136.7/136.7; 27.5/27.7 | 150.7/150.7; 28.3/28.4 | 120.6/120.6; 30.0/30.4 |
| probe/call0 | 394.7/394.7; 101.8/102.0 | 434.7/434.7; 110.7/110.9 | 344.6/344.6; 83.4/85.4 |
| probe/call1 | 434.7/434.7; 112.8/113.6 | 480.7/480.7; 129.4/130.3 | 388.6/388.7; 89.9/90.4 |
| probe/callr | 488.7/488.7; 120.3/121.7 | 538.7/538.7; 134.1/134.9 | 448.7/448.7; 102.7/103.1 |
| probe/calls | 26161.0/26211.0; 5210.8/5280.7 | 29401.0/29501.0; 6116.3/6172.9 | 25891.0/25891.0; 6683.9/7008.3 |
| probe/empty | 66.7/66.7; 19.5/19.9 | 72.7/72.7; 21.6/21.9 | 56.6/56.6; 17.6/17.8 |
| probe/getenv | 2496.7/2516.7; 669.2/688.6 | 2602.7/2602.7; 686.9/692.5 | 1032.6/1032.6; 236.7/237.1 |
| probe/gtab | 246.7/246.7; 44.0/44.5 | 282.7/282.7; 55.4/55.7 | 174.6/192.6; 41.5/49.3 |
| probe/il | 4350.7/4350.7; 819.7/824.1 | 4850.7/4850.7; 901.0/901.0 | 4000.6/4000.6; 820.7/822.4 |
| probe/iobench | 9267.0/9289.0; 1867.5/2487.1 | 9249.1/9249.2; 1831.3/2529.4 | 8012.0/8012.0; 1900.3/2394.0 |
| probe/move | 104.7/104.7; 24.6/26.8 | 116.7/116.7; 24.9/33.1 | 96.6/96.6; 25.4/30.5 |
| probe/ncall | 420.7/420.7; 77.7/78.4 | 476.7/476.7; 90.1/90.5 | 436.6/436.6; 105.3/105.7 |
| probe/os_date | 67113.7/67127.7; 16568.9/16829.7 | 67240.7/67273.7; 17085.5/19234.2 | 20788.4/20788.4; 5136.1/5397.7 |
| probe/self | 622.7/622.7; 152.4/156.8 | 798.7/818.7; 171.6/215.3 | 662.6/680.6; 145.0/202.6 |
| probe/w1 | 14076.0/14176.0; 2749.7/2901.8 | 14451.0/14501.0; 2871.3/3938.9 | 12561.2/12561.2; 3012.6/3606.0 |

The default's median instructions exceed switch on `closures` (+1.0%),
`file_lines` (+0.4%) and `iobench` (+0.4%). Their cycle comparisons, especially
closure and I/O results, are noisy. On the `gtab` probe the reference varied
from 174.6M minimum to 192.6M median instructions with the randomized hash seed.

## Binary and symbol sizes

For Linux x86-64 `-o:speed` PIE builds of the current source, GNU `size`
reports text/data of 898,151/63,864 bytes for threaded, 874,310/62,840 for
switch, and 283,206/6,216 for reference Lua 5.5.1. The unset-default and explicit
`-define:VM_THREADED=true` builds have byte-identical `.text`. `nm -S` reports:

| Symbol group | Bytes |
|---|---:|
| Switch `kernel::vm_execute` | 32,377 |
| Threaded 85 opcode-named handler symbols | 40,520 |
| Other threaded entry, slow-path and helper text symbols | 8,744 |
| All 112 `kernel::vm_thread_*` text symbols | 49,264 |
| Threaded handler-address table | 1,024 |
| Reference `luaV_execute` | 15,905 |

The threaded groups are the `nm -S` text symbols with the `vm_thread_` prefix;
opcode-named symbols end in uppercase opcode names. These are approximate code
comparisons, since inlining and helper boundaries differ between interpreters.

## Changes since the historical table

The threaded call path adopted the switch's frame-setup pass (ab67c21), then
split interrupt and hook work off the common returns (83c1cc1). In the latter's
measurements, `call1` fell from 454.5M to 434.5M instructions, versus 480.5M
switch; `fib(32)` fell from 2,147.9M to 2,070.3M, versus 2,073.9M switch.

The upvalue handlers now reuse the carried closure (fcc8aac). The table paths
use the carried base, contextless pre-sets where safe and cold tail transitions
for reads (d9e7d6a, 9b6289c, 0c5f0da, 103258a, fa6baa9). d025cdc added a
contextless common concat path with original-context slow callouts. In that
change's three-run medians `strconcat` fell from 683.25M to 657.54M instructions
against 673.24M switch, while `tablechurn` fell from 3,890.17M to 3,751.79M
against 3,914.60M switch. These are historical before/after comparisons, not a
replacement for the current comparison above.

Conversion is selective, not universal: current generated `GETI`, `SETI` and
`SETFIELD` still establish the original context and call the ordinary helpers;
register-operand `MOD` and `IDIV` use the ordinary arithmetic path, and
comparisons retain their existing context and fallback paths. Unlike the old
concat description, the common `CONCAT` path now uses `vm_thread_concat_run`.
See Decision 2 in `docs/ARCHITECTURE.md` for the safety boundaries.

## Historical results: 2026-11-14, before the allocation and call passes

The following table and experiments describe earlier builds, before the allocation
pass (1055a5c, 2dc564b), the call pass and its threaded port (68f45c9, 3e82229,
ab67c21, 83c1cc1), and the later table, upvalue and concat improvements. They
are retained as experiment history, not as the performance of today's default.
In particular, the prior concat context-copy bottleneck was addressed by
d025cdc. Its contextless common path retains the original-context slow callouts.

### Historical method

Measured on 2026-11-14 on an AMD Ryzen 9 7950X, Linux x86-64, Odin
`dev-2026-11-nightly:9a69916`, with `-o:speed` PIE builds. Reference is Lua
5.5.1 from `/tmp/opencode/refbuild/src/lua`. Each row runs in a fresh process,
with 15 rotating runs per interpreter and one measurement driver at a time.
`perf stat -x, -e instructions:u,cycles:u` includes process startup and harness
setup. Each cell reports **minimum/median cycles; minimum/median instructions**,
independently, in **millions**. Harness names run in isolation as described in
`bench/README.md`; the probe files under `/tmp/opencode/inv` were not modified.
Profiles used `perf record -e cycles:u -g --user-callchains`; the empty-loop
profile loaded the probe once and ran it 100 times to obtain enough samples.

Core 12 and its SMT sibling were idle in the samples taken before the drivers;
all measured processes were pinned to core 12. Before the final batch `uptime`
reported a 6.22 load average; a five-second sample measured 0.2% on core 12 and
0.4% on its sibling. During a ten-second sample in that batch, the measured
process used 96.8% of core 12 while its sibling used 0.2%. A PUC relocation/ASan
run was active on another core during some measurements, and other activity was
present. Hash seeds, GC, allocation and I/O also add variation. In particular,
overlapping ranges do not settle small differences in the table workloads. A
later burst of activity made some formatting timings especially noisy; another
measurement workload was active after the tests, so no competing driver was run.

In a separate 15-run master-versus-switch instruction comparison, master was
commit `6f13068` from an unmodified source archive. The switch did not show an
instruction regression on any probe. `self` ranges were 810.8–870.8M master and
810.8–850.8M switch; `w1` ranges were 14,696.2–14,946.2M for both. `calls`
ranges were 30,871.2–31,171.2M master and 30,671.2–30,821.2M switch. Those
method/hash-sensitive distributions vary with the seed. Non-hash probes matched
to startup variation. The switch `.text` was unchanged by the loop experiment.

| Workload | Switch cycles; instructions | Threaded cycles; instructions | Reference cycles; instructions |
|---|---:|---:|---:|
| probe/empty | 19.6/20.1; 74.8/74.8 | 19.9/20.2; 66.8/66.8 | 17.4/17.9; 56.7/56.7 |
| probe/move | 24.7/24.9; 120.8/120.8 | 24.6/24.7; 104.8/104.8 | 25.0/25.4; 96.7/96.7 |
| probe/add | 28.8/28.9; 154.8/154.8 | 27.2/27.8; 136.8/136.8 | 29.9/30.4; 120.7/120.7 |
| probe/gtab | 54.9/55.3; 286.8/286.8 | 44.9/48.7; 246.8/246.8 | 42.7/43.4; 174.7/174.7 |
| probe/call0 | 124.6/126.0; 492.8/492.8 | 99.0/104.6; 418.8/418.8 | 82.7/85.1; 344.7/344.7 |
| probe/call1 | 132.5/132.9; 540.8/540.8 | 117.1/117.8; 460.8/460.8 | 89.3/90.2; 388.7/388.7 |
| probe/callr | 143.7/144.8; 600.8/600.8 | 127.5/128.4; 516.8/516.8 | 103.2/104.2; 448.7/448.7 |
| probe/ncall | 100.8/101.0; 492.8/492.8 | 78.6/79.0; 422.8/422.8 | 104.7/104.9; 436.7/436.7 |
| probe/self | 159.8/162.3; 810.8/810.8 | 120.6/131.4; 624.8/644.8 | 147.8/150.4; 662.7/662.7 |
| probe/il | 951.3/953.0; 5,000.8/5,000.8 | 819.0/823.1; 4,350.8/4,350.8 | 814.9/824.1; 4,000.7/4,000.7 |
| probe/calls | 6,408.9/6,478.0; 30,671.2/30,671.2 | 5,337.1/5,493.9; 26,631.2/26,731.2 | 6,765.4/6,935.4; 25,891.1/25,891.1 |
| probe/w1 | 2,864.5/2,936.0; 14,696.2/14,746.2 | 2,758.8/2,828.2; 14,236.2/14,336.2 | 2,937.9/2,991.5; 12,291.3/12,606.3 |
| probe/iobench | 1,925.3/1,967.6; 9,536.1/9,580.1 | 1,922.1/1,945.0; 9,501.4/9,501.4 | 1,832.8/1,921.7; 7,818.6/8,012.0 |
| micro/fib(32) | 598.8/601.9; 2,299.9/2,299.9 | 534.9/538.6; 2,169.5/2,169.5 | 427.1/437.5; 1,640.5/1,640.5 |
| micro/intloop | 1,201.5/1,212.8; 6,601.8/6,601.8 | 1,122.0/1,129.2; 6,101.8/6,101.8 | 961.8/968.0; 4,953.0/4,953.0 |
| micro/floatloop | 2,406.2/2,425.1; 9,067.7/9,067.7 | 2,326.0/2,344.0; 8,157.7/8,157.7 | 1,742.2/1,797.1; 7,217.0/7,217.0 |
| micro/strconcat | 380.9/394.6; 913.2/913.2 | 390.8/407.6; 924.5/924.6 | 296.3/300.9; 880.1/880.1 |
| micro/strpattern | 1,028.8/1,045.4; 5,209.8/5,209.8 | 1,029.8/1,049.9; 5,165.0/5,165.0 | 1,099.1/1,187.3; 3,803.6/3,803.6 |
| micro/tablechurn | 4,688.7/5,097.2; 4,873.5/4,874.4 | 4,627.3/5,077.8; 4,967.8/4,968.4 | 4,713.3/5,035.0; 4,812.6/4,813.2 |
| micro/tablesort | 1,603.8/1,615.2; 6,836.5/6,846.5 | 1,502.9/1,514.5; 6,164.2/6,174.2 | 1,232.0/1,252.0; 4,523.3/4,523.3 |
| micro/closures | 1,085.6/1,105.6; 4,229.3/4,229.3 | 1,092.4/1,103.5; 4,171.2/4,171.2 | 690.7/699.5; 3,028.8/3,028.8 |
| tables/array_insert | 153.1/154.1; 739.7/739.7 | 138.0/138.8; 751.7/751.7 | 122.8/122.9; 572.6/572.6 |
| tables/hash_strkey | 1,029.4/1,074.9; 1,364.3/1,364.5 | 1,022.8/1,114.4; 1,388.5/1,388.7 | 769.6/873.9; 1,288.0/1,288.3 |
| tables/hash_prekey | 603.2/643.7; 1,108.2/1,108.5 | 614.3/631.7; 1,148.2/1,148.5 | 452.5/476.1; 972.1/972.4 |
| tables/tablesort | 445.3/449.5; 1,908.6/1,911.6 | 415.7/420.7; 1,722.5/1,722.5 | 340.9/347.6; 1,266.3/1,269.0 |
| stdlib/tostring_float | 284.3/292.9; 1,170.8/1,171.0 | 279.8/295.1; 1,144.8/1,144.9 | 782.7/982.1; 3,196.0/3,198.0 |
| stdlib/tonumber_float | 132.0/170.2; 574.3/574.3 | 116.1/161.3; 558.3/558.3 | 189.4/223.5; 714.2/714.2 |
| stdlib/string_format | 349.7/355.0; 1,468.2/1,470.2 | 345.2/400.6; 1,442.6/1,445.0 | 638.4/937.4; 2,350.5/2,354.2 |
| stdlib/format_int | 217.3/221.9; 911.4/911.4 | 211.5/215.8; 874.6/878.6 | 200.6/205.0; 797.3/798.0 |
| stdlib/math_transcend | 303.6/306.0; 1,488.2/1,488.2 | 281.1/283.4; 1,366.2/1,366.2 | 293.4/295.7; 1,228.9/1,228.9 |
| stdlib/file_lines | 245.7/251.9; 896.1/896.1 | 244.8/249.5; 897.1/897.1 | 161.5/165.7; 707.1/713.9 |
| stdlib/os_date | 164.0/167.4; 707.2/707.9 | 158.6/162.0; 698.0/698.7 | 227.0/228.5; 692.1/692.2 |

GNU `size` reports text/data of 876,856/62,936 bytes for switch,
895,172/63,960 for threaded, and 283,206/6,216 for reference. `nm -S` reports
33,889 bytes for switch `vm_execute`, 45,474 bytes for threaded handlers and
helpers, and 15,905 bytes for reference `luaV_execute`; the threaded address
table is 1,024 bytes. These comparisons are approximate because helper and
inlining boundaries differ.

## Historical experiments

### Integer back edge and costs at that time

In 15 rotating runs, the original threaded integer loop had an empty-probe
minimum/median of 21.51/21.74M cycles. Fetching the next instruction earlier on
every integer back edge reduced that to 19.59/20.09M, versus switch at
19.78/20.16M. Instructions were unchanged at 66.81M threaded and 74.81M switch.
The same change improved `il` from 826.14/827.17M to 819.84/821.57M cycles and
`intloop` from 1,133.21/1,137.33M to 1,124.07/1,128.19M. Integer numeric loops
with bodies are common Lua code; no opcode or body shape is recognized. The
register updates and interrupt poll still happen at the same edge. If a poll or
trace is needed, it discards the early read and fetches normally.

The original x86-64 handler had no actual context copy on its integer path.
Its back edge decodes the target from the current instruction, fetches the next
instruction and uses it to index the handler table. A 418-sample cycle profile
of repeated empty loops attributed 99.75% to `FORLOOP`; samples can land a few
instructions late, so they do not pinpoint the delay. In 15 runs, switch and
threaded each had a median of about 11,000 branch misses and 15,000 L1-load
misses, so neither kind of miss alone explains the difference. Earlier fetch
moves the instruction load ahead of loop-register stores in the generated
x86-64 code; the result does not prove which dependency was limiting throughput.

Other 15-run comparisons kept the existing wins: for example old/new `ncall`
minima/medians were 79.48/79.66 and 78.55/78.83M cycles, `calls` were
5,367.60/5,449.30 and 5,339.31/5,399.58M, and `tablesort` were
1,503.51/1,515.07 and 1,503.09/1,508.87M. `fib` minima were 536.83/536.65M,
while medians were 544.99/553.23M and ranges overlapped substantially; that
small median difference remains uncertain. Instruction counts were unchanged
apart from hash-seed variation.

`strconcat` builds each result from two strings and two numbers, so an
all-string-only shortcut would not address this workload. A 206-sample
threaded profile was led by the heap allocator (25.5%), string interning
(10.9%), freeing (9.3%), string-table resizing (7.4%) and GC marking (6.8%);
`vm_concat` itself accounted for 4.2%, excluding its callees. Its handler then
copied the activation context. A shared-helper experiment inlined the string
check and moved numeric conversion out of line. It reduced instructions from
913.16M to 902.15M in switch and from 924.56M to 913.95M in threaded, but
switch minima/medians were 366.24/379.73M before and 372.64/381.16M after,
while threaded closures got slower in that comparison. Code placement changed.
It was dropped without a reliable broad win; the later d025cdc change addressed
the common concat path differently.

The closure workload allocates both a closure and an upvalue on each iteration.
A 221-sample threaded profile attributed 3.3% to `CLOSURE`, 9.5% to frame
entry, and substantial time to the allocator stack. A 440-sample switch profile
was also dominated by the allocator and `vm_execute`. The handler still copies
the context and spills around allocations; an emergency collection can make a
newly anchored closure black before its upvalues are wired, so the existing
barrier cannot simply be omitted. No measured safe replacement was retained.

The initial 15-run table-churn switch/threaded cycle ranges were
4,838.5–5,981.7M / 5,118.6–5,954.4M, with medians 5,302.1M / 5,237.2M.
Fresh-string hash ranges were 1,071.3–1,395.8M / 1,076.2–1,252.6M, medians
1,192.1M / 1,184.8M; prebuilt-key ranges were 616.5–676.1M / 621.8–786.5M,
medians 629.5M / 639.7M. These overlap and some runs coincided with the PUC
stress run on another core. A 973-sample threaded table-churn profile was led
by interning (27.4%), the heap allocator (17.7%), numeric conversion (10.8%)
and `GETTABLE` (9.4%); `vm_thread_setslow` itself accounted for 2.2%, excluding
its callees. At that time string-key writes took the original miss and barrier path.
No replacement was kept without an established regression and a reviewed benefit.

In the final table, `string_format` switch/threaded cycle ranges were
349.7–578.0M / 345.2–538.7M. The medians, 355.0M / 400.6M, reversed the earlier
ordering, while the reference median also rose sharply from 648.7M in the prior
batch to 937.4M. The ranges overlap and activity increased during these runs;
this comparison needs a quiet rerun rather than a conclusion from the medians.

### Earlier follow-up: loop entry, string length and frame entry

Each comparison below uses seven alternating runs, in millions of user-space
instructions / cycles. The machine was heavily loaded, so minima and medians
can differ substantially; these comparisons do not prove every small cycle
change. The historical 14-run follow-ups in the bullets predate the
constant-division change; the later confirmation uses the finished code. The
code remains PIE.

* The empty-loop profile put most samples in `FORLOOP`, including its
  instruction-dependent back edge and the next opcode's table lookup. At that
  point the threaded empty probe was 66.6 / 21.6 against 74.6 / 19.9 for switch:
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
  hash-node loads. At that time string-key writes fell back to the original set
  path, whose miss can allocate and needs the original context and GC barrier. A seven-run
  comparison had overlapping ranges of 1,290.2–1,666.8 threaded and
  1,384.9–1,660.3 switch, reversing the earlier minimum ordering. No new
  string-write shortcut was retained without a reliable win and a reviewed
  miss/barrier path. In 14 additional runs switch/threaded medians were
  1,546.5M / 1,600.5M cycles, so that comparison did not rule out a difference.
  The later d9e7d6a and d025cdc changes affected this path.
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
  The then-current threaded `CONCAT` handler copied the context and spilled VM
  state; d025cdc later split its contextless common path from the slow callouts.
  The 460-sample threaded profile was dominated by allocation, string interning
  and GC rather than the handler alone. No replacement was retained at that time.
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

For the latest loop change on Linux x86-64, both interpreter modes passed all
315 unit tests in normal, single-threaded, and relocation-plus-ASan modes; the
normal tests include the generated-source drift check. Both modes also passed
the PUC-Rio suite in normal, relocation, and relocation-plus-ASan modes, each to
`final OK !!!`, with no sanitizer reports. CLI tests passed 31/31 with reference
`luac`, and rebranding passed 11/11, in both modes. Linker-free checks, the
freestanding and hosted builds, and Windows x64, Linux arm64 and macOS arm64
checks and object cross-builds passed in both modes. The cross-built targets
were not run.
