package lua

// do.odin -- our analogue of reference Lua's `ldo.h` / `ldo.c`.
//
// The call-and-return protocol and the protected-execution machinery. In
// reference Lua this is the home of luaD_call / luaD_pcall / luaD_throw /
// luaD_rawrunprotected and the stack-reallocation logic. For us it's where the
// explicit-frame model earns its keep (see docs/ARCHITECTURE.md, Decision 2):
//
//   * setting up and tearing down call frames on the explicit frame stack,
//   * running a computation under a protected boundary and catching Errored,
//   * driving coroutine resume/yield as transitions over that frame stack,
//   * growing the value stack (by index-safe reallocation).
//
// Errors themselves unwind via a faithful setjmp/longjmp (see control.odin's
// `throw`/`run_protected`); the explicit frame stack here is what makes
// coroutine yield -- which longjmp cannot express -- resumable.
//
// This file and `vm` together *are* the interpreter's spine, tied together by
// the `Exec_Outcome` from control.odin.
//
// TODO(phase-5): frame push/pop, protected call, error propagation to the
// nearest boundary, and coroutine resume/yield.
//
// Phase 2 delivers the piece the whole runtime leans on before any of that: the
// value stack's index-safe growth. Because our slots are addressed by index, the
// reallocation that would force reference Lua to walk every pointer and rebase it
// (`correctstack`) is, for us, a no-op -- which is exactly the payoff of the
// index model (Decision 4).

// ---------------------------------------------------------------------------
// Stack-size constants (reference Lua: lua.h, lstate.h, ldo.c, ldo.h)
// ---------------------------------------------------------------------------

// The minimum working slots any function is guaranteed on the stack (lua.h).
LUA_MINSTACK :: 20

// Extra slots reserved past `stack_last` so a handful of operations (pushing an
// error object, a metamethod's arguments) can proceed without a growth check
// (lstate.h's `EXTRA_STACK`).
EXTRA_STACK :: 5

// A fresh thread's usable stack size: two minimum working areas (lstate.h's
// `BASIC_STACK_SIZE`).
BASIC_STACK_SIZE :: 2 * LUA_MINSTACK

// The hard ceiling on stack size. Reference Lua takes the smaller of a fixed
// cap and whatever `size_t` can address; on our 64-bit target the fixed cap
// (`LUAI_MAXSTACK`, 1,000,000 -- it fits under INT_MAX/2) always wins, but we
// compute the minimum honestly so a hypothetical tiny-pointer platform stays
// correct (ldo.c's `MAXSTACK`).
LUAI_MAXSTACK :: 1_000_000
STACKERRSPACE :: 200
MAXSTACK_BYSIZET :: int(MAX_SIZET / uint(size_of(StackValue)) - uint(STACKERRSPACE))
MAXSTACK :: min(LUAI_MAXSTACK, MAXSTACK_BYSIZET)

// The size the stack is blown up to while *handling* a stack-overflow error, so
// there's room to build and report the error (ldo.c's `ERRORSTACKSIZE`).
ERRORSTACKSIZE :: MAXSTACK + STACKERRSPACE

// The nested non-yieldable-call ceiling that guards against runaway C recursion
// (ldo.h's `LUAI_MAXCCALLS`).
LUAI_MAXCCALLS :: 200

// ---------------------------------------------------------------------------
// Value-stack (re)allocation and growth
// ---------------------------------------------------------------------------

// Reallocate the value stack to `newsize` usable slots (plus the `EXTRA_STACK`
// reserve), erasing any freshly exposed slots to nil -- reference Lua's
// `luaD_reallocstack`. On failure we either raise `Err_Mem` through the active
// protected boundary (`raise == true`) or hand the status back for the caller to
// decide (`raise == false`), and the old stack is left untouched and usable
// either way.
//
// The reference version follows this with `correctstack`, rebasing `top`,
// `tbclist`, every open upvalue, and every frame's `func`/`top` pointers onto the
// moved array. We store all of those as indices, so there is nothing to rebase --
// the moved array is addressed exactly as the old one was. That deletion is the
// entire reason the kernel speaks in indices.
realloc_stack :: proc(L: ^Lua_State, newsize: int, raise: bool) -> Thread_Status {
	oldsize := L.stack_size
	oldbytes := uint(oldsize + EXTRA_STACK) * size_of(StackValue)
	newbytes := uint(newsize + EXTRA_STACK) * size_of(StackValue)

	// TODO(phase-7): set gcstopem to stop an emergency GC firing mid-realloc.
	newblock := state_realloc(L, L.stack, oldbytes, newbytes)
	if newblock == nil {
		if raise {
			return throw(L, .Err_Mem)
		}
		return .Err_Mem
	}
	L.stack = ([^]StackValue)(newblock)
	L.stack_size = newsize
	// Erase the newly grown tail so nothing downstream scans stale bytes.
	// When shrinking, the loop range is empty and this does nothing.
	for i in (oldsize + EXTRA_STACK) ..< (newsize + EXTRA_STACK) {
		set_nil(&L.stack[i].val)
	}
	return .Ok
}

// Grow the stack by at least `n` slots -- reference Lua's `luaD_growstack`. The
// growth policy is faithful: prefer 1.5x, but never below what's actually needed
// and never above `MAXSTACK`. If the request itself can't fit, we grow to the
// error-reserve size and report "stack overflow" (a Phase-5 error *message*, once
// interned strings exist -- for now we surface the right status).
grow_stack :: proc(L: ^Lua_State, n: int, raise: bool) -> Thread_Status {
	size := L.stack_size
	if size > MAXSTACK {
		// The stack is already in its error-reserve regime, i.e. we are
		// handling a stack overflow and cannot grow any further.
		if raise {
			// TODO(phase-5): luaD_errerr -- "error in error handling".
			return throw(L, .Err_Err)
		}
		return .Err_Err
	}
	if n < MAXSTACK { // guard against arithmetic overflow
		newsize := size + (size >> 1) // tentative 1.5x
		needed := L.top + n // slots the request truly demands
		if newsize > MAXSTACK {
			newsize = MAXSTACK
		}
		if newsize < needed {
			newsize = needed
		}
		if newsize <= MAXSTACK {
			return realloc_stack(L, newsize, raise)
		}
	}
	// True stack overflow: make room for the error, then report it. If even
	// that reserve allocation fails, propagate its status unchanged (reference
	// Lua's luaM_error does not return) rather than masking OOM as overflow.
	status := realloc_stack(L, ERRORSTACKSIZE, raise)
	if status != .Ok {
		return status
	}
	if raise {
		// TODO(phase-5): luaG_runerror(L, "stack overflow").
		return throw(L, .Err_Run)
	}
	return .Err_Run
}

// Ensure the stack has room for `n` more slots, growing (and raising on failure)
// if not -- reference Lua's `luaD_checkstack`. `stack_size` is the usable ceiling
// (reference's `stack_last`), so `stack_size - top` is the current headroom.
check_stack :: proc(L: ^Lua_State, n: int) -> Thread_Status {
	if L.stack_size - L.top <= n {
		return grow_stack(L, n, true)
	}
	return .Ok
}

// Push one slot: bump `top`, then make sure the stack can still absorb another
// slot -- reference Lua's `luaD_inctop`. The bump-before-check is safe because
// `EXTRA_STACK` always leaves a slot of slack.
inc_top :: proc(L: ^Lua_State) -> Thread_Status {
	L.top += 1
	return check_stack(L, 1)
}

// Compute how many stack slots are actually in use: the furthest of `top` and
// every live frame's `top`, floored at `LUA_MINSTACK` -- reference Lua's
// `stackinuse`. Used by shrink logic (Phase 5) and honest in isolation now.
stack_in_use :: proc(L: ^Lua_State) -> int {
	lim := L.top
	for i in 0 ..< L.nci {
		if lim < L.frames[i].top {
			lim = L.frames[i].top
		}
	}
	res := lim + 1
	if res < LUA_MINSTACK {
		res = LUA_MINSTACK
	}
	return res
}
