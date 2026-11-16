# Future work

What remains, in priority order, with the evidence behind it. Written in
November 2026 against master `0738e32`, after eight per-area analyses whose
details are in [plans/](plans/README.md). Correctness and platform validation
come before performance. Failed experiments are under [Dead ends](#dead-ends) so
they are not repeated.

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

The analyses found larger gaps that the harness does not cover (threaded /
reference, millions; the probes are described in the plans):

| Probe | Threaded | Reference |
|---|---:|---:|
| `string.find` of a plain string, long subject, no match (2,000) | 100.8 | 3.3 |
| `gsub` with a long replacement string (10,000) | 153.8 | 15.5 |
| `t.x = v` (SETFIELD, 2M) / `t.x` (GETFIELD, 2M) | 320.5 / 244.5 | 196.5 / 170.5 |
| `#t` (2M; switch 270.5) | 312.5 | 226.5 |
| `os.time(t)` with a reused table (100k) | 868.2 | 469.1 |
| `math.min` + `math.max` loop (2M) | 1,500.7 | 1,232.7 |
| `table.sort` with an `__lt` metamethod (100 × 1,000) | 983.2 | 830.9 |

**Measuring.** Instruction counts are the primary metric; every cycle figure so
far comes from a shared, loaded machine and is approximate. Hash seeds, GC,
environment layout and I/O vary some counts, so compare distributions. Code
placement moves both interpreters by a few instructions per operation; check the
generated code before attributing a small change.

## Plan

Each item is one branch, sized for one agent, with acceptance targets in the
linked plan. "Measured" means a scratch prototype was built and counted;
"estimated" means it was not.

### P0 — correctness

1. **`fix/pattern-position-backref`** — `string.match("abc", "()%1a")` aborts the
   interpreter with an uncatchable bounds-check failure, and `("abc"):match("()%1")`
   returns 1 instead of nil: `check_capture` accepts a position capture as a
   back-reference. ([patterns](plans/patterns.md), package 1)
2. **`fix/os-time-range-sentinel`** — `os.time` returns −1 for one second before
   the epoch in UTC where reference raises an error, and accepts normalized years
   outside the representable range. ([correctness-tz](plans/correctness-tz.md) A1, A2)
3. **`fix/os-local-mktime-candidates`** — in a DST gap, or with a wrong `isdst`,
   `os.time` can choose a zone's 19th-century local-mean-time offset (New York
   2024-03-10 02:30 normalizes to 03:26:02, not 03:30), and `isdst=true` in a zone
   without DST raises an error. Then land **`os-time-lazy-civil`** on the same
   function: 867 → 720M per 100k, measured. (correctness-tz A3, A4;
   [os-io](plans/os-io.md) lever 1)
4. **`tests/portable-nan-fixture`** — the only unit test that fails on arm64
   assumes `-(0/0)` formats as `NAN`; reference prints `-NAN` there too.
   ([validation](plans/validation.md))

### P1 — performance with measured prototypes

The VM packages all touch the generator. Land `perf/threaded-dispatch-table` first,
because it changes every handler's signature; the others touch different opcodes
and can then run in parallel, merging mechanically.

5. **`perf/threaded-dispatch-table`** — carry the handler table's address between
   handlers instead of recomputing it each fetch: one instruction per executed
   instruction; `intloop` −140M, `fib` −25M, `call1` −6M measured, `ncall` flat.
   Add the arithmetic and dispatch probes from the plan first.
   ([loops-arith](plans/loops-arith.md), packages 1–2)
6. **`perf/threaded-compare`** — `LTI` and the other comparison handlers copy the
   120-byte Odin context before testing for integers; contextless integer and
   float paths are estimated at −106 to −141M on `fib(32)`, its largest excess.
   Not prototyped. ([calls](plans/calls.md), Causes)
7. **`perf/table-len`** — contextless `#t` for tables without a metatable: 312 →
   225M; `t[#t+1] = v` 77 → 64M (reference 63), measured.
   ([tables-globals](plans/tables-globals.md), package 2)
8. **`perf/global-shortset`**, then **`perf/field-hit`** — inline existing-key hits
   for global writes (−22 instructions each) and for field reads and writes (244 →
   184M, 320 → 196M), measured. The prototypes re-probed on a miss, which is a dead
   end; the plan specifies passing the lookup's position to the miss path instead.
   (tables-globals, packages 3–4)
9. **`perf/array-pivot`** — keep the array pointer in a local: `array_insert` 613 →
   601M, `tablechurn` −13M, measured. (tables-globals, package 1)
10. **`calls/minmax-native`** — contextless `math.min`/`max`: 1,501 → 1,359M,
    measured, with `call1` and `ncall` unchanged. (calls, package 1)
11. **`calls/multireturn`** — a fast path for fixed multiple results: 220 → 167M
    for three results, measured, but the prototype slowed varargs, `<close>` and
    closures; land it only without those regressions. (calls, package 3)
12. **`patterns/matcher-hotpath`** — after P0 item 1: drop index checks only where
    the plan proves them redundant, stop zeroing the 512-byte capture array per
    call, and inline `match_default`: `strpattern` 5,077 → 4,300M, measured.
    (patterns, package 2)
13. **`patterns/plain-search`** — a sparse scan for plain `find`: target long miss
    ≤10M without slowing dense or binary subjects. (patterns, package 3)
14. **`patterns/replacement-spans`** — copy literal replacement spans in `gsub`:
    target ≤25M on the long-replacement probe. (patterns, package 4)
15. **`os-getenv-fast-string`** — the checked native argument path and `strlen`:
    about −80M per 2M lookups, measured. (os-io, package 2)

### P2 — conditional or exploratory

- `perf/threaded-floor-k`: split integer `MODK`/`IDIVK` from their float and error
  paths, −214M on `intloop` after item 5, but the prototype slows float `//` and
  `%` by about 3%; land only if that is eliminated. Then `perf/threaded-arith-layout`.
- `perf/short-hash` (bounded hash mask and node pointer, a few million on string
  keys), `calls/tm-stack` (small), `calls/reentry-study` (context reuse when native
  code calls Lua, ≤14M ceiling on the `__lt` sort), `calls/entry-closure-study`,
  `patterns/boundary-eval`, `os-time-cache-candidates`.
- `io-locality-study` (4/8/16 KiB stream buffers, on a quiet machine), then
  `io-lock-fastpath-study` only if it pays and stays thread-safe.
- `strings-gc/pacing-traces`: diagnostic collector traces for future pacing work.
- Time-zone compatibility with glibc: `fix/tz-linux-discovery` (`TZ=:` and
  `TZDIR`), `fix/tz-linux-partial-parser` (names glibc half-parses), and, if
  wanted, `feat/tz-posix-default-rules` and `feat/tzif-leap-seconds`.
- Validation: `build/native-validation-harness`, then `ci/native-vm-validation`
  (draft workflow in [validation](plans/validation.md)); `bench/quiet-vm-compare`.

## Decisions needed

1. **Native CI.** Enable the draft GitHub Actions matrix (Windows x64, macOS
   arm64, Linux arm64; free for this public repository)? Manual runs first, or on
   every push? Accept the device-adapted PUC run as a gate alongside a recorded
   verbatim failure on Windows and macOS?
2. **External strings.** Lua 5.5's `lua_pushexternalstring` is not implemented.
   Implementing it would complete the embedding API and remove about 4,240 KiB of
   counted peak on string building, but only a design with zero cost on hot string
   paths is acceptable. Prototype it, or defer?
3. **Time zones.** Support leap-second (`right/*`) zones? Should a change of `TZDIR`
   invalidate the zone cache? Keep the documented repeated- and skipped-hour
   choices and the pre-1970 POSIX-rule behavior (recommended)? Adopt glibc's
   default DST rules (`posixrules`) for `TZ` values like `AAA0BBB`?
4. **A quiet machine** for cycle measurements, and permission to change its CPU
   settings; the protocol is in [validation](plans/validation.md).
5. **32-bit and BSD.** Recommended: defer both until there is a target. BSD amd64
   does not compile today (the jump shim rejects it); FreeBSD and NetBSD arm64
   type-check. A 32-bit port is several weeks of layout and ABI work.

## Settled by the analysis

- **Peak heap on string building** (`strconcat` 26,046 KiB counted against 14,754).
  The collector's sweep, step sizes and debt match reference step for step. The
  gap comes from our 8-byte larger short-string header, which shifts collection
  timing (a diagnostic build that ignored those 8 bytes dropped to 19,984 KiB),
  and from reference keeping the finished buffer as an uncounted external string
  (about 4,240 KiB). There is no pacing fix; see decision 2. An index sidecar
  that would shrink the header costs about 484 KiB more than it saves at 200k
  strings.
- **Intern-chain cost:** the old 3× claim is wrong. A chain step costs 5
  instructions against reference's 6.
- **`file:lines`:** the earlier 1.2× cycle gap and cache misses did not recur;
  remaining L1 misses depend on buffer size.
- **`iobench`:** the threaded/switch difference is hash-seed noise.
- **Linux arm64:** both interpreters pass the PUC-Rio suite under QEMU, plain and
  stressed; number formatting matched an arm64 reference over 279,336 cases.
  Native arm64, Windows and macOS remain unrun, and the arm64 ASan runtime was
  unavailable.
- **Accepted time-zone differences:** our deterministic repeated- and
  skipped-hour choices, proleptic pre-1970 POSIX rules, re-reading an oversized
  changed zone file, and glibc artifacts on malformed `TZ` values stay as they
  are (correctness-tz classes C and D).

## Dead ends

Measured and dropped; instruction counts in millions. Commit bodies and plans
have more.

**Calls**
- Native fallback through the original handler: `ncall` 420.5 → 446.5; a
  partially prepared fallback 442.5.
- A more aggressive direct fresh entry: `call1` 376.5 but `ncall` 420.5 → 424.5.
- A native-call tail transition: `fib` −14 but `ncall` 420.5 → 440.5.
- Skipping the same-slot result copy after metamethod calls: switch `call1` 476.7
  → 482.7.
- Passing `&context` directly through internal calls does not compile in Odin; it
  needs an explicit context-pointer design.
- Switch interpreter: a frame pointer local to `vm_execute`; 64-byte frames (3
  more instructions per call); re-deriving the closure in each handler; moving
  the trace fetch out of line; native precall out of line (+25 per native call).

**Loops, arithmetic and dispatch**
- A dedicated handler for empty self-jumping loops: it helps only empty loops and
  hides the back-edge cost the probe measures.
- An integer-only `ADD`/`SUB`/`MUL` split: `intloop` −560 but `floatloop` +310.
- An inline mixed-number arithmetic rewrite: worse on both loops.
- Reordering the threaded handler arguments: no change.
- Threaded-only declarations in `vm.odin`: they moved the switch's code and slowed
  it; threaded helpers live in their own files.
- Splitting the generated region into a second file: mixed results.

**Tables and API**
- The first variable-key array split: integer-hash writes 236.6 → 286.6, generic
  keys +38.
- Global or field write hits that re-probe the table on a miss: new environments
  483.6 → 512.2 (and 438 → 449 in a later prototype).
- Skipping the open-upvalue and non-string-constant checks on globals: 3–6 per
  access, unsafe with `debug.upvaluejoin` and partially loaded chunks.
- A first generic `SELF` check: string method calls 882.7 → 900.7.
- Inlining numeric ordering inside `vm_lessthan`: switch code generation
  regressed.
- Moving the collectable-value barrier check into the hot write handler:
  `strconcat` 686.7 → 676.1 but `array_insert` 721.3 → 724.3.
- Testing string keys first in the slow setter: `strconcat` and `hash_prekey`
  both regressed.

**Strings and memory**
- A 24-byte `TString` header with short/long length dispatch: `strconcat` 657.7 →
  709.4, `tablechurn` 3,751.8 → 4,080.2, hash workloads regressed.
- Charging the collector as if string headers were 8 bytes smaller: it closes
  much of the heap gap but misstates memory use.
- Transferring long aux buffers to external strings with a check on every string
  access: peak 25,448 → 21,207 KiB, but `strconcat` +8 and `tablechurn` +24.
- A shared concat helper: −11 instructions but code placement elsewhere got worse.
- A wrapper that only moved concat's context copy: +5 instructions per concat.
- A contextless wrapper around closure allocation: `closures` 4,205.8 → 4,241.8.

**Libraries**
- Plain `find` via an `index_byte` hybrid: long miss 100.8 → 6.1, but dense
  candidates +11% and binary subjects +8%.
- Deduplicating time-zone candidates per call: POSIX zones 700.3 → 705.9.
- Removing the stream read lock: −18 per 200k lines, but unsafe; a measurement
  control only.
