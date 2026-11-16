# Future work

What remains, with the evidence behind it, as of master `fbcffa8` and the doc
trim that followed (November 2026). Correctness and platform validation come
before performance. Failed experiments are listed under [Dead ends](#dead-ends)
so they are not repeated.

## Where we stand

Median instructions in millions against reference Lua 5.5.1, Linux x86-64, from
`build/vm-compare.sh` (method, minima, cycles and sizes in
[bench/THREADED_VM.md](../bench/THREADED_VM.md)):

| Workload | Default threaded | Switch | Reference | Threaded vs reference |
|---|---:|---:|---:|---:|
| micro/fib(32) | 1,901.3 | 2,074.0 | 1,640.5 | +15.9% |
| micro/intloop | 6,061.5 | 6,421.6 | 4,952.9 | +22.4% |
| micro/floatloop | 7,519.9 | 8,339.9 | 7,217.0 | +4.2% |
| micro/strconcat | 645.5 | 667.2 | 880.0 | −26.6% |
| micro/strpattern | 5,077.4 | 5,112.6 | 3,803.6 | +33.5% |
| micro/tablechurn | 3,669.8 | 3,881.0 | 4,813.7 | −23.8% |
| micro/tablesort | 3,577.5 | 3,662.5 | 4,532.3 | −21.1% |
| micro/closures | 2,919.5 | 2,981.5 | 3,026.6 | −3.5% |
| tables/array_insert | 613.5 | 712.5 | 572.5 | +7.2% |
| tables/hash_strkey | 1,017.0 | 1,049.0 | 1,288.0 | −21.0% |
| stdlib/math_transcend | 1,187.8 | 1,297.8 | 1,228.9 | −3.3% |
| stdlib/file_lines | 717.9 | 719.1 | 712.7 | +0.7% |
| probe/gtab (global read) | 192.7 | 298.7 | 174.6 | +10.4% |
| probe/call1 (one-argument call) | 384.7 | 476.7 | 388.7 | −1.0% |
| probe/empty (empty numeric loop) | 62.7 | 68.7 | 56.6 | +10.8% |
| probe/os_date (local time) | 19,168.1 | 19,297.8 | 20,801.9 | −7.9% |
| probe/getenv | 1,314.7 | 1,472.7 | 1,046.6 | +25.6% |
| probe/iobench | 8,611.9 | 8,550.2 | 8,070.4 | +6.7% |

**Measuring.** Instruction counts are the primary metric; the machine these
were taken on was shared and loaded, so every cycle figure so far is
approximate. Hash seeds, GC, environment layout and I/O vary some counts
(`gtab` reference ranged 174.6–192.6M), so compare distributions for those.
Code placement moves both interpreters by a few instructions per operation;
check the generated code before attributing a small change.

## 1. Calls and recursion

`call1` costs 194 instructions per iteration, equal to reference. Per piece,
threaded/reference: fetch and dispatch 46/27, frame entry 24/26, `CALL` 25/23,
`RETURN1` 21/19, two `MOVE`s 18/28, `FORLOOP` 23/23, frame setup 37/48.

- **`fib(32)` +16%.** In `fib(22)`, frame entry/re-entry costs 2.29M against
  1.43M and other VM work including dispatch 7.94M against 6.16M. Any change must
  not slow native calls (`ncall`).
- **General `RETURN` and closure creation** have not been profiled on their own.
- **`__lt` sorting +19%** (983M against 826M) and a `math.min`/`max` probe
  +28% (994M against 777M) point at metamethod calls (`callbinTM`) and the
  native-call path rather than at sort itself.

## 2. Loops, arithmetic and dispatch

Per iteration, threaded/reference: `FORLOOP` 31/28, `ADD` plus dispatch 35/32.
`intloop` costs 303 against about 248: two `ADD`s 70, `MODK` 67, `IDIVK` 64,
`MULK` 36, `SUB` 35, `FORLOOP` 31. The empty loop is +11%, `il` +6%. Polling,
hooks, tags and relocation behavior must not change.

## 3. Tables, globals and the API

- **Global reads** hit in 65–76 instructions against 59–68: the handler also
  checks open against closed upvalues and supports non-string constants from
  unvalidated bytecode, which reference does not.
- **Global writes** to an existing key cost 93–103 against 71–80.
- **Arrays:** an insert-and-read pair costs 197 against 179 (`array_insert`
  +7%).

## 4. Strings, memory and the collector

- **Peak heap on string building.** `strconcat` peaks at 25,448 KiB against
  14,012. Two causes, from a full collector trace: the port retains more garbage
  strings between collections (it entered the last atomic phase with 157,408
  strings against 215,384, then grew to 320,742 against 221,803, with 180
  against 247 major sweep steps), and reference keeps a spilled aux buffer as
  an uncounted external string (`LSTRMEM`) where the port copies it into a
  counted one (4.3 MB). After a full collection about 1.6 MB remains, eight
  bytes per live short string: our `TString` header is 32 bytes, reference's 24.
- **External strings** need an ownership design (short-string normalization,
  allocation failure, finalizers) that costs nothing on hot paths.
- **Intern-chain cost.** An old profile showed 3× reference per chain step; an
  aggregate 200k-lookup probe now uses 32.8M against 37.4M. The chain step itself
  has not been isolated.

## 5. Hosted libraries

- **`os.getenv` +26%** and **`os.time(table)` about 1.9×** (864.5M against
  447.6M per 100k).
- **`file:lines()`** is at instruction parity but about 1.2× reference in
  cycles, with far more cache misses (about 750k against 23k). Samples gather
  near the stream mutex; not established, and needs a quiet machine.
- **Lua patterns** execute 34% more instructions, though earlier cycle
  measurements were below reference.
- **`iobench`**: the threaded/switch difference is unattributed and seed
  sensitive.

## 6. Correctness differences

These differ from glibc and predate the time-zone cache: POSIX `TZ` DST rules
before 1970, some invalid `TZ` names with alphabetic prefixes, and some `mktime`
`isdst`, repeated-hour and skipped-hour cases. The uncached fallback can re-read
a changed zone file where glibc keeps its copy.

## 7. Validation and portability

- **Run the threaded default** on Windows x64, Linux arm64 and macOS arm64. They
  are cross-compiled only. macOS would also exercise the hosted allocator's
  direct `malloc` path for the first time.
- **Number formatting on macOS and the BSDs** follows their `vfprintf` sources
  but has not been run there (`tests/format_diff.lua`).
- **A quiet machine** is needed for any cycle conclusion.
- **32-bit targets** would need the object layouts, allocator alignment and the
  vararg count revisited.

## Dead ends

Measured and dropped; instruction counts in millions. Commit bodies have more.

**Calls**
- Native fallback through the original handler: `ncall` 420.5 → 446.5; a
  partially prepared fallback 442.5.
- A more aggressive direct fresh entry: `call1` 376.5 but `ncall` 420.5 → 424.5.
- A native-call tail transition: `fib` −14 but `ncall` 420.5 → 440.5.
- Switch interpreter: a frame pointer local to `vm_execute`; 64-byte frames (3
  more instructions per call); re-deriving the closure in each handler; moving
  the trace fetch out of line; native precall out of line (+25 per native call).

**Loops and dispatch**
- A dedicated handler for empty self-jumping loops: it helps only empty loops and
  hides the back-edge cost the probe measures.
- Threaded-only declarations in `vm.odin`: they moved the switch's code and slowed
  it; threaded helpers live in their own files.
- Splitting the generated region into a second file: mixed results.

**Tables and API**
- The first variable-key array split: integer-hash writes 236.6 → 286.6, generic
  keys +38.
- The first global-write split repeated the pre-set on misses: new environments
  483.6 → 512.2.
- A first generic `SELF` check: string method calls 882.7 → 900.7.
- Inlining numeric ordering inside `vm_lessthan`: switch code generation
  regressed.
- Moving the collectable-value barrier check into the hot write handler:
  `strconcat` 686.7 → 676.1 but `array_insert` 721.3 → 724.3.
- Testing string keys first in the slow setter: `strconcat` and `hash_prekey`
  both regressed.

**Strings and memory**
- A 24-byte `TString` header: `strconcat` 657.7 → 709.4, `tablechurn` 3,751.8 →
  4,080.2, hash workloads regressed (short/long length dispatch on every access).
- Transferring long aux buffers to external strings: peak 25,448 → 21,207 KiB,
  but `strconcat` +8 and `tablechurn` +24, without short external strings.
- A shared concat helper: −11 instructions but code placement elsewhere got worse.
- A wrapper that only moved concat's context copy: +5 instructions per concat.
- A contextless wrapper around closure allocation: `closures` 4,205.8 → 4,241.8.
