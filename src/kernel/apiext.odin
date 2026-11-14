package kernel
// apiext.odin -- a small set of public-API and thread-control primitives that the
// standard library (Phase 9) needs but that had not yet been pulled in during the
// kernel phases. Grouping them here keeps the diff reviewable: none of these change
// existing behaviour, they only *add* reference-faithful entry points.
//
// Everything in this file mirrors a specific reference-Lua function:
//   * lua_warning / lua_setwarnf     -> lapi.c   (the warning subsystem)
//   * lua_upvalueid / lua_upvaluejoin-> lapi.c   (upvalue identity + sharing)
//   * luaE_resetthread / lua_closethread -> lstate.c / lapi.c (coroutine.close)
//
// The comments lean conversational on purpose: these touch subtle GC-barrier and
// stack-unwinding invariants, and a newcomer deserves to know *why* each step is
// there, not just that it is.

// --------------------------------------------------------------------------------
// Warnings
// --------------------------------------------------------------------------------

// Emit a warning through the currently installed warning handler -- reference
// `lua_warning`. `msg` is a NUL-terminated C string (Lua strings already carry a
// terminating NUL at `str_bytes(ts)[len]`, so the base library can hand its string
// arguments straight through without copying). `tocont` is true when this piece is
// a fragment of a larger message still to be continued; the handler uses it to
// decide whether to flush a newline. If no handler is installed the warning is
// silently dropped, exactly as reference Lua does when `g->warnf` is nil.
api_warning :: proc(L: ^State, msg: cstring, tocont: bool) {
	g := L.g
	if g.warnf != nil {
		g.warnf(g.ud_warn, msg, tocont ? 1 : 0)
	}
}

// Install a new warning handler and its opaque user-data pointer -- reference
// `lua_setwarnf`. Passing `nil` for `f` disables warnings.
api_setwarnf :: proc(L: ^State, f: Warn_Proc, ud: rawptr) {
	g := L.g
	g.ud_warn = ud
	g.warnf = f
}

// --------------------------------------------------------------------------------
// Upvalue identity and sharing
// --------------------------------------------------------------------------------

// Return the address of the n-th upvalue *slot* of the Lua closure at `fidx`,
// together with the closure itself -- reference Lua's `getupvalref`. The returned
// pointer is the address of the `^UpVal` entry inside the closure's `upvals`
// vector, so callers can both read the shared `UpVal*` and overwrite it (that is
// how `lua_upvaluejoin` makes two closures share one upvalue). Only valid for Lua
// closures; the caller must have already established that.
getupvalref :: proc(L: ^State, fidx: int, n: int) -> (slot: ^^UpVal, f: ^LClosure, ok: bool) {
	fi := index2value(L, fidx)
	// Callers are contractually required to pass a Lua closure here. We assert on
	// the tag rather than silently misbehaving, matching reference `api_check`.
	assert(type_tag(fi) == VLCL, "api_upvaluejoin/upvalueid on a non-" + BRAND + " closure")
	cl := api_closure_value(fi)
	// Reference `getupvalref` does NOT assert on an out-of-range index: it returns
	// a pointer to a static NULL upvalue so callers can detect the miss. We mirror
	// that with an `ok` flag (nil slot when false); `debug.upvalueid(f, 99)` must
	// yield nil rather than crash.
	if 1 <= n && n <= int(cl.p.sizeupvalues) {
		return &cl.upvals[n - 1], cl, true
	}
	return nil, cl, false
}

// Return a unique identity for the n-th upvalue of the function at `fidx` --
// reference `lua_upvalueid`. Two closures that *share* an upvalue return the same
// identity here; that is exactly what `debug.upvalueid` exposes to Lua code.
//   * Lua closure: the shared `UpVal*` object (its address is the identity).
//   * C closure:   the address of the boxed `TValue` (C upvalues are never shared).
//   * light C fn:  nil -- light functions carry no upvalues at all.
api_upvalueid :: proc(L: ^State, fidx: int, n: int) -> rawptr {
	fi := index2value(L, fidx)
	switch type_tag(fi) {
	case VLCL:
		slot, _, ok := getupvalref(L, fidx, n)
		if !ok {
			return nil // out-of-range index -> no identity (reference returns NULL)
		}
		return rawptr(slot^) // the UpVal* itself is the identity
	case VCCL:
		f := c_closure_value(fi)
		if 1 <= n && n <= int(f.nupvalues) {
			return rawptr(&f.upvalue[n - 1])
		}
		return nil // out-of-range -> no identity (reference falls through to NULL)
	case VLCF:
		return nil // light C functions have no upvalues
	case:
		assert(false, "api_upvalueid on a non-function value")
		return nil
	}
}

// Make the n1-th upvalue of the closure at `fidx1` refer to the same `UpVal` as the
// n2-th upvalue of the closure at `fidx2` -- reference `lua_upvaluejoin`. Both must
// be Lua closures. After the join, mutating one closure's upvalue is observable
// through the other. We fire a forward barrier because `f1` now points at an object
// (`*up1`) it did not reference before, and the GC must not lose track of it.
api_upvaluejoin :: proc(L: ^State, fidx1: int, n1: int, fidx2: int, n2: int) {
	up1, f1, ok1 := getupvalref(L, fidx1, n1)
	up2, _, ok2 := getupvalref(L, fidx2, n2)
	// Reference `api_check`s that both indices resolved; the stdlib wrapper
	// (`db_upvaluejoin`) has already validated them, so this only guards against
	// a misbehaving direct C-API caller.
	assert(ok1 && ok2, "invalid upvalue index")
	up1^ = up2^
	gc_barrier(L, obj2gco(f1), obj2gco(up1^))
}

// --------------------------------------------------------------------------------
// Thread reset / close (coroutine.close, lua_closethread)
// --------------------------------------------------------------------------------

// Reset a thread to a clean, just-created state, running any pending to-be-closed
// variables through their `__close` handlers -- reference `luaE_resetthread`.
//
// This is the machinery behind `coroutine.close` and behind recovering a thread
// after an error. The sequence is delicate and mirrors reference Lua exactly:
//   1. resetCI: collapse the call chain back to the base (host) frame.
//   2. A yielded thread is treated as OK for the purpose of closing.
//   3. luaD_closeprotected walks the to-be-closed list, calling `__close` handlers
//      under protection; if one of them raises, its error becomes the new status.
//   4. On error we materialize the error object at stack slot 1; otherwise we
//      simply reset `top` to slot 1 (an empty, ready-to-use stack).
//   5. Shrink the value stack back down to the base frame's declared top, releasing
//      any growth the dead computation had forced.
state_resetthread :: proc(L: ^State, status_in: Thread_Status) -> Thread_Status {
	reset_ci(L) // collapse to the base frame; also clears L.status/errfunc

	status := status_in
	if status == .Yield {
		status = .Ok
	}
	// Close every to-be-closed variable above stack slot 1, under protection so a
	// throwing `__close` handler cannot escape past us.
	status = do_closeprotected(L, 1, status)
	if status != .Ok {
		// A close handler raised: park its error object at slot 1 for the caller.
		set_error_object(L, status, 1)
	} else {
		// Clean shutdown: leave an empty stack whose top is the first usable slot.
		L.top = 1
	}
	// Release stack growth: shrink back to the base frame's usable top. Passing
	// `raise = false` means a (near-impossible) shrink failure is swallowed rather
	// than thrown -- there is nothing sensible to do on the teardown path.
	realloc_stack(L, L.frames[L.ci].top, false)
	return status
}

// The reset itself must be protected: a __close handler can close this same
// thread, throwing directly to the outermost close boundary. Propagate ordinary
// reset errors through that boundary as well, leaving their object at slot 1.
@(private = "file")
resetthread_aux :: proc(L: ^State, ud: rawptr) -> Thread_Status {
	status := state_resetthread(L, (^Thread_Status)(ud)^)
	if status != .Ok {
		return throw(L, status)
	}
	return .Ok
}

// Close a thread, returning its final status -- reference `lua_closethread`.
// `from` is the thread performing the close (used by reference Lua to restore the
// C-call counter); we thread the yieldable/C-call bookkeeping through `nCcalls`
// the same way the resume path does. The heavy lifting lives in `luaE_resetthread`.
api_closethread :: proc(L: ^State, from: ^State) -> Thread_Status {
	if from != nil {
		// Inherit the caller's C-call budget so the close handlers run with a sane
		// stack-depth guard (reference copies `getCcalls(from)`).
		L.n_ccalls = get_ccalls(from)
	} else {
		L.n_ccalls = 0
	}
	status := run_protected(L, resetthread_aux, &L.status)
	assert(L.top == (status == .Ok ? 1 : 2), "thread close stack invariant")
	if L == from { // closing itself: unwind the whole thread, do not return
		throw_baselevel(L, status)
	}
	return status
}
