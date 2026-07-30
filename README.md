# lua-odin

A faithful, from-scratch reimplementation of **Lua 5.5.0** in **standard-library-only
[Odin](https://odin-lang.org/)**.

The goal is *correctness first*: an implementation whose observable behavior matches
reference Lua as closely as we can make it — same language semantics, same garbage
collection behavior (incremental + generational), and byte-compatible bytecode.
Performance work comes later, once correct is locked in.

The pristine reference C source for Lua 5.5.0 lives under [`lua/`](lua/) and is used
only for reference and for *differential testing* — we never link against it.

## Status

Early scaffolding. See the phased plan and progress in the project docs. Every phase is
designed, reviewed, and then implemented; nothing ships without honest tests that
truthfully prove correctness (no tests fitted to pass).

## Layout

```
lua/        Vendored reference C source of Lua 5.5.0 (reference + differential tests).
src/        Our Odin implementation.
  lua/      The kernel: one Odin package (Lua's core is mutually recursive).
  stdlib/   Standard libraries, written against the public embedding API.
  luac/     The `luac` bytecode compiler/dumper (package main).
  main.odin The standalone `lua` interpreter/REPL (package main).
tests/      Odin unit tests + (later) the vendored PUC-Rio 5.5 suite under tests/puc.
build/      Build/test scripts (tracked) and build output (ignored).
docs/       Architecture and design notes.
```

For *why* the kernel is a single package and how error handling / coroutines work
without `longjmp`, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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

### Freestanding / bare metal

Odin's native `ODIN_OS == .Freestanding` switch selects a bare-metal build
automatically; there is no project-specific `-define:` to keep in sync. Build a
relocatable object (not an executable) with:

```sh
./build/build.sh freestanding
# or, on Windows:
.\build\build.ps1 freestanding
```

This emits one `build/out/lua-freestanding.o` on Unix or
`build/out/lua-freestanding.obj` on Windows for `freestanding_amd64_sysv`.
Set `FREESTANDING_TARGET` on Unix or pass
`-FreestandingTarget` in PowerShell to choose another Odin freestanding target.
The exact flags are `-target:<target> -no-crt -default-to-nil-allocator
-no-entry-point -build-mode:obj -use-single-module`.
For Odin's `freestanding_amd64_win64` and `freestanding_amd64_mingw`
subtargets the wrappers additionally set
`-define:LUA_FREESTANDING_WIN64_ABI=true`; Odin exposes the freestanding OS
automatically but currently exposes no compile-time sub-ABI value for the
assembly jump shim.

The current libc-free jump implementation supports amd64 (SysV and Win64 ABIs)
and arm64. Odin's freestanding arm32, riscv64, wasm32, and wasm64p32 targets
remain honest compile-time failures until `jmp_set`/`jmp_long` exist for those
architectures. Odin also cannot currently produce a cross-compiled static
library for freestanding amd64, so the supported deliverable is the object file.

The object contains the Lua kernel and base, coroutine, math, string, table, and
utf8 libraries. `io`, `os`, `package`, the interactive debug library, the stream
platform layer, and the `lua`/`luac` programs are omitted because bare metal has
no filesystem, environment, process, or terminal. Base therefore also omits
`print`, `loadfile`, and `dofile`; `load` from memory remains available.

There is deliberately no default Lua allocator in this configuration. The
embedder must provide a `lua.Allocator` callback and userdata to `lua.new_state`,
plus any board-specific panic/reset behavior it needs. Odin's default allocator
is set to nil so an accidental implicit Odin allocation cannot masquerade as a
working heap.

For object-file consumers, the artifact exports
`luao_freestanding_newstate(alloc, ud)` and `luao_freestanding_close(L)`. The
constructor rejects a nil callback and opens the freestanding library set.

## Intentional deviations from reference Lua

Kept deliberately small and always documented:

- **Native modules:** `require` / `package.loadlib` load **Odin-native** dynamic
  modules instead of C `luaopen_*` modules (std-lib-only Odin has no C ABI loader).
  Lua-source module loading works normally.
- **Locale collation** falls back to byte order (no `strcoll`/`setlocale`).
- **OS locale support is the C locale only.** `os.setlocale` accepts `"C"`,
  `"POSIX"`, and `""`; other locale names return nil. Consequently
  `os.date` uses fixed English C-locale names and C-locale `%c`/`%x`/`%X`
  forms instead of the machine's localized names.
- **OS error text** comes from Odin's `core:os`, so wording and capitalization
  can differ from the C runtime's `strerror` text while the Lua result shape
  remains `nil, message, code`.
- **Local time on targets without an Odin OS time-zone bridge** falls back to
  UTC. Windows uses the configured OS time zone and its DST transition rules.
- **Transcendental functions may differ from the platform's libm in the last
  bit.** `sin`, `cos`, `tan`, `exp` and `pow` are our own pure-Odin
  implementations, checked against reference over 91,606 evaluations at a
  worst case of 1 ulp. Platform libm implementations differ from each other by
  about as much, and the PUC-Rio `math.lua` suite passes either way; the numbers
  that Lua programs actually round-trip -- `tostring`, `%q`, `string.format` --
  are byte-identical to reference.
- **`io.popen` is not available** (no pipe-to-process facility without a C
  runtime). Reference Lua permits this to fail, and it reports as much.

Two more, inherited from the platform rather than from our own choices:
`files.lua` in the PUC-Rio suite stops on Windows at its `/dev/null` test, since
that Unix device does not exist there and reference Lua fails identically; and
the `T` internal C test library the suite optionally uses is absent, which the
suite itself handles. Both are covered in `tests/puc/README.md`.

## License

The reference Lua source under `lua/` is distributed under Lua's MIT license (see
`lua/doc/readme.html`). This reimplementation's license is TBD.
