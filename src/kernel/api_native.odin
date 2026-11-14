package kernel

import "base:runtime"

// These narrowly scoped helpers are for the standard libraries' C-ABI entries.
// Their callers use positive argument indices and have the default Odin context
// when they take a slow path. Keep the ordinary embedding API (including its
// caller-supplied assertion handler and procedure types) separate and unchanged.
// No pointer returned by native_arg may survive an operation that moves the stack.
@(private = "file")
native_arg :: #force_inline proc "contextless" (L: ^State, idx: int) -> ^TValue {
	ci := &L.frames[L.ci]
	when API_CHECKS {
		if idx <= 0 || idx > ci.top - (ci.func + 1) {
			native_bad_index(L, idx)
		}
	}
	o := ci.func + idx
	return o >= L.top ? &L.g.nilvalue : stack_value(L, o)
}

@(private = "file")
native_bad_index :: #force_no_inline proc "contextless" (L: ^State, idx: int) -> ! {
	context = runtime.default_context()
	// Retain the embedding API's assertion and message on an invalid index.
	index2value(L, idx)
	panic("invalid native argument index")
}

@(private = "file")
native_incr_top :: #force_inline proc "contextless" (L: ^State) {
	L.top += 1
	when API_CHECKS {
		if L.top > L.frames[L.ci].top {
			native_bad_top(L)
		}
	}
}

@(private = "file")
native_bad_top :: #force_no_inline proc "contextless" (L: ^State) {
	context = runtime.default_context()
	assert(L.top <= L.frames[L.ci].top, "stack overflow")
}

api_native_gettop :: #force_inline proc "contextless" (L: ^State) -> int {
	return L.top - (L.frames[L.ci].func + 1)
}

api_native_type :: #force_inline proc "contextless" (L: ^State, idx: int) -> int {
	o := native_arg(L, idx)
	return o != &L.g.nilvalue ? int(base_type(o)) : TNONE
}

api_native_rawequal :: #force_inline proc "contextless" (L: ^State, a, b: int) -> bool {
	x := native_arg(L, a)
	y := native_arg(L, b)
	return x != &L.g.nilvalue && y != &L.g.nilvalue && raw_equal(x, y)
}

api_native_tothread :: #force_inline proc "contextless" (L: ^State, idx: int) -> ^State {
	o := native_arg(L, idx)
	return is_thread(o) ? thread_value(o) : nil
}

api_native_toboolean :: #force_inline proc "contextless" (L: ^State, idx: int) -> bool {
	return !is_falsy(native_arg(L, idx))
}

api_native_isyieldable :: #force_inline proc "contextless" (L: ^State) -> bool {
	return yieldable(L)
}

// Strings and userdata have an immediate length. A table's border search goes
// through the ordinary API so its hint updates and all edge cases stay intact.
api_native_rawlen :: #force_inline proc "contextless" (L: ^State, idx: int) -> uint {
	o := native_arg(L, idx)
	switch type_tag(o) {
	case VSHRSTR, VLNGSTR: return str_value(o).len
	case VUSERDATA: return udata_value(o).len
	case VTABLE: return native_rawlen_slow(L, table_value(o))
	case: return 0
	}
}

@(private = "file")
native_rawlen_slow :: #force_no_inline proc "contextless" (L: ^State, t: ^Table) -> uint {
	context = runtime.default_context()
	return uint(table_getn(L, t))
}

// Fast shrink without closing a to-be-closed slot. Growing, invalid indices and
// any close go through api_settop unchanged, including its assertion policy.
api_native_trimtop :: #force_inline proc "contextless" (L: ^State, idx: int) {
	ci := &L.frames[L.ci]
	base := ci.func + 1
	newtop := base + idx
	if idx < 0 || idx > ci.top - base || newtop > L.top ||
	   (newtop < L.top && L.tbclist >= newtop) {
		native_settop_slow(L, idx)
		return
	}
	L.top = newtop
}

@(private = "file")
native_settop_slow :: #force_no_inline proc "contextless" (L: ^State, idx: int) {
	context = runtime.default_context()
	api_settop(L, idx)
}

api_native_isinteger :: #force_inline proc "contextless" (L: ^State, idx: int) -> bool {
	return is_integer(native_arg(L, idx))
}

api_native_exact_integer :: #force_inline proc "contextless" (L: ^State, idx: int) -> (Integer, bool) {
	o := native_arg(L, idx)
	return is_integer(o) ? int_value(o) : 0, is_integer(o)
}

@(private = "file")
native_tointeger_slow :: #force_no_inline proc "contextless" (o: ^TValue) -> (Integer, bool) {
	context = runtime.default_context()
	return vm_tointeger(o, .Eq)
}

api_native_tointegerx :: #force_inline proc "contextless" (L: ^State, idx: int) -> (Integer, bool) {
	o := native_arg(L, idx)
	if is_integer(o) {
		return int_value(o), true
	}
	return native_tointeger_slow(o)
}

@(private = "file")
native_tonumber_slow :: #force_no_inline proc "contextless" (o: ^TValue) -> (Number, bool) {
	context = runtime.default_context()
	return vm_tonumber(o)
}

api_native_tonumberx :: #force_inline proc "contextless" (L: ^State, idx: int) -> (Number, bool) {
	o := native_arg(L, idx)
	if is_float(o) {
		return flt_value(o), true
	} else if is_integer(o) {
		return Number(int_value(o)), true
	}
	return native_tonumber_slow(o)
}

@(private = "file")
native_tolstring_slow :: #force_no_inline proc "contextless" (L: ^State, idx: int, o: ^TValue) -> (string, bool) {
	context = runtime.default_context()
	return api_tolstring_slow(L, idx, o)
}

api_native_tolstring :: #force_inline proc "contextless" (L: ^State, idx: int) -> (string, bool) {
	o := native_arg(L, idx)
	if !is_string(o) {
		return native_tolstring_slow(L, idx, o)
	}
	return string(str_slice(str_value(o))), true
}

api_native_pushinteger :: #force_inline proc "contextless" (L: ^State, n: Integer) {
	set_int(stack_value(L, L.top), n)
	native_incr_top(L)
}

api_native_pushnumber :: #force_inline proc "contextless" (L: ^State, n: Number) {
	set_float(stack_value(L, L.top), n)
	native_incr_top(L)
}

api_native_pushboolean :: #force_inline proc "contextless" (L: ^State, b: bool) {
	set_bool(stack_value(L, L.top), b)
	native_incr_top(L)
}

api_native_pushnil :: #force_inline proc "contextless" (L: ^State) {
	set_nil(stack_value(L, L.top))
	native_incr_top(L)
}

// The common no-growth check is safe without an Odin context. Stress mode must
// always use the ordinary API, which deliberately relocates the value stack.
api_native_checkstack :: #force_inline proc "contextless" (L: ^State, n: int) -> bool {
	when !HARDSTACKTESTS {
		if n >= 0 && L.stack_size - L.top > n {
			ci := &L.frames[L.ci]
			if ci.top < L.top + n {
				ci.top = L.top + n
			}
			return true
		}
	}
	return native_checkstack_slow(L, n)
}

@(private = "file")
native_checkstack_slow :: #force_no_inline proc "contextless" (L: ^State, n: int) -> bool {
	context = runtime.default_context()
	return api_checkstack(L, n)
}
