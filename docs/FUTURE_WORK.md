# Future work

This is the list of work we intend to do next, mostly performance, with the
evidence behind each item. It reflects `master` at 10b89a2 (November 2026). Each
item says what is known, what has already been tried, and what is still open,
so the next attempt does not repeat a measured dead end.

## How the numbers were taken

All comparisons are against reference PUC-Rio Lua 5.5.1 built with `-O2` on the
same machine (AMD Ryzen 9 7950X, Linux x86-64, glibc), with lua-odin built
`-o:speed` (PIE). The workloads are the `bench/` harness (see
[bench/README.md](../bench/README.md)) and a few one-line probes, quoted where
they are used.

- **Instruction counts** (`perf stat -e instructions:u`, or callgrind) are
  deterministic and are the primary metric. Method and global lookups vary by
  ±20M instructions between runs with the randomized string-hash seed, so compare
  distributions for those, not single runs.
- **Cycle figures** below are medians of 11-15 alternating runs pinned to an idle
  core. The machine was shared with other heavy work, so treat them as
  approximate (±5%). Re-measure on a quiet machine before relying on a small
  difference.
- `vm_execute` is one large `switch`. Unrelated edits shift its register
  allocation and code placement, and that alone has moved call costs by ±3
  instructions and empty-loop timings by 10-20%. Check generated code
  (callgrind `--dump-instr=yes`, `perf annotate`) before attributing a change.

Instructions in millions, switch / threaded / reference, for the workloads that
are still behind:

| Workload | Switch | Threaded | Reference | Switch vs reference |
|---|---:|---:|---:|---:|
| micro `fib(32)` | 2,073.9 | 2,162.0 | 1,640.4 | +26% |
| micro `intloop` | 6,461.5 | 6,101.5 | 4,952.9 | +30% |
| micro `floatloop` | 8,857.3 | 8,157.3 | 7,216.9 | +23% |
| micro `tablesort` | 6,827.1 | 6,176.8 | 4,532.2 | +51% |
| micro `strpattern` | 5,129.7 | 5,094.5 | 3,803.5 | +35% |
| tables `array_insert` | 724.4 | 751.4 | 572.5 | +27% |
| stdlib `math_transcend` | 1,457.8 | 1,365.8 | 1,228.8 | +19% |
| stdlib `file_lines` | 766.8 | 772.0 | 714.4 | +7% |
| global read (`y = x`, 2M) | 282.6 | 252.6 | 174.6 | +62% |
| one-argument Lua call (2M) | 480.6 | 458.6 | 388.6 | +24% |
| empty numeric loop (2M) | 72.6 | 66.6 | 56.6 | +28% |
| `os.date("%c %D %T %F %R")` (2M) | 69,873.5 | 69,771.2 | 20,815.5 | +236% |
| `os.getenv("HOME")` (2M) | 3,666.7 | 3,580.7 | 2,156.7 | +70% |

String building, table churn, string keys, closures, number formatting and
`os.date` in UTC are now at or near reference, in both instructions and cycles.

## 1. Make the threaded interpreter the default

`-define:VM_THREADED=true` selects the tail-call-threaded interpreter described
in [ARCHITECTURE.md](ARCHITECTURE.md#experimental-tail-call-threaded-dispatch).
It is merged but off by default. Measured on Linux x86-64 just before the call
pass, it was faster than the switch interpreter on one-argument calls (about −13%
cycles), native calls (about −16%), method calls (about −21%), `calls.lua`
(about −12%) and loops (`il` about −9%). The call pass then made the switch
interpreter's calls about 5% faster, and the threaded interpreter has not yet
picked that up (point 2). What still stands in the way:

1. **Runtime validation on Windows x64, Linux arm64 and macOS arm64.** All three
   cross-compile, and their handlers end in real indirect tail jumps, but none has
   been run. This is the main blocker.
2. **Port the call pass into the threaded call path.** 68f45c9 and 3e82229 made
   the switch interpreter's frame setup cheaper (`do_precall_vm`), but the
   threaded interpreter keeps its own hand-written `vm_thread_precall` and
   `vm_thread_native_try` from before that pass. That code still clears `u2` and
   fills missing arguments the old way. As a result `fib(32)` now executes fewer
   instructions with the switch (2,073.9M) than threaded (2,162.0M). The
   generator's review hashes on `do_precall` and `prepCallInfo` exist to flag
   exactly this drift.
3. **Workloads where threaded executes more instructions than switch:**
   `strconcat` (687.3M against 673.3M), `tablechurn` (4,051.0M against
   3,914.6M), `closures` (3,047.4M against 2,985.4M), `array_insert` (751.4M
   against 724.4M), and `hash_strkey` and `hash_prekey` (3% and 5% more). Known
   contributors:
   - `CONCAT` still copies the Odin context for coercion, allocation and
     metamethods.
   - The upvalue opcodes use `vm_upvals(regs)`, a load from the function slot,
     even though the threaded handlers already carry the closure in a register.
     There, `closure_upvals(cl)` would avoid the load.
   - String-key table writes that miss still take the original slow path,
     with its barrier.
4. **Re-measure on a quiet machine.** The tables in
   [bench/THREADED_VM.md](../bench/THREADED_VM.md) predate the allocation pass
   (1055a5c, 2dc564b) and the call pass, and were partly taken under load.
   Refresh them before deciding.

Once threaded is the default, the switch interpreter must still stay. It serves
targets without the `"preserve/none"` tail-call support (anything but amd64 and
arm64), and it is what the threaded handlers are generated from.

## 2. Lua-to-Lua calls

A one-argument call loop (`local function f(x) return x end; for i = 1, N do
f(i) end`) costs 240 instructions per iteration with the switch against 194 in
reference. Cycles are about +44% (call) and +29% (`fib(32)`). Per iteration,
from callgrind:

| Piece | Switch | Reference |
|---|---:|---:|
| Instruction fetch and dispatch (5 per iteration) | 60 | 27 |
| Frame entry and re-entry | 47 | 26 |
| `CALL` handler | 31 | 23 |
| `RETURN1`, result discarded | 20 | 19 |
| Two `MOVE`s | 20 | 28 |
| Numeric `FORLOOP` | 24 | 23 |
| Frame setup (`do_precall_vm`) | 38 | 48 |

- **Dispatch:** each fetch is 12 instructions against about 5. Part of that is
  inherent: Odin's `switch` compiles to a PIE jump-table sequence
  (`lea`/`movslq`/`add`/`jmp`) where reference uses computed `goto`. The rest is
  trap handling and a spill reload on the shared path. The threaded interpreter
  removes most of this cost.
- **Frame entry and re-entry:** each entry spills the frame index and multiplies
  it by the 56-byte frame stride. It then reloads `L.stack`, `L.frames`, `func`
  and `savedpc`, the closure, prototype, constants and code, and converts the
  saved PC index to a pointer. Frames stay in an index-addressed array
  (Decision 3), so some of this is structural; redundant reloads between the
  call and return sides are not.
- **`CALL`:** compare step by step with reference's `OP_CALL`: the `L.top` and
  saved-PC stores, the result-count encoding and the interrupt poll.
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
  constant short-string key on `_ENV`) executes 62% more instructions than
  reference (45% threaded). Compare against `luaV_fastget`/`luaH_getshortstr`.
- **`table.sort`:** +51% instructions, about +30% cycles. As in reference, every
  element read, write and comparison goes through the embedding API
  (`api_geti`, `api_seti`, `api_compare`), so the per-call cost of those entry
  points is the likely lever.
- **Numeric loops:** `intloop` +30%, `floatloop` +23%, `il` +21% and the empty
  loop +28% instructions. Mostly dispatch and the `FORLOOP` back edge; threaded
  is closer (+9% to +23%).
- **Array part:** `array_insert` +27% instructions, about +17% cycles: the
  `SETI`/`GETI` paths on 5.5's split array layout.
- **`file:lines()` and buffered reads:** +7% instructions but about +24% cycles,
  so this is memory or I/O behavior rather than instruction count. Profile with
  cache counters.
- **`os.date` in local time:** 3.4× the instructions of reference; UTC `os.date`
  is already at parity. A profile puts 55% of the cost in locating the zone file
  (`local_zone_file`) and finding the transition (`tzif_transition`), both
  repeated on every call. Caching the located zone and the last transition is
  the obvious lever. It must still notice a changed `TZ`, as the C library
  does for reference.
- **`os.getenv`:** 1.7× the instructions of reference.
- **`math` transcendental functions:** +19% instructions, spent in the pure-Odin
  libm routines.
- **Lua patterns:** `strpattern` executes 35% more instructions, but is already
  at or below reference in cycles, so this is low priority.

## 4. Memory and the collector

- **Peak heap on string building:** sampling `collectgarbage("count")` every
  1,000 instructions during `strconcat` showed a peak of 25,449 KiB against
  14,012 KiB in reference (the sampling hook perturbs this a little). The intern
  table ended at 320,742 strings in 524,288 buckets, against 244,478 strings in
  262,144. Our collector is retaining more garbage strings at that point.
  Compare the pacing (debt, step size, generational thresholds) step by step
  with `lgc.c`. 2dc564b fixed two pacing differences; there may be more.
- **Intern-table lookups:** walking an intern chain costs about 3× reference per
  lookup, although the hash, the growth thresholds and the chain lengths (1.145
  nodes per hit against 1.144) all match. Our string header is 32 bytes against
  reference's 24. A 24-byte header helped `strconcat` but cost instructions on
  the hash workloads; that was measured before the allocator fix (1055a5c).
  Retry it now.
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
