# Threaded VM measurements

The tail-call-threaded interpreter is the default on amd64 and arm64; the switch
interpreter is the source it is generated from, the explicit `VM_THREADED=0`
choice, and the automatic choice elsewhere. This file records the current
comparison of the two against reference Lua. The remaining work is in
[docs/FUTURE_WORK.md](../docs/FUTURE_WORK.md).

It has been run only on Linux x86-64. Windows x64, Linux arm64 and macOS arm64,
and the freestanding amd64 SysV, amd64 Win64 and arm64 objects, are
cross-compiled, and their `MOVE` handler was checked to end in an indirect jump
(`jmp` on amd64, `br` on arm64). That is not runtime validation.

## Current comparison (master `fbcffa8`, 2026-11-15)

AMD Ryzen 9 7950X, Linux x86-64, glibc, Odin `dev-2026-11-nightly:9a69916`;
reference Lua 5.5.1 built `-O2`; both VMs built `-o:speed` (PIE) by
`REFLUA=<reference lua> CPU=11 bash build/vm-compare.sh 5`, with
`TZ=America/Chicago` and `HOME=/home/sky`. Each workload runs in a fresh
process, rotating the three interpreters, and the `perf stat` counts include
startup and harness setup.

The host was shared and loaded (load average about 37), so **cycles are
approximate** and instruction counts are the primary evidence. Hash seeds, GC,
environment layout and I/O still vary some instruction counts. Each cell is
**minimum/median instructions; minimum/median cycles**, in millions.

| Workload | Default threaded | Switch | Reference |
|---|---:|---:|---:|
| micro/fib(32) | 1901.3/1901.3; 489.1/492.7 | 2074.0/2074.0; 539.7/541.6 | 1640.5/1640.5; 429.0/437.6 |
| micro/intloop | 6061.5/6061.5; 1065.4/1067.7 | 6421.5/6421.6; 1141.6/1144.7 | 4952.9/4952.9; 961.7/963.6 |
| micro/floatloop | 7519.9/7519.9; 2088.4/2094.3 | 8339.9/8339.9; 2189.3/2190.1 | 7217.0/7217.0; 1786.2/1796.8 |
| micro/strconcat | 645.5/645.5; 296.3/305.7 | 667.2/667.2; 296.3/303.2 | 880.0/880.0; 295.3/300.2 |
| micro/strpattern | 5077.4/5077.4; 1009.5/1331.2 | 5112.6/5112.6; 1344.2/1571.7 | 3803.6/3803.6; 1205.8/1247.5 |
| micro/tablechurn | 3668.8/3669.8; 5839.4/6602.9 | 3880.7/3881.0; 5074.7/6974.7 | 4812.6/4813.7; 6318.1/7299.1 |
| micro/tablesort | 3567.5/3577.5; 1194.8/1243.2 | 3652.5/3662.5; 1138.3/1206.3 | 4523.3/4532.3; 1473.7/1662.2 |
| micro/closures | 2919.5/2919.5; 841.3/903.7 | 2981.5/2981.5; 822.1/900.8 | 3026.6/3026.6; 782.3/923.3 |
| tables/array_insert | 613.5/613.5; 154.7/158.4 | 712.5/712.5; 154.5/206.7 | 572.5/572.5; 139.9/164.8 |
| tables/hash_strkey | 1016.9/1017.0; 845.5/1147.4 | 1048.8/1049.0; 892.4/1112.3 | 1287.9/1288.0; 924.8/1416.2 |
| tables/hash_prekey | 857.6/857.8; 443.2/458.3 | 891.0/891.2; 442.8/447.0 | 972.1/972.2; 450.9/466.8 |
| tables/tablesort | 1005.9/1005.9; 289.6/290.7 | 1031.4/1034.4; 297.6/299.2 | 1266.3/1266.3; 340.8/345.1 |
| stdlib/tostring_float | 1081.3/1081.3; 262.5/275.3 | 1125.7/1125.8; 266.1/271.8 | 3194.7/3197.7; 775.8/792.7 |
| stdlib/tonumber_float | 533.2/533.2; 105.4/123.5 | 568.0/568.0; 107.3/144.7 | 714.2/714.2; 152.7/225.6 |
| stdlib/string_format | 1321.3/1323.5; 399.9/446.4 | 1349.7/1351.7; 428.9/455.8 | 2350.6/2352.4; 874.3/902.2 |
| stdlib/format_int | 662.3/662.3; 212.3/212.8 | 706.7/706.7; 231.4/232.7 | 799.5/799.5; 261.3/279.0 |
| stdlib/math_transcend | 1187.8/1187.8; 296.3/344.6 | 1297.8/1297.8; 394.1/396.8 | 1228.9/1228.9; 429.0/433.8 |
| stdlib/file_lines | 717.9/717.9; 198.6/228.5 | 715.2/719.1; 210.5/232.0 | 712.7/712.7; 194.0/216.2 |
| stdlib/os_date | 663.8/663.8; 154.1/155.0 | 674.9/674.9; 159.7/161.7 | 692.3/692.5; 228.1/230.2 |
| scaling/scale_12500 | 31.5/31.5; 12.5/12.7 | 32.4/32.4; 12.8/12.9 | 37.1/37.1; 14.0/14.0 |
| scaling/scale_25000 | 60.8/60.8; 23.3/23.7 | 62.6/62.6; 24.0/24.2 | 71.7/71.8; 26.1/26.5 |
| scaling/scale_50000 | 122.7/122.7; 50.6/51.1 | 126.2/126.2; 51.6/52.0 | 145.0/145.1; 55.6/55.9 |
| scaling/scale_100000 | 248.9/249.0; 106.7/107.2 | 256.0/256.0; 107.7/110.9 | 285.4/285.5; 113.0/113.9 |
| probe/add | 132.7/132.7; 28.4/28.6 | 146.7/146.7; 27.5/27.6 | 120.6/120.6; 29.9/30.5 |
| probe/call0 | 344.7/344.7; 95.0/95.4 | 430.7/430.7; 107.9/108.1 | 344.6/344.6; 82.9/83.8 |
| probe/call1 | 384.7/384.7; 101.5/109.5 | 476.7/476.7; 125.0/139.1 | 388.6/388.7; 89.6/101.8 |
| probe/callr | 438.7/438.7; 114.4/131.9 | 534.7/534.7; 134.1/157.1 | 448.7/448.7; 103.1/117.6 |
| probe/calls | 25461.0/25461.0; 5205.9/5218.9 | 29061.0/29061.0; 5946.2/5997.9 | 25891.0/25891.0; 6795.4/6960.8 |
| probe/empty | 62.7/62.7; 18.6/18.7 | 68.7/68.7; 20.1/20.4 | 56.6/56.6; 17.7/17.8 |
| probe/getenv | 1314.7/1314.7; 260.9/263.1 | 1472.7/1472.7; 285.2/293.5 | 1046.6/1046.6; 238.8/239.1 |
| probe/gtab | 192.7/192.7; 39.3/39.9 | 278.7/298.7; 52.4/61.2 | 174.6/174.6; 41.3/42.2 |
| probe/il | 4250.7/4250.7; 777.3/790.9 | 4750.7/4750.7; 901.0/901.3 | 4000.6/4000.6; 817.7/823.8 |
| probe/iobench | 8557.0/8611.9; 1708.1/1781.7 | 8549.2/8550.2; 1718.2/1750.9 | 8012.0/8070.4; 1906.3/1918.3 |
| probe/move | 100.7/100.7; 23.2/23.5 | 112.7/112.7; 24.7/24.8 | 96.6/96.6; 25.2/25.3 |
| probe/ncall | 414.7/414.7; 77.5/77.6 | 472.7/472.7; 89.7/89.8 | 436.6/436.6; 104.8/105.1 |
| probe/os_date | 19128.1/19168.1; 4431.4/4503.8 | 19277.8/19297.8; 4467.0/4642.0 | 20788.4/20801.9; 5261.3/5425.7 |
| probe/self | 636.7/656.7; 161.0/168.6 | 794.7/794.7; 207.5/214.0 | 662.6/662.6; 212.9/217.0 |
| probe/w1 | 13271.0/13371.0; 2618.0/2697.4 | 13641.0/13791.0; 2673.9/2817.6 | 12561.2/12651.2; 2982.2/2987.4 |

### Sizes

GNU `size` text/data/BSS in bytes: threaded 932,759/63,872/73,536; switch
901,803/62,848/73,536; reference 283,206/6,216/80. From `nm -S`:

| Symbol group | Bytes |
|---|---:|
| Switch `kernel::vm_execute` | 32,361 |
| Threaded opcode handlers (85) | 39,609 |
| Other threaded entry, slow-path and helper symbols (44) | 17,154 |
| Threaded handler-address table | 1,024 |
| Reference `luaV_execute` | 15,905 |

These are rough comparisons: inlining and helper boundaries differ.

### Validation of this build

In both interpreters: `build/check.sh` without warnings, all 366 unit tests
plain, stress, ASan and stress+ASan, the PUC-Rio suite in the same four modes
(`final OK !!!` each), CLI tests against reference `luac` (31/31), rebranding
(11/11), and the hosted and freestanding builds.

## How we got here

Median threaded instructions in millions, from each step's own measurements.
Commit bodies carry the full numbers; the complete earlier experiment log is
`git show 24b6131:bench/THREADED_VM.md`. Experiments that did not pay off are
listed in [docs/FUTURE_WORK.md](../docs/FUTURE_WORK.md#dead-ends).

| Step | Commits | Effect |
|---|---|---|
| Prototype and first tuning, off by default | 67ff1d7..10b89a2 | handlers generated from the switch; contextless table, call and method hits; FORLOOP prefetch |
| Port the switch's call pass | ab67c21, 83c1cc1 | `fib(32)` 2,162 → 2,070 |
| Upvalues, table reads and writes, concat | fcc8aac..368b850 | `strconcat` 687 → 658, `tablechurn` 4,051 → 3,752, `array_insert` 751 → 649 |
| Explicit interpreter selection, probes, `vm-compare.sh` | 40a5f03..6403f11 | |
| Threaded becomes the default | c9db250 | |
| Lua call setup | 9530c1d..2aa3ea5 | `call1` 435 → 389 (reference 389), `fib(32)` 2,063 → 1,901 |
| Globals, loops, writes | de0c23d..fbcffa8 | global read 247 → 193, empty loop 67 → 63, `array_insert` 650 → 614 |
