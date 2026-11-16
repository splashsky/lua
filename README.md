# lua-odin

A faithful, from-scratch, **branding-agnostic** language runtime in
**standard-library-only [Odin](https://odin-lang.org/)**, whose default profile is
a reimplementation of **Lua 5.5.1**.

The goal is *correctness first*: an implementation whose observable behavior matches
reference Lua as closely as we can make it — same language semantics, same garbage
collection behavior (incremental + generational), and byte-compatible bytecode.
Performance work comes later, once correct is locked in.

The implementation is self-contained: no C source is vendored and we never link
against reference Lua. Correctness is proved against the official PUC-Rio 5.5 test
suite under [`tests/puc/`](tests/puc/), run verbatim. Differential and benchmark
comparisons against a reference `lua`/`luac` binary are still supported — you point
the scripts at a build of your own (see [BUILDING.md](BUILDING.md)).

## Branding is a build-time choice

Nothing in the source hardcodes the name of the language it implements. The
kernel uses neutral subsystem names (`api_*`, `code_*`, `table_*`, `State`),
and every user-visible name — the `_VERSION` string, the banner, the bytecode
signature, the source-file extension, the environment-variable prefix, the
`package.path` templates, the program names — is a `#config` constant in
[`src/kernel/brand.odin`](src/kernel/brand.odin):

```sh
./build/build.sh all                # lua  / luac,  _VERSION "Lua 5.5",  *.lua
BRAND=moon ./build/build.sh all     # moon / moonc, _VERSION "Moon 5.5", *.moon
```

The defaults reproduce Lua 5.5.1 exactly, so a plain build is the one the
PUC-Rio suite validates. `build/rebrand-smoke.*` proves the other direction.
See [BUILDING.md](BUILDING.md#branding) for every knob.

## Status

Early scaffolding. See the phased plan and progress in the project docs. Every phase is
designed, reviewed, and then implemented; nothing ships without honest tests that
truthfully prove correctness (no tests fitted to pass).

## Layout

```
src/        Our Odin implementation.
  kernel/   The kernel: one Odin package (the core is mutually recursive).
  stdlib/   Standard libraries, written against the public embedding API.
  compiler/ The bytecode compiler/dumper (package main).
  main.odin The standalone interpreter/REPL (package main).
tests/      Odin unit tests, plus the vendored PUC-Rio 5.5 suite under tests/puc.
build/      Build/test scripts (tracked) and build output (ignored).
docs/       Architecture and design notes.
```

For *why* the kernel is a single package and how error handling / coroutines use
`longjmp` and explicit frames, read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Planned
work, mostly performance, and the measurements behind it are in
[docs/FUTURE_WORK.md](docs/FUTURE_WORK.md).

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

The tail-call-threaded VM is the default on amd64 and arm64; other architectures
select the switch automatically. Set `VM_THREADED=0` for the switch in the
wrappers, or pass `-define:VM_THREADED=false` to Odin directly. The threaded VM
has been runtime-tested only on Linux x86-64; Windows x64, Linux arm64 and macOS
arm64 were cross-compiled to objects but not run. See [BUILDING.md](BUILDING.md#interpreter-selection).

## Interactive line editing

When both standard input and standard output are terminals, the hosted `lua`
REPL uses a native, libc-free editor. Windows uses `ReadConsoleInputW` key
records; Linux uses the kernel termios/ioctl/read interfaces. Darwin and BSD
currently fall back explicitly to the plain line reader because their terminal
ABIs differ from Linux. Redirected input/output and `TERM=dumb` also use the
plain reader.

The editor supports Left/Right/Up/Down, Home, End, Delete, Backspace, Ctrl-A,
Ctrl-E, Ctrl-K, Ctrl-U, Ctrl-W, and Ctrl-L. History is session-only and stores
each complete logical statement, including continuation lines. Editing is
horizontally scrolled within one physical row; the final terminal column is
reserved to avoid ambiguous automatic wrapping.

Lines are limited to 511 input bytes, matching `MAXINPUT`; additional input
rings the terminal bell. The editor uses fixed storage while raw mode is active,
so allocation failure cannot strand the terminal there. Tab is displayed as
four spaces but remains one tab byte. Ctrl-D means EOF on an empty line and
forward-delete otherwise. On Windows Ctrl-Z means EOF on an empty line and is
ignored on a non-empty line.

Movement and deletion preserve arbitrary bytes and operate on valid UTF-8 code
points (an invalid byte is one editable unit). Control and invalid bytes are
rendered visibly rather than executed. ASCII display and cursor placement are
correct. General Unicode cell width is intentionally not claimed: without a
`wcwidth`-style table, combining marks and wide characters can misplace the
cursor during redraw.

Terminal restoration is best-effort for every normal return, protected Lua
error, `os.exit`, and hosted fatal exit. No program can restore terminal state
after `SIGKILL`, Windows `TerminateProcess`, power loss, or an equivalent
unrecoverable process termination.

### Freestanding / bare metal

Odin's native `ODIN_OS == .Freestanding` switch selects a bare-metal build
automatically; there is no project-specific `-define:` to keep in sync. Build a
relocatable object (not an executable) with:

```sh
./build/build.sh freestanding
# or, on Windows:
.\build\build.ps1 freestanding
```

This emits one `build/out/<brand>-freestanding.o` on Unix or
`build/out/<brand>-freestanding.obj` on Windows (`lua-freestanding.*` by
default) for `freestanding_amd64_sysv`.
Set `FREESTANDING_TARGET` on Unix or pass
`-FreestandingTarget` in PowerShell to choose another Odin freestanding target.
The exact flags are `-target:<target> -no-crt -default-to-nil-allocator
-no-entry-point -build-mode:obj -use-single-module`.
For Odin's `freestanding_amd64_win64` and `freestanding_amd64_mingw`
subtargets the wrappers additionally set
`-define:FREESTANDING_WIN64_ABI=true`; Odin exposes the freestanding OS
automatically but currently exposes no compile-time sub-ABI value for the
assembly jump shim.

The current libc-free jump implementation supports amd64 (SysV and Win64 ABIs)
and arm64. Odin's freestanding arm32, riscv64, wasm32, and wasm64p32 targets
remain honest compile-time failures until `jmp_set`/`jmp_long` exist for those
architectures. Odin also cannot currently produce a cross-compiled static
library for freestanding amd64, so the supported deliverable is the object file.

The object contains the kernel and base, coroutine, math, string, table, and
utf8 libraries. `io`, `os`, `package`, the interactive debug library, the stream
platform layer, and the two standalone programs are omitted because bare metal has
no filesystem, environment, process, or terminal. Base therefore also omits
`print`, `loadfile`, and `dofile`; `load` from memory remains available.

There is deliberately no default allocator in this configuration. The embedder
must provide a `kernel.Allocator` callback and userdata to `kernel.new_state`,
plus any board-specific panic/reset behavior it needs. Odin's default allocator
is set to nil so an accidental implicit Odin allocation cannot masquerade as a
working heap.

For object-file consumers, the artifact exports
`lang_freestanding_newstate(alloc, ud)` and `lang_freestanding_close(L)`. The
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
- **Number formatting uses a fixed C locale and platform rules, without libc.**
  Linux follows glibc's signed NaNs, hexadecimal subnormals and `%a` modifiers.
  Windows keeps the Lua C89 `%a` fallback and UCRT non-finite spellings; the
  `%#g` leading-zero significant-digit bug is fixed on every target. Freestanding
  uses the same fixed Windows-style rules. Apple and FreeBSD `vfprintf`/`__hdtoa`
  source describes unsigned NaNs and normalized hexadecimal subnormals; NetBSD
  suppresses NaN signs too, while OpenBSD retains them. Those BSD/macOS paths are
  based on source reading, not runtime validation, and other libc details may
  differ. Linux builds against a non-glibc libc still use the glibc rules. The
  relevant source paths are [UCRT `cvt.cpp`](https://github.com/huangqinjin/ucrt/blob/master/convert/cvt.cpp),
  [FreeBSD `vfprintf.c`](https://github.com/freebsd/freebsd-src/blob/main/lib/libc/stdio/vfprintf.c)
  and [Apple `vfprintf.c`](https://github.com/apple-oss-distributions/Libc/blob/main/stdio/FreeBSD/vfprintf.c).
- **Local time:** Windows uses the configured OS time zone and its DST
  transition rules. Hosted POSIX targets read `TZ` (an absolute or
  `:`-prefixed TZif path, a zone name under `TZDIR` or the usual zoneinfo
  directories, or a POSIX rule such as `EST5EDT,M3.2.0,M11.1.0`) and otherwise
  read `/etc/localtime`. TZif v1/v2/v3 transition tables, abbreviations, and
  v2/v3 trailing rules are supported. POSIX rules support alphabetic or
  `<quoted>` names, `hh[:mm[:ss]]` offsets, and `Jn`, `n`, or `Mm.w.d`
  transitions with optional `/time`; DST strings without explicit transition
  rules are rejected because POSIX leaves their default implementation-defined.
  An unreadable or unsupported zone still falls back to UTC. For `os.time`, an
  unspecified repeated hour chooses standard time, and an unspecified skipped
  hour normalizes forward; an explicit `isdst` chooses that offset's side.
  The parser is unit-tested from constructed byte images. Local-time round trips
  and the PUC date tests have run on Linux; macOS end-to-end behavior remains
  unvalidated.
- **Transcendental functions may differ from the platform's libm in the last
  bit.** `sin`, `cos`, `tan`, `exp` and `pow` are our own pure-Odin
  implementations, checked against reference over 91,606 evaluations at a
  worst case of 1 ulp. Platform libm implementations differ from each other by
  about as much, and the PUC-Rio `math.lua` suite passes either way; the numbers
  that Lua programs actually round-trip -- `tostring`, `%q`, `string.format` --
  follow the platform formatting rules described above.
- **`io.popen` is available on Windows and Linux without a C runtime.** Windows
  uses anonymous KERNEL32 pipes and `cmd.exe /c`; Linux uses syscall-backed
  pipes and `/bin/sh -c`. Other hosted targets retain Lua's explicit
  `"'popen' not supported"` fallback until their process ABIs are implemented. Reference Lua permits this to fail, and it reports as much.

Two more, inherited from the platform rather than from our own choices:
`files.lua` in the PUC-Rio suite stops on Windows at its `/dev/null` test, since
that Unix device does not exist there and reference Lua fails identically — and
on macOS it stops slightly later at `/dev/full`, which is a Linux-only device;
only Linux runs that file to completion. The other is the `T` internal C test
library the suite optionally uses, which is absent and which the suite itself
handles. Both are covered in `tests/puc/README.md`.

## License

The PUC-Rio Lua test suite vendored under `tests/puc/` is distributed under Lua's
MIT license; the full notice is reproduced in `tests/puc/README.md`. This
reimplementation's license is TBD.
