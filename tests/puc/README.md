# tests/puc — vendored PUC-Rio Lua 5.5 test suite

This directory holds the **official PUC-Rio Lua 5.5 test suite**, vendored
verbatim, and serves as the project's final, whole-language correctness oracle:
real Lua's own regression tests, run unmodified against our reimplementation.
Because the files are not written by us and are not tailored to our internals,
passing them is honest, un-fitted evidence that the interpreter behaves like Lua.

## What's here

- `all.lua` — the master driver. It `dofile`s every other suite file in
  dependency order (some through an in-memory dump/undump round-trip).
- The individual test files (`math.lua`, `strings.lua`, `pm.lua`, `sort.lua`,
  `coroutine.lua`, `gc.lua`, `files.lua`, …) — vendored verbatim.
- `libs/` and `ltests/` — the reference build's C helper library (`lib*.c`) and
  internal C testing module (`ltests.c`/`ltests.h`). These are vendored for
  fidelity but are **not** used by our runner: they only build under the reference
  C toolchain and expose the internal `T` test library. Every suite file guards
  its `T` usage with `not T or ...`, so with `T` absent those checks are simply
  skipped.

These files are third-party and are marked `linguist-vendored` in
`.gitattributes` so they don't skew language stats and collapse in diffs.

## Running the suite

From the repository root:

```powershell
# Windows
.\build\puc.ps1                 # build lua.exe, run the whole suite (all.lua)
.\build\puc.ps1 -File math.lua  # run one file standalone
```

```bash
# macOS / Linux
./build/puc.sh                  # build lua, run the whole suite (all.lua)
./build/puc.sh math.lua         # run one file standalone
```

The whole-suite run passes `-e "_U=true"` (the suite's "user tests" mode). A
single-file run passes `-e "_soft=true; _port=true; _nomsg=true"` — soft limits
(smaller iteration counts), portable mode, and no interactive message.

## Status

Every suite file passes against our interpreter, with the platform-specific
exception noted below. The suite is exercised continuously as the final gate for
correctness work.

## Documented deviations

These are intentional, documented differences — not defects — consistent with the
project's scope decisions (see `docs/ARCHITECTURE.md`).

- **`files.lua` — Unix device files (Windows only).** Partway through, `files.lua`
  opens the Unix special files `/dev/null` and `/dev/full` to test flushing and
  write-error handling. Those paths don't exist on Windows, so the file aborts
  there — reference Lua on Windows fails at the exact same point. All of the io
  library tests *before* that point pass. On macOS/Linux, where the devices exist,
  `files.lua` runs to completion.

- **`T` internal test library absent.** We do not build the reference `ltests`
  C module, so the global `T` is `nil`. The suite is written to skip `T`-gated
  checks in that case (`not T or ...`), which is the same behavior as a stock
  reference build compiled without `LUA_USER_H`/ltests.

- **C dynamic modules (`libs/*.c`).** Tests that `require`/`loadlib` a compiled C
  module (e.g. parts of `attrib.lua`) target `.so`/`.dll` files built from
  `libs/`. Our `package` library loads **Odin-native** dynamic modules instead of
  C `luaopen_*` modules (a documented project-wide deviation), so those specific
  C-module load paths are not exercised; the Lua-source searchers still are.
