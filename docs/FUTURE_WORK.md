# Future work

This is the list of work we intend to do next, mostly performance, with the
evidence behind each item. It reflects the threaded-default change after 368b850
(November 2026). Each item says what is known, what has already been tried, and
what is still open, so the next attempt does not repeat a measured dead end.

## How the numbers were taken

All comparisons are against reference PUC-Rio Lua 5.5.1 built with `-O2` on the
same machine (AMD Ryzen 9 7950X, Linux x86-64, glibc), with lua-odin built
`-o:speed` (PIE). The workloads are the `bench/` harness (see
[bench/README.md](../bench/README.md)) and a few one-line probes, quoted where
they are used.

- **Instruction counts** (`perf stat -e instructions:u`, or callgrind) are the
  primary metric. Fixed paths are repeatable, but hash seeds, GC and temporary
  file I/O can vary; compare distributions for those, not single runs.
- The new comparison uses five rotating, isolated runs, pinned to CPU 12 after
  an idle-core sample. The host was shared and the PUC stress/ASan matrix was
  active; **cycle figures are approximate**, not a quiet-machine measurement.
  Re-measure on a quiet machine before relying on a small difference. Full
  minima, medians and method are in [bench/THREADED_VM.md](../bench/THREADED_VM.md).
- The retained switch `vm_execute` is one large procedure. Unrelated edits
  shift register allocation and code placement, and that alone has moved switch
  call costs by ±3 instructions and empty-loop timings by 10-20%. Threaded
  handler layout can matter too. Check generated code (callgrind
  `--dump-instr=yes`, `perf annotate`) before attributing a change.

Median instructions in millions, default threaded / switch / reference. The
`gtab` reference median varies with the randomized hash seed; its minimum in
this run was 174.6M, not 192.6M. The full min/median table includes cycles.

| Workload | Default threaded | Switch | Reference | Default vs reference |
|---|---:|---:|---:|---:|
| micro/fib(32) | 2,063.4 | 2,074.0 | 1,640.5 | +26% |
| micro/intloop | 6,101.6 | 6,461.6 | 4,952.9 | +23% |
| micro/floatloop | 8,117.4 | 8,857.4 | 7,217.0 | +12% |
| micro/strconcat | 657.7 | 673.4 | 880.0 | -25% |
| micro/strpattern | 5,094.6 | 5,129.8 | 3,803.6 | +34% |
| micro/tablechurn | 3,752.3 | 3,914.4 | 4,813.0 | -22% |
| micro/tablesort | 6,167.9 | 6,837.2 | 4,523.3 | +36% |
| micro/closures | 3,015.5 | 2,985.5 | 3,026.6 | -0.4% |
| tables/array_insert | 649.5 | 724.5 | 572.5 | +13% |
| tables/hash_strkey | 1,026.1 | 1,053.9 | 1,288.1 | -20% |
| tables/hash_prekey | 877.2 | 893.3 | 972.2 | -10% |
| stdlib/math_transcend | 1,359.9 | 1,457.9 | 1,228.9 | +11% |
| stdlib/file_lines | 772.1 | 769.0 | 712.7 | +8% |
| probe/gtab (global read, 2M) | 246.7 | 282.7 | 192.6 | +28% |
| probe/call1 (one-argument call, 2M) | 434.7 | 480.7 | 388.7 | +12% |
| probe/empty (numeric loop, 2M) | 66.7 | 72.7 | 56.6 | +18% |
| probe/os_date (local, 2M) | 67,127.7 | 67,273.7 | 20,788.4 | +223% |
| probe/getenv (`HOME`, 2M) | 2,516.7 | 2,602.7 | 1,032.6 | +144% |
| probe/iobench | 9,289.0 | 9,249.2 | 8,012.0 | +16% |

Threaded string building, table churn, string keys and number formatting execute
fewer instructions than reference here; closures and UTC `os.date` are near it.
Do not infer small cycle wins from these counts on a loaded machine.

## 1. Threaded default: done and what remains

The [tail-call-threaded interpreter](ARCHITECTURE.md#tail-call-threaded-dispatch)
is now the default on amd64 and arm64. The frame-setup pass was ported to its
specialized call path; upvalue, table-read/write and concatenation improvements
removed the previously identified instruction regressions in several workloads.
The switch remains both the source of the generated handlers and the automatic
choice on other architectures; `VM_THREADED=0` explicitly selects it.

Remaining, in priority order:

1. **Runtime validation on Windows x64, Linux arm64 and macOS arm64.** These
   targets have been cross-compiled to objects but not run. The user decided to
   skip their runtime validation for this flip; they remain an unvalidated gap,
   not a demonstrated runtime success.
2. **Cycle re-measurement on a quiet machine.** The new comparisons were taken
   on a shared, heavily loaded host. Treat cycles as approximate and repeat on
   a quiet machine before relying on small differences.
3. **Workloads where threaded executes more instructions than switch.** Median
   `closures` is +1.0% (3,015.5M versus 2,985.5M), `file_lines` +0.4% and
   `iobench` +0.4%. Profile the residual closure and I/O paths rather than
   assuming a cycle regression; hash seeds, temporary files and GC can affect
   the counts. The earlier table and concat blockers have been addressed.

## 2. Lua-to-Lua calls

A one-argument call loop (`local function f(x) return x end; for i = 1, N do
f(i) end`) costs roughly 217 instructions per iteration with the threaded
default against 240 with the switch and 194 in reference. In the new five-run
comparison, approximate median cycles are 113.6M versus 90.4M for the
two-million-call probe, and 503.6M versus 431.4M for `fib(32)`.

The following callgrind breakdown is **historical switch data**, not a breakdown
of the threaded default; obtain a new threaded profile before choosing a lever:

| Piece | Switch | Reference |
|---|---:|---:|
| Instruction fetch and dispatch (5 per iteration) | 60 | 27 |
| Frame entry and re-entry | 47 | 26 |
| `CALL` handler | 31 | 23 |
| `RETURN1`, result discarded | 20 | 19 |
| Two `MOVE`s | 20 | 28 |
| Numeric `FORLOOP` | 24 | 23 |
| Frame setup (`do_precall_vm`) | 38 | 48 |

- **Dispatch (switch):** each fetch was 12 instructions against about 5. Part of
  that is inherent: Odin's `switch` compiles to a PIE jump-table sequence
  (`lea`/`movslq`/`add`/`jmp`) where reference uses computed `goto`. The rest is
  trap handling and a spill reload on the shared path. The threaded interpreter
  removes much of this cost.
- **Frame entry and re-entry (switch profile):** each entry spilled the frame
  index and multiplied it by the 56-byte frame stride. It then reloaded
  `L.stack`, `L.frames`, `func` and `savedpc`, the closure, prototype, constants
  and code, and converted the saved PC index to a pointer. Frames stay in an
  index-addressed array
  (Decision 3), so some of this is structural; redundant reloads between the
  call and return sides are not.
- **`CALL`:** compare the current threaded path step by step with reference's
  `OP_CALL`: the `L.top` and saved-PC stores, the result-count encoding and the
  interrupt poll.
- **Tried and dropped:**
  - a frame pointer local to `vm_execute`;
  - 64-byte frames, to turn the multiply into a shift (3 more instructions per
    call);
  - re-deriving the closure in each handler;
  - moving the trace fetch out of line;
  - native precall as a separate out-of-line procedure (25 more instructions per
    native call).

  The commit bodies of 65e55dc, e3fafd4, 6481741, 68f45c9 and 3e82229 have the
  measurements.

## 3. Other interpreter and library gaps

Roughly in order of how broadly they would help:

- **Global variable access:** a `y = x` loop on a global (`GETTABUP` with a
  constant short-string key on `_ENV`) executes 246.7M instructions, against
  reference's 174.6M minimum and 192.6M median (+41% and +28% respectively).
  Hash-seed variability makes single ratios unreliable. Compare against
  `luaV_fastget`/`luaH_getshortstr`.
- **`table.sort`:** about +36% instructions, with approximate cycle medians of
  1,537.6M versus 1,290.1M. As in reference, every
  element read, write and comparison goes through the embedding API
  (`api_geti`, `api_seti`, `api_compare`), so the per-call cost of those entry
  points is the likely lever.
- **Numeric loops:** `intloop` about +23%, `floatloop` +12%, `il` +9% and the empty
  loop +18% instructions. Mostly dispatch and the `FORLOOP` back edge.
- **Array part:** `array_insert` about +13% instructions, with approximate
  cycle medians of 127.9M versus 123.5M: the `SETI`/`GETI` paths on 5.5's
  split array layout.
- **`file:lines()` and buffered reads:** about +8% instructions; approximate
  cycle medians are 203.5M versus 164.5M. Cycle and I/O variation needs a
  quieter measurement and cache-counter profile.
- **`os.date` in local time:** 3.2× the instructions of reference; UTC `os.date`
  is already at parity. A historical profile put 55% of the cost in locating the zone file
  (`local_zone_file`) and finding the transition (`tzif_transition`), both
  repeated on every call. Caching the located zone and the last transition is
  the obvious lever. It must still notice a changed `TZ`, as the C library
  does for reference.
- **`os.getenv`:** 2.4× the instructions of reference in this environment;
  lookup cost depends on environment layout, and this includes VM lookups.
- **`math` transcendental functions:** about +11% instructions, spent in the
  pure-Odin libm routines.
- **Lua patterns:** `strpattern` executes about 34% more instructions, but its
  approximate cycle median is 1,048.9M versus 1,192.1M, so this is low priority.

## 4. Memory and the collector

- **Peak heap on string building:** a historical switch build sampled
  `collectgarbage("count")` every 1,000 instructions during `strconcat` and
  showed a peak of 25,449 KiB against 14,012 KiB in reference (the sampling hook
  perturbs this a little). The intern table ended at 320,742 strings in 524,288
  buckets, against 244,478 strings in
  262,144. Our collector is retaining more garbage strings at that point.
  Compare the pacing (debt, step size, generational thresholds) step by step
  with `lgc.c`. 2dc564b fixed two pacing differences; there may be more. Recheck
  this measurement with the threaded default and its newer concat path.
- **Intern-table lookups:** a historical switch profile found walking an intern
  chain cost about 3× reference per lookup, although the hash, growth thresholds
  and chain lengths (1.145 nodes per hit against 1.144) all match. Our string
  header is 32 bytes against reference's 24. A 24-byte header helped `strconcat`
  but cost instructions on
  the hash workloads; that was measured before the allocator fix (1055a5c).
  Retry it with the current default and allocator.
- **32-bit targets** are not supported: the kernel's layout assertions require
  64-bit. Supporting them would need the object layouts, the hosted allocator's
  alignment guarantees and the vararg-count width revisited.

## 5. Validation and robustness

- **Number formatting on macOS and the BSDs** follows their `vfprintf` source
  (54f0160); it has not been run there. Run `tests/format_diff.lua` against a
  reference build on each, as [BUILDING.md](../BUILDING.md) describes for Linux.
- **Two stream tests failed together** in two separate parallel stress +
  AddressSanitizer runs on a heavily loaded machine:
  `stream_partial_flush_discards_whole_buffer` and `stream_concurrent_states`.
  Five reruns passed. The working hypothesis is a concurrent `flush_all`
  touching the deliberately full pipe one of them uses. Find the cause before it
  becomes a flaky failure.
- The runtime validation of the threaded interpreter on other platforms
  (section 1) also exercises the hosted allocator's direct `malloc` path on
  macOS (1055a5c), which has only been cross-compiled there.
