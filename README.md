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

## License

The reference Lua source under `lua/` is distributed under Lua's MIT license (see
`lua/doc/readme.html`). This reimplementation's license is TBD.
