# Benchmark harness

This directory contains repeatable, pure-Lua measurements for comparing
lua-odin with reference PUC Lua. They are deliberately simple and fixed-size:
the goal is trustworthy before/after evidence for runtime changes, not a broad
application benchmark.

## What the files stress

- `micro.lua` covers recursive calls, integer and float arithmetic, string
  construction and patterns, mixed table churn, sorting, and closure allocation.
- `tables.lua` separates dense array storage, hash operations with freshly
  allocated string keys, hash operations with pre-built keys, and sorting.
- `scaling.lua` inserts pre-built string keys at four doubling sizes. Near-2x
  time growth is linear; near-4x growth can reveal an O(N²) rehash pathology.
- `stdlib.lua` covers float conversion, formatting, transcendental maths,
  buffered file I/O, and date formatting.
- `harness.lua` holds the shared collection, timing, throughput, and Lua-heap
  reporting methodology so every measured workload uses the same boundaries.

The workloads are unchanged from the original throwaway scripts, which keeps
new results comparable with the historical measurements.

## Running

From the repository root:

```powershell
# Windows: build and run all files.
.\build\bench.ps1

# Run one file, or reuse the previous optimized build.
.\build\bench.ps1 -File tables.lua
.\build\bench.ps1 -NoBuild

# Run lua-odin and reference Lua back-to-back for each file.
# Comparisons isolate every named benchmark in a fresh process by default.
.\build\bench.ps1 -Reference C:\path\to\lua.exe

# Request isolation without a reference, or deliberately inspect interactions.
.\build\bench.ps1 -NoBuild -File micro.lua -Isolated
.\build\bench.ps1 -NoBuild -File micro.lua -InProcess
```

```bash
# macOS / Linux: build and run all files.
./build/bench.sh

# Run one file, or reuse the previous optimized build.
./build/bench.sh tables.lua
./build/bench.sh --no-build

# Run lua-odin and reference Lua back-to-back for each file.
REFLUA=/path/to/lua ./build/bench.sh

# Request isolation without a reference, or deliberately inspect interactions.
./build/bench.sh --no-build --isolated micro.lua
./build/bench.sh --no-build --in-process micro.lua
```

The runners build lua-odin with `-o:speed`. The Windows runner also reserves the
larger native stack used by the project's other CLI scripts.

Every benchmark file also has a small direct-invocation interface:

```text
lua micro.lua --list
lua micro.lua strconcat
```

With no second argument the file runs all of its benchmarks, just as it always
has. `--list` prints discoverable names, one per line, and a name runs only that
workload. The runners use those names rather than maintaining hard-coded copies.

## Why comparison runs are isolated

Running a whole file in one interpreter process makes later results depend on
earlier workloads. Two full collections before timing reclaim unreachable
objects, but they do not shrink the allocator's heap capacity or reset the
collector's pacing and debt. A later benchmark can therefore see a materially
different runtime state than it gets in a fresh process.

`strconcat` made the problem especially visible:

| build | in-suite | run alone |
|---|---:|---:|
| pre-change | 1,388,889 ops/s | 1,282,051 ops/s |
| current | 609,524 ops/s | **1,828,571 ops/s** |
| PUC reference | 1,307,190 ops/s | 1,234,568 ops/s |

The in-suite result calls the current build a 0.44x regression, while the fresh
process result shows a 1.43x improvement. That inversion is a harness artifact,
not a property of string concatenation. **Published or decision-making
comparison numbers should always come from isolated runs.** The all-in-one mode
remains available because those interaction effects can themselves be useful
when deliberately investigating allocator or GC behavior. Runner headings say
`isolated process` or `all-in-one process` so captured output is unambiguous.

## Reading the output

Each normal benchmark reports CPU seconds, work units per second, and the change
in Lua-visible heap size. An “op” has a different meaning on every line, so
**ops/sec is comparable only between interpreters for the same benchmark name**.
Never compare the ops/sec values of two different benchmark names.

`collectgarbage("count")` reports memory visible to Lua's allocator in KiB. Peak
RSS is sampled by the runner and covers the whole process, including the
executable, native stacks, allocator overhead, and libraries. They answer
different questions and should not be expected to match.

Machine load, thermal state, and background activity materially affect timings.
Only same-session, back-to-back lua-odin/reference runs should be treated as a
comparison. Even then, repeat noisy results and consider alternating interpreter
order when investigating a small difference; the standard runner intentionally
runs lua-odin first for a stable, easy-to-understand protocol.

On a loaded Linux machine, wall-clock times are especially noisy. As an additional
comparison, alternate builds and collect `perf stat -x, -e cycles:u,instructions:u`
for at least five runs of each workload, reporting the minimum cycles and instruction
counts. Instruction counts help distinguish a genuine path change from scheduling
noise; use isolated benchmark names for the same reason as above.
