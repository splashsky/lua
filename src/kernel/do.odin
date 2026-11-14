package kernel
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
// This file owns frame push and pop, the protected call, error propagation to the
// nearest boundary, and coroutine resume and yield.
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
MINSTACK :: 20

// Extra slots reserved past `stack_last` so a handful of operations (pushing an
// error object, a metamethod's arguments) can proceed without a growth check
// (lstate.h's `EXTRA_STACK`).
EXTRA_STACK :: 5

// A fresh thread's usable stack size: two minimum working areas (lstate.h's
// `BASIC_STACK_SIZE`).
BASIC_STACK_SIZE :: 2 * MINSTACK

// The hard ceiling on stack size. Reference Lua takes the smaller of a fixed
// cap and whatever `size_t` can address; on our 64-bit target the fixed cap
// (`LUAI_MAXSTACK`, 1,000,000 -- it fits under INT_MAX/2) always wins, but we
// compute the minimum honestly so a hypothetical tiny-pointer platform stays
// correct (ldo.c's `MAXSTACK`).
MAXSTACK_LIMIT :: 1_000_000
STACKERRSPACE :: 200
MAXSTACK_BYSIZET :: int(MAX_SIZET / uint(size_of(StackValue)) - uint(STACKERRSPACE))
MAXSTACK :: min(MAXSTACK_LIMIT, MAXSTACK_BYSIZET)

// The size the stack is blown up to while *handling* a stack-overflow error, so
// there's room to build and report the error (ldo.c's `ERRORSTACKSIZE`).
ERRORSTACKSIZE :: MAXSTACK + STACKERRSPACE

// The nested non-yieldable-call ceiling that guards against runaway C recursion
// (ldo.h's `LUAI_MAXCCALLS`).
MAXCCALLS :: 200

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
realloc_stack :: proc(L: ^State, newsize: int, raise: bool) -> Thread_Status {
	oldsize := L.stack_size
	oldbytes := uint(oldsize + EXTRA_STACK) * size_of(StackValue)
	newbytes := uint(newsize + EXTRA_STACK) * size_of(StackValue)

	// Stop emergency collection for the duration of the reallocation: an
	// emergency GC triggered mid-realloc would traverse a stack that is, for a
	// moment, in an inconsistent state. Reference Lua's `luaD_reallocstack`
	// brackets the allocation the same way. (Indices, not pointers, mean we still
	// need no `correctstack` afterward.)
	oldgcstop := L.g.gcstopem
	L.g.gcstopem = 1
	newblock := state_realloc(L, L.stack, oldbytes, newbytes)
	L.g.gcstopem = oldgcstop
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

// Raise the "error in error handling" error -- reference Lua's `luaD_errerr`.
// Reached when the stack overflows *while already* unwinding an error (so the
// overflow handler itself has no room left). We push the fixed message as the
// error object -- EXTRA_STACK guarantees the one slot -- and throw `LUA_ERRERR`.
do_errerr :: proc(L: ^State) -> Thread_Status {
	msg := string_new(L, "error in error handling")
	set_string(&L.stack[L.top].val, msg)
	L.top += 1 // assume EXTRA_STACK
	return throw(L, .Err_Err)
}

// Grow the stack by at least `n` slots -- reference Lua's `luaD_growstack`. The
// growth policy is faithful: prefer 1.5x, but never below what's actually needed
// and never above `MAXSTACK`. If the request itself can't fit, we grow to the
// error-reserve size and report "stack overflow".
grow_stack :: proc(L: ^State, n: int, raise: bool) -> Thread_Status {
	size := L.stack_size
	if size > MAXSTACK {
		// The stack is already in its error-reserve regime, i.e. we are
		// handling a stack overflow and cannot grow any further.
		if raise {
			return do_errerr(L) // "error in error handling"
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
		debug_runerror(L, "stack overflow") // raises LUA_ERRRUN, never returns
	}
	return .Err_Run
}

// Ensure the stack has room for `n` more slots, growing (and raising on failure)
// if not -- reference Lua's `luaD_checkstack`. `stack_size` is the usable ceiling
// (reference's `stack_last`), so `stack_size - top` is the current headroom.
check_stack :: proc(L: ^State, n: int) -> Thread_Status {
	if L.stack_size - L.top <= n {
		return grow_stack(L, n, true)
	}
	return .Ok
}

// Push one slot: bump `top`, then make sure the stack can still absorb another
// slot -- reference Lua's `luaD_inctop`. The bump-before-check is safe because
// `EXTRA_STACK` always leaves a slot of slack.
inc_top :: proc(L: ^State) -> Thread_Status {
	L.top += 1
	return check_stack(L, 1)
}

// Compute how many stack slots are actually in use: the furthest of `top` and
// every live frame's `top`, floored at `LUA_MINSTACK` -- reference Lua's
// `stackinuse`. Used by shrink logic (Phase 5) and honest in isolation now.
stack_in_use :: proc(L: ^State) -> int {
	lim := L.top
	for i in 0 ..< L.nci {
		if lim < L.frames[i].top {
			lim = L.frames[i].top
		}
	}
	res := lim + 1
	if res < MINSTACK {
		res = MINSTACK
	}
	return res
}

// ---------------------------------------------------------------------------
// C-stack overflow guard
// ---------------------------------------------------------------------------
// Every nested call through C (a metamethod, `pcall`, a coroutine resume, the VM
// re-entering itself) bumps `n_ccalls`. If that count runs away -- e.g. infinite
// recursion with no Lua-stack growth to catch it -- we would blow the *native*
// stack. Reference Lua's `luaE_checkcstack` draws the line at LUAI_MAXCCALLS, and
// once we are already handling that overflow (about 110% of the limit) it escalates
// to an "error in error handling" throw so we don't recurse forever building the
// message.
state_checkcstack :: proc(L: ^State) {
	if get_ccalls(L) == MAXCCALLS {
		debug_runerror(L, "C stack overflow")
	} else if get_ccalls(L) >= (MAXCCALLS / 10 * 11) {
		throw(L, .Err_Err)
	}
}

// A raising stack check that discards the status -- our analogue of reference
// Lua's `checkstackp`/`checkstackGCp` (minus the GC step, which arrives in Phase 7).
// Because our slots are index-addressed, there is no `func` pointer to correct
// after a growth, so this is simply `check_stack` with the error left to `throw`.
check_stack_p :: #force_inline proc(L: ^State, n: int) {
	// Like check_stack, including its strict headroom test. Keep the common
	// check at the call site and the allocating/error path out of line.
	if L.stack_size - L.top <= n {
		#force_no_inline grow_stack(L, n, true)
	}
}

// ---------------------------------------------------------------------------
// Debug hooks
// ---------------------------------------------------------------------------

// Fire the installed hook for `event` -- reference Lua's `luaD_hook`. Guarded so
// it is a no-op unless a hook is actually installed and hooks are currently
// allowed (they cannot fire inside another hook). We widen the visible stack to the
// whole activation register, ensure minimum working space, run the callback, then
// restore `top`/`ci.top` exactly. `line`/`ftransfer`/`ntransfer` describe the event
// for the line and call/return hooks.
do_hook :: proc(L: ^State, event: i32, line: int, ftransfer: int, ntransfer: int) {
	hook := L.hook
	if hook == nil || L.allowhook == 0 {
		return
	}
	ci := &L.frames[L.ci]
	saved_top := L.top // preserve original tops (index model: values, not pointers)
	saved_ci_top := ci.top
	ar: Debug_Info
	ar.event = event
	ar.currentline = i32(line)
	ar.i_ci = L.ci
	L.transfer_first = ftransfer
	L.transfer_n = ntransfer
	if is_lua_frame(ci) && L.top < ci.top {
		L.top = ci.top // protect the entire activation register
	}
	check_stack(L, MINSTACK)
	ci = &L.frames[L.ci]
	if ci.top < L.top + MINSTACK {
		ci.top = L.top + MINSTACK
	}
	L.allowhook = 0 // cannot call hooks inside a hook
	ci.callstatus |= CIST_HOOKED
	hook(L, &ar)
	L.allowhook = 1
	ci = &L.frames[L.ci]
	ci.top = saved_ci_top
	L.top = saved_top
	ci.callstatus &~= CIST_HOOKED
}

// The call hook for entering a Lua function -- reference Lua's `luaD_hookcall`.
// Also resets `oldpc` so the line hook restarts cleanly for the new function.
do_hookcall :: proc(L: ^State, ci_idx: int) {
	L.oldpc = 0
	if (L.hookmask & MASKCALL) != 0 {
		ci := &L.frames[ci_idx]
		event: i32 = HOOKCALL
		if (ci.callstatus & CIST_TAIL) != 0 {
			event = HOOKTAILCALL
		}
		p := ci_func(L, ci).p
		ci.u.l.savedpc += 1 // hooks assume pc is already incremented
		do_hook(L, event, -1, 1, int(p.numparams))
		ci = &L.frames[ci_idx]
		ci.u.l.savedpc -= 1 // put it back
	}
}

// The return hook for Lua and C functions; also maintains `oldpc` for the line
// hook -- reference Lua's static `rethook`. `nres` results sit at the top of the
// stack. For a vararg Lua function the frame's `func` was moved *past* the hidden
// varargs when the frame was set up; here we shift it up by `delta` to the
// "virtual" func (the position transfer offsets are measured from) while the hook
// runs, then restore it -- exactly mirroring reference's `+= delta` / `-= delta`.
// Getting this sign right matters: a Lua return hook can call debug.getlocal on
// the returning frame, and that reads locals relative to `func`, so a wrong shift
// points `func` at a non-closure slot and crashes.
rethook :: proc(L: ^State, ci_idx: int, nres: int) {
	ci := &L.frames[ci_idx]
	if (L.hookmask & MASKRET) != 0 {
		firstres := L.top - nres
		delta := 0
		if is_lua_frame(ci) {
			p := ci_func(L, ci).p
			if (p.flag & PF_VAHID) != 0 {
				delta = ci.u.l.nextraargs + int(p.numparams) + 1
			}
		}
		ci.func += delta
		ftransfer := firstres - ci.func
		do_hook(L, HOOKRET, -1, ftransfer, nres)
		ci = &L.frames[ci_idx]
		ci.func -= delta
	}
	// Set 'oldpc' from the caller frame, if it is a Lua frame.
	if ci_idx > 0 {
		prev := &L.frames[ci_idx - 1]
		if is_lua_frame(prev) {
			L.oldpc = prev.u.l.savedpc - 1
		}
	}
}

// ---------------------------------------------------------------------------
// The call protocol: precall / poscall / result movement
// ---------------------------------------------------------------------------

// Handle a call to a non-function object by looking for a `__call` metamethod --
// reference Lua's `tryfuncTM`. On success the metamethod is inserted *below* the
// original object (which becomes its first argument), so the ordinary call path
// can proceed with the metamethod as the callable. The CIST_CCMT bits count how
// many `__call` metamethods have been chained (and thus how many extra arguments
// were pushed); an overflow means a pathological `__call` chain.
tryfuncTM :: proc(L: ^State, func: int, status: u32) -> u32 {
	tm := tm_gettmbyobj(L, stack_value(L, func), TM_CALL)
	if is_nil(tm) {
		debug_callerror(L, stack_value(L, func))
	}
	// Open a slot at `func` by shifting everything above it up by one.
	p := L.top
	for p > func {
		set_obj(stack_value(L, p), stack_value(L, p - 1))
		p -= 1
	}
	L.top += 1 // the caller pre-reserved this slot
	set_obj(stack_value(L, func), tm) // metamethod becomes the callee
	if (status & MAX_CCMT) == MAX_CCMT {
		debug_runerror(L, "'__call' chain too long")
	}
	return status + (u32(1) << CIST_CCMT)
}

// Move `nres` freshly-produced results down to `res`, padding or trimming to
// exactly `wanted` -- reference Lua's `genmoveresults`.
genmoveresults :: proc(L: ^State, res: int, nres: int, wanted: int) {
	firstresult := L.top - nres
	n := nres
	if n > wanted {
		n = wanted // caller doesn't want the extras
	}
	i := 0
	for ; i < n; i += 1 {
		set_obj(stack_value(L, res + i), stack_value(L, firstresult + i))
	}
	for ; i < wanted; i += 1 {
		set_nil(stack_value(L, res + i)) // pad missing results with nil
	}
	L.top = res + wanted
}

// Move a call's results into place, keyed on the encoded "wanted" field --
// reference Lua's `moveresults`. `fwanted` is `ci.callstatus` masked to the
// result-count field plus the CIST_TBC flag; the common shapes (no results, one
// result, all results) are special-cased, and anything with to-be-closed variables
// or a fixed count >= 2 falls to the general path.
moveresults :: #force_inline proc(L: ^State, res: int, nres: int, fwanted: u32) {
	switch fwanted {
	case 0 + 1: // no values needed (a statement call)
		L.top = res
		return
	case 1 + 1: // exactly one value needed (an expression)
		if nres == 0 {
			set_nil(stack_value(L, res))
		} else {
			set_obj(stack_value(L, res), stack_value(L, L.top - nres))
		}
		L.top = res + 1
		return
	case:
		moveresults_other(L, res, nres, fwanted)
	}
}

// Keep uncommon result counts and the potentially yielding close path out of the
// caller. No stack or frame pointer is kept across this call.
moveresults_other :: #force_no_inline proc(L: ^State, res: int, nres: int, fwanted: u32) {
	switch fwanted {
	case u32(MULTRET + 1): // caller wants every result (encoded as 0)
		genmoveresults(L, res, nres, nres)
	case: // two-or-more fixed results, and/or to-be-closed variables
		wanted := get_nresults(fwanted)
		r := res
		if (fwanted & CIST_TBC) != 0 {
			// Results movement must run after closing to-be-closed variables,
			// because a __close can yield/err.
			ci := &L.frames[L.ci]
			ci.u2 = nres
			ci.callstatus |= CIST_CLSRET
			r = func_close(L, r, CLOSEKTOP, true)
			// Re-derive the frame pointer rather than reusing the one above.
			// `luaF_close` runs arbitrary `__close` handlers, and a handler that
			// calls deep enough grows the frame array, which reallocates
			// `L.frames` and leaves any pointer taken before the call dangling.
			// Reference Lua holds its `ci` across this safely only because its
			// CallInfo nodes are individually allocated and linked, so they never
			// move; our contiguous array does move. `luaD_poscall` just below
			// already re-derives after `rethook` for exactly this reason, and this
			// was the one place in the call path that did not.
			ci = &L.frames[L.ci]
			ci.callstatus &~= CIST_CLSRET
			if L.hookmask != 0 {
				rethook(L, L.ci, nres)
			}
			if wanted == MULTRET {
				wanted = nres
			}
		}
		genmoveresults(L, r, nres, wanted)
	}
}

// Finish a call: fire the return hook if needed, move results into place, and pop
// back to the caller frame -- reference Lua's `luaD_poscall`.
do_poscall :: #force_inline proc(L: ^State, ci_idx: int, nres: int) {
	ci := &L.frames[ci_idx]
	fwanted := ci.callstatus & (CIST_TBC | CIST_NRESULTS)
	if L.hookmask != 0 && (fwanted & CIST_TBC) == 0 {
		rethook(L, ci_idx, nres)
		ci = &L.frames[ci_idx]
	}
	moveresults(L, ci.func, nres, fwanted)
	L.ci = ci_idx - 1 // back to the caller (frames are a stack; caller is one below)
	L.nci = ci_idx
}

// Allocate and initialize the next call frame -- reference Lua's `prepCallInfo`.
// Returns the new frame's index. Only the result-count, CIST_C, and CCMT bits are
// valid in `status` at this point.
prepCallInfo :: #force_inline proc(L: ^State, func: int, status: u32, top: int) -> int {
	idx := next_ci(L) // grows the frame array if needed; sets L.ci
	ci := &L.frames[idx]
	ci.func = func
	ci.callstatus = status
	ci.top = top
	ci.u2 = 0
	return idx
}

// precall for a C function (closure or light) -- reference Lua's `precallC`.
// C functions run to completion right here: we build their frame, optionally fire
// the call hook, invoke the native function, then post-process its results. Returns
// the number of results. NOTE the re-entrancy hazard: `f(L)` can trigger arbitrary
// nested calls and frame-array growth, so we hold the frame by *index* and
// re-derive the pointer for `poscall`.
precallC :: #force_inline proc(L: ^State, func: int, status: u32, f: C_Function) -> int {
	check_stack_p(L, MINSTACK)
	ci_idx := prepCallInfo(L, func, status | CIST_C, L.top + MINSTACK)
	if (L.hookmask & MASKCALL) != 0 {
		narg := L.top - func - 1
		do_hook(L, HOOKCALL, -1, 1, narg)
	}
	n := int(f(L)) // the actual C call; may re-enter the runtime
	do_poscall(L, ci_idx, n)
	return n
}

// Prepare a tail call, reusing the current frame `ci_idx` -- reference Lua's
// `luaD_pretailcall`. `narg1` counts the arguments plus the function itself;
// `delta` is how far the current frame's `func` was shifted past hidden varargs
// (so we can restore it before overwriting the frame). Returns the result count for
// a C callee, or -1 for a Lua callee (which the VM then continues executing in
// place).
do_pretailcall :: proc(L: ^State, ci_idx: int, func_in: int, narg1_in: int, delta: int) -> int {
	func := func_in
	narg1 := narg1_in
	status := u32(MULTRET + 1)
	for {
		switch type_tag(stack_value(L, func)) {
		case VCCL:
			cl := (^CClosure)(stack_value(L, func).value_.gc)
			return precallC(L, func, status, cl.f)
		case VLCF:
			return precallC(L, func, status, stack_value(L, func).value_.f)
		case VLCL:
			ci := &L.frames[ci_idx]
			p := (^LClosure)(stack_value(L, func).value_.gc).p
			fsize := int(p.maxstacksize)
			nfixparams := int(p.numparams)
			check_stack_p(L, fsize - delta)
			ci = &L.frames[ci_idx]
			ci.func -= delta // restore the real frame base (if vararg)
			for i in 0 ..< narg1 { // slide function + args down over the old frame
				set_obj(stack_value(L, ci.func + i), stack_value(L, func + i))
			}
			func = ci.func
			for narg1 <= nfixparams { // nil-fill any missing fixed parameters
				set_nil(stack_value(L, func + narg1))
				narg1 += 1
			}
			ci.top = func + 1 + fsize
			ci.u.l.savedpc = 0 // start at the callee's first instruction
			ci.u.l.nextraargs = 0
			ci.u.l.trap = 0
			ci.callstatus |= CIST_TAIL
			L.top = func + narg1
			return -1
		case:
			check_stack_p(L, 1) // room for the __call metamethod
			status = tryfuncTM(L, func, status)
			narg1 += 1
			// loop and retry with the metamethod as the callee
		}
	}
}

// Prepare a call to a function (C or Lua) -- reference Lua's `luaD_precall`. For a
// C function it also *performs* the call and returns -1 (no Lua frame to run). For
// a Lua function it builds the frame and returns its index for the VM to execute.
// A non-function object is retried through its `__call` metamethod.
do_precall :: proc(L: ^State, func_in: int, nresults: int) -> int {
	func := func_in
	status := u32(nresults + 1)
	for {
		switch type_tag(stack_value(L, func)) {
		case VCCL:
			cl := (^CClosure)(stack_value(L, func).value_.gc)
			precallC(L, func, status, cl.f)
			return -1
		case VLCF:
			precallC(L, func, status, stack_value(L, func).value_.f)
			return -1
		case VLCL:
			p := (^LClosure)(stack_value(L, func).value_.gc).p
			narg := L.top - func - 1
			nfixparams := int(p.numparams)
			fsize := int(p.maxstacksize)
			check_stack_p(L, fsize)
			ci_idx := prepCallInfo(L, func, status, func + 1 + fsize)
			ci := &L.frames[ci_idx]
			ci.u.l.savedpc = 0 // starting instruction
			ci.u.l.nextraargs = 0
			ci.u.l.trap = 0
			for narg < nfixparams { // nil-fill missing fixed parameters
				set_nil(stack_value(L, L.top))
				L.top += 1
				narg += 1
			}
			return ci_idx
		case:
			check_stack_p(L, 1)
			status = tryfuncTM(L, func, status)
			// loop and retry with the metamethod as the callee
		}
	}
}

// Call a function through C -- reference Lua's static `ccall`. `inc` bumps the
// C-call counters (1 for an ordinary call, `nyci` when yields are disallowed).
// If the callee is a Lua function, we mark its frame FRESH and hand it to the VM;
// the FRESH bit tells `luaV_execute` to return here (rather than continue an outer
// Lua frame) when this call returns.
ccall :: proc(L: ^State, func: int, nResults: int, inc: u32) {
	L.n_ccalls += inc
	if get_ccalls(L) >= MAXCCALLS {
		check_stack_p(L, 0) // release any EXTRA_STACK use before erroring
		state_checkcstack(L)
	}
	ci_idx := do_precall(L, func, nResults)
	if ci_idx >= 0 { // a Lua function: run it
		L.frames[ci_idx].callstatus |= CIST_FRESH
		vm_execute(L, ci_idx)
	}
	L.n_ccalls -= inc
}

// Call a function (C or Lua) -- reference Lua's `luaD_call`.
do_call :: proc(L: ^State, func: int, nResults: int) {
	ccall(L, func, nResults, 1)
}

// Like `luaD_call` but forbidding yields across the call -- reference Lua's
// `luaD_callnoyield`.
do_callnoyield :: proc(L: ^State, func: int, nResults: int) {
	ccall(L, func, nResults, nyci)
}

// ---------------------------------------------------------------------------
// Stack shrinking (post-error / post-yield housekeeping)
// ---------------------------------------------------------------------------

// After an error or a completed protected call, the stack may have ballooned --
// e.g. it was blown up to `ERRORSTACKSIZE` to report an overflow. Reference Lua's
// `luaD_shrinkstack` reclaims that: if the stack is more than 3x the live usage
// (and we are no longer handling an overflow), shrink it back to ~2x usage. A
// failed shrink is harmless, so we never raise here.
//
// Reference also shrinks the CallInfo list here (`luaE_shrinkCI`). Our frames are
// a single growable array addressed by index, so there is nothing analogous to
// free -- the spare capacity is reused by the next call, not leaked.
shrink_stack :: proc(L: ^State) {
	inuse := stack_in_use(L)
	max := inuse > MAXSTACK / 3 ? MAXSTACK : inuse * 3
	if inuse <= MAXSTACK && L.stack_size > max {
		nsize := inuse > MAXSTACK / 2 ? MAXSTACK : inuse * 2
		realloc_stack(L, nsize, false) // ok if it fails
	}
}

// ---------------------------------------------------------------------------
// Protected calls (the plumbing behind `pcall` / loading / finalizers)
// ---------------------------------------------------------------------------

// Adjust the current frame's `top` so it covers everything pushed so far when the
// caller asked for `LUA_MULTRET` -- reference Lua's `adjustresults` macro. Only the
// multret shape needs this widening; fixed-count calls already know their extent.
adjust_results :: #force_inline proc(L: ^State, nres: int) {
	if nres <= MULTRET && L.frames[L.ci].top < L.top {
		L.frames[L.ci].top = L.top
	}
}

// Close any to-be-closed variables at or above `level` under a protected boundary,
// looping until no fresh error surfaces -- reference Lua's `luaD_closeprotected`.
// A `__close` handler can itself raise; each time it does we restore the saved
// frame/hook state and try again from where we left off (each pass has at least one
// fewer variable to close), returning the final error status (or the original one
// if everything closed cleanly).
do_closeprotected :: proc(L: ^State, level: int, status_in: Thread_Status) -> Thread_Status {
	old_ci := L.ci
	old_allowhooks := L.allowhook
	status := status_in
	for {
		// Bundle the arguments for the protected close in a small struct so we can
		// pass them through the opaque `ud` pointer that `run_protected` expects.
		Close_Args :: struct {
			level:  int,
			status: Thread_Status,
		}
		args := Close_Args{level, status}
		st := run_protected(L, proc(L: ^State, ud: rawptr) -> Thread_Status {
			a := (^Close_Args)(ud)
			func_close(L, a.level, int(a.status), false)
			return .Ok
		}, &args)
		if st == .Ok {
			return args.status // no more errors: report the status we came in with
		}
		// A close raised: undo the partial unwind and go around again.
		status = st
		L.ci = old_ci
		L.allowhook = old_allowhooks
	}
}

// The argument bundle for `luaD_pcall` -- the protected procedure plus its own
// opaque payload, so a single `run_protected` call can forward both.
PCall_Args :: struct {
	func: Protected_Proc,
	ud:   rawptr,
}

// Run `func` in fully protected mode, restoring thread bookkeeping on error --
// reference Lua's `luaD_pcall`. On the error path we rewind `ci`/`allowhook`, close
// any pending to-be-closed variables (which may change the status), install the
// error object at `old_top`, and shrink the stack back down. `ef` is the message
// handler index to use while `func` runs; it is restored afterward.
do_pcall :: proc(L: ^State, func: Protected_Proc, ud: rawptr, old_top: int, ef: int) -> Thread_Status {
	old_ci := L.ci
	old_allowhooks := L.allowhook
	old_errfunc := L.errfunc
	L.errfunc = ef
	args := PCall_Args{func, ud}
	status := run_protected(L, proc(L: ^State, ud: rawptr) -> Thread_Status {
		a := (^PCall_Args)(ud)
		return a.func(L, a.ud)
	}, &args)
	if status != .Ok { // an error escaped `func`
		L.ci = old_ci
		L.allowhook = old_allowhooks
		status = do_closeprotected(L, old_top, status)
		set_error_object(L, status, old_top)
		shrink_stack(L) // reclaim any overflow-handling reserve
	}
	L.errfunc = old_errfunc
	return status
}

// ---------------------------------------------------------------------------
// Protected parsing (compile a chunk under a protected boundary)
// ---------------------------------------------------------------------------
//
// `lua_load` turns a stream of source (or precompiled bytecode) into a callable
// closure. Parsing can raise -- a syntax error, a mode mismatch, or an OOM -- so it
// runs inside `luaD_pcall`. Crucially, the parser's scratch buffers (`Mbuffer` and
// the `Dyndata` arrays) are *not* GC-managed, so they must be freed on BOTH the
// success and error paths; a naive `run_protected` wrapper would leak them when a
// syntax error longjmps out. This mirrors reference Lua's `luaD_protectedparser`
// exactly, including forbidding yields for the duration.

// Does `mode` contain byte `ch`? Reference Lua uses `strchr`; our mode is a short
// Odin string, so a linear scan is faithful and clear.
@(private = "file")
mode_has :: proc(mode: string, ch: u8) -> bool {
	for i in 0 ..< len(mode) {
		if mode[i] == ch {
			return true
		}
	}
	return false
}

// Raise a syntax error when the chunk's kind is not permitted by `mode` -- reference
// Lua's `checkmode`. The message is left as the error object at the top of the stack
// and we longjmp with `Err_Syntax`.
@(private = "file")
checkmode :: proc(L: ^State, mode: string, x: string) {
	if !mode_has(mode, x[0]) {
		object_pushfstring(L, "attempt to load a %s chunk (mode is '%s')", x, mode)
		throw(L, .Err_Syntax)
	}
}

// The carrier passed through `luaD_pcall` to `f_parser` -- reference Lua's
// `struct SParser`. It owns the parser's non-GC scratch structures so they can be
// freed after the protected call regardless of how it ended.
@(private = "file")
SParser :: struct {
	z:    ^Zio,
	buff: Mbuffer,
	dyd:  Dyndata,
	name: string,
	mode: string,
}

// The protected body: peek the first byte to decide binary vs. text, enforce the
// mode, run the undumper or the parser, then wire up the closure's upvalues --
// reference Lua's `f_parser`.
@(private = "file")
f_parser :: proc(L: ^State, ud: rawptr) -> Thread_Status {
	p := (^SParser)(ud)
	mode := p.mode if p.mode != "" else "bt"
	c := zio_getc(p.z) // read the first character
	cl: ^LClosure
	if c == int(SIGNATURE[0]) {
		// A precompiled (binary) chunk. `B` mode loads it "fixed" (pinned strings)
		// and skips the plain binary-permission check; otherwise `b` is required.
		fixed := false
		if mode_has(mode, 'B') {
			fixed = true
		} else {
			checkmode(L, mode, "binary")
		}
		cl = undump_chunk(L, p.z, p.name, fixed)
	} else {
		checkmode(L, mode, "text")
		cl = parse_parser(L, p.z, &p.buff, &p.dyd, p.name, c)
	}
	func_initupvals(L, cl)
	return .Ok
}

// Compile the chunk read through `z` under full protection, freeing the parser's
// scratch memory on every exit path -- reference Lua's `luaD_protectedparser`. On
// success the new closure sits on top of the stack; on failure the error object
// does. Yields are forbidden while parsing (`incnny`/`decnny`).
do_protectedparser :: proc(L: ^State, z: ^Zio, name: string, mode: string) -> Thread_Status {
	p: SParser
	incnny(L) // parsing cannot yield
	p.z = z
	p.name = name
	p.mode = mode
	p.dyd = {}
	mbuffer_init(&p.buff)
	status := do_pcall(L, f_parser, &p, L.top, L.errfunc)
	mbuffer_free(L, &p.buff)
	// Free the three dynamic parser arrays. `state_free` already ignores a nil
	// block, and an array that never grew has both a nil pointer and a zero size,
	// so no guard is needed here -- reference calls `luaM_freearray` unconditionally
	// for the same reason.
	state_free(L, p.dyd.actvar.arr, uint(p.dyd.actvar.size) * size_of(Vardesc))
	state_free(L, p.dyd.gt.arr, uint(p.dyd.gt.size) * size_of(Labeldesc))
	state_free(L, p.dyd.label.arr, uint(p.dyd.label.size) * size_of(Labeldesc))
	decnny(L)
	return status
}

// ---------------------------------------------------------------------------
// Coroutine resume / yield
// ---------------------------------------------------------------------------
//
// Reference Lua switches coroutine stacks with `longjmp`, which cannot resume a
// stack it already unwound. Our explicit heap frame-stack + trampoline is exactly
// what makes cooperative resume possible: a yielding coroutine leaves its frames
// in place and `lua_resume` walks back into them (see docs/ARCHITECTURE.md,
// Decision 2). The pieces below mirror ldo.c's `resume`/`unroll`/`precover`/
// `lua_resume`/`lua_yieldk` one-for-one, translated to the index model.

// Finish a `lua_pcallk` that a yield (or an error inside it) interrupted --
// reference Lua's `finishpcallk`. It recovers the original status stashed in the
// frame's recover-status field: `Ok` means "was merely interrupted by a yield",
// anything else means a genuine error whose to-be-closed variables must now finish
// closing before the error object is installed.
finishpcallk :: proc(L: ^State, ci_idx: int) -> Thread_Status {
	status := get_cist_recst(&L.frames[ci_idx])
	if status == .Ok { // no error: the pcall was interrupted by a yield
		status = .Yield
	} else { // a real error: close pending TBC vars, then place the error object
		func := L.frames[ci_idx].u2 // saved funcidx
		L.allowhook = get_oah(&L.frames[ci_idx]) // restore allowhook
		func = func_close(L, func, int(status), true) // may yield or raise
		set_error_object(L, status, func)
		shrink_stack(L)
		set_cist_recst(&L.frames[ci_idx], .Ok) // clear the recorded status
	}
	L.frames[ci_idx].callstatus &= ~CIST_YPCALL
	L.errfunc = L.frames[ci_idx].u.c.old_errfunc
	return status
}

// Complete a C frame that a yield interrupted -- reference Lua's `finishCcall`.
// Two shapes: it was closing to-be-closed variables (just redo `luaD_poscall`), or
// it was inside `lua_callk`/`lua_pcallk` and must run its continuation function
// before finishing the enclosing `luaD_call`.
finishCcall :: proc(L: ^State, ci_idx: int) {
	n: int // actual number of results
	if (L.frames[ci_idx].callstatus & CIST_CLSRET) != 0 { // was closing TBC vars?
		n = L.frames[ci_idx].u2 // just redo the poscall with the saved count
	} else {
		status := Thread_Status.Yield // default when there were no errors
		if (L.frames[ci_idx].callstatus & CIST_YPCALL) != 0 { // inside a pcallk?
			status = finishpcallk(L, ci_idx)
		}
		adjust_results(L, MULTRET) // finish the callk
		kf := L.frames[ci_idx].u.c.k // the continuation
		ctx := L.frames[ci_idx].u.c.ctx
		n = int(kf(rawptr(L), i32(status), ctx)) // run it
	}
	do_poscall(L, ci_idx, n) // finish the do_call
}

// Run every remaining suspended frame of a resumed coroutine to completion (or
// until another yield long-jumps out) -- reference Lua's `unroll`. C frames get
// `finishCcall`; Lua frames get their interrupted instruction finished and then
// execute down to the next C boundary.
unroll :: proc(L: ^State, ud: rawptr) -> Thread_Status {
	for L.ci != 0 { // while there is something above the base frame
		ci_idx := L.ci
		if !is_lua_frame(&L.frames[ci_idx]) {
			finishCcall(L, ci_idx)
		} else {
			vm_finishOp(L) // finish the instruction the yield cut short
			vm_execute(L, ci_idx) // run to the next C boundary
		}
	}
	return .Ok
}

// Find the innermost suspended yieldable protected call (a recover point) --
// reference Lua's `findpcall`. Walks the frame stack from the current frame down to
// the base, returning that frame's index or -1 if there is no pending pcall.
findpcall :: proc(L: ^State) -> int {
	for i := L.ci; i >= 0; i -= 1 {
		if (L.frames[i].callstatus & CIST_YPCALL) != 0 {
			return i
		}
	}
	return -1
}

// Re-unroll a resumed coroutine while errors keep landing inside protected calls --
// reference Lua's `precover`. Each recoverable error drops us to its pcall frame,
// records the status for the pcall to report, and re-runs `unroll` under a fresh
// boundary. Stops at a clean end, a yield, or an error with no recover point.
precover :: proc(L: ^State, status_in: Thread_Status) -> Thread_Status {
	status := status_in
	for is_error_status(status) {
		ci := findpcall(L)
		if ci < 0 {
			break
		}
		L.ci = ci // drop to the recovery frame
		set_cist_recst(&L.frames[ci], status) // status for pcall to finish with
		status = run_protected(L, unroll, nil)
	}
	return status
}

// Signal an error in the *call to* `lua_resume` itself (bad/dead coroutine) rather
// than an error *inside* the coroutine -- reference Lua's `resume_error`. Such
// errors must not be caught by the coroutine's own error handling, so we simply
// leave a message string on the stack and report `Err_Run`.
resume_error :: proc(L: ^State, msg: string, narg: int) -> Thread_Status {
	L.top -= narg // discard the arguments
	set_string(stack_value(L, L.top), string_new(L, msg))
	L.top += 1
	return .Err_Run
}

// The protected body of `lua_resume` -- reference Lua's `resume`. Starts the
// coroutine's body (first resume) or continues it from where a previous yield left
// off, then unrolls any remaining frames. `ud` points at the argument count.
resume :: proc(L: ^State, ud: rawptr) -> Thread_Status {
	n := (^int)(ud)^ // number of arguments
	first_arg := L.top - n // first argument index
	ci_idx := L.ci
	if L.status == .Ok { // starting a coroutine?
		ccall(L, first_arg - 1, MULTRET, 0) // just call its body
	} else { // resuming from a previous yield
		L.status = .Ok // mark it running again
		if is_lua_frame(&L.frames[ci_idx]) { // yielded inside a hook?
			L.frames[ci_idx].u.l.savedpc -= 1 // the instruction wasn't run yet
			L.top = first_arg // discard arguments
			vm_execute(L, ci_idx) // continue running Lua code
		} else { // a "common" yield
			kf := L.frames[ci_idx].u.c.k
			if kf != nil { // does it have a continuation?
				ctx := L.frames[ci_idx].u.c.ctx
				n = int(kf(rawptr(L), i32(Thread_Status.Yield), ctx))
			}
			do_poscall(L, ci_idx, n) // finish the do_call
		}
		unroll(L, nil) // run continuation
	}
	return .Ok
}

// Resume (start or continue) coroutine `L`, whose arguments (and, on the first
// resume, the body function) are already on its stack -- reference Lua's
// `lua_resume`. `from` is the resuming thread (for C-call accounting). Returns the
// final status and, through the return tuple, how many results/yielded values sit
// on `L`'s stack.
api_resume :: proc(L: ^State, from: ^State, nargs_in: int) -> (status: Thread_Status, nresults: int) {
	nargs := nargs_in
	if L.status == .Ok { // may be starting a coroutine
		if L.ci != 0 { // not at the base level?
			return resume_error(L, "cannot resume non-suspended coroutine", nargs), 0
		} else if L.top - (L.frames[L.ci].func + 1) == nargs { // no body function?
			return resume_error(L, "cannot resume dead coroutine", nargs), 0
		}
	} else if L.status != .Yield { // ended with errors?
		return resume_error(L, "cannot resume dead coroutine", nargs), 0
	}
	L.n_ccalls = from != nil ? get_ccalls(from) : 0
	if get_ccalls(L) >= MAXCCALLS {
		return resume_error(L, "C stack overflow", nargs), 0
	}
	L.n_ccalls += 1
	status = run_protected(L, resume, &nargs)
	status = precover(L, status) // keep running through recoverable errors
	if is_error_status(status) { // an unrecoverable error
		L.status = status // mark the thread dead
		set_error_object(L, status, L.top)
		L.frames[L.ci].top = L.top
	}
	nresults = status == .Yield ? L.frames[L.ci].u2 : L.top - (L.frames[L.ci].func + 1)
	return status, nresults
}

// Suspend the running coroutine, handing `nresults` values back to whoever resumed
// it -- reference Lua's `lua_yieldk`. A continuation `k` (with context `ctx`) may be
// registered to run when the coroutine is next resumed. Yielding is illegal across a
// non-yieldable C boundary or from the main thread; both raise a runtime error.
api_yieldk :: proc(L: ^State, nresults: int, ctx: K_Context, k: K_Function) -> i32 {
	ci_idx := L.ci
	if !yieldable(L) {
		if L != &L.g.main_thread.l {
			debug_runerror(L, "attempt to yield across a C-call boundary")
		} else {
			debug_runerror(L, "attempt to yield from outside a coroutine")
		}
	}
	L.status = .Yield
	L.frames[ci_idx].u2 = nresults // save the number of yielded values
	if is_lua_frame(&L.frames[ci_idx]) { // inside a hook?
		// Hooks can't yield values or carry a continuation; the VM's hook path
		// (once wired) handles the resume. Nothing to throw -- return to luaD_hook.
	} else {
		L.frames[ci_idx].u.c.k = k
		if k != nil {
			L.frames[ci_idx].u.c.ctx = ctx
		}
		throw(L, .Yield) // long-jump out to the resuming boundary
	}
	return 0
}

// The common no-continuation yield -- reference Lua's `lua_yield`.
api_yield :: proc(L: ^State, nresults: int) -> i32 {
	return api_yieldk(L, nresults, K_Context(0), nil)
}
