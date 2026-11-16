# lua-odin architecture

This document explains the shape of the implementation and the decisions Odin
forces on us that reference Lua, written in C, did not have to make. Read it
before touching the kernel; several things look surprising until you know why
they are the way they are. Measurements and remaining work are in
[FUTURE_WORK.md](FUTURE_WORK.md).

## The big picture

```
                +------------------------------------+
                |        src/main.odin               |   standalone interpreter / REPL
                +------------------------------------+
                +------------------------------------+
                |        src/compiler/main.odin      |   bytecode compiler / dumper
                +------------------------------------+
                                 |
                                 v   (imports lang:stdlib, lang:kernel)
                +------------------------------------+
                |        src/stdlib  (package)       |   base/string/table/math/io/os/
                |  auxlib + all standard libraries   |   coroutine/utf8/debug/package
                +------------------------------------+
                                 |
                                 v   (imports lang:kernel — public API only)
                +------------------------------------+
                |        src/kernel  (ONE package)   |   the kernel
                |  object state gc string table func |
                |  tm vm do code parse lex api dump  |
                +------------------------------------+
```

`src/stream/` is the hosted buffered-stream layer shared by the I/O library and
the two programs; see [Hosted services](#hosted-services).

## Decision 1 — the kernel is a *single* Odin package

In C, Lua's kernel is a set of `.c`/`.h` files that freely include one another:
`lvm.c` calls into `ldo.c`, which calls `lgc.c`, which calls back into VM-level
concepts. It is one mutually recursive unit held together by header declarations.

Odin has a hard rule: **one directory is one package, and packages may not form
import cycles.** So the entire kernel lives in one package, `src/kernel/`, as many
files sharing a single namespace. This mirrors Lua's kernel and sidesteps the
cycle rule. The standard libraries and the two executables depend on the kernel
but never the reverse, so they are separate packages. The kernel must never
import `stdlib`; if it seems to need to, the public API is missing something.

Because files in one package share a namespace, a helper needed by a sibling file
should be `@(private)` (package-visible), not `@(private = "file")` plus a copy.

### Freestanding platform boundary

`ODIN_OS == .Freestanding` is the platform switch; there is no parallel project
define. In that build the dependency graph stops before every hosted service:
`stream.odin`, `io`, `os`, `package`, the interactive debug library and both
mains carry `#+build !freestanding`. The freestanding stdlib is base, coroutine,
math, string, table and utf8; base omits `print`, `loadfile` and `dofile` but
keeps in-memory `load`.

The kernel never owns a heap. Hosted builds add `default_allocator` in a
host-only file; freestanding builds expose only the allocator-taking
`new_state`, and pass `-default-to-nil-allocator` so an unintended Odin
allocation cannot reach for a heap that does not exist.

**Platform-split files** are *one untagged file holding everything shared* plus
*small tagged files holding only what differs*, never two whole-file forks:
`auxlib.odin` is untagged, `auxlib_hosted.odin` holds the loaders, `newstate`,
result reporters and warnings, and `auxlib_freestanding.odin` holds only
`aux_makeseed`. The one exception is `base_funcs`, spelled out in full in both
`base_hosted.odin` and `base_freestanding.odin`: registration order fixes the
key order in `_G`, which `pairs(_G)` makes observable.

`build/check.*` type-checks the freestanding target alongside the hosted
packages so this split cannot rot unnoticed. The only other define,
`FREESTANDING_WIN64_ABI`, selects the amd64 register set for the jump shim on
Odin's Win64 and MinGW freestanding triples, which Odin does not expose.

File-to-origin map (each Odin file corresponds to reference `l*.c`/`l*.h`):

| Odin file            | Reference origin                          |
|----------------------|-------------------------------------------|
| `conf.odin`          | `luaconf.h`                               |
| `limits.odin`        | `llimits.h`                               |
| `object.odin`        | `lobject.h` / `lobject.c`                 |
| `state.odin`         | `lstate.h` / `lstate.c`                   |
| `mem.odin`           | `lmem.h` / `lmem.c`                        |
| `gc.odin`            | `lgc.h` / `lgc.c`                          |
| `string.odin`        | `lstring.h` / `lstring.c`                 |
| `table.odin`         | `ltable.h` / `ltable.c`                   |
| `func.odin`          | `lfunc.h` / `lfunc.c`                     |
| `tm.odin`            | `ltm.h` / `ltm.c`                          |
| `ctype.odin`         | `lctype.h` / `lctype.c`                   |
| `zio.odin`           | `lzio.h` / `lzio.c`                        |
| `opcodes.odin`       | `lopcodes.h/.c`, `lopnames.h`, `ljumptab.h` |
| `lex.odin`           | `llex.h` / `llex.c`                       |
| `parse.odin`         | `lparser.h` / `lparser.c`                 |
| `code.odin`          | `lcode.h` / `lcode.c`                     |
| `do.odin`            | `ldo.h` / `ldo.c`                          |
| `vm.odin`            | `lvm.h` / `lvm.c`                          |
| `debug.odin`         | `ldebug.h` / `ldebug.c`                   |
| `api.odin`           | `lapi.h` / `lapi.c`                       |
| `dump.odin`          | `ldump.c`                                  |
| `undump.odin`        | `lundump.h` / `lundump.c`                 |
| `brand.odin`         | (no origin — the build-time branding knobs) |

### Naming: neutral in the source, branded at build time

Nothing in the source spells the name of the language it implements. Kernel
subsystems use neutral prefixes rather than reference Lua's `lua*_` initials, so
a rebranded distribution needs no renaming pass:

| Reference C | Here      | Reference C | Here       | Reference C | Here      |
|-------------|-----------|-------------|------------|-------------|-----------|
| `lua_*`     | `api_*`   | `luaK_*`    | `code_*`   | `luaS_*`    | `string_*`|
| `luaL_*`    | `aux_*`   | `luaO_*`    | `object_*` | `luaT_*`    | `tm_*`    |
| `luaB_*`    | `base_*`  | `luaD_*`    | `do_*`     | `luaV_*`    | `vm_*`    |
| `luaopen_*` | `open_*`  | `luaE_*`    | `state_*`  | `luaC_*`    | `gc_*`    |
| `luaX_*`    | `lex_*`   | `luaG_*`    | `debug_*`  | `luaF_*`    | `func_*`  |
| `luaY_*`    | `parse_*` | `luaH_*`    | `table_*`  | `luaM_*`    | `mem_*`   |
| `luaP_*`    | `opcode_*`| `luaZ_*`    | `zio_*`    | `LUA_*`     | (stripped)|

`lua_State` is `State`, `lua_Debug` is `Debug_Info`, and `LUA_TNIL` and friends
are the kernel's own `TNIL` tags. Backticked `lua*` names *in comments* always
name the **reference C** identifier being mirrored, never one in this tree.

Odin defines produce values, not identifiers, which is why names are neutral
rather than brand-derived. Everything that *is* data (`_VERSION`, the banner, the
bytecode signature, the source extension, the environment prefix, the search
paths) is a `#config` constant in `src/kernel/brand.odin`; see BUILDING.md.

## Decision 2 — an explicit frame stack, a trampoline, and `longjmp` for errors

Reference Lua uses the native C stack for two different things:

1. `setjmp`/`longjmp` (`luaD_throw` / `luaD_rawrunprotected`) unwinds arbitrarily
   deep C frames to the nearest protected boundary when an error is raised.
2. Coroutines suspend deep inside the interpreter and resume later.

These are different problems with different solutions.

**Errors use a libc-free `setjmp`/`longjmp`.** `throw` and `run_protected` in
`control.odin` model `luaD_throw` and `luaD_rawrunprotected`. The machine-state
save and jump are small inline-assembly routines in `jmp.odin` for amd64 (SysV
and Win64 register sets) and arm64; other architectures fail at compile time.
They must stay `#force_no_inline`, for the reason in that file's header. Because
a `longjmp` skips every intervening `defer`, a raw (non-GC) allocation must never
be freed in a `defer` a throw could leap over: the protected wrapper that owns it
frees it explicitly on both paths, as reference frees the parser's
`Dyndata`/`Mbuffer` after `luaD_pcall`.

**Coroutines need an explicit heap frame stack.** `longjmp` can only unwind a
stack, not resume one it left, so a recursive interpreter cannot implement
`coroutine.yield`. Like reference Lua's `CallInfo` list, and together with
`longjmp` rather than instead of it:

- Each `State` owns its **value stack** and **call-frame stack** as arrays it
  manages itself, not the native Odin stack. A frame records everything needed to
  resume it: PC, base/top, expected results, call kind, recovery info, any
  continuation (`callk`/`pcallk`) and any partially completed operation.
- The interpreter (`vm_execute`, reference `luaV_execute`) is an **in-place
  trampoline**. The switch VM uses a labeled loop (`newframe`); the default
  threaded VM tail-transitions between opcode and frame-entry handlers. Lua→Lua
  calls, tail calls and returns never grow the native stack. A frame entered
  fresh from C (`CIST_FRESH`) returns to its native caller. Metamethods,
  iterators and `pcall` re-enter the VM recursively through `luaD_call`, as fresh
  activations.

Errors and yields both leave with `longjmp`: `throw` jumps to the nearest
protected boundary, and `api_yieldk` jumps out with a `Yield` status. A yield is
resumable because the coroutine's heap frames are left intact: `api_resume`
walks back into them through `resume`/`unroll`/`precover` in `do.odin`,
finishing the interrupted instruction (`luaV_finishOp`) or running the C
continuation. Error recovery instead reconciles the frame stack at the catch
site: it restores the frame index, closes upvalues and to-be-closed slots and
installs the error object (`luaD_pcall`/`luaD_closeprotected`).

Host (Odin) callbacks follow the continuation rules of C functions in reference
Lua: an ordinary callback is non-yieldable across its native frame, and a
yieldable one must register a continuation. `control.odin`'s
`Exec_Signal`/`Exec_Outcome` names these transitions for the callback contract;
the hot path expresses them as loop control, tail transitions and `longjmp`.

### Tail-call-threaded dispatch

The threaded VM is the default on amd64 and arm64. `VM_THREADED=0` in the
wrappers, or `-define:VM_THREADED=false`, selects the switch, which other
architectures use automatically; forcing threaded elsewhere is a compile error.
Each of the 85 opcodes has a handler, and a 128-entry table maps the whole
seven-bit opcode field, with one error handler for the 43 unused encodings. Odin's
`"preserve/none"` convention and `#must_tail` turn every fetch into an indirect
jump. It runs natively on Linux x86-64 and under QEMU emulation on Linux arm64;
Windows x64 and macOS arm64 objects were inspected for indirect tail jumps but
not run.

Handlers pass `L`, the next PC, the register-base pointer, closure, code base,
frame index, trap, an Odin context pointer and the current instruction.
Constants and the base index are derived when needed. A VM activation owns the
context copy for its whole tail-call chain; frame entry is another tail
transition that re-derives closure, PC and base and runs the call hook. The
fetch trap is a separate cold handler that runs `debug_traceexec` and refreshes
the base, including after relocation. Interrupts are polled at the same edges
as the switch; slow polls tail-jump to a handler that applies the request and
continues. Errors, yields and coroutine resumption use the same protected
boundaries and continuations as the switch.

**Generated from the switch.** The switch bodies in `vm.odin` are the source of
the checked-in threaded region, generated by `tools/generate_threaded/` (run
`bash build/generate-threaded.sh`); `build/test.*` fails on drift. The generator
checks the opcode inventory and frame transitions, and hashes every rewritten
body and every shared helper a specialization mirrors, so a change to one
requires reviewing the specialization before updating the hash. This catches
drift; it does not prove equivalence. Threaded-only helpers live in
`vm_threaded_fast.odin` and `vm_threaded_concat.odin`: declaring them in
`vm.odin` measurably changed the switch's code placement.

**Specialized paths.** Most handlers are the switch bodies. These are rewritten:

- **Calls.** `CALL` keeps non-allocating Lua-closure frame setup in the handler;
  native calls, stack growth and `__call` tail-transition to separate handlers so
  their callouts cannot force spills on the Lua path. A fresh, unhooked Lua frame
  reuses the already loaded code for its first entry. Native setup keeps the
  encoded result count and the caller's frame index; frames are resolved again
  after the callback, which may relocate either stack or install hooks. Return
  hooks, to-be-closed values and result counts other than zero or one use the
  ordinary post-call path. `RETURN0`/`RETURN1` keep no-hook result movement in
  the handler; interrupts and hooks tail-transition to a copy of the switch body.
- **Table reads.** Global reads keep short-string hits in the handler and
  tail-transition to generic-key and miss handlers; non-string constants from
  unvalidated bytecode remain supported. Field reads use the shared contextless
  lookup. Variable-key array and short-string hits stay in the handler; other
  key types go to contextless lookup handlers, and known empty slots and
  non-tables go straight to the finish path. `SELF` handles a string whose
  `__index` is a table.
- **Table writes.** Integer-key writes of non-collectable values, short-string
  writes of primitives, immediate-index (`GETI`/`SETI`) hits and global writes
  use the ordinary pre-sets without a context. Collectable values are written
  contextless only when the back barrier would be a no-op. An unfinished global
  short-string pre-set passes its hash location to the finish handler in the
  trap argument, so the lookup is not repeated.
- **Concatenation.** The common path mirrors short-string interning and string
  allocation (same C-ABI allocator, GC link and debt accounting) without a
  context; a non-coercible pair goes to a cold metamethod handler.
- **Other.** String `LEN` and constant-operand `//` and `%` are contextless, with
  zero-divisor errors on the original context. The integer `FORLOOP` back edge
  reads the next instruction before updating the loop registers; a pending
  interrupt or trace discards it. Float loops address their control slots from
  the register base in both modes. Upvalue handlers take the vector from the
  carried closure.

**Rules every specialization follows.** A contextless hit must not allocate,
re-enter Lua, move a stack or change the trap. A miss or callout receives the
activation's original context, after the same saved-PC and top updates the
switch makes, and reloads the trap afterwards. A collectable value may be stored
without the barrier only when the barrier would do nothing, with no allocation
or re-entry between the color test and the store. Anything that can trigger an
emergency collection re-resolves stack slots afterwards. `CLOSURE` keeps its
upvalue barrier: an emergency collection can blacken the anchored closure before
its upvalues are wired. Relocation test mode (`HARDSTACKTESTS`) routes calls
through the ordinary helper so its forced moves still happen.

## Decision 3 — persistent indices, temporary VM pointers

Because the value and frame stacks can reallocate, frames, protected boundaries,
open upvalues and API stack slots store **indices**, resolved to a pointer only
for one operation on the current array. Frame pointers are never retained across
re-entrant calls. Active frames are exactly `0..L.ci`.

The VM keeps a local register-base pointer. Stack reallocation arms the trap on
every Lua frame; after a potentially moving call (metamethods, GC, hooks, native
calls, iterators, varargs) the VM reloads the trap and re-derives the base at
the next fetch. A handler that needs a register again within the same
instruction must re-derive it immediately after the call. Tail-call argument
sliding derives a temporary pointer only after its growth check; nothing between
can allocate.

The saved PC is an instruction index, not a pointer. A loader reader can obtain
a still-compiling closure through the debug API, start it in a coroutine and
yield; compilation can then resize its code before the coroutine resumes. The
index lets frame entry re-derive the PC from the current code array.

Frame setup leaves `u2` untouched (every use writes it before its continuation
reads it), nil-fills missing fixed arguments after both growth checks, and
publishes the final top before the callee runs. The hidden vararg count is 32
bits when the stack ceiling allows.

`HARDSTACKTESTS` forces every value-stack check, GC shrink and frame push to move
to a new block and free (and, outside ASan, poison) the old one; combined with
AddressSanitizer it catches outdated pointers. As in reference's `ltests` build,
it defaults to a 68,000-slot stack limit instead of 1,000,000. Its extra
allocations change GC timing.

Internal assertions follow reference `lua_assert`: off in release, on in debug,
test and stress builds. Embedding API precondition checks have their own
`API_CHECKS` switch, on by default. Input checks and fail-fast guards are never
disabled.

## Decision 4 — a fallible allocator and honest OOM

Reference Lua survives out-of-memory: a failed allocation triggers an emergency
collection and retry, and a preallocated error object means reporting OOM never
allocates. We reproduce this with one **fallible allocator callback** for all
kernel allocation. The kernel avoids containers that panic or allocate
implicitly, so failure is always a handled value. OOM is tested at allocation
points.

On Linux, macOS and the BSDs the hosted allocator calls Odin's contextless C-heap
`realloc`/`free`; Windows uses its process heap. A failed resize leaves the old
block for `state_realloc`'s emergency collection and retry. Kernel types need at
most 8-byte alignment, which every supported heap provides; the layout
assertions currently require 64-bit targets.

On 64-bit targets an `UpVal` is 48 bytes, overlaying the open-list links with the
closed `TValue`; open upvalues keep a thread and index, not a stack pointer. An
`LClosure` is a 32-byte header followed by its inline upvalue-pointer vector. GC
debt, marking and frees use the actual allocation sizes, as in reference. A
`TString` header is 32 bytes against reference's 24.

## Decision 5 — byte-compatible bytecode for one fixed ABI

Lua chunks embed raw host representations, so "compatible with every Lua build"
is impossible. We target one configuration: little-endian, 32-bit `Instruction`
and `int`, 64-bit `lua_Integer`, IEEE-754 binary64 `lua_Number`. Float bit
patterns are preserved, the C layout is serialized explicitly rather than through
Odin padding, and incompatible chunks are rejected as the reference header check
does. `build/clitest.*` compares our dumps byte for byte with a reference `luac`.

## Native callbacks and the embedding API

Native library callbacks keep their C ABI. A hot callback may skip
`runtime.default_context()` only when its fast path calls exclusively
`"contextless"` helpers; coercion, allocation, formatting, errors and OS calls
must establish the default context first, in a no-inline slow helper or on the
branch that needs it. `api_native_*` is a narrow positive-argument fast path for
such callbacks; the embedding API keeps its procedure types and assertion
handler. The transcendental math functions use it for numeric arguments.

`api_geti`, `api_seti` and `api_compare` inline their checked index translation,
so constant-index callers such as `table.sort` drop the unused index classes
while keeping metamethod and relocation paths. `api_tolstring` roots a converted
number before the reference GC checkpoint and re-resolves the slot afterwards.
Returned string bytes stay valid only while the string is reachable.

Some auxiliary buffers and parser scope records live in the caller's frame and
are linked into state for the duration of one call, as in reference; Odin warns
that they may outlive it. Each such site converts the pointer explicitly with a
comment stating why it does not.

## Hosted services

**Streams.** Each stream serializes operations with its own mutex; `flush_all`
pins streams one at a time from a separately locked process-wide list before
taking their mutexes, so it can flush another state's stream between two
operations and reports a failure on any of them. EOF and error indicators are
atomic and the last OS error is thread-local. Tests that create deliberately
failing streams or call `flush_all` serialize on a test mutex. Bulk delimiter
reads copy bytes under the mutex and update position and pushback as `getc`
would; Windows text mode still handles CRLF, Ctrl-Z and lookahead. Lines and
bounded reads that fit the Lua buffer's initial area become strings directly.

**Environment and time zones.** On hosted Linux, `os.getenv` passes the rooted
Lua argument to the host and copies the result straight into Lua. Local
`os.date` and table-form `os.time` share a static, mutex-protected time-zone
cache: a 4 KiB `TZ` key, a 64 KiB TZif image, a POSIX rule and the last
transition range. `TZ` is compared on every call, and `/etc/localtime` is
re-statted when `TZ` is unset; oversized keys, files or abbreviations fall back
to the uncached loader. No Lua code runs with the mutex held. Other hosts keep
their existing paths; freestanding has no OS library.

## Testing philosophy

Tests must *truthfully* prove correctness, never be fitted to pass by asserting
on incidental internals. Two layers: Odin unit and differential tests against
reference behavior and bytecode, and the official PUC-Rio Lua 5.5 suite under
`tests/puc`, run verbatim, as the whole-language oracle. Both run in both
interpreters, and with forced relocation under AddressSanitizer.
