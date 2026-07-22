# lua-odin architecture

This document explains the *shape* of the implementation and — more importantly — the
handful of decisions that Odin forces on us that reference Lua (written in C) didn't
have to make. Read this before touching the kernel; several things look surprising
until you know why they are the way they are.

## The big picture

```
                +------------------------------------+
                |        src/main.odin  (lua)        |   standalone interpreter / REPL
                +------------------------------------+
                +------------------------------------+
                |        src/luac/main.odin          |   bytecode compiler / dumper
                +------------------------------------+
                                 |
                                 v   (imports luao:stdlib, luao:lua)
                +------------------------------------+
                |        src/stdlib  (package)       |   base/string/table/math/io/os/
                |  auxlib + all standard libraries   |   coroutine/utf8/debug/package
                +------------------------------------+
                                 |
                                 v   (imports luao:lua — public API only)
                +------------------------------------+
                |        src/lua  (ONE package)      |   the kernel
                |  object state gc string table func |
                |  tm vm do code parse lex api dump  |
                +------------------------------------+
```

## Decision 1 — the kernel is a *single* Odin package

In C, Lua's kernel is a pile of `.c`/`.h` files that freely `#include` one another:
`lvm.c` calls into `ldo.c`, which calls `lgc.c`, which calls back into `lvm`-level
concepts, and so on. It is one tightly mutually-recursive unit held together by header
declarations.

Odin has a hard rule: **one directory is one package, and packages may not form import
cycles.** There is no way to split mutually-recursive code across Odin packages. So the
entire kernel lives in **one package**, `src/lua/`, as many files that share a single
namespace (files in the same Odin package see each other's declarations with no
`import` needed). This mirrors Lua's kernel exactly and sidesteps the cycle rule.

The standard libraries and the two executables are genuinely downstream — they depend
on the kernel but the kernel never depends on them — so they *are* separate packages.
The kernel must never import `stdlib`; if it ever seems to need to, that's a signal the
public API is missing something.

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

## Decision 2 — an explicit-frame-stack VM with a trampoline (no `longjmp`)

This is the single most important design decision, and it was confirmed by reviewing
the plan before writing any code.

Reference Lua does two things Odin's standard language cannot:

1. It uses `setjmp`/`longjmp` (`luaD_throw` / `luaD_rawrunprotected`) to unwind across
   arbitrarily deep C call frames when an error is raised, snapping the state back to
   the nearest protected-call (`pcall`) boundary.
2. Its coroutines suspend execution from deep inside the interpreter and resume later —
   effectively stack switching.

Odin has **no** `setjmp`/`longjmp`, no exceptions, and no way to save/restore a native
call stack. A naive recursive interpreter (where a Lua call is an Odin function call)
therefore *cannot* faithfully implement `error`/`pcall` unwinding or `coroutine.yield`,
because once we return up the Odin stack to propagate a yield/error we've destroyed the
very frames we'd need to resume.

So we do what reference Lua effectively models with its `CallInfo` list, but make it
fully explicit:

- Each `lua_State` owns its **value stack** and its **call-frame stack** as arrays it
  manages itself — *not* the native Odin call stack.
- Each frame records everything needed to resume it: program counter, stack base/top,
  expected result count, call kind, protected-call recovery info, any continuation
  (`callk`/`pcallk`), hook/finalizer state, and any partially-completed operation.
- The interpreter is a **trampoline**: a loop that steps the current frame and reacts
  to a single unified outcome:

  ```
  Exec_Outcome ::
      Continue          -- keep stepping the current frame
      Returned          -- current frame finished; pop and resume caller
      Yielded           -- unwind to the resuming boundary, staying resumable
      Errored(status,v) -- unwind to the nearest protected boundary
      Out_Of_Memory     -- emergency-collect then retry, or propagate as error
  ```

Error recovery and coroutine suspension become explicit state-machine transitions over
this frame stack, not native stack unwinding. Crucially, **coroutines force this
design**: you cannot resume suspended Lua execution after the native frames that ran it
have returned, so the frames must live in the heap where we can pause and resume them.
The two hard problems (errors and coroutines) share one solution.

Host (Odin) callbacks follow the same continuation rules as C functions in reference
Lua: an ordinary callback is non-yieldable across its native frame, while a yieldable
callback must register a continuation. A callback returns a *tagged outcome*, not just
an integer result count.

## Decision 3 — indices, never retained pointers

Because the value and frame stacks are Odin arrays that **grow** (and growth may
reallocate the backing memory), we never hold a raw pointer into them across anything
that could reallocate or trigger GC. Frames, protected boundaries, open upvalues, and
API stack slots all store **indices/offsets** and resolve them to a pointer only for
the duration of an operation on the current backing array. This is the Odin-safe
equivalent of Lua's care around stack reallocation.

## Decision 4 — a fallible allocator and honest OOM

Reference Lua can catch out-of-memory: allocation failure triggers an emergency
collection and retry, and a *preallocated* memory-error object means reporting OOM
never itself needs to allocate. We reproduce this with a single **fallible allocator
abstraction** through which all kernel allocation flows. The kernel avoids standard
containers that panic or allocate implicitly, so an allocation failure is always a
value we can handle (`Out_Of_Memory`) rather than a crash. OOM is tested at allocation
points, not hand-waved.

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
