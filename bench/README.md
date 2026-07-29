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
.\build\bench.ps1 -Reference C:\path\to\lua.exe
```

```bash
# macOS / Linux: build and run all files.
./build/bench.sh

# Run one file, or reuse the previous optimized build.
./build/bench.sh tables.lua
./build/bench.sh --no-build

# Run lua-odin and reference Lua back-to-back for each file.
REFLUA=/path/to/lua ./build/bench.sh
```

The runners build lua-odin with `-o:speed`. The Windows runner also reserves the
larger native stack used by the project's other CLI scripts.

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
