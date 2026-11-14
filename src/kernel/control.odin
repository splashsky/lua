package kernel
// control.odin -- the unified execution/error outcome and protected boundaries.
//
// This file has no single reference-Lua counterpart. Reference Lua unwinds
// errors with setjmp/longjmp; our libc-free equivalents live in jmp.odin.
//
// The whole VM/call machinery speaks in one tagged outcome:
//   Continue        -- keep stepping the current frame
//   Returned        -- current frame finished; pop and resume its caller
//   Yielded         -- suspend to the resuming boundary, staying resumable
//   Errored(status) -- unwind to the nearest protected (pcall) boundary
//   Out_Of_Memory   -- emergency-collect then retry, or surface as an error
//
// It lands *before* the compiler on purpose: the lexer, parser, undumper, and
// allocator all raise protected errors, so this primitive must exist first or
// they'd grow throwaway error handling we'd later rip out.
//
import "base:runtime"
import host "lang:host"

// ---------------------------------------------------------------------------
// Thread status / error codes
// ---------------------------------------------------------------------------

// `Thread_Status` is the exact set of status codes reference Lua defines in
// `lua.h` (LUA_OK .. LUA_ERRERR), with the same integer values so the embedding
// API can hand them back to callers unchanged. A thread carries the last such
// status on `Lua_State.status`; a protected call reports one as its result.
//
//   Ok         -- no error / normal completion
//   Yield      -- a coroutine suspended itself
//   Err_Run    -- a runtime error (the `error()` builtin, a failed metamethod...)
//   Err_Syntax -- the lexer/parser/undumper rejected a chunk
//   Err_Mem    -- an allocation failed and could not be recovered
//   Err_Err    -- an error occurred while running the message handler
Thread_Status :: enum i32 {
	Ok         = 0,
	Yield      = 1,
	Err_Run    = 2,
	Err_Syntax = 3,
	Err_Mem    = 4,
	Err_Err    = 5,
}

// Reference Lua's `errorstatus`: a status is a *real error* only when it ranks
// above `Yield`. `Ok` and `Yield` are the two non-error outcomes. Used by the
// error machinery to decide when there is genuinely an error object to move.
is_error_status :: proc "contextless" (s: Thread_Status) -> bool {
	return i32(s) > i32(Thread_Status.Yield)
}

// ---------------------------------------------------------------------------
// The unified execution outcome
// ---------------------------------------------------------------------------

// `Exec_Signal` is the coarse "what happened" that the VM trampoline (Phase 5)
// returns after stepping a frame. It is defined here, ahead of the compiler and
// VM, so every subsystem that returns control can speak the same vocabulary from
// day one (see this file's header for why control must exist early).
Exec_Signal :: enum u8 {
	Continue, // keep stepping the current frame
	Returned, // current frame finished; pop and resume its caller
	Yielded, // suspended to the resuming boundary, still resumable
	Errored, // unwind to the nearest protected boundary
	Out_Of_Memory, // emergency-collect then retry, or surface as an error
}

// `Exec_Outcome` pairs the signal with the status it carries. The review that
// vetted this design flagged that a bare enum can't remember *which* error a
// frame hit (Err_Run vs Err_Syntax vs Err_Mem vs Err_Err), and that stashing it
// on `Lua_State.status` would wrongly leave a thread looking broken after a
// caught error. So we thread the status alongside the signal instead. For a
// non-error signal `status` is simply `Ok`.
Exec_Outcome :: struct {
	signal: Exec_Signal,
	status: Thread_Status,
}

// ---------------------------------------------------------------------------
// Protected boundaries with setjmp/longjmp
// ---------------------------------------------------------------------------

// Reference Lua unwinds errors with `longjmp`, jumping straight from the point
// of failure back to the matching `luaD_rawrunprotected`. `jmp.odin` implements
// the same plain register-restoring jump directly for each supported ABI, so we
// can model the error path faithfully without depending on a C runtime.
//
// One subtlety worth stating up front: `longjmp` only solves *error escape*. It
// cannot resume a stack it already unwound, so coroutine `yield` still rides the
// explicit heap frame-stack + trampoline (see docs/ARCHITECTURE.md, Decision 2).
// Reference Lua uses *both* mechanisms together -- an explicit `CallInfo` list
// AND `longjmp` -- so adopting the jump for errors while keeping the frame stack
// for yields is more faithful, not a contradiction.
//
// Because a `longjmp` skips every intervening `defer`, kernel and compiler code
// must never park cleanup of a *raw* (non-GC) allocation in a `defer` that a
// throw could leap over. Anything heap-allocated outside the GC (the parser's
// `Dyndata`/`Mbuffer`, say) is freed explicitly by the protected wrapper that
// owns it, on both the success and the error path -- exactly as reference Lua
// frees them after `luaD_pcall`.

// `Lua_Longjmp` is our analogue of reference Lua's `struct lua_longjmp`: one
// node of the per-thread chain of active protected scopes. It parks the machine
// state to jump back to and the error code being carried out. It lives on the
// native stack of whichever `run_protected` created it -- never on the heap --
// so nothing here can itself fail to allocate while we're handling an error.
Longjmp :: struct {
	previous: ^Longjmp,  // the enclosing protected scope, if any
	b:        Jmp_Buf,       // saved machine state (the `setjmp` target)
	status:   Thread_Status, // error code in flight; set by `throw`, read on catch
}

// A protected computation is any procedure with this shape. The `ud` pointer is
// an opaque payload (an argument bundle), exactly like reference Lua's `Pfunc`.
//
// Contract: `f` reports normal completion or a coroutine yield by *returning*
// (`.Ok` / `.Yield`); a genuine error is raised through `throw`, which longjmps
// back to `run_protected` and never returns. `f` must never *return* an
// `.Err_*` status -- if it does, a throw site was missed, and `run_protected`
// asserts to catch that during development.
Protected_Proc :: #type proc(L: ^State, ud: rawptr) -> Thread_Status

// Run `f` under a fresh protected boundary and report the caught status. This is
// our analogue of `luaD_rawrunprotected`. We push a `Lua_Longjmp` onto the
// thread's `errorJmp` chain, `setjmp` a landing pad, and run `f`; a `throw`
// anywhere inside `f` longjmps straight back here. We save and restore the
// C-call count around the boundary just as reference Lua does, so a caught error
// doesn't leak a bumped `n_ccalls`.
//
// This routine restores ONLY `errorJmp` and `n_ccalls` -- deliberately the same
// minimal set reference `luaD_rawrunprotected` touches. Full Lua-level `pcall`
// recovery (rewinding the frame index, closing open upvalues and to-be-closed
// slots, restoring `errfunc`/`allowhook`, installing the error object, shrinking
// the stack) is a *separate* layer built on top of this in Phase 5; keeping it
// out of here mirrors reference Lua's split and avoids conflating the two.
// Keep this boundary out of its caller: Odin cannot mark jmp_set as returning
// twice, so inlining could reuse a caller's live stack slot on the initial path
// and then read the overwritten slot when a longjmp takes the error path.
run_protected :: #force_no_inline proc(L: ^State, f: Protected_Proc, ud: rawptr) -> Thread_Status {
	old_ccalls := L.n_ccalls
	lj: Longjmp
	lj.status = .Ok
	lj.previous = L.errorJmp // chain onto any enclosing boundary
	L.errorJmp = &lj
	// `setjmp` returns 0 on the initial call and (here) 1 when reached via a
	// `longjmp` from `throw`. On the initial pass we run the computation; on
	// the error return we skip straight past it, leaving in place the status
	// that `throw` already stored on `lj`.
	if (transmute(proc "c" (^Jmp_Buf) -> i32)jmp_set)(&lj.b) == 0 {
		st := f(L, ud)
		when INTERNAL_ASSERTS {assert(!is_error_status(st), "protected proc returned an error status instead of throwing it")}
		lj.status = st
	}
	L.errorJmp = lj.previous // unlink this boundary
	L.n_ccalls = old_ccalls
	return lj.status
}

// Raise an error of the given code. Our analogue of `luaD_throw`, and now a
// faithful one: it does not return to its caller. Two cases mirror reference Lua:
//
//   * A protected boundary is active (`errorJmp != nil`): stash the code on the
//     innermost boundary and `longjmp` back to its `setjmp` in `run_protected`.
//     We deliberately do NOT touch `L.status` here -- a thread whose error is
//     about to be caught by `pcall` must remain observably fine afterward. (The
//     review that vetted this specifically caught that clobbering `L.status`
//     would leave a recovered thread looking errored.)
//   * No boundary at all: this is unrecoverable. Set `L.status`, invoke the
//     panic function if the embedder installed one, and `abort()` -- reference
//     Lua does the same. (Re-throwing into the main thread from a coroutine is a
//     Phase-5 concern once real threads/frames exist.)
//
// The declared return type stays `Thread_Status` purely so the ~20 existing
// `return throw(L, .Err_*)` propagation sites keep compiling unchanged. Both
// branches below diverge (`longjmp` and `abort` are both `-> !`), so there is no
// reachable `return` and Odin is happy; the type is never actually produced.
throw :: proc(L: ^State, errcode: Thread_Status) -> Thread_Status {
	if L.errorJmp != nil {
		L.errorJmp.status = errcode
		jmp_long(&L.errorJmp.b, 1)
	}
	g := L.g
	L.status = errcode
	if g != nil && g.panic != nil {
		g.panic(L)
	}
	when ODIN_OS == .Freestanding {
		// There is no process to terminate on bare metal. The panic callback is
		// the embedder's last chance to reset, halt, or report the fault; if it
		// returns, park forever rather than reaching an unavailable OS exit.
		for {}
	} else {
		host.fatal_exit(134)
	}
}

// Throw straight to the *base* protected boundary of this thread -- reference
// Lua's `luaD_throwbaselevel`. Ordinary `throw` unwinds to the *innermost* active
// boundary (the nearest `pcall`); this one first rewinds the `errorJmp` chain to
// its outermost node, so the throw leaps past every intervening `pcall` in one
// go. It is exactly what a coroutine closing *itself* needs: `coroutine.close()`
// run from inside a coroutine must terminate the whole coroutine (back to the
// `resume` boundary), not merely pop out to some enclosing `pcall`. With no
// boundary at all it degenerates to a plain `throw` (panic + abort).
throw_baselevel :: proc(L: ^State, errcode: Thread_Status) -> Thread_Status {
	if L.errorJmp != nil {
		for L.errorJmp.previous != nil {
			L.errorJmp = L.errorJmp.previous
		}
	}
	return throw(L, errcode)
}

// Move the error object into place after an error is caught, our analogue of
// `luaD_seterrorobj`. `old_top` is the stack index the protected boundary wants
// the error object to land at; afterward `top` sits one slot past it.
//
//   * `Err_Mem`: reference Lua reuses the preallocated "not enough memory"
//     string so that reporting an out-of-memory error never itself allocates.
//     We do the same, pointing the error slot at `g.memerrmsg`. On the rare path
//     where the state isn't complete yet (memerrmsg not interned), we fall back
//     to nil rather than dereference a null string.
//   * `Err_Err`: an error was raised *while handling* another error. Reference
//     replaces whatever half-formed object is on the stack with the fixed literal
//     "error in error handling" -- the message handler is deliberately NOT the
//     surviving value, so callers see a stable diagnostic string.
//   * any other error: the raiser left the error object at `top-1`; slide it down
//     to `old_top`.
set_error_object :: proc(L: ^State, errcode: Thread_Status, old_top: int) {
	if errcode == .Err_Mem {
		if L.g.memerrmsg != nil {
			set_string(stack_value(L, old_top), L.g.memerrmsg)
		} else {
			set_nil(stack_value(L, old_top))
		}
	} else if errcode == .Err_Err {
		set_string(stack_value(L, old_top), string_new(L, "error in error handling"))
	} else {
		stack_value(L, old_top)^ = stack_value(L, L.top - 1)^
	}
	L.top = old_top + 1
}
