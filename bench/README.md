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

### Comparing VM instruction counts on Linux

`build/vm-compare.sh` builds explicitly selected switch and threaded interpreters
side by side under `TMPDIR`, and optionally compares reference Lua. The threaded
column represents the default on amd64 and arm64; the switch is selectable with
`VM_THREADED=0` in single-mode wrappers:

```sh
REFLUA=/path/to/lua CPU=12 ./build/vm-compare.sh 5 > comparison.md
```

It requires Linux `perf` with access to user-space `instructions:u` and
`cycles:u`; `CPU` optionally pins every run with `taskset`. The positional run
count defaults to 3. Each named harness workload (including scaling) and every
file in `bench/probes/` runs in a fresh process, with interpreter order rotated
between repetitions. The Markdown table reports **minimum/median instructions;
minimum/median cycles**, in millions, for switch / threaded / reference. A
missing `REFLUA` leaves the reference column empty. Counts include startup and
harness setup. Cycles are **approximate** under load; hash-sensitive workloads
vary by around ±20M instructions with the randomized string-hash seed. Use more
runs and a quiet, pinned core for small differences.

The probe files include the historical microprobes as well as the two-million
iteration global-read, one-argument-call, empty-loop, local `os.date` and
`os.getenv("HOME")` probes cited in `docs/FUTURE_WORK.md`. The local date probe
uses the process timezone; record or set `TZ` consistently across comparisons.
Benchmark builds inherit the brand settings, but not `VM_THREADED`: the runner
always explicitly builds both modes. Its temporary files are removed on exit.
For a source snapshot in another directory, `VM_COMPARE_SRC=/path/to/src`
selects its source tree while retaining this checkout's harness and probes.

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
earlier workloads: full collections before timing reclaim garbage but do not
shrink the allocator's heap or reset the collector's pacing. In one measurement
`strconcat` looked like a 0.44× regression in-suite and was a 1.43× improvement
run alone. **Decision-making numbers should always come from isolated runs.** The
all-in-one mode remains for deliberately investigating those interactions; runner
headings say `isolated process` or `all-in-one process`.

## Reading the output

Each normal benchmark reports CPU seconds, work units per second, and the change
in Lua-visible heap size. An “op” means something different on every line, so
**ops/sec is comparable only between interpreters for the same benchmark name**.

`collectgarbage("count")` reports memory visible to Lua's allocator in KiB. Peak
RSS is sampled by the runner and covers the whole process, so the two should not
be expected to match.

Timings depend on machine load, so only same-session, back-to-back runs are a
comparison. On a loaded machine prefer `build/vm-compare.sh`: instruction counts
separate a real path change from scheduling noise.
