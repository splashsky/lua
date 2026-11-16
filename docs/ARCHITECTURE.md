# lua-odin architecture

This document explains the *shape* of the implementation and — more importantly — the
handful of decisions that Odin forces on us that reference Lua (written in C) didn't
have to make. Read this before touching the kernel; several things look surprising
until you know why they are the way they are.

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

### Hosted buffered streams

The hosted I/O library shares `src/stream/` with the command-line programs.
Each stream serializes operations with its own mutex; `flush_all` pins streams
from a separately locked process-wide list before taking their mutexes. It can
therefore flush a different state's stream between two public operations. EOF
and error indicators are atomic, and the last OS error is thread-local.

Bulk delimiter reads copy ordinary bytes, including the delimiter, while holding
the stream mutex and update position and pushback cookies as `getc` would.
Windows text translation still handles CRLF, Ctrl-Z, and saved lookahead. For
lines and bounded reads that fit the Lua buffer's initial scratch area, the I/O
library retains its stack placeholder through string creation and replaces it
with the result; longer reads retain the growable, to-be-closed buffer path.

## Decision 1 — the kernel is a *single* Odin package

In C, Lua's kernel is a pile of `.c`/`.h` files that freely `#include` one another:
`lvm.c` calls into `ldo.c`, which calls `lgc.c`, which calls back into `lvm`-level
concepts, and so on. It is one tightly mutually-recursive unit held together by header
declarations.

Odin has a hard rule: **one directory is one package, and packages may not form import
cycles.** There is no way to split mutually-recursive code across Odin packages. So the
entire kernel lives in **one package**, `src/kernel/`, as many files that share a single
namespace (files in the same Odin package see each other's declarations with no
`import` needed). This mirrors Lua's kernel exactly and sidesteps the cycle rule.

The standard libraries and the two executables are genuinely downstream — they depend
on the kernel but the kernel never depends on them — so they *are* separate packages.
The kernel must never import `stdlib`; if it ever seems to need to, that's a signal the
public API is missing something.

### Freestanding platform boundary

`ODIN_OS == .Freestanding` is the platform switch; there is no parallel project
define. In that build the dependency graph stops before every hosted service:
`stream.odin`, `io`, `os`, `package`, the interactive debug library, and both
standalone mains carry `#+build !freestanding`. The freestanding stdlib surface
is base, coroutine, math, string, table, and utf8. Base omits its three hosted
entries (`print`, `loadfile`, and `dofile`) while retaining in-memory `load`.

The kernel itself never owns a heap. Hosted builds add `default_allocator` in a
host-only source file; freestanding builds expose only the
allocator-taking `new_state`. Firmware must provide that callback, its arena or
heap policy, and any panic/reset behavior. The build also passes
`-default-to-nil-allocator`, so an unintended Odin allocation cannot silently
reach for a platform heap that does not exist.

**Convention for platform-split files.** A target-dependent subsystem is split as
*one untagged file holding everything shared* plus *small tagged files holding only
what genuinely differs*. It is never split as two whole-file forks. Concretely:
`auxlib.odin` carries no build tag and is compiled for every target, while
`auxlib_hosted.odin` (`#+build !freestanding`) holds the file loaders,
`luaL_newstate`, the file/exec result reporters, and the stderr warning system, and
`auxlib_freestanding.odin` (`#+build freestanding`) holds only `aux_makeseed` —
the single routine that is not simply *absent* on bare metal but needs a different
body. `base.odin` follows the same shape, with `print`/`loadfile`/`dofile` in
`base_hosted.odin`.

The one deliberate exception is a registration table: `base_funcs` is spelled out
in full in *both* `base_hosted.odin` and `base_freestanding.odin` rather than being
assembled from a shared list plus per-target extras. Registration order determines
the order keys are inserted into `_G`, hence that table's node layout and
`pairs(_G)` iteration order. Lua leaves that unspecified but it is observable, so
each target owns one explicit ordered list.

Because files in one Odin package share a namespace, a helper needed by a sibling
file should be `@(private)` (package-visible), not `@(private = "file")`. Marking it
file-private and then re-declaring a copy next door is how duplication creeps back
in.

`build/check.*` type-checks the freestanding target alongside the hosted packages
precisely so this split cannot rot unnoticed.

One small build define remains for amd64 ABI selection, not platform selection:
the wrappers set `FREESTANDING_WIN64_ABI=true` for Odin's Win64 and MinGW
freestanding triples. `ODIN_OS` is correctly `Freestanding` for all of them,
but Odin does not expose the sub-ABI needed by the assembly setjmp/longjmp shim.

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

Nothing in the source spells the name of the language it implements. The kernel
subsystems use neutral, semantic prefixes rather than reference Lua's `lua*_`
initials, so a rebranded distribution needs no renaming pass:

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
are simply the kernel's own `TNIL` tags.

**Comment convention.** Backticked `lua*` names *in comments* are always the
**reference C** identifier being mirrored, never a name that exists in this
tree — that provenance is the point of those comments. When a comment means our
code, it uses our spelling.

Identifiers cannot be parameterized by `-define:` (Odin resolves names at
compile time and defines only produce *values*), which is exactly why the names
are neutral rather than brand-derived. Everything that *is* data —  the
`_VERSION` string, the banner, the bytecode signature, the source extension, the
environment-variable prefix, the search paths — lives behind the `#config`
constants in `src/kernel/brand.odin`. See BUILDING.md for the knobs.

## Decision 2 — an explicit-frame-stack VM with a trampoline (plus real `longjmp` for errors)

This is the single most important design decision, and it was confirmed by reviewing
the plan before writing any code.

Reference Lua does two distinct things with the native C stack:

1. It uses `setjmp`/`longjmp` (`luaD_throw` / `luaD_rawrunprotected`) to unwind across
   arbitrarily deep C call frames when an error is raised, snapping the state back to
   the nearest protected-call (`pcall`) boundary.
2. Its coroutines suspend execution from deep inside the interpreter and resume later —
   effectively stack switching.

These are **not** the same problem, and they do **not** need the same solution.

**Errors (1) use real `setjmp`/`longjmp`.** An earlier revision of this document assumed
Odin had no access to them; that was wrong. Odin's standard library binds them in
`core:c/libc`, and on Windows the binding deliberately selects UCRT's *non-unwinding*
`longjmp` (the plain register-restoring jump Lua wants, no SEH unwind). So `throw` /
`run_protected` (see `src/kernel/control.odin`) model `luaD_throw` / `luaD_rawrunprotected`
faithfully: `throw` stashes the status on the innermost `Longjmp` and jumps straight
back to the matching `run_protected`. `throw` never returns; it keeps a `Thread_Status`
return type purely so existing `return throw(...)` propagation sites keep compiling, but
both of its paths diverge (`longjmp` and `abort` are `-> !`). The one discipline this
imposes: because a `longjmp` skips every intervening `defer`, cleanup of a **raw**
(non-GC) allocation must never live in a `defer` a throw could leap over — the protected
wrapper that owns such memory frees it explicitly on both paths, exactly as reference Lua
frees the parser's `Dyndata`/`Mbuffer` after `luaD_pcall`.

**Coroutines (2) still need the explicit heap frame stack.** `longjmp` only *unwinds* a
stack; it cannot *resume* one it already left. A naive recursive interpreter (where a Lua
call is an Odin function call) therefore still cannot implement `coroutine.yield`, because
once we return up the Odin stack to suspend we've destroyed the frames we'd need to
resume. Reference Lua handles this with its explicit `CallInfo` list — and, crucially, it
uses that list *together with* `longjmp`, not instead of it. We do the same.

So we do what reference Lua effectively models with its `CallInfo` list, but make it
fully explicit:

- Each `State` owns its **value stack** and its **call-frame stack** as arrays it
  manages itself — *not* the native Odin call stack.
- Each frame records everything needed to resume it: program counter, stack base/top,
  expected result count, call kind, protected-call recovery info, any continuation
  (`callk`/`pcallk`), hook/finalizer state, and any partially-completed operation.
- The interpreter (`vm_execute`, reference `luaV_execute`) is an **in-place
  trampoline**, not an outcome-returning one. The switch VM uses a labeled loop
  (`newframe`); the default threaded VM tail-transitions between opcode and frame
  entry handlers. Both reload per-frame locals (closure, constants, code, base,
  pc) on frame entry. Ordinary Lua→Lua calls, tail calls and returns never grow
  the native Odin stack: calls push an explicit frame, returns pop it, and both
  re-enter the appropriate frame. A frame entered *fresh* from C (`CIST_FRESH`)
  returns to its native caller instead. Metamethods, iterators and `pcall` can
  re-enter the VM recursively (through reference `luaD_call`); these activations
  are fresh so they return cleanly.

  The unified `Exec_Signal`/`Exec_Outcome` vocabulary still lives in `control.odin` and
  names these transitions for documentation and for the host-callback contract, but the
  hot path expresses *Continue/Returned* as loop control or tail transitions and
  *Errored/Yielded* as a `longjmp` (see below) rather than as a returned tagged
  value — this is both faster and a closer match to reference Lua's own `lvm.c`.

**Both errors and yields unwind with `longjmp`; coroutines resume over the heap frame
stack.** `throw` long-jumps to the nearest protected boundary for a real error, and
`api_yieldk` long-jumps out with a `Yield` status for a suspension. What makes the yield
*resumable* is that the coroutine's frames are heap arrays that are left intact: the
resuming `api_resume` walks back into them via `resume`/`unroll`/`precover` (in `do.odin`),
finishing the interrupted instruction (`luaV_finishOp`) or running the C continuation, and
then trampolines onward. You cannot resume suspended Lua execution after the native frames
that ran it have returned, so the frames must live in the heap where we can pause and
resume them. Error recovery, by contrast, reconciles the explicit frame stack at the catch
site — restoring the frame index, closing open upvalues and to-be-closed slots, and
installing the error object (`luaD_pcall`/`luaD_closeprotected`). The two hard problems are
solved by these two mechanisms working together, exactly as in reference Lua.

Host (Odin) callbacks follow the same continuation rules as C functions in reference
Lua: an ordinary callback is non-yieldable across its native frame, while a yieldable
callback must register a continuation. A callback returns a *tagged outcome*, not just
an integer result count.

### Tail-call-threaded dispatch

The threaded VM is the default on amd64 and arm64. `VM_THREADED=0` in the wrappers
or `-define:VM_THREADED=false` in direct Odin commands selects the switch; other
architectures select it automatically. Each of the 85 opcodes has a handler, and
a 128-entry table maps the entire seven-bit opcode field to handlers, including
one error handler for the 43 unused encodings. Each fetch tail-jumps through the
table. It contains procedure addresses, relocated once by the loader. In the
inspected amd64 and arm64 objects Odin's `"preserve/none"` calling convention and
`#must_tail` produce indirect jumps rather than growing the native stack. Those
are the architectures supported by the current jump shim; enabling this VM on
another architecture is explicitly rejected rather than assuming an ABI. Runtime
validation has only been performed on Linux x86-64: Windows x64, Linux arm64 and
macOS arm64 have been cross-compiled to objects but not run, by the user's decision.

Handlers pass `L`, the next PC, the register-base pointer, closure, code base,
frame index, trap, an Odin context pointer, and the current instruction. The
constants are derived from the closure, and the register-base *index* from the
pointer and the current stack, when an opcode needs them. A VM activation owns
the context copy for the lifetime of its tail-call chain. Frame entry is another
tail transition, which re-derives the closure, PC, and base and performs the
normal call-hook setup. Lua-to-Lua calls, tail calls and returns therefore use
the same explicit frame stack; `CIST_FRESH`
returns to the native caller. Native calls, iterators and metamethods retain their
existing re-entrant boundaries.

The fetch trap moves to a separate cold handler: it runs `debug_traceexec` and
refreshes the base before fetching, including after relocation. `VARARGPREP`
refreshes the base immediately and retains its delayed call-hook behavior.
Interrupts are still polled at the same control-flow edges; edge-only slow polls
tail-jump to a handler that applies the request and continues at the next fetch.
Errors and yields still long-jump through the existing protected boundaries.
Coroutine resumption runs the existing interrupted-op continuation and re-enters
`vm_execute`, rebuilding the local PC from the persistent index.

The switch bodies in `vm.odin` are the source of the checked-in threaded region,
generated by the Odin tool `tools/generate_threaded/`; `build/test.*` builds
and runs it to check for drift. The generator verifies the opcode inventory and
frame transitions. It also rejects unreviewed changes to rewritten entry, fetch,
poll, and specialized opcode bodies, as well as the ordinary table and call
helpers those specializations mirror. This requires review when a guarded body
changes; it is not a proof of semantic equivalence.

The threaded upvalue handlers derive the inline vector from the carried closure,
the same non-moving object held in the function slot below the register base.
Variable-key table handlers address operands directly from that base, whose
pointers are consumed before any callout; the slow read still receives a stack
index for its result. Global, field and variable-key reads try the shared
contextless table lookup before entering a no-inline miss path. Variable-key
array and short-string hits stay in their handler; integer-hash and other key
types tail-transition to contextless lookup handlers without repeating the
table/type dispatch. Known empty slots and non-tables go straight to the
existing finish path without repeating the lookup. Method lookup
also handles a string whose `__index` is a table with a matching key; it keeps
the saved PC and stack top updates made by the original non-table path.

Variable-key integer writes of non-collectable values use the ordinary pre-set
without a context. The slow setter also tries short-string pre-sets for primitive
values; that shared pre-set declines a new white key in a black table. It may
finish an integer-key write of a collectable value without a context only when
the ordinary back barrier is a no-op, with no allocation or re-entry between
the color test and the write. A needed barrier uses the original setter. An
unfinished pre-set passes its location to the original finish path. These hits
cannot move the stack or change the trap. Misses receive the activation's
original context and reload the trap after any callout. The generator guards
the shared pre-set and barrier predicates as well as the opcode bodies.

Threaded concatenation follows the same right-to-left folding, coercion and
top/saved-PC protocol as the switch VM. Its contextless common path mirrors
short-string interning and fresh string-object allocation: it calls the same
C-ABI allocator, links the same GC object and updates debt by the same amount.
It re-resolves stack slots after a numeric conversion that may have triggered
an emergency collection. Allocation retries, intern-table growth, GC steps,
errors and metamethod calls use the activation's original context. A
two-operand non-coercible pair tail-transitions to a cold metamethod handler;
the other cases use the contextless fold and its original-context callouts.
The generator guards the mirrored concat, string, allocation and GC helpers.

String lengths use a contextless handler but retain the switch VM's saved-PC
and stack-top updates; other lengths use the ordinary helper with the original
context. Constant-operand floor division and modulo use the contextless raw
arithmetic helper, with the same saved-PC and top updates; their zero-divisor
errors use the original context. On an integer `FORLOOP` back edge, the next
instruction is read before the loop registers are updated; a pending interrupt
or trace discards that read and uses the ordinary poll or trace path. The code
is immutable while the activation runs, and the same register tags are written
as in the switch. This applies to integer loops generally, not just empty ones;
floating-point loops use the ordinary path. The call-hook work at frame entry
is separated from the no-hook path, with the same base refresh after the hook.
These rewrites are guarded by the generator.

The threaded CALL handler specializes non-allocating Lua-closure and native
frame setup. Native call hooks, growth and `__call` remain out of line. A native
callback can relocate both stacks or install hooks, so its frame is re-derived
after the call; return hooks, to-be-closed values and result counts other than
zero or one use the ordinary post-call path. Relocation test mode routes all
calls through the ordinary helper so its forced moves still happen. The
specialized helpers are in `vm_threaded_fast.odin`: keeping them out of
`vm.odin` also avoids a measured switch-VM code-placement regression.

Threaded `RETURN0` and `RETURN1` keep their no-hook result movement in the hot
handler. A pending interrupt or active hook tail-transitions to a separate copy
of the switch-derived body, which polls, saves the PC and resolves the frame
after hooks just as the switch does. The generator guards the original bodies
and emits both paths. These specializations duplicate parts of the shared
helpers and must be reviewed when those helpers change. Both modes use the same
tests, including forced stack and frame relocation. Results and limitations are
recorded in
[bench/THREADED_VM.md](../bench/THREADED_VM.md); remaining validation and
performance work is listed in [FUTURE_WORK.md](FUTURE_WORK.md).

## Decision 3 — persistent indices, temporary VM pointers

Because the value and frame stacks can reallocate, frames, protected boundaries,
open upvalues, and API stack slots store **indices/offsets**. They resolve a slot
to a pointer only for an operation on the current backing array. Frame pointers
are never retained across re-entrant calls. Active frames are exactly `0..L.ci`;
there is no separate live-frame count to reconcile after an error unwind.

The VM also keeps a local register-base pointer. Stack reallocation
arms the trap on every Lua frame; after a potentially moving call, the VM reloads
the trap and re-derives the base at the next fetch, before dereferencing it. Such
calls include metamethods, GC, hooks, native calls, iterators and varargs. A handler
that needs a register pointer again within the same instruction must re-derive it
immediately after the call instead of waiting for the next fetch.
Tail-call argument sliding similarly derives a temporary stack pointer only after
its growth check; the following copies and nil writes cannot allocate or re-enter
Lua, and no such pointer survives that operation.

The saved program counter remains an instruction index. Completed prototypes have
immutable code rooted by the closure in the live frame's function slot; undumping
copies the code, including for stripped and fixed-mode chunks. However, a loader
reader can obtain the still-being-compiled closure through a C temporary exposed
by the debug API, start it in a coroutine and yield. Compilation can then grow
or shrink its code before that coroutine resumes. A saved code pointer would be
outdated; the index lets frame entry re-derive the PC from the current code array.
The local dispatch PC only exists while its VM activation is running, when that
reader has not yet returned control to the parser.

`HARDSTACKTESTS` forces even no-growth value-stack checks and GC shrink paths, and
every frame push, to allocate a different block and free the old block. It poisons
the old block before freeing outside ASan; the test scripts can combine stress
with AddressSanitizer to catch outdated references. Frame growth also arms the existing
per-frame traps, before publishing the new slot. As in reference's `ltests` build,
stress defaults to a 68,000-slot stack limit so stack-overflow tests finish despite
quadratic copying; ordinary builds retain the 1,000,000-slot limit. Extra allocations
can change GC timing and Lua-visible memory measurements in this test mode.

Frame setup leaves `u2` untouched: each of its yield, protected-call, and close
uses writes the field before the matching continuation can read it. Missing fixed
arguments are nil-filled after both growth checks, and the final top is published
before the callee runs. The hidden-vararg count is 32 bits when the configured
stack ceiling and its reserves fit; larger custom ceilings use the full-width
count. This does not narrow saved PCs or stack/frame indices and leaves the frame
allocation size unchanged.

For `CALL`, the VM can set up Lua and native frames without allocating when
stack headroom and a frame slot are already available. Non-functions and growth
go through the full precall protocol; native calls also use that path when a
call hook is enabled. Lua hooks still run at frame entry, and native return hooks
run in `do_poscall`. A native callback can allocate and move either array, so its
frame is retained by index and resolved again after the callback. `HARDSTACKTESTS`
always uses the full protocol so its forced moves still exercise every call.

Internal invariant assertions follow reference `lua_assert`: release builds omit
them; debug, Odin test and stress builds enable them. Embedding API precondition
checks have their own `API_CHECKS` switch and remain enabled by default to preserve
the existing embedding contract. Input checks and fail-fast guards are not
disabled by these switches.

## Decision 4 — a fallible allocator and honest OOM

Reference Lua can catch out-of-memory: allocation failure triggers an emergency
collection and retry, and a *preallocated* memory-error object means reporting OOM
never itself needs to allocate. We reproduce this with a single **fallible allocator
abstraction** through which all kernel allocation flows. The kernel avoids standard
containers that panic or allocate implicitly, so an allocation failure is always a
value we can handle (`Out_Of_Memory`) rather than a crash. OOM is tested at allocation
points, not hand-waved.

On Linux, macOS and the BSDs the hosted default allocator goes directly through
Odin's contextless C-heap `realloc`/`free` wrappers; Windows uses its process
heap. These blocks are returned only through the same callback, not an Odin
allocator. A failed resize leaves the old block intact for `state_realloc`'s
emergency collection and retry; signed-size guards reject unrepresentable
requests before reaching the heap. The 64-bit glibc, musl and macOS C heaps give
16-byte alignment. BSD heaps need not do so for tiny allocations: FreeBSD's
jemalloc may give an 8-aligned block for requests of at most 8 bytes. Kernel
allocation types need at most 8-byte alignment. Typical 32-bit heaps provide at
least 8 bytes, but the kernel's layout assertions currently require 64-bit
targets. Freestanding builds use only the embedder's allocator.

On hosted Linux with libc, `os.getenv` passes the rooted, NUL-terminated Lua
argument directly to the host and copies its result into Lua before the GC
check. Windows and no-CRT builds retain the scoped host-string lookup. Linux
local date and table-to-time conversions share a bounded static timezone cache:
a mutex protects its TZif image, POSIX rule and last transition range. The
current `TZ` is compared on every call; when it is unset, the site default is
re-statted. Unusually large inputs fall back to the scoped loader. No Lua call
runs with the mutex held, and zone names are copied before unlocking. This
storage has process lifetime without a per-state allocation or leak. Other
hosts retain their existing timezone paths; freestanding excludes the OS library.

On 64-bit targets an `UpVal` is 48 bytes. Its body overlays the open-list links
with the closed `TValue`; open upvalues retain a thread and full-width index,
not a movable stack pointer. An `LClosure` has a 32-byte header followed by
its inline vector of 8-byte upvalue pointers; the vector address is derived
from the closure. GC debt, marking and frees use the actual allocation sizes,
just as in reference.

Native library callbacks retain their C ABI. A hot callback may omit its usual
`runtime.default_context()` only when its fast path calls exclusively
`"contextless"` helpers. Coercion, allocation, formatting, error reporting, OS
operations and other ordinary Odin calls must first establish the default context,
either in a no-inline slow helper or only on the branch that needs it.
`api_native_*` is a narrow positive-argument fast path for these callbacks, not a
replacement for the embedding API: the latter keeps its existing procedure types
and caller-supplied assertion handler. Both paths retain `API_CHECKS`; stress stack
checks still perform forced relocation.

## Decision 5 — byte-compatible bytecode is per a fixed ABI config

Lua bytecode chunks embed raw host representations (instruction words, `lua_Number`
bit patterns, integer sizes, endianness, alignment). "Compatible with every Lua build"
is impossible because the format is configuration-dependent. We therefore target one
explicit reference configuration:

- little-endian,
- 32-bit `Instruction` and `int`,
- 64-bit integer (`lua_Integer`),
- IEEE-754 binary64 (`lua_Number`),

preserve floating-point *bit patterns* (never numerically re-encode), and serialize the
C-defined layout explicitly rather than relying on Odin struct padding. Incompatible
chunks are rejected exactly as the reference header check does. Correctness is proven
with golden-byte differential tests against a matching reference `luac` build.

## Testing philosophy

Tests must *truthfully* prove correctness — never fitted to pass by asserting on
incidental internals. Two layers:

1. **Odin unit + differential tests, every phase.** Compare our behavior/bytecode
   against reference Lua as each subsystem lands (numeric edge cases, table/string
   behavior, compiler prototypes as golden bytes, VM instruction-level programs, GC
   weak/finalizer behavior, coroutine/`pcallk`/hook interactions).
2. **The official PUC-Rio Lua 5.5 suite** (vendored under `tests/puc`) as the final,
   whole-language oracle.
