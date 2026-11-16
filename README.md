# lua-odin

A faithful, from-scratch, **branding-agnostic** language runtime in
**standard-library-only [Odin](https://odin-lang.org/)**, whose default profile is
a reimplementation of **Lua 5.5.1**.

The goal is *correctness first*: observable behavior that matches reference Lua
as closely as we can make it — the same language semantics, the same garbage
collection behavior (incremental and generational), and byte-compatible
bytecode. Performance changes are measured against reference and must preserve
correctness.

The implementation is self-contained: no C source is vendored and we never link
against reference Lua. Correctness is proved against the official PUC-Rio 5.5 test
suite under [`tests/puc/`](tests/puc/), run verbatim. Differential and benchmark
comparisons against a reference `lua`/`luac` you build yourself are supported
(see [BUILDING.md](BUILDING.md)).

## Status

- The runtime and standard libraries pass the PUC-Rio suite and the unit tests
  on Linux x86-64, in both interpreters, including forced stack relocation under
  AddressSanitizer.
- A tail-call-threaded interpreter is the default on amd64 and arm64; the switch
  interpreter is used on other architectures and with `VM_THREADED=0`. Both run
  natively on Linux x86-64 and, under QEMU user-mode emulation, on Linux arm64,
  where the PUC-Rio suite passes. Windows x64 and macOS arm64 are cross-compiled
  but not yet run.
- Against reference Lua 5.5.1 on Linux x86-64, the default executes no more
  instructions than reference on simple calls, string building, tables, sorting,
  local dates and number formatting. The largest remaining gaps are Lua patterns
  (+34%), `os.getenv` (+26%), integer loops (+22%) and deep recursion (`fib`,
  +16%). Measurements and plans are in [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

## Branding is a build-time choice

Nothing in the source hardcodes the name of the language it implements. The
kernel uses neutral subsystem names (`api_*`, `code_*`, `table_*`, `State`),
and every user-visible name — `_VERSION`, the banner, the bytecode signature, the
source extension, the environment prefix, the `package.path` templates, the
program names — is a `#config` constant in
[`src/kernel/brand.odin`](src/kernel/brand.odin):

```sh
./build/build.sh all                # lua  / luac,  _VERSION "Lua 5.5",  *.lua
BRAND=moon ./build/build.sh all     # moon / moonc, _VERSION "Moon 5.5", *.moon
```

The defaults reproduce Lua 5.5.1 exactly, so a plain build is the one the
PUC-Rio suite validates; `build/rebrand-smoke.*` checks the other direction. See
[BUILDING.md](BUILDING.md#branding) for every knob.

## Layout

```
src/        Our Odin implementation.
  kernel/   The kernel: one Odin package (the core is mutually recursive).
  stdlib/   Standard libraries, written against the public embedding API.
  stream/   Hosted buffered streams shared by io and the programs.
  compiler/ The bytecode compiler/dumper (package main).
  main.odin The standalone interpreter/REPL (package main).
tests/      Odin unit tests, plus the vendored PUC-Rio 5.5 suite under tests/puc.
bench/      Benchmark harness and instruction-count probes.
build/      Build/test scripts (tracked) and build output (ignored).
tools/      The threaded-VM generator and verification harnesses.
docs/       Architecture notes and future work.
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains why the kernel is one
package, how errors and coroutines use `longjmp` and explicit frames, and how the
threaded interpreter is generated from the switch.

## Building & testing

See [BUILDING.md](BUILDING.md). Quick version:

```sh
# macOS / Linux
./build/build.sh all
./build/test.sh

# Windows (PowerShell)
.\build\build.ps1 all
.\build\test.ps1
```

`./build/build.sh freestanding` builds a relocatable bare-metal object with the
kernel and the base, coroutine, math, string, table and utf8 libraries; the
embedder supplies the allocator. See [BUILDING.md](BUILDING.md#freestanding-object).

## Interactive line editing

When standard input and output are both terminals, the hosted REPL uses a
native, libc-free line editor on Windows and Linux (Darwin and the BSDs use the
plain reader, as do redirected streams and `TERM=dumb`). It supports the arrow
keys, Home, End, Delete, Backspace, Ctrl-A/E/K/U/W/L and session history of
complete statements, edits UTF-8 code points, and limits lines to 511 bytes
(`MAXINPUT`). Wide and combining characters can misplace the cursor, since no
`wcwidth` table is used. The terminal is restored on every normal exit, error,
`os.exit` and fatal exit, but not after `SIGKILL` or an equivalent.

## Intentional deviations from reference Lua

Kept deliberately small and always documented:

- **Native modules:** `require` / `package.loadlib` load **Odin-native** dynamic
  modules instead of C `luaopen_*` modules (standard-library-only Odin has no C
  ABI loader). Lua-source modules load normally.
- **Locale:** only the C locale. Collation is byte order, `os.setlocale` accepts
  `"C"`, `"POSIX"` and `""`, and `os.date` uses C-locale names and formats.
- **OS error text** comes from Odin's `core:os`, so wording can differ from
  `strerror`; the result shape stays `nil, message, code`.
- **Number formatting follows the platform's C library rules without linking
  it.** Linux follows glibc (signed NaNs, hexadecimal subnormals, `%a`); Windows
  and freestanding follow UCRT's spellings and Lua's C89 `%a` fallback; macOS and
  the BSDs follow their `vfprintf` sources, which have not been run there. The
  `%#g` leading-zero bug is fixed everywhere.
- **Local time:** Windows uses the OS time zone. POSIX hosts read `TZ` (a TZif
  path, a zone name under `TZDIR` or the usual zoneinfo directories, or a POSIX
  rule) and otherwise `/etc/localtime`; TZif v1–v3 and POSIX rules with explicit
  transitions are supported, and an unreadable zone falls back to UTC. For
  `os.time`, an ambiguous repeated hour chooses standard time and a skipped hour
  normalizes forward. Some edge cases differ from glibc; see
  [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md). Local time has been checked
  end to end on Linux only.
- **Transcendental functions** (`sin`, `cos`, `tan`, `exp`, `pow`) are pure Odin
  and may differ from the platform libm in the last bit; they were checked
  against reference over 91,606 evaluations at a worst case of 1 ulp.
- **`io.popen`** works on Windows and Linux without a C runtime; other hosted
  targets report Lua's `"'popen' not supported"`, which reference permits.

The PUC-Rio suite's `files.lua` stops at the `/dev/null` and `/dev/full` tests on
Windows and macOS, as reference Lua does there, and the suite's optional internal
`T` library is absent; see [tests/puc/README.md](tests/puc/README.md).

## License

The PUC-Rio Lua test suite vendored under `tests/puc/` is distributed under Lua's
MIT license; the full notice is in `tests/puc/README.md`. This reimplementation's
license is TBD.
