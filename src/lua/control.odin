package lua

// control.odin -- the unified execution/error outcome and protected boundaries.
//
// This file has no single reference-Lua counterpart; it exists because Odin has
// no setjmp/longjmp. Reference Lua unwinds errors and switches coroutine stacks
// with longjmp over the native C stack. We can't, so we make the control flow
// *explicit* (see docs/ARCHITECTURE.md, Decision 2).
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
import "core:c/libc"

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
// Protected boundaries without setjmp/longjmp
// ---------------------------------------------------------------------------

// Reference Lua unwinds errors with `longjmp`, jumping straight from the point
// of failure back to the matching `luaD_rawrunprotected`. Odin has no safe
// equivalent (a `longjmp` would skip `defer`s and leave the runtime in an
// undefined state), so we make the unwinding *explicit*: an operation that fails
// returns an error `Thread_Status`, and every caller in the chain propagates it
// upward by returning it too. `run_protected` is the one place that *stops* the
// propagation and reports the status as a caught result.
//
// A protected computation is any procedure with this shape. The `ud` pointer is
// an opaque payload (an argument bundle), exactly like reference Lua's `Pfunc`.
Protected_Proc :: #type proc(L: ^Lua_State, ud: rawptr) -> Thread_Status

// Run `f` under a fresh protected boundary and return whatever status it yields.
// This is our analogue of `luaD_rawrunprotected`, minus the longjmp. We bump a
// depth counter so a `throw` deeper in the call chain knows *some* handler is
// active (and therefore that it may simply return an error status rather than
// panic). We save and restore the C-call count around the boundary just as
// reference Lua does, so a caught error doesn't leak a bumped `nCcalls`.
//
// Note the depth counter is deliberately just "a raw protected scope exists" --
// it is NOT the model for Lua-level `pcall`, continuations, or coroutine unwind,
// which (Phase 5) need indexed frame/top/errfunc records. Keeping it minimal now
// avoids a boundary stack that could itself fail to allocate while handling OOM.
run_protected :: proc(L: ^Lua_State, f: Protected_Proc, ud: rawptr) -> Thread_Status {
	old_ccalls := L.n_ccalls
	old_depth := L.error_boundary_depth
	L.error_boundary_depth += 1
	status := f(L, ud)
	L.error_boundary_depth = old_depth
	L.n_ccalls = old_ccalls
	return status
}

// Raise an error of the given code. Our analogue of `luaD_throw` -- but since we
// can't jump, this cannot itself unwind: it records what's needed and returns the
// code so the caller can propagate it. Two cases mirror reference Lua:
//
//   * A protected boundary is active (`error_boundary_depth > 0`): return the
//     code. Crucially we do NOT touch `L.status` here -- a thread whose error is
//     about to be caught by `pcall` must remain observably fine afterward. (The
//     review specifically caught that clobbering `L.status` would leave a
//     recovered thread looking errored.)
//   * No boundary at all: this is unrecoverable. Set `L.status`, invoke the
//     panic function if the embedder installed one, and abort -- reference Lua
//     calls `abort()` here too. (Re-throwing into the main thread from a
//     coroutine is a Phase-5 concern once real threads/frames exist.)
throw :: proc(L: ^Lua_State, errcode: Thread_Status) -> Thread_Status {
	if L.error_boundary_depth > 0 {
		return errcode
	}
	g := L.g
	L.status = errcode
	if g.panic != nil {
		g.panic(L)
	}
	// TODO(phase-5): faithful main-thread re-throw before aborting.
	libc.abort()
}

// Move the error object into place after an error is caught, our analogue of
// `luaD_seterrorobj`. `old_top` is the stack index the protected boundary wants
// the error object to land at; afterward `top` sits one slot past it.
//
//   * `Err_Mem`: reference Lua reuses the preallocated "not enough memory"
//     string. That string is a `TString`, which doesn't exist until Phase 3, so
//     for now we leave a nil placeholder there. No Phase-2 path builds an ERRMEM
//     error object on a completed state, so this stays honest.
//   * any other error: the raiser left the error object at `top-1`; slide it down
//     to `old_top`.
set_error_object :: proc(L: ^Lua_State, errcode: Thread_Status, old_top: int) {
	if errcode == .Err_Mem {
		// TODO(phase-3): copy G(L).memerrmsg once interned strings exist.
		set_nil(stack_value(L, old_top))
	} else {
		stack_value(L, old_top)^ = stack_value(L, L.top - 1)^
	}
	L.top = old_top + 1
}
