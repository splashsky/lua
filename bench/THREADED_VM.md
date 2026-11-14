# Threaded VM prototype measurements

The optional `VM_THREADED` interpreter is **not a clear overall win**. It cuts
the instruction count for the empty, MOVE, ADD and integer-loop probes, but
increases it for table access, Lua/native calls and method lookup. Some cycle
results move in a different direction from instruction counts. The table-insert
and closure workloads regress; sorting improves. Keep the switch as the default.

The 2026-11-14 measurements below are from an AMD Ryzen 9 7950X (Linux x86-64), Odin
`dev-2026-11-nightly:9a69916`, speed builds, and reference Lua 5.5.1 from
`/tmp/opencode/refbuild/src/lua`. The machine was loaded. Each row is a fresh
process; each interpreter ran seven times with rotating order, measured with
`perf stat -x, -e instructions:u,cycles:u`. The minimum instructions and minimum
cycles are reported independently, in **millions**; they need not come from the
same run. This does not measure kernel time, and the I/O-heavy workloads can be
particularly noisy. Each named harness workload is isolated, as in `bench.sh`;
the 13 probe files are the unmodified `/tmp/opencode/inv/*.lua` scripts used in
the investigation. The standard harness was also run with `REFLUA` for each
of the three suites and both builds.

A ten-argument dispatch toy using Odin's ordinary `"contextless"` convention
did emit a tail jump, but spilled and reloaded stack arguments on amd64 SysV,
Windows x64 and Linux arm64. `"preserve/none"` kept the toy arguments in
registers. Actual threaded handlers were also cross-compiled and inspected for
Windows x64, Linux/macOS arm64, and the supported freestanding amd64 and arm64
objects; those checks inspect code generation, not execution on those machines.

| Workload | Switch instructions / cycles | Threaded instructions / cycles | Reference instructions / cycles |
|---|---:|---:|---:|
| probe/empty | 74.7 / 18.4 | 66.7 / 21.7 | 56.6 / 17.6 |
| probe/move | 120.7 / 25.9 | 104.7 / 24.6 | 96.6 / 25.2 |
| probe/add | 154.7 / 28.8 | 136.7 / 27.3 | 120.6 / 30.3 |
| probe/gtab | 286.7 / 55.9 | 318.7 / 62.7 | 174.6 / 42.5 |
| probe/call0 | 492.7 / 129.5 | 514.7 / 123.6 | 344.6 / 84.5 |
| probe/call1 | 540.7 / 131.6 | 556.7 / 132.5 | 388.6 / 90.1 |
| probe/callr | 600.7 / 140.9 | 612.7 / 148.7 | 448.6 / 103.3 |
| probe/ncall | 492.7 / 98.6 | 514.7 / 105.3 | 436.6 / 100.5 |
| probe/self | 810.7 / 158.6 | 882.7 / 177.3 | 662.6 / 137.6 |
| probe/il | 5,000.7 / 957.7 | 4,350.7 / 835.1 | 4,000.6 / 831.1 |
| probe/calls | 30,671.1 / 6,362.4 | 31,601.1 / 6,662.7 | 25,890.9 / 5,980.8 |
| probe/w1 | 14,696.0 / 2,905.3 | 15,191.0 / 3,021.5 | 12,396.1 / 2,747.7 |
| probe/iobench | 9,536.0 / 2,016.2 | 9,717.5 / 2,038.8 | 8,011.9 / 1,775.0 |
| micro/fib(32) | 2,299.7 / 595.7 | 2,507.7 / 581.6 | 1,640.4 / 394.9 |
| micro/intloop | 6,601.7 / 1,266.5 | 6,601.7 / 1,210.9 | 4,952.9 / 969.0 |
| micro/floatloop | 9,067.5 / 2,464.5 | 8,947.5 / 2,469.7 | 7,216.9 / 1,744.4 |
| micro/strconcat | 913.1 / 611.0 | 918.9 / 538.7 | 879.9 / 412.7 |
| micro/strpattern | 5,209.7 / 1,028.0 | 5,315.3 / 1,057.5 | 3,803.5 / 1,054.6 |
| micro/tablechurn | 4,873.4 / 6,784.2 | 5,078.5 / 6,874.0 | 4,812.7 / 6,505.2 |
| micro/tablesort | 6,836.4 / 1,980.3 | 6,304.1 / 1,912.1 | 4,523.2 / 1,499.8 |
| micro/closures | 4,232.0 / 1,059.5 | 4,365.8 / 1,163.2 | 3,024.6 / 678.5 |
| tables/array_insert | 739.6 / 155.9 | 874.6 / 174.2 | 572.5 / 125.1 |
| tables/hash_strkey | 1,364.3 / 1,897.3 | 1,384.7 / 1,932.4 | 1,287.8 / 1,549.8 |
| tables/hash_prekey | 1,106.9 / 1,281.9 | 1,145.3 / 1,155.1 | 972.2 / 753.2 |
| tables/tablesort | 1,908.5 / 454.5 | 1,764.3 / 443.0 | 1,266.2 / 361.4 |
| stdlib/tostring_float | 1,170.7 / 288.3 | 1,199.1 / 299.7 | 3,195.0 / 785.0 |
| stdlib/tonumber_float | 574.1 / 187.6 | 594.2 / 191.4 | 714.1 / 258.3 |
| stdlib/string_format | 1,466.3 / 343.0 | 1,470.9 / 334.0 | 2,350.5 / 633.7 |
| stdlib/format_int | 911.0 / 222.3 | 935.8 / 224.8 | 799.3 / 200.9 |
| stdlib/math_transcend | 1,488.0 / 309.5 | 1,504.0 / 344.8 | 1,228.8 / 294.8 |
| stdlib/file_lines | 894.6 / 318.0 | 902.7 / 320.0 | 712.6 / 160.9 |
| stdlib/os_date | 702.9 / 164.8 | 709.0 / 168.4 | 692.2 / 205.0 |

In these binaries, `nm -S` reports 33,889 bytes for the switch `vm_execute`
code, plus its 512-byte relative jump table. Threaded handlers and entry/trace/
poll code total 42,877 bytes, plus a 1,024-byte address table; the entry wrapper
is inlined into callers. Total executable text is 874,804 versus 890,852 bytes,
and data is 62,936 versus 63,960 bytes. The reference `luaV_execute` symbol is
15,905 bytes and its executable text is 283,206 bytes; different helpers and
inlining make these symbol sizes only a rough comparison. All sizes are
compiler/build dependent.

In particular, the threaded FORLOOP and MOVE hot paths can stay in registers,
but call and table handlers still have substantial setup and normal-call costs.
The handler calling convention also moves context and live state across those
calls, and the larger handler set changes instruction-cache behavior. Before
considering a default change, reduce those costs without changing context,
relocation, hook, error or yield behavior; repeat the full correctness matrix and
cross-target code-generation checks, and demonstrate a broad, repeatable win.
For example, a cycles profile of the threaded `calls` probe attributed about 30%
of sampled user cycles to `do_precall` and 14% to the CALL handler; profiles
are diagnostic samples, not independent benchmark timings.
