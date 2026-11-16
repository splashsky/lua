# Building lua-odin

## Prerequisites

- **Odin compiler** on your `PATH`. Check with `odin version`.
- A recent nightly is fine; this project tracks current Odin.
- **A native linker + system libraries to produce runnable binaries and run tests:**
  - **Windows:** the **Windows SDK** plus the **MSVC** toolchain (e.g. install
    *Visual Studio Build Tools* with the "Desktop development with C++" workload).
    Without these, Odin reports `Windows SDK not found` and cannot link `.exe`s or
    run `odin test`. You can still fully *type-check* the code without them — see
    "Linker-free verification" below.
  - **macOS:** the Xcode command-line tools (`xcode-select --install`).
  - **Linux:** a working `cc`/`clang` and libc.
- (Optional, for differential tests) a reference `lua`/`luac` built from the official
  Lua 5.5.1 sources from [lua.org](https://www.lua.org/ftp/) — see "Comparing against
  reference Lua" below.

## Linker-free verification

`odin check` type-checks a package without linking, so it works even on a machine
with no native linker/SDK. This is the quickest way to confirm the code is sound:

```sh
odin check src            -collection:lang=src   # the interpreter CLI (package main)
odin check src/compiler   -collection:lang=src   # the compiler CLI (package main)
odin check src/kernel     -collection:lang=src -no-entry-point   # kernel library
odin check src/stdlib     -collection:lang=src -no-entry-point   # stdlib library
odin check tests          -collection:lang=src                   # the test package

# The bare-metal build selects a different set of files via `#+build freestanding`,
# so the hosted checks above cannot catch a break in it. `odin check` rejects the
# link-time flags (`-no-crt`, `-build-mode:obj`) and does not need them.
odin check src/freestanding -collection:lang=src \
    -target:freestanding_amd64_sysv -default-to-nil-allocator -no-entry-point
```

The convenience wrappers `build/check.ps1` (Windows) and `build/check.sh` (Unix)
run these and type-check the generator without linking. They check both the switch
and threaded interpreters, including freestanding, regardless of `VM_THREADED`.
The generated-source drift check runs in `build/test.*`, which needs a linker.

## The `lang` collection

Odin compiles a whole directory as a single package, and packages find each other
through *collections*. Every build/test command in this repo passes:

```
-collection:lang=<repo>/src
```

which lets any package import its siblings as `lang:kernel`, `lang:stdlib`, and so on,
independent of where the repo is checked out. The provided scripts set this for you.

## Build

macOS / Linux:

```sh
./build/build.sh          # build the standalone interpreter CLI (default)
./build/build.sh compiler # build the bytecode compiler
./build/build.sh all      # build both
DEBUG=1 ./build/build.sh  # debug build
```

Windows (PowerShell):

```powershell
.\build\build.ps1          # build the standalone interpreter CLI (default)
.\build\build.ps1 compiler # build the bytecode compiler
.\build\build.ps1 all      # build both
.\build\build.ps1 lua -DebugBuild
```

Binaries land in `build/out/`, named after the brand (`lua` / `luac` by default).

### Interpreter selection

The tail-call-threaded interpreter is the default on amd64 and arm64; other
architectures use the switch interpreter automatically, and forcing threaded on
them is a compile error. Every wrapper accepts `VM_THREADED=1` (threaded),
`VM_THREADED=0` (switch) or unset (the default); any other value is rejected. On
Windows set `$env:VM_THREADED`, and in direct Odin commands pass
`-define:VM_THREADED=true` or `false`. `build/check.*` and `build/vm-compare.sh`
always cover both. The PUC wrapper names explicitly selected binaries
`-threaded` or `-switch`.

```sh
VM_THREADED=0 bash build/build.sh all
VM_THREADED=0 bash build/test.sh --stress --asan
VM_THREADED=0 STRESS=1 ASAN=1 bash build/puc.sh
```

The threaded interpreter has been run only on Linux x86-64. Windows x64, Linux
arm64 and macOS arm64 are cross-compiled but not yet run.

The switch opcode bodies are the source of the threaded handlers. After changing
one, or a helper a threaded specialization mirrors, run
`bash build/generate-threaded.sh` (`.\build\generate-threaded.ps1` on Windows).
The generator refuses changes to guarded bodies until their specialization has
been reviewed and its hash updated; `build/test.*` fails if the checked-in
region is out of date. See Decision 2 in `docs/ARCHITECTURE.md`.

Internal invariant assertions follow reference Lua's `lua_assert`: off in release
builds, on in debug, `odin test` and stress builds; override with
`-define:INTERNAL_ASSERTS=true|false` (stress requires true). Embedding API
precondition checks stay on by default; `-define:API_CHECKS=false` opts out.
Input checks and fail-fast guards are unconditional.

`-define:HARDSTACKTESTS=true` forces value-stack moves at every check and GC
shrink, and frame-array moves on every push, freeing (and outside ASan,
poisoning) the old block. Its `MAXSTACK_LIMIT` defaults to 68,000, as in
reference's `ltests` build, instead of 1,000,000; `-define:MAXSTACK_LIMIT=<n>`
overrides it. The extra allocations change GC timing and Lua-visible heap sizes.

## Branding

This runtime hardcodes no language name. The source uses neutral identifiers
(`api_*`, `code_*`, `State`; see docs/ARCHITECTURE.md), and every user-visible
*value* is an Odin `#config` constant declared in `src/kernel/brand.odin`:

| `-define:` knob   | Default                                      | Drives |
|-------------------|----------------------------------------------|--------|
| `BRAND`           | `Lua`                                        | `_VERSION`, the `-v` banner, `debug.getinfo().what`, the bytecode signature, type names in error messages |
| `BRAND_LOWER`     | `lua`                                        | the program names (`lua`, `luac`, `luac.out`), the `package.path` directory component, the `debug.debug()` prompt, `os.tmpname`'s prefix |
| `SOURCE_EXT`      | `.lua`                                       | the `package.path` templates |
| `ENV_PREFIX`      | `LUA`                                        | `LUA_INIT`, `LUA_INIT_5_5`, `LUA_PATH`, `LUA_PATH_5_5`, `LUA_CPATH`, `LUA_NOENV` |
| `NATIVE_OPEN_FMT` | `luaopen_%s`                                 | the entry-point symbol a native extension module must export |
| `COPYRIGHT_TEXT`  | `Copyright (C) 1994-2026 Lua.org, PUC-Rio`   | the `-v` banner |
| `AUTHORS_TEXT`    | `R. Ierusalimschy, L. H. de Figueiredo, W. Celes` | credits |

Odin cannot parameterize *identifiers* with `-define:` — defines produce values,
not names — which is exactly why the source names are already neutral. Only data
is configurable.

The build scripts wrap all of this behind one argument, which also names the
output binaries:

```sh
BRAND=moon ./build/build.sh all       # moon, moonc
```

```powershell
.\build\build.ps1 all -Brand moon     # moon.exe, moonc.exe
```

`-Brand lua` (the default) passes no branding defines, so the default brand is
the configuration the PUC-Rio suite validates. `-Display`,
`-SourceExt` and `-EnvPrefix` (`BRAND_DISPLAY`, `SOURCE_EXT`, `ENV_PREFIX` on
Unix) override individual knobs.

To verify a rebranded build end to end:

```sh
./build/rebrand-smoke.sh              # or: .\build\rebrand-smoke.ps1
```

It checks the banner, `_VERSION`, `debug.getinfo().what`, the `package.path`
templates, `require` of a module with the new extension, the brand-prefixed
`*_INIT` variable, and the precompiled-chunk signature.

> **Bytecode is deliberately not portable across brands.** The precompiled-chunk
> signature is `ESC` followed by `BRAND` (`\x1bLua` by default), so a rebranded
> compiler's dumps are rejected by a differently-branded interpreter rather than
> silently misread. The default profile stays byte-compatible with reference
> `luac` — `build/clitest.*` asserts exactly that when you point it at one.

> The PUC-Rio suite is the oracle for the **default** profile only: it hardcodes
> `_VERSION == "Lua 5.5"`, `.lua` paths, and `what == 'Lua'`. Rebranded builds are
> validated by `rebrand-smoke` instead.

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

It emits one `build/out/<brand>-freestanding.o` on Unix or
`build/out/<brand>-freestanding.obj` on Windows (`lua-freestanding.*` by
default) using:

```
-target:freestanding_amd64_sysv -no-crt -default-to-nil-allocator
-no-entry-point -build-mode:obj -use-single-module
```

This is a relocatable object for an embedder or firmware link, not a runnable
program. The embedder must call `kernel.new_state` with its own `kernel.Allocator`;
the hosted `kernel.default_allocator` is intentionally not declared.
The emitted object also provides the C-ABI convenience exports
`lang_freestanding_newstate` and `lang_freestanding_close`.

The wrappers add `-define:FREESTANDING_WIN64_ABI=true` only for the
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

To exercise forced stack and frame relocation, including under AddressSanitizer:

```sh
bash build/test.sh --stress
STRESS=1 bash build/puc.sh
bash build/test.sh --asan
bash build/test.sh --stress --asan
ASAN=1 bash build/puc.sh
STRESS=1 ASAN=1 bash build/puc.sh
```

The PowerShell equivalents are `build/test.ps1 [-Stress] [-Asan]` and
`build/puc.ps1 [-Stress] [-Asan]`. ASan requires a supported Odin toolchain.
The PUC wrappers give stress and ASan binaries distinct output names; normal
invocations still build and run the release binary.

> **Note (Windows, spaces in the repo path):** `odin test` compiles the test binary
> and then runs it; if the output path contains a space (e.g. an `OneDrive - Microsoft`
> path), Odin mis-tokenizes it and fails with `Unknown argument encountered '-'`.
> `build/test.ps1` avoids this by writing the test binary to a space-free temp
> directory (`%TEMP%\lang-tests-<brand>`). If you invoke `odin test` by hand from such a path,
> pass `-out:` to a space-free location yourself.

## Comparing against reference Lua (differential tests & benchmarks)

We do not vendor the reference C source: the project is self-contained, and the
PUC-Rio test suite under `tests/puc/` is the correctness oracle. When you want a
head-to-head comparison anyway, build a reference interpreter yourself from the
official 5.5.1 tarball at <https://www.lua.org/ftp/>:

```sh
curl -R -O https://www.lua.org/ftp/lua-5.5.1.tar.gz
tar zxf lua-5.5.1.tar.gz
cd lua-5.5.1 && make            # produces src/lua and src/luac
```

Then point the scripts at those binaries — nothing is read from inside this repo:

```powershell
# Windows: benchmark ours against the reference build.
.\build\bench.ps1 -Reference C:\path\to\lua.exe

# Windows: enable the luac byte-compatibility check in clitest.ps1 by placing
# the reference luac at %TEMP%\refluabuild\refluac.exe.
```

```bash
# macOS / Linux
REFLUA=/path/to/lua ./build/bench.sh
REFLUAC=/path/to/luac ./build/clitest.sh

# Linux: instruction counts for switch, threaded and reference under perf
REFLUA=/path/to/lua CPU=12 ./build/vm-compare.sh 5
```

The checks are skipped cleanly when no reference binary is provided. See
[bench/README.md](bench/README.md) for the harness and how to read its numbers.

For the numeric formatting corpus, run both interpreters on the same host and
compare their output. The corpus includes successful bytes and error text; it
prints its case count on standard error. Use a C locale in both processes.

```bash
LC_ALL=C /path/to/reference/lua tests/format_diff.lua > /tmp/format-reference.txt
LC_ALL=C build/out/lua tests/format_diff.lua > /tmp/format-odin.txt
cmp /tmp/format-reference.txt /tmp/format-odin.txt
```

For bit-for-bit verification of math changes, run `tests/transcend_bits.lua`
with the old and new interpreters and compare their binary output:

```bash
/path/to/old/lua tests/transcend_bits.lua > /tmp/math-old.bin
build/out/lua tests/transcend_bits.lua > /tmp/math-new.bin
cmp /tmp/math-old.bin /tmp/math-new.bin
```

It prints the input and result counts on standard error; an optional integer
argument replaces the default 100,000 full-range random inputs. The corpus
also covers special values and neighbours of important boundaries. Reference
libm need not match every bit of the existing implementation, so compare to
the old build as well as any reference interpreter.
