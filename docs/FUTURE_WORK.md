# Future work

This list reflects the merged master at `fbcffa8` (15 November 2026). It puts
the remaining work roughly in order of breadth, with measured results and failed
experiments retained so a future pass does not repeat a dead end. Correctness
and platform validation remain prerequisites, not performance tradeoffs.

## Measurement

The comparison uses reference PUC-Rio Lua 5.5.1 built `-O2`, and lua-odin
`-o:speed` PIE, on an AMD Ryzen 9 7950X, Linux x86-64, glibc and Odin
`dev-2026-11-nightly:9a69916`. Five fresh-process runs per workload rotate
the three interpreters, pinned to CPU 11, sampled at 0.4% busy with its sibling
at 0.2% before the run. `TZ=America/Chicago` and `HOME=/home/sky` were fixed;
environment layout affects `getenv`. The host was shared and heavily loaded;
**instructions are primary and cycles approximate**. Hash seeds, GC and I/O
vary. Minima, medians, cycles, sizes and method are in
[bench/THREADED_VM.md](../bench/THREADED_VM.md).

Median user-space instructions in millions, including startup and harness setup:

| Workload | Default threaded | Switch | Reference | Default vs reference |
|---|---:|---:|---:|---:|
| micro/fib(32) | 1,901.3 | 2,074.0 | 1,640.5 | +15.9% |
| micro/intloop | 6,061.5 | 6,421.6 | 4,952.9 | +22.4% |
| micro/floatloop | 7,519.9 | 8,339.9 | 7,217.0 | +4.2% |
| micro/strconcat | 645.5 | 667.2 | 880.0 | -26.6% |
| micro/strpattern | 5,077.4 | 5,112.6 | 3,803.6 | +33.5% |
| micro/tablechurn | 3,669.8 | 3,881.0 | 4,813.7 | -23.8% |
| micro/tablesort | 3,577.5 | 3,662.5 | 4,532.3 | -21.1% |
| micro/closures | 2,919.5 | 2,981.5 | 3,026.6 | -3.5% |
| tables/array_insert | 613.5 | 712.5 | 572.5 | +7.2% |
| tables/hash_strkey | 1,017.0 | 1,049.0 | 1,288.0 | -21.0% |
| tables/hash_prekey | 857.8 | 891.2 | 972.2 | -11.8% |
| tables/tablesort | 1,005.9 | 1,034.4 | 1,266.3 | -20.6% |
| stdlib/math_transcend | 1,187.8 | 1,297.8 | 1,228.9 | -3.3% |
| stdlib/file_lines | 717.9 | 719.1 | 712.7 | +0.7% |
| probe/gtab (global read, 2M) | 192.7 | 298.7 | 174.6 | +10.4% |
| probe/call1 (one-argument call, 2M) | 384.7 | 476.7 | 388.7 | -1.0% |
| probe/empty (numeric loop, 2M) | 62.7 | 68.7 | 56.6 | +10.8% |
| probe/os_date (local, 2M) | 19,168.1 | 19,297.8 | 20,801.9 | -7.9% |
| probe/getenv (`HOME`, 2M) | 1,314.7 | 1,472.7 | 1,046.6 | +25.6% |
| probe/iobench | 8,611.9 | 8,550.2 | 8,070.4 | +6.7% |

Seed-sensitive medians are not stable rankings: for example earlier reference
`gtab` runs ranged from 174.6M to 192.6M. Different batches and layouts also
explain differences from the targeted before/after figures below. Switch's
large `vm_execute` is sensitive to register allocation and code placement;
threaded handler layout matters too. Inspect generated code and compare
distributions before attributing a small change.

## 1. Calls, dispatch and numeric loops

The [threaded VM](ARCHITECTURE.md#tail-call-threaded-dispatch) is the default
on amd64 and arm64; switch remains the source of generated handlers and the
automatic fallback elsewhere. The call pass reduced `call1` from 434.5M to
388.5M, equal to reference at 194 instructions per iteration in that batch.
Its threaded/reference breakdown per iteration was: fetch/dispatch 46/27,
frame entry/re-entry 24/26, `CALL` 25/23, `RETURN1` 21/19, two `MOVE`s 18/28,
`FORLOOP` 23/23, frame setup 37/48. Closures are now below switch.

- **Open:** `fib(32)` improved 2,063M to 1,901M but remains about 16% above
  reference's 1,640M. In `fib(22)`, frame entry/re-entry costs 2.293M versus
  1.433M and other VM work including dispatch 7.938M versus 6.161M. Profile
  frame re-entry, arithmetic and conditionals without regressing native calls;
  profile general `RETURN` and closure creation too. The `CLOSURE` barrier is
  required: an emergency GC can blacken an anchored closure before wiring its
  upvalues.
- **Loops:** empty 66.7M → 62.7M (reference 56.6M), `il` 4,350.7M → 4,250.7M
  (4,000.6M), and `intloop` 6,101.6M → 6,061.5M (4,952.9M). Per iteration,
  threaded/reference `FORLOOP` is 31/28 and `ADD` plus dispatch 35/32.
  `intloop` costs 303 versus about 248 instructions: two ADDs 70, MODK 67,
  IDIVK 64, MULK 36, SUB 35 and FORLOOP 31. Improvements here help many loops;
  preserve polling, hooks, tags and relocation behavior.
- **Tried and dropped:** sending native fallback through the original handler
  raised `ncall` 420.5M → 446.5M; a partially prepared fallback cost 442.5M.
  More aggressive direct fresh entry reduced `call1` to 376.5M but raised
  `ncall` 420.5M → 424.5M. Earlier discarded attempts include a frame pointer
  local to `vm_execute`; 64-byte frames (three extra instructions per call);
  re-deriving the closure in each handler; moving trace fetch out of line; and
  native precall as a separate out-of-line procedure (25 extra instructions per
  native call). See commits 65e55dc, e3fafd4, 6481741, 68f45c9 and 3e82229.

## 2. Tables, globals and library calls

- **Globals:** short-string global reads fell 246.7M → 192.7M (reference
  174.6–192.6M); primitive `SETTABUP` 380–400M → 248–268M (198–216M).
  Remaining hit costs per iteration are 65–76 versus 59–68 for reads and
  93–103 versus 71–80 for existing-key writes. Reads must handle open and
  closed upvalues and non-string constants from unvalidated bytecode. Writes
  must preserve key/value barriers, saved PC, top and trap on the finish path.
- **Arrays:** `array_insert` fell 649.5M → 613.5M (reference 572.5M); an
  insert-and-read pair costs 197 versus 179 instructions. Look for broader
  `SETTABLE`/`GETTABLE` and immediate-index wins without hurting hash keys.
- **Sort and API:** `micro/tablesort` improved 6,157.8M → 3,616.3M (reference
  4,523M); `tables/tablesort` 1,723M → 1,020M (1,269M). A Lua comparator
  fell 635M → 518M (505M), while `__lt` sort fell 1,093M → 983M (826M,
  +19%). Profile `callbinTM`, metamethod lookup and re-entrant callbacks.
  A math.min/max probe improved 1,089.5M → 993.5M but reference is 776.5M;
  check shared API/call costs, not just sort.
- **Tried and dropped:** the first variable-key array split raised integer-hash
  writes 236.6M → 286.6M and generic keys by 38M. The first global-write split
  repeated the pre-set on misses and raised new empty environments 483.6M →
  512.2M. Inlining numeric ordering inside `vm_lessthan` regressed switch I/O
  code generation: the `iobench` minimum moved 9,249.9M → 9,254.2M.

## 3. Memory, strings and collection

Overlapping-word `mem_eq` reduced tablechurn by 22M and strpattern by 15M
instructions. `api_tolstring` now checks GC after rooting a converted number:
numeric `table.concat` sampled peak fell 7,362 → 1,918 KiB (reference 1,188)
and the intern table 119,944 → 229 strings (reference 230).

- **Open: string garbage and accounting.** `strconcat` sampled peak remains
  25,448 KiB versus 14,012 KiB. At the final atomic → sweep the port has
  157,408 interned strings versus reference's 215,384, then grows to 320,742
  strings / 524,288 buckets versus 221,803 / 262,144. Minor, major sweep and
  major propagate steps were 53/53, 180/247 and 8/9 respectively (port/ref).
  A forced-full-GC control went 252,184 → 200,216 versus 201,075 → 200,215:
  investigate why sweep timing leaves more real garbage. Reference also
  transfers a spilled aux buffer into an `LSTRMEM` external string, uncounted
  by `collectgarbage("count")`, and charges a GC step; the port copies it to
  a counted string (+4.34 MB). After full GC the counted heap still differs by
  about 1.6 MB, about eight bytes per live short string (32-byte header versus
  24). Explore ownership with short-string normalization, allocation failure
  and finalizers, and compact short strings, without hot-path regressions.
- **Intern chains:** an old profile claimed 3× reference per chain lookup, but
  a 200k-lookup aggregate probe used 32.8M versus reference's 37.4M. This does
  not isolate the chain step, so the 3× claim is not reproduced.
- **Tried and dropped:** a 24-byte header raised `strconcat` 657.7M → 709.4M,
  `tablechurn` 3,751.8M → 4,080.2M and regressed hashes due to short/long
  length dispatch. A long-buffer external-transfer prototype reduced peak
  25,448 → 21,207 KiB but raised `strconcat` 657.6M → 665.5M and tablechurn
  3,729.9M → 3,754.1M, and lacked short external-string semantics. An older
  24-byte-header experiment also regressed hashes before allocator fix 1055a5c.

## 4. Hosted libraries and correctness

- **OS:** Linux's bounded timezone cache reduced local `os.date` 72,166M →
  19,284M (reference 20,808M, `TZ=America/Chicago`), `os.date("*t")` 3,161M
  → 503M (456M), and `os.time(table)` 4,048M → 864.5M (447.6M). `getenv`
  fell 2,496M → 1,378M (1,032M). The remaining table-to-time and getenv gaps
  merit profiling. The cache rechecks `TZ`, re-stats `/etc/localtime` when
  unset, and falls back to the scoped loader for oversized zones; Windows is
  unchanged. Pre-existing differences from glibc remain for POSIX DST rules
  before 1970, some invalid TZ names with alphabetic prefixes, and some
  `mktime` `isdst`/fold/gap cases. The scoped fallback can re-read a changed
  named file where glibc retains its cached copy.
- **Streams:** `file_lines` improved 767.7M → 729.3M (reference 712.7M) and
  `iobench` 9,248M → 8,583M (8,012M). Earlier `file_lines` cycles were about
  1.2× reference, with roughly 750k versus 23k cache misses and 2.68M versus
  1.46M L1 misses. Samples clustered near the stream mutex's atomic exchange;
  that is not an established cause and needs a quiet machine. The possible
  threaded `iobench` minimum shift 8,582.7M → 8,641.1M needs a larger seed
  distribution; its threaded/switch residual is unattributed.
  The former stream-test flake was test isolation, not incorrect locking:
  process-wide `flush_all` could flush another test's deliberately failing pipe
  or `/dev/full` stream before its explicit flush. A test mutex and a
  cross-thread error-reporting test fix and cover this. Forced interleaving
  failed 20/20 before the fix; natural reproduction was 0/200 both before and
  after. The full current matrix passed, but that is not a flake frequency proof.
- **Math and patterns:** contextless transcendental callbacks reduced
  `math_transcend` 1,359.9M → 1,201.8M (reference 1,228.9M); results are
  bit-identical to the previous implementation over 1,568,070 raw patterns
  (`tests/transcend_bits.lua`), not necessarily to platform libm. Patterns
  were unchanged: `strpattern` remains about +34% instructions with earlier
  approximate cycles below reference, so prioritize broader wins first.
- **Formatting:** macOS/BSD number formatting follows their `vfprintf` source
  (54f0160) but has not run there. Compare `tests/format_diff.lua` with a
  reference build on each host as described in [BUILDING.md](../BUILDING.md).

## 5. Validation and portability

- Run the threaded default on Windows x64, Linux arm64 and macOS arm64. They
  were cross-compiled to objects only; runtime testing was skipped by the
  user's decision. macOS also needs runtime validation of the hosted allocator's
  direct malloc path (1055a5c).
- Repeat cycle measurements on a quiet machine, including the stream cache
  counters and seed-sensitive I/O. On this host a small cycle difference is not
  conclusive.
- Support for **32-bit targets** requires revisiting object layouts, hosted
  allocator alignment and vararg-count width; current layout assertions require
  64-bit targets.
- Compiler checks now emit no warnings. Parser and aux-buffer lifetime warnings
  were false positives silenced explicitly with lifetime comments; `jmp.odin`
  shim warnings use byte-identical encodings, and `check.sh` no longer passes
  kernel defines to the generator. Preserve these lifetime and byte-encoding
  constraints if the affected code changes.
