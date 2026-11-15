package kernel

import "base:runtime"

// Keep these in a separate file: even excluded declarations in vm.odin can
// change the switch interpreter's code placement and its branch performance.
when VM_THREADED {
	// Non-string lengths can call Lua or raise errors and need the original
	// context. The handler has already saved the PC and top, as vm_execute does.
	vm_thread_lenslow :: #force_no_inline proc "contextless" (L: ^State, ra: int, rb: ^TValue, ctx: ^runtime.Context) {
		context = ctx^
		vm_objlen(L, ra, rb)
	}

	// Hits cannot run Lua, move a stack, or change the frame trap. The miss
	// receives the activation's original context, not the default context.
	vm_thread_tryget :: #force_inline proc "contextless" (t, key, out: ^TValue) -> bool {
		if base_type(t) != TTABLE {
			return false
		}
		h := (^Table)(t.value_.gc)
		tag := table_fastget(h, key, out)
		return !tag_is_empty(tag)
	}

	vm_thread_getslow :: #force_no_inline proc "contextless" (
		L: ^State, ci_idx, pc: int, t, key: ^TValue, ra: int, ctx: ^runtime.Context,
	) -> i32 {
		context = ctx^
		L.frames[ci_idx].u.l.savedpc = pc
		L.top = L.frames[ci_idx].top
		vm_finishget(L, t, key, ra)
		return L.frames[ci_idx].u.l.trap
	}

	// Primitive values do not need a backward GC barrier. A failed pre-set has
	// not changed the table; the original helper handles it and values that may
	// need a barrier.
	vm_thread_tryset :: #force_inline proc "contextless" (t, key, val: ^TValue) -> bool {
		if base_type(t) != TTABLE || is_collectable(val) || !is_integer(key) {
			return false
		}
		return table_fastseti((^Table)(t.value_.gc), int_value(key), val) == HOK
	}

	vm_thread_setslow :: #force_no_inline proc "contextless" (
		L: ^State, ci_idx, pc: int, t, key, val: ^TValue, ctx: ^runtime.Context,
	) -> i32 {
		// Short-string pre-set can finish without context for primitive values.
		// It already declines a new white key in a black table. If it cannot
		// finish, retain its result rather than doing the same pre-set twice.
		if base_type(t) == TTABLE && !is_collectable(val) && type_tag(key) == VSHRSTR {
			hres := table_psetshortstr((^Table)(t.value_.gc), str_value(key), val)
			if hres == HOK {
				return L.frames[ci_idx].u.l.trap
			}
			context = ctx^
			L.frames[ci_idx].u.l.savedpc = pc
			L.top = L.frames[ci_idx].top
			vm_finishset(L, t, key, val, hres)
			return L.frames[ci_idx].u.l.trap
		}
		// Integer keys need no key barrier. A collectable value is safe here
		// only when the ordinary back barrier would do nothing. No allocation
		// or re-entry occurs between this test and a completed pre-set.
		if base_type(t) == TTABLE && is_collectable(val) && is_integer(key) {
			h := (^Table)(t.value_.gc)
			if !is_black(obj2gco(h)) || !keepinvariant(L.g) {
				hres := table_fastseti(h, int_value(key), val)
				if hres == HOK {
					return L.frames[ci_idx].u.l.trap
				}
				context = ctx^
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				vm_finishset(L, t, key, val, hres)
				return L.frames[ci_idx].u.l.trap
			}
		}
		context = ctx^
		#force_inline vm_settable(L, ci_idx, pc, t, key, val)
		return L.frames[ci_idx].u.l.trap
	}

	// A string's __index may be a table. Only a hit in that table is handled
	// here; functions, chains, misses and errors use vm_finishget as before.
	vm_thread_tryself :: #force_inline proc "contextless" (L: ^State, t, key, out: ^TValue) -> bool {
		if base_type(t) == TTABLE {
			return vm_thread_tryget(t, key, out)
		}
		if is_string(t) {
			tm := tm_gettmbyobj(L, t, TM_INDEX)
			if base_type(tm) == TTABLE {
				return vm_thread_tryget(tm, key, out)
			}
		}
		return false
	}

	vm_thread_precall_slow :: #force_no_inline proc "contextless" (
		L: ^State, func, nresults: int, ctx: ^runtime.Context,
	) -> int {
		context = ctx^
		return do_precall(L, func, nresults)
	}

	vm_thread_precall_native :: #force_no_inline proc "contextless" (
		L: ^State, func, nresults: int, f: C_Function, ctx: ^runtime.Context,
	) -> int {
		context = ctx^
		precallC(L, func, u32(nresults + 1), f)
		return -1
	}

	vm_thread_poscall_slow :: #force_no_inline proc "contextless" (L: ^State, ci, n: int, ctx: ^runtime.Context) {
		context = ctx^
		do_poscall(L, ci, n)
	}

	// The native frame and the zero/one-result return are the same as
	// precallC/poscall. Hooks, growth, other result counts and to-be-closed
	// values use the original helpers. Re-resolve the frame after the callback:
	// it may have re-entered Lua and moved both the frame and value stacks.
	vm_thread_native_try :: #force_inline proc "contextless" (L: ^State, func, nresults: int, f: C_Function, ctx: ^runtime.Context) -> int {
		when !HARDSTACKTESTS {
			next := L.ci + 1
			if L.hookmask == 0 && L.stack_size - L.top > MINSTACK && next < L.frames_capacity {
				L.ci = next
				ci := &L.frames[next]
				ci.func = func
				ci.callstatus = u32(nresults + 1) | CIST_C
				ci.top = L.top + MINSTACK
				ci.u2 = 0
				n := int(f(L))
				ci = &L.frames[next]
				fwanted := ci.callstatus & (CIST_TBC | CIST_NRESULTS)
				if L.hookmask == 0 && fwanted == 1 {
					L.top = ci.func
					L.ci = next - 1
				} else if L.hookmask == 0 && fwanted == 2 {
					if n == 0 {
						set_nil(stack_value(L, ci.func))
					} else {
						set_obj(stack_value(L, ci.func), stack_value(L, L.top - n))
					}
					L.top = ci.func + 1
					L.ci = next - 1
				} else {
					vm_thread_poscall_slow(L, next, n, ctx)
				}
				return -1
			}
		}
		return vm_thread_precall_native(L, func, nresults, f, ctx)
	}

	// This is the non-allocating Lua-closure arm of do_precall. Growth,
	// __call, and all relocation-test calls use the original implementation.
	vm_thread_precall :: #force_inline proc "contextless" (
		L: ^State, func, nresults: int, ctx: ^runtime.Context,
	) -> int {
		when !HARDSTACKTESTS {
			callee := stack_value(L, func)
			switch type_tag(callee) {
			case VLCL:
				p := (^LClosure)(callee.value_.gc).p
				fsize := int(p.maxstacksize)
				next := L.ci + 1
				if L.stack_size - L.top > fsize && next < L.frames_capacity {
					narg := L.top - func - 1
					L.ci = next
					ci := &L.frames[next]
					ci.func = func
					ci.callstatus = u32(nresults + 1)
					ci.top = func + 1 + fsize
					ci.u2 = 0
					ci.u.l.savedpc = 0
					ci.u.l.nextraargs = 0
					ci.u.l.trap = 0
					for narg < int(p.numparams) {
						set_nil(stack_value(L, L.top))
						L.top += 1
						narg += 1
					}
					return next
				}
			case VLCF:
				return vm_thread_native_try(L, func, nresults, callee.value_.f, ctx)
			case VCCL:
				return vm_thread_native_try(L, func, nresults, (^CClosure)(callee.value_.gc).f, ctx)
			case:
			}
		}
		return vm_thread_precall_slow(L, func, nresults, ctx)
	}

	vm_thread_pollcall :: #force_no_inline proc "contextless" (
		L: ^State, trap: i32, ctx: ^runtime.Context,
	) -> i32 {
		context = ctx^
		return vm_apply_async_hook(L, trap)
	}

	// Raw arithmetic cannot allocate or raise. Only the zero-divisor error
	// needs the activation's original context.
	vm_thread_arith :: #force_inline proc "contextless" (ra, v1, v2: ^TValue, op: Arith_Op) -> Arith_Status {
		return raw_arith_to(op, v1, v2, ra)
	}

	vm_thread_aritherror :: #force_no_inline proc "contextless" (L: ^State, ctx: ^runtime.Context, is_mod: bool) {
		context = ctx^
		if is_mod {
			debug_runerror(L, "attempt to perform 'n%%0'")
		} else {
			debug_runerror(L, "attempt to divide by zero")
		}
	}
}
