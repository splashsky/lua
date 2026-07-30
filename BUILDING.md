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

## Freestanding object

The freestanding build is selected by Odin's built-in
`ODIN_OS == .Freestanding` condition, not a custom define:

```sh
./build/build.sh freestanding
FREESTANDING_TARGET=freestanding_amd64_sysv ./build/build.sh freestanding
```

```powershell
.\build\build.ps1 freestanding
.\build\build.ps1 freestanding -FreestandingTarget freestanding_amd64_sysv
```

It emits one `build/out/lua-freestanding.o` on Unix or
`build/out/lua-freestanding.obj` on Windows using:

```
-target:freestanding_amd64_sysv -no-crt -default-to-nil-allocator
-no-entry-point -build-mode:obj -use-single-module
```

This is a relocatable object for an embedder or firmware link, not a runnable
program. The embedder must call `lua.new_state` with its own `lua.Allocator`;
the hosted `lua.default_allocator` is intentionally not declared.
The emitted object also provides the C-ABI convenience exports
`luao_freestanding_newstate` and `luao_freestanding_close`.

The wrappers add `-define:LUA_FREESTANDING_WIN64_ABI=true` only for the
`freestanding_amd64_win64` and `freestanding_amd64_mingw` triples. Odin selects
the freestanding source set without help, but does not currently expose that
amd64 sub-ABI to source code; the jump shim must know which nonvolatile
registers to preserve.

Verified object targets are `freestanding_amd64_sysv`,
`freestanding_amd64_win64`, `freestanding_amd64_mingw`, and
`freestanding_arm64`. arm32, riscv64, wasm32, and wasm64p32 stop at the explicit
`jmp.odin` unsupported-architecture panic. `-build-mode:lib` is not used because
this Odin toolchain reports that linking a freestanding amd64 static library is
not yet supported.

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

> **Note (Windows, spaces in the repo path):** `odin test` compiles the test binary
> and then runs it; if the output path contains a space (e.g. an `OneDrive - Microsoft`
> path), Odin mis-tokenizes it and fails with `Unknown argument encountered '-'`.
> `build/test.ps1` avoids this by writing the test binary to a space-free temp
> directory (`%TEMP%\luao-tests`). If you invoke `odin test` by hand from such a path,
> pass `-out:` to a space-free location yourself.

## Building the reference Lua (for differential tests)

The vendored source under `lua/` builds with its own Makefile:

```sh
cd lua && make            # produces lua/src/lua and lua/src/luac
```

These reference binaries are used by differential tests to compare our output and
bytecode byte-for-byte. Their build artifacts are git-ignored.
