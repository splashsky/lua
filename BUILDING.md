# Building lua-odin

## Prerequisites

- **Odin compiler** on your `PATH`. Check with `odin version`.
- A recent nightly is fine; this project tracks current Odin.
- **A native linker + system libraries to produce runnable binaries:**
  - **Windows:** the **Windows SDK** plus the **MSVC** toolchain (e.g. install
    *Visual Studio Build Tools* with the "Desktop development with C++" workload).
    Without these, Odin reports `Windows SDK not found` and cannot link `.exe`s or
    run `odin test`. You can still fully *type-check* the code without them — see
    "Linker-free verification" below.
  - **macOS:** the Xcode command-line tools (`xcode-select --install`).
  - **Linux:** a working `cc`/`clang` and libc.
- (Optional, for differential tests) a C toolchain to build the reference Lua under
  `lua/` — `make` on macOS/Linux, or MSVC/clang on Windows.

## Linker-free verification

`odin check` type-checks a package without linking, so it works even on a machine
with no native linker/SDK. This is the quickest way to confirm the code is sound:

```sh
odin check src            -collection:luao=src   # the `lua` CLI (package main)
odin check src/luac       -collection:luao=src   # the `luac` CLI (package main)
odin check src/lua        -collection:luao=src -no-entry-point   # kernel library
odin check src/stdlib     -collection:luao=src -no-entry-point   # stdlib library
odin check tests          -collection:luao=src                   # the test package
```

The convenience wrappers `build/check.ps1` (Windows) and `build/check.sh` (Unix) run
all of these for you.

## The `luao` collection

Odin compiles a whole directory as a single package, and packages find each other
through *collections*. Every build/test command in this repo passes:

```
-collection:luao=<repo>/src
```

which lets any package import its siblings as `luao:lua`, `luao:stdlib`, and so on,
independent of where the repo is checked out. The provided scripts set this for you.

## Build

macOS / Linux:

```sh
./build/build.sh          # build the standalone `lua` CLI (default)
./build/build.sh luac     # build the `luac` compiler
./build/build.sh all      # build both
DEBUG=1 ./build/build.sh  # debug build
```

Windows (PowerShell):

```powershell
.\build\build.ps1          # build the standalone `lua` CLI (default)
.\build\build.ps1 luac     # build the `luac` compiler
.\build\build.ps1 all      # build both
.\build\build.ps1 lua -DebugBuild
```

Binaries land in `build/out/`.

## Test

Odin's built-in test runner compiles and runs the `@(test)` procs under `tests/`.

macOS / Linux:

```sh
./build/test.sh                # run all unit tests
./build/test.sh some_test_name # run a single test by (unqualified) name
```

Windows (PowerShell):

```powershell
.\build\test.ps1                 # run all unit tests
.\build\test.ps1 -Name some_test_name
```

Running one test by name uses Odin's `-define:ODIN_TEST_NAMES=tests.<name>` filter
under the hood.

## Building the reference Lua (for differential tests)

The vendored source under `lua/` builds with its own Makefile:

```sh
cd lua && make            # produces lua/src/lua and lua/src/luac
```

These reference binaries are used by differential tests to compare our output and
bytecode byte-for-byte. Their build artifacts are git-ignored.
