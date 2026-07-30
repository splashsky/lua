package lua

// api.odin -- our analogue of reference Lua's `lapi.h` / `lapi.c`.
//
// The embedding API: the surface the standard libraries and host programs use to
// talk to a Lua state. It's the Odin-idiomatic equivalent of Lua's C API --
// pushing and reading stack values, calling functions (protected and not),
// creating and manipulating tables and metatables, the registry and the
// reference system, and userdata.
//
// This is the boundary that keeps `stdlib` a separate package: everything the
// libraries need must be exposed here. If a library ever wants to reach past
// this into kernel internals, that's a bug in the API, not a reason to couple.
//
// A single, load-bearing idea runs through this whole file: **the stack is
// addressed by integer indices, never by retained pointers.** Reference Lua
// works in terms of `StkId` pointers and rebases them after every reallocation;
// we sidestep that entire class of bug because our `savestack`/`restorestack`
// are the identity function. `index2value` resolves an API index (positive from
// the frame base, negative from the top, or a pseudo-index for the registry and
// upvalues) to a live `^TValue` -- valid only until the next thing that can move
// or grow the stack, exactly like reference Lua's `s2v(index2stk(...))`.

// ---------------------------------------------------------------------------
// Consistency checks
// ---------------------------------------------------------------------------
//
// Reference Lua's `api_check` compiles to nothing in a release build; it exists
// to catch embedder mistakes (bad indices, popping too much) during development.
// We keep it as a plain assert: honest, and it costs nothing worth worrying
// about while correctness is the goal. If we ever want a release build to drop
// these, this is the single chokepoint to gate.
@(private = "file")
api_check :: #force_inline proc(cond: bool, msg: string, loc := #caller_location) {
	assert(cond, msg, loc)
}

// The pointer we hand back for "no valid value here" -- reference Lua's
// `&G(L)->nilvalue`. It doubles as the sentinel `isvalid` tests against, so a
// read of an out-of-range index observes nil while a *write* through such an
// index can be rejected. Keeping this as pointer identity (rather than a
// separate boolean) is deliberately faithful to the reference.
@(private = "file")
nilobj :: #force_inline proc "contextless" (L: ^Lua_State) -> ^TValue {
	return &L.g.nilvalue
}

// Is `o` a real, addressable value (as opposed to the shared read-only nil we
// return for invalid indices)? Reference Lua's `isvalid`.
@(private = "file")
isvalid :: #force_inline proc "contextless" (L: ^Lua_State, o: ^TValue) -> bool {
	return o != &L.g.nilvalue
}

// ---------------------------------------------------------------------------
// Index translation
// ---------------------------------------------------------------------------

// Is `idx` a pseudo-index (the registry or an upvalue slot)? Reference `ispseudo`.
@(private = "file")
ispseudo :: #force_inline proc "contextless" (idx: int) -> bool {
	return idx <= LUA_REGISTRYINDEX
}

// Resolve an API index to the value it names -- reference Lua's `index2value`.
//
//   * A positive index counts up from the current frame's function slot: index 1
//     is the first argument/local. If it points past the live top we return the
//     shared nil (a read of an absent-but-legal slot yields nil).
//   * A negative, non-pseudo index counts down from the top: -1 is the topmost
//     value.
//   * `LUA_REGISTRYINDEX` names the registry table value itself.
//   * Anything more negative than that is an upvalue of the *currently running* C
//     closure: pseudo-index `LUA_REGISTRYINDEX - i` is that closure's i-th
//     captured value. A light C function (which captures nothing) yields nil.
index2value :: proc(L: ^Lua_State, idx: int) -> ^TValue {
	ci := &L.frames[L.ci]
	if idx > 0 {
		o := ci.func + idx
		api_check(idx <= ci.top - (ci.func + 1), "unacceptable index")
		if o >= L.top {
			return nilobj(L)
		}
		return stack_value(L, o)
	} else if !ispseudo(idx) { // negative, ordinary
		api_check(idx != 0 && -idx <= L.top - (ci.func + 1), "invalid index")
		return stack_value(L, L.top + idx)
	} else if idx == LUA_REGISTRYINDEX {
		return &L.g.registry
	} else { // upvalue of the running closure
		i := LUA_REGISTRYINDEX - idx // 1-based upvalue number
		fv := stack_value(L, ci.func)
		if is_c_closure(fv) {
			cl := c_closure_value(fv)
			return i <= int(cl.nupvalues) ? &cl.upvalue[i - 1] : nilobj(L)
		}
		// A light C function has no upvalues; reference returns nil here.
		return nilobj(L)
	}
}

// Resolve an API index to a *stack index* (never a pseudo-index) -- reference
// Lua's `index2stack`. Used where only real stack slots make sense (rotate,
// the message handler for pcall, ...).
@(private = "file")
index2stack :: proc(L: ^Lua_State, idx: int) -> int {
	ci := &L.frames[L.ci]
	if idx > 0 {
		o := ci.func + idx
		api_check(idx <= ci.top - (ci.func + 1), "invalid index")
		return o
	} else {
		api_check(idx != 0 && -idx <= L.top - (ci.func + 1), "invalid index")
		api_check(!ispseudo(idx), "invalid index")
		return L.top + idx
	}
}

// Bump the top by one after pushing, checking we stayed inside the frame's
// reserved region -- reference Lua's `api_incr_top`.
@(private = "file")
api_incr_top :: #force_inline proc(L: ^Lua_State) {
	L.top += 1
	api_check(L.top <= L.frames[L.ci].top, "stack overflow")
}

// Assert the caller left at least `n` values on the stack in this frame --
// reference Lua's `api_checknelems`. `api_checkpop` additionally forbids popping
// a value that is still guarded as to-be-closed.
@(private = "file")
api_checknelems :: #force_inline proc(L: ^Lua_State, n: int) {
	api_check(n < L.top - L.frames[L.ci].func, "not enough elements in the stack")
}

@(private = "file")
api_checkpop :: #force_inline proc(L: ^Lua_State, n: int) {
	api_check(n < L.top - L.frames[L.ci].func, "not enough elements in the stack")
	api_check(L.tbclist < L.top - n, "no tbc variable inside the popped elements")
}

// ---------------------------------------------------------------------------
// Basic stack manipulation
// ---------------------------------------------------------------------------

// Turn any acceptable index into its absolute (positive/pseudo) form -- reference
// Lua's `lua_absindex`.
lua_absindex :: proc(L: ^Lua_State, idx: int) -> int {
	if idx > 0 || ispseudo(idx) {
		return idx
	}
	return (L.top - L.frames[L.ci].func) + idx
}

// How many values are on the stack in the current frame -- reference `lua_gettop`.
lua_gettop :: proc(L: ^Lua_State) -> int {
	return L.top - (L.frames[L.ci].func + 1)
}

// Set the stack top to exactly `idx` values -- reference Lua's `lua_settop`.
// Growing nil-fills; shrinking discards. Crucially, if the shrink crosses any
// to-be-closed variable we must run its `__close` *synchronously* here (via
// `luaF_close` with the `CLOSEKTOP` sentinel) -- reference Lua does exactly this,
// and skipping it would silently leak a resource the program expected closed.
lua_settop :: proc(L: ^Lua_State, idx: int) {
	ci := &L.frames[L.ci]
	funcbase := ci.func + 1
	newtop: int
	if idx >= 0 {
		api_check(idx <= ci.top - funcbase, "new top too large")
		// Nil-fill any slots between the old and new top.
		for i in L.top ..< funcbase + idx {
			set_nil(stack_value(L, i))
		}
		newtop = funcbase + idx
	} else {
		api_check(-(idx + 1) <= L.top - funcbase, "invalid new top")
		newtop = L.top + idx + 1 // subtract the |idx| topmost values
	}
	// If we are shrinking across a to-be-closed variable, close it now.
	if newtop < L.top && L.tbclist >= newtop {
		newtop = luaF_close(L, newtop, CLOSEKTOP, false)
	}
	L.top = newtop
}

// Close (run `__close` on) the to-be-closed variable pinned at `idx`, then nil
// its slot -- reference Lua's `lua_closeslot`. Distinct from `settop` in that it
// targets one specific slot the embedder marked with `lua_toclose`.
lua_closeslot :: proc(L: ^Lua_State, idx: int) {
	level := index2stack(L, idx)
	api_check(
		(L.frames[L.ci].callstatus & CIST_TBC) != 0 && L.tbclist == level,
		"no variable to close at given level",
	)
	level = luaF_close(L, level, CLOSEKTOP, false)
	set_nil(stack_value(L, level))
}

// Reverse a contiguous slice of the stack in place -- the workhorse behind
// `lua_rotate`. Reference Lua's `reverse`.
@(private = "file")
reverse_slice :: proc(L: ^Lua_State, from, to: int) {
	from, to := from, to
	for from < to {
		tmp: TValue
		set_obj(&tmp, stack_value(L, from))
		set_obj(stack_value(L, from), stack_value(L, to))
		set_obj(stack_value(L, to), &tmp)
		from += 1
		to -= 1
	}
}

// Rotate the values from `idx` up to the top by `n_rot` positions -- reference
// Lua's `lua_rotate`. Implemented as three reversals, the classic trick. A
// to-be-closed variable must not be shuffled (its slot is pinned), so we reject
// any rotation whose segment contains one.
lua_rotate :: proc(L: ^Lua_State, idx: int, n_rot: int) {
	t := L.top - 1 // end of the affected segment
	p := index2stack(L, idx) // start of the affected segment
	api_check(L.tbclist < p, "moving a to-be-closed variable")
	// Length of the segment [p, t]. Reference Lua requires the caller to pass a
	// rotation count already within [-len, len] and only *checks* it under an
	// api-check that is compiled out of release builds -- which is why a legitimate
	// degenerate call like `lua_insert(L, -1)` (rotate a single-element segment by
	// 1) works there despite failing that check. We keep our api-checks live for
	// safety, so we instead reduce the count modulo the length (Euclidean `%%`, so
	// the result is always in [0, len)). This is identical to reference's `t - n`
	// for every in-range count and gracefully folds the full-rotation boundary into
	// the identity case rather than tripping an assertion.
	length := t - p + 1
	api_check(length > 0, "invalid 'n'")
	m := t - (n_rot %% length) // end of the prefix to reverse
	reverse_slice(L, p, m) // reverse the prefix
	reverse_slice(L, m + 1, t) // reverse the suffix
	reverse_slice(L, p, t) // reverse the whole
}

// Copy the value at `fromidx` into the slot `toidx` -- reference `lua_copy`.
// Writing through a real stack slot never needs a barrier (stack slots are never
// black); writing an upvalue pseudo-index can, so we barrier in that case.
lua_copy :: proc(L: ^Lua_State, fromidx, toidx: int) {
	fr := index2value(L, fromidx)
	to := index2value(L, toidx)
	api_check(isvalid(L, to), "invalid index")
	set_obj(to, fr)
	if ispseudo(toidx) && is_collectable(fr) { // writing an upvalue of the running C closure
		fv := stack_value(L, L.frames[L.ci].func)
		luaC_barrier(L, gc_value(fv), gc_value(fr))
	}
}

// Push a copy of the value at `idx` -- reference `lua_pushvalue`.
lua_pushvalue :: proc(L: ^Lua_State, idx: int) {
	set_obj(stack_value(L, L.top), index2value(L, idx))
	api_incr_top(L)
}

// Ensure the stack can hold `n` more values, growing if needed -- reference
// `lua_checkstack`. Returns false (without raising) if it cannot.
lua_checkstack :: proc(L: ^Lua_State, n: int) -> bool {
	api_check(n >= 0, "negative 'n'")
	ci := &L.frames[L.ci]
	res: bool
	if L.stack_size - L.top > n {
		res = true
	} else {
		res = grow_stack(L, n, false) == .Ok
	}
	if res && ci.top < L.top + n {
		ci.top = L.top + n // this frame may now use the freshly reserved slots
	}
	return res
}

// Move `n` values from the top of `from` to the top of `to` -- reference
// `lua_xmove`. Both threads must belong to the same global state.
lua_xmove :: proc(from, to: ^Lua_State, n: int) {
	if from == to {
		return
	}
	api_checknelems(from, n)
	api_check(from.g == to.g, "moving among independent states")
	api_check(to.frames[to.ci].top - to.top >= n, "stack overflow")
	from.top -= n
	for i in 0 ..< n {
		set_obj(stack_value(to, to.top), stack_value(from, from.top + i))
		to.top += 1
	}
}

// Pop `n` values -- reference Lua's `lua_pop` macro, expressed as `settop`.
lua_pop :: proc(L: ^Lua_State, n: int) {
	lua_settop(L, -n - 1)
}

// ---------------------------------------------------------------------------
// Access functions: stack -> program (type queries and conversions)
// ---------------------------------------------------------------------------

// The Lua type of the value at `idx`, or `LUA_TNONE` (-1) for an out-of-range
// index -- reference `lua_type`.
lua_type :: proc(L: ^Lua_State, idx: int) -> int {
	o := index2value(L, idx)
	return isvalid(L, o) ? int(base_type(o)) : LUA_TNONE
}

// The human-readable name of a type tag -- reference `lua_typename`.
lua_typename :: proc(L: ^Lua_State, t: int) -> string {
	api_check(TNONE <= t && t < NUM_TYPES, "invalid type")
	return ttypename(t)
}

lua_isnumber :: proc(L: ^Lua_State, idx: int) -> bool {
	_, ok := lua_tonumberx(L, idx)
	return ok
}

lua_isinteger :: proc(L: ^Lua_State, idx: int) -> bool {
	return is_integer(index2value(L, idx))
}

lua_isstring :: proc(L: ^Lua_State, idx: int) -> bool {
	o := index2value(L, idx)
	return is_string(o) || is_number(o) // numbers are coercible to strings
}

lua_iscfunction :: proc(L: ^Lua_State, idx: int) -> bool {
	o := index2value(L, idx)
	return is_light_cfunction(o) || is_c_closure(o)
}

lua_isuserdata :: proc(L: ^Lua_State, idx: int) -> bool {
	o := index2value(L, idx)
	return is_full_userdata(o) || is_light_userdata(o)
}

lua_isfunction :: proc(L: ^Lua_State, idx: int) -> bool {
	return is_function(index2value(L, idx))
}

lua_istable :: proc(L: ^Lua_State, idx: int) -> bool {
	return is_table(index2value(L, idx))
}

lua_isnil :: proc(L: ^Lua_State, idx: int) -> bool {
	return is_nil(index2value(L, idx))
}

lua_isboolean :: proc(L: ^Lua_State, idx: int) -> bool {
	return is_boolean(index2value(L, idx))
}

lua_isnone :: proc(L: ^Lua_State, idx: int) -> bool {
	return lua_type(L, idx) == LUA_TNONE
}

lua_isnoneornil :: proc(L: ^Lua_State, idx: int) -> bool {
	return lua_type(L, idx) <= TNIL
}

// Raw (metamethod-free) primitive equality of two values -- reference
// `lua_rawequal`. Invalid indices compare unequal.
lua_rawequal :: proc(L: ^Lua_State, idx1, idx2: int) -> bool {
	o1 := index2value(L, idx1)
	o2 := index2value(L, idx2)
	return (isvalid(L, o1) && isvalid(L, o2)) ? raw_equal(o1, o2) : false
}

// Compare two values with a given operator, honoring metamethods -- reference
// `lua_compare`. `op` is one of `LUA_OPEQ`/`LUA_OPLT`/`LUA_OPLE`.
lua_compare :: proc(L: ^Lua_State, idx1, idx2: int, op: int) -> bool {
	o1 := index2value(L, idx1)
	o2 := index2value(L, idx2)
	if !(isvalid(L, o1) && isvalid(L, o2)) {
		return false
	}
	switch op {
	case LUA_OPEQ:
		return luaV_equalobj(L, o1, o2)
	case LUA_OPLT:
		return luaV_lessthan(L, o1, o2)
	case LUA_OPLE:
		return luaV_lessequal(L, o1, o2)
	case:
		api_check(false, "invalid option")
		return false
	}
}

// Apply an arithmetic (or bitwise) operator to the top values -- reference
// `lua_arith`. Unary ops (unm, bnot) read one operand and duplicate it so the
// two-operand core sees a well-formed pair, exactly as reference Lua does.
lua_arith :: proc(L: ^Lua_State, op: int) {
	if !(op == LUA_OPUNM || op == LUA_OPBNOT) {
		api_checknelems(L, 2) // binary operators
	} else {
		api_checknelems(L, 1) // unary operators: duplicate the operand
		set_obj(stack_value(L, L.top), stack_value(L, L.top - 1))
		api_incr_top(L)
	}
	// The result overwrites the first operand; the second is then popped.
	luaO_arith(L, op, stack_value(L, L.top - 2), stack_value(L, L.top - 1), L.top - 2)
	L.top -= 1
}

// Interpret the value at `idx` as a floating number, coercing strings --
// reference `lua_tonumberx`. `ok` reports whether a number was obtained.
lua_tonumberx :: proc(L: ^Lua_State, idx: int) -> (n: Number, ok: bool) {
	o := index2value(L, idx)
	return vm_tonumber(o)
}

lua_tonumber :: proc(L: ^Lua_State, idx: int) -> Number {
	n, _ := lua_tonumberx(L, idx)
	return n
}

// Interpret the value at `idx` as an integer -- reference `lua_tointegerx`.
lua_tointegerx :: proc(L: ^Lua_State, idx: int) -> (i: Integer, ok: bool) {
	o := index2value(L, idx)
	return vm_tointeger(o, .Eq)
}

lua_tointeger :: proc(L: ^Lua_State, idx: int) -> Integer {
	i, _ := lua_tointegerx(L, idx)
	return i
}

// Lua truthiness of the value at `idx` -- reference `lua_toboolean`. Only nil
// and false are falsy.
lua_toboolean :: proc(L: ^Lua_State, idx: int) -> bool {
	return !is_falsy(index2value(L, idx))
}

// Interpret the value at `idx` as a string, converting a number *in place* --
// reference `lua_tolstring`. Returns the interned bytes as an Odin string plus a
// flag; `ok == false` means the value was neither a string nor a number.
//
// The in-place conversion matters: after this call the stack slot genuinely holds
// a string object, so a subsequent GC won't reclaim the bytes we just handed back
// and repeated calls are cheap. This is precisely reference Lua's behavior (and
// the reason `lua_tolstring` is not `const`-correct on its argument).
lua_tolstring :: proc(L: ^Lua_State, idx: int) -> (s: string, ok: bool) {
	o := index2value(L, idx)
	if !is_string(o) {
		if !is_number(o) { // not convertible
			return "", false
		}
		// Render the number and replace the value with the resulting string.
		buf: [N2S_BUFF_SZ]u8
		n := number_to_str(o, buf[:])
		ts := luaS_newlstr(L, raw_data(buf[:]), uint(n))
		set_string(o, ts)
		o = index2value(L, idx) // re-fetch (conversion cannot move the stack)
	}
	ts := str_value(o)
	return string(str_slice(ts)), true
}

lua_tostring :: proc(L: ^Lua_State, idx: int) -> (s: string, ok: bool) {
	return lua_tolstring(L, idx)
}

// The raw length of a string, table, or userdata -- reference `lua_rawlen`.
// (Tables report their border length; no `__len` metamethod is consulted.)
lua_rawlen :: proc(L: ^Lua_State, idx: int) -> uint {
	o := index2value(L, idx)
	switch type_tag(o) {
	case VSHRSTR, VLNGSTR:
		return str_value(o).len
	case VUSERDATA:
		return udata_value(o).len
	case VTABLE:
		return uint(luaH_getn(L, table_value(o)))
	case:
		return 0
	}
}

// The native function behind the value at `idx`, or nil -- reference
// `lua_tocfunction`.
lua_tocfunction :: proc(L: ^Lua_State, idx: int) -> C_Function {
	o := index2value(L, idx)
	if is_light_cfunction(o) {
		return cfunction_value(o)
	} else if is_c_closure(o) {
		return c_closure_value(o).f
	}
	return nil
}

// A pointer to a full userdata's payload, or the pointer stored in a light
// userdata -- reference `lua_touserdata`.
lua_touserdata :: proc(L: ^Lua_State, idx: int) -> rawptr {
	o := index2value(L, idx)
	switch base_type(o) {
	case TUSERDATA:
		return rawptr(udata_mem(udata_value(o)))
	case TLIGHTUSERDATA:
		return ptr_value(o)
	case:
		return nil
	}
}

// The thread behind the value at `idx`, or nil -- reference `lua_tothread`.
lua_tothread :: proc(L: ^Lua_State, idx: int) -> ^Lua_State {
	o := index2value(L, idx)
	return is_thread(o) ? thread_value(o) : nil
}

// A generic pointer identifying the object at `idx` -- reference `lua_topointer`,
// used mostly by `tostring`/debugging to print `table: 0x...`. Non-object values
// yield nil.
lua_topointer :: proc(L: ^Lua_State, idx: int) -> rawptr {
	o := index2value(L, idx)
	switch type_tag(o) {
	case VLCF:
		return rawptr(cfunction_value(o))
	case VUSERDATA:
		return rawptr(udata_mem(udata_value(o)))
	case VLIGHTUSERDATA:
		return ptr_value(o)
	case:
		return is_collectable(o) ? rawptr(gc_value(o)) : nil
	}
}

// ---------------------------------------------------------------------------
// Push functions: program -> stack
// ---------------------------------------------------------------------------

lua_pushnil :: proc(L: ^Lua_State) {
	set_nil(stack_value(L, L.top))
	api_incr_top(L)
}

lua_pushnumber :: proc(L: ^Lua_State, n: Number) {
	set_float(stack_value(L, L.top), n)
	api_incr_top(L)
}

lua_pushinteger :: proc(L: ^Lua_State, n: Integer) {
	set_int(stack_value(L, L.top), n)
	api_incr_top(L)
}

// Push a byte string, interning it -- reference `lua_pushlstring`. Returns the
// interned bytes so the caller can keep referring to them.
lua_pushlstring :: proc(L: ^Lua_State, s: []u8) -> string {
	ts: ^TString
	if len(s) == 0 {
		ts = luaS_newlstr(L, raw_data([]u8{0}), 0)
	} else {
		ts = luaS_newlstr(L, raw_data(s), uint(len(s)))
	}
	set_string(stack_value(L, L.top), ts)
	api_incr_top(L)
	luaC_checkGC(L)
	return string(str_slice(ts))
}

// Push a NUL-free Odin string -- reference `lua_pushstring`.
lua_pushstring :: proc(L: ^Lua_State, s: string) -> string {
	ts := luaS_new(L, s)
	set_string(stack_value(L, L.top), ts)
	api_incr_top(L)
	luaC_checkGC(L)
	return string(str_slice(ts))
}

// Push a printf-style formatted string -- reference `lua_pushfstring`. Delegates
// to `luaO_pushfstring`, which builds the result directly on the stack.
lua_pushfstring :: proc(L: ^Lua_State, fmt: string, args: ..any) -> string {
	ts := luaO_pushfstring(L, fmt, ..args)
	return string(str_slice(ts))
}

// Push a C closure over the `n` topmost values -- reference `lua_pushcclosure`.
// With `n == 0` this is a bare light C function (no captured state); otherwise it
// pops `n` values into a freshly allocated closure. The captured values move by
// copy, matching native-closure semantics.
lua_pushcclosure :: proc(L: ^Lua_State, fn: C_Function, n: int) {
	if n == 0 {
		set_c_function(stack_value(L, L.top), fn)
		api_incr_top(L)
		return
	}
	api_checknelems(L, n)
	api_check(n <= MAXUPVAL, "upvalue index too large")
	cl := luaF_newCclosure(L, n)
	if cl == nil {
		throw(L, .Err_Mem) // allocation failed under an active protected boundary
	}
	cl.f = fn
	L.top -= n
	for i in 0 ..< n {
		set_obj(&cl.upvalue[i], stack_value(L, L.top + i))
		// No barrier: the closure is brand new (white), so it can point at
		// anything without violating the tricolor invariant.
	}
	set_c_closure(stack_value(L, L.top), cl)
	api_incr_top(L)
	luaC_checkGC(L)
}

// Convenience: push a light C function (a closure with no upvalues) -- reference
// `lua_pushcfunction` macro.
lua_pushcfunction :: proc(L: ^Lua_State, fn: C_Function) {
	lua_pushcclosure(L, fn, 0)
}

lua_pushboolean :: proc(L: ^Lua_State, b: bool) {
	set_bool(stack_value(L, L.top), b)
	api_incr_top(L)
}

lua_pushlightuserdata :: proc(L: ^Lua_State, p: rawptr) {
	set_light_userdata(stack_value(L, L.top), p)
	api_incr_top(L)
}

// Push the running thread and report whether it is the main thread -- reference
// `lua_pushthread`.
lua_pushthread :: proc(L: ^Lua_State) -> bool {
	set_gc(stack_value(L, L.top), obj2gco(L))
	api_incr_top(L)
	return L == &L.g.main_thread.l
}

// ---------------------------------------------------------------------------
// Get functions: table read helpers and the public getters
// ---------------------------------------------------------------------------

// The globals table value (registry[LUA_RIDX_GLOBALS]) -- reference `getGtable`.
// This copies through the tag-returning table API instead of retaining an array
// slot pointer; the registry array will shortly have split tags and payloads.
@(private = "file")
getGtable :: #force_inline proc(L: ^Lua_State, res: ^TValue) {
	tag := luaH_getint(table_value(&L.g.registry), LUA_RIDX_GLOBALS, res)
	assert(!tag_is_empty(tag))
}

// Core indexed read with metamethod fallback, writing the result to stack slot
// `ra` -- the shared body behind every getter. Mirrors the VM's fast path but
// resolves error positions against the *current* frame (there is no bytecode pc
// to sync). `luaV_finishget` walks any `__index` chain.
@(private = "file")
api_get :: proc(L: ^Lua_State, t: ^TValue, key: ^TValue, ra: int) {
	if is_table(t) {
		h := table_value(t)
		tag: Byte
		if is_integer(key) {
			tag = luaH_fastgeti(h, int_value(key), stack_value(L, ra))
		} else {
			tag = luaH_fastget(h, key, stack_value(L, ra))
		}
		if !tag_is_empty(tag) {
			return
		}
	}
	luaV_finishget(L, t, key, ra)
}

// Read `t[k]` for a string key, pushing the result -- reference `auxgetstr`.
// The key/value slot alias is intentional and safe (reference does the same):
// the key string is only read *before* the value is written.
@(private = "file")
auxgetstr :: proc(L: ^Lua_State, t: ^TValue, k: string) -> int {
	str := luaS_new(L, k)
	set_string(stack_value(L, L.top), str)
	api_incr_top(L)
	api_get(L, t, stack_value(L, L.top - 1), L.top - 1)
	return int(base_type(stack_value(L, L.top - 1)))
}

// `push(t[k])` where `t` is the value at `idx` and `k` is popped from the top --
// reference `lua_gettable`.
lua_gettable :: proc(L: ^Lua_State, idx: int) -> int {
	api_checkpop(L, 1)
	t := index2value(L, idx)
	api_get(L, t, stack_value(L, L.top - 1), L.top - 1)
	return int(base_type(stack_value(L, L.top - 1)))
}

lua_getfield :: proc(L: ^Lua_State, idx: int, k: string) -> int {
	return auxgetstr(L, index2value(L, idx), k)
}

lua_getglobal :: proc(L: ^Lua_State, name: string) -> int {
	gt: TValue
	getGtable(L, &gt)
	return auxgetstr(L, &gt, name)
}

@(private = "file")
lua_geti_slow :: proc(L: ^Lua_State, t: ^TValue, n: Integer) -> int {
	key: TValue
	set_int(&key, n)
	luaV_finishget(L, t, &key, L.top)
	api_incr_top(L)
	return int(base_type(stack_value(L, L.top - 1)))
}

// `push(t[i])` for an integer key -- reference `lua_geti`. This entry point is
// also the inner read primitive for table.sort. Keep its hit path tiny so Odin
// can optimize it independently of the uncommon metamethod path, which remains
// outlined in `lua_geti_slow`.
lua_geti :: proc(L: ^Lua_State, idx: int, n: Integer) -> int {
	t := index2value(L, idx)
	if is_table(t) {
		tag := luaH_fastgeti(table_value(t), n, stack_value(L, L.top))
		if !tag_is_empty(tag) {
			api_incr_top(L)
			return int(base_type(stack_value(L, L.top - 1)))
		}
	}
	// Do not route this miss through `api_get`: that would look up n twice.
	return lua_geti_slow(L, t, n)
}

// Raw (metamethod-free) reads -----------------------------------------------

lua_rawget :: proc(L: ^Lua_State, idx: int) -> int {
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	api_checkpop(L, 1)
	tag := luaH_get(table_value(t), stack_value(L, L.top - 1), stack_value(L, L.top - 1))
	if tag_is_empty(tag) {
		set_nil(stack_value(L, L.top - 1))
	}
	return int(base_type(stack_value(L, L.top - 1)))
}

lua_rawgeti :: proc(L: ^Lua_State, idx: int, n: Integer) -> int {
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	tag := luaH_fastgeti(table_value(t), n, stack_value(L, L.top))
	if tag_is_empty(tag) {
		set_nil(stack_value(L, L.top))
	}
	api_incr_top(L)
	return int(base_type(stack_value(L, L.top - 1)))
}

// Raw read keyed by a light-userdata pointer -- reference `lua_rawgetp`.
lua_rawgetp :: proc(L: ^Lua_State, idx: int, p: rawptr) -> int {
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	key: TValue
	set_light_userdata(&key, p)
	tag := luaH_get(table_value(t), &key, stack_value(L, L.top))
	if tag_is_empty(tag) {
		set_nil(stack_value(L, L.top))
	}
	api_incr_top(L)
	return int(base_type(stack_value(L, L.top - 1)))
}

// Create a fresh table (optionally pre-sized) and push it -- reference
// `lua_createtable`.
lua_createtable :: proc(L: ^Lua_State, narray, nrec: int) {
	t := luaH_new(L)
	set_gc(stack_value(L, L.top), obj2gco(t))
	api_incr_top(L)
	if narray > 0 || nrec > 0 {
		luaH_resize(L, t, u32(narray), u32(nrec))
	}
	luaC_checkGC(L)
}

lua_newtable :: proc(L: ^Lua_State) {
	lua_createtable(L, 0, 0)
}

// Allocate a full userdata with `nuvalue` user values and push it, returning a
// pointer to its raw payload -- reference `lua_newuserdatauv`.
lua_newuserdatauv :: proc(L: ^Lua_State, size: uint, nuvalue: int) -> rawptr {
	api_check(0 <= nuvalue && nuvalue < 0x10000, "invalid value count")
	u := luaS_newudata(L, size, nuvalue)
	set_userdata(stack_value(L, L.top), u)
	api_incr_top(L)
	luaC_checkGC(L)
	return rawptr(udata_mem(u))
}

// Push userdata's n-th user value -- reference `lua_getiuservalue`.
lua_getiuservalue :: proc(L: ^Lua_State, idx: int, n: int) -> int {
	o := index2value(L, idx)
	api_check(is_full_userdata(o), "full userdata expected")
	u := udata_value(o)
	if n <= 0 || n > int(u.nuvalue) {
		set_nil(stack_value(L, L.top))
		api_incr_top(L)
		return LUA_TNONE
	}
	set_obj(stack_value(L, L.top), udata_uv(u, n - 1))
	api_incr_top(L)
	return int(base_type(stack_value(L, L.top - 1)))
}

// Push the metatable of the value at `idx`, if any -- reference
// `lua_getmetatable`. Returns whether one was pushed.
lua_getmetatable :: proc(L: ^Lua_State, objindex: int) -> bool {
	o := index2value(L, objindex)
	mt: ^Table
	switch base_type(o) {
	case TTABLE:
		mt = table_value(o).metatable
	case TUSERDATA:
		mt = udata_value(o).metatable
	case:
		mt = L.g.mt[base_type(o)]
	}
	if mt == nil {
		return false
	}
	set_gc(stack_value(L, L.top), obj2gco(mt))
	api_incr_top(L)
	return true
}

// ---------------------------------------------------------------------------
// Set functions: table write helpers and the public setters
// ---------------------------------------------------------------------------

// Core indexed write with metamethod fallback -- the shared body behind every
// setter. Mirrors the VM's fast path; `luaV_finishset` walks any `__newindex`
// chain and performs the raw insert when no metamethod intervenes.
@(private = "file")
api_set :: proc(L: ^Lua_State, t: ^TValue, key: ^TValue, val: ^TValue) {
	if is_table(t) {
		h := table_value(t)
		hres: int
		if is_integer(key) {
			hres = luaH_fastseti(h, int_value(key), val)
		} else {
			hres = luaH_fastpset(h, key, val)
		}
		if hres == HOK {
			if is_collectable(val) {
				luaC_barrierback(L, obj2gco(h))
			}
			return
		}
		luaV_finishset(L, t, key, val, hres)
		return
	}
	luaV_finishset(L, t, key, val, HNOTATABLE)
}

// `t[k] = v` for a string key, popping the value -- reference `auxsetstr`.
@(private = "file")
auxsetstr :: proc(L: ^Lua_State, t: ^TValue, k: string) {
	api_checknelems(L, 1)
	str := luaS_new(L, k)
	set_string(stack_value(L, L.top), str) // push key above the value
	api_incr_top(L)
	api_set(L, t, stack_value(L, L.top - 1), stack_value(L, L.top - 2))
	L.top -= 2 // pop both the key and the value
}

// `t[k] = v` where `t` is at `idx` and both key and value are popped -- reference
// `lua_settable`.
lua_settable :: proc(L: ^Lua_State, idx: int) {
	api_checkpop(L, 2)
	t := index2value(L, idx)
	api_set(L, t, stack_value(L, L.top - 2), stack_value(L, L.top - 1))
	L.top -= 2
}

lua_setfield :: proc(L: ^Lua_State, idx: int, k: string) {
	auxsetstr(L, index2value(L, idx), k)
}

lua_setglobal :: proc(L: ^Lua_State, name: string) {
	gt: TValue
	getGtable(L, &gt)
	auxsetstr(L, &gt, name)
}

@(private = "file")
lua_seti_slow :: proc(
	L: ^Lua_State,
	t: ^TValue,
	n: Integer,
	val: ^TValue,
	hres: int,
) {
	key: TValue
	set_int(&key, n)
	luaV_finishset(L, t, &key, val, hres)
	L.top -= 1
}

// `t[n] = v` for an integer key, popping the value -- reference `lua_seti`.
// table.sort performs swaps through this API, so mirror the get side: inline the
// successful array update and leave key construction/metamethod handling cold.
lua_seti :: proc(L: ^Lua_State, idx: int, n: Integer) {
	api_checknelems(L, 1)
	t := index2value(L, idx)
	val := stack_value(L, L.top - 1)
	hres := HNOTATABLE
	if is_table(t) {
		h := table_value(t)
		hres = luaH_fastseti(h, n, val)
		if hres == HOK {
			if is_collectable(val) {
				luaC_barrierback(L, obj2gco(h))
			}
			L.top -= 1
			return
		}
	}
	lua_seti_slow(L, t, n, val, hres)
}

// Raw (metamethod-free) writes ----------------------------------------------

lua_rawset :: proc(L: ^Lua_State, idx: int) {
	api_checkpop(L, 2)
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	h := table_value(t)
	luaH_set(L, h, stack_value(L, L.top - 2), stack_value(L, L.top - 1))
	invalidateTMcache(h)
	luaC_barrierback(L, obj2gco(h))
	L.top -= 2
}

lua_rawseti :: proc(L: ^Lua_State, idx: int, n: Integer) {
	api_checknelems(L, 1)
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	h := table_value(t)
	luaH_setint(L, h, n, stack_value(L, L.top - 1))
	luaC_barrierback(L, obj2gco(h))
	L.top -= 1
}

// Raw write keyed by a light-userdata pointer -- reference `lua_rawsetp`.
lua_rawsetp :: proc(L: ^Lua_State, idx: int, p: rawptr) {
	api_checknelems(L, 1)
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	h := table_value(t)
	key: TValue
	set_light_userdata(&key, p)
	luaH_set(L, h, &key, stack_value(L, L.top - 1))
	luaC_barrierback(L, obj2gco(h))
	L.top -= 1
}

// Set (or clear, with nil) the metatable of the value at `objindex` -- reference
// `lua_setmetatable`. For tables and userdata the metatable is stored on the
// object; for every other type it is a per-type default kept in the global
// state. A forward barrier keeps the tricolor invariant when a black object
// starts pointing at a (possibly white) metatable.
//
// Set (or clear, with nil) the metatable of the value at `objindex` -- reference
// `lua_setmetatable`. For tables and userdata the metatable is stored on the
// object; for every other type it is a per-type default kept in the global
// state. A forward barrier keeps the tricolor invariant when a black object
// starts pointing at a (possibly white) metatable. If the new metatable carries a
// `__gc` field, the object is enrolled for finalization via `luaC_checkfinalizer`.
lua_setmetatable :: proc(L: ^Lua_State, objindex: int) -> bool {
	api_checknelems(L, 1)
	o := index2value(L, objindex)
	v := stack_value(L, L.top - 1)
	mt: ^Table
	if is_nil(v) {
		mt = nil
	} else {
		api_check(is_table(v), "table expected")
		mt = table_value(v)
	}
	switch base_type(o) {
	case TTABLE:
		h := table_value(o)
		h.metatable = mt
		if mt != nil {
			luaC_barrier(L, obj2gco(h), obj2gco(mt))
			luaC_checkfinalizer(L, obj2gco(h), mt)
		}
	case TUSERDATA:
		u := udata_value(o)
		u.metatable = mt
		if mt != nil {
			luaC_barrier(L, obj2gco(u), obj2gco(mt))
			luaC_checkfinalizer(L, obj2gco(u), mt)
		}
	case:
		L.g.mt[base_type(o)] = mt
	}
	L.top -= 1
	return true
}

// Store the top value as the n-th user value of a userdata -- reference
// `lua_setiuservalue`. Returns false if `n` is out of range (value still popped).
lua_setiuservalue :: proc(L: ^Lua_State, idx: int, n: int) -> bool {
	api_checknelems(L, 1)
	o := index2value(L, idx)
	api_check(is_full_userdata(o), "full userdata expected")
	u := udata_value(o)
	res: bool
	if !(n >= 1 && n <= int(u.nuvalue)) {
		res = false
	} else {
		set_obj(udata_uv(u, n - 1), stack_value(L, L.top - 1))
		luaC_barrierback(L, obj2gco(u))
		res = true
	}
	L.top -= 1
	return res
}

// ---------------------------------------------------------------------------
// Garbage-collection control -- reference `lua_gc`.
// ---------------------------------------------------------------------------

// Drive the collector from the embedding side: this is the machinery behind
// Lua's `collectgarbage`. `what` selects an operation (one of the `LUA_GC*`
// constants); `args` carries the extra integer arguments a couple of the
// operations take (the byte count for STEP, and the param index + new value for
// PARAM). The return value's meaning is per-operation and mirrors reference Lua
// exactly -- callers pattern-match on `what` to interpret it.
//
// When the collector is internally stopped (mid-close or being torn down) every
// operation is invalid and we hand back -1, just like the reference guard.
lua_gc :: proc(L: ^Lua_State, what: int, args: ..int) -> int {
	g := L.g
	if g.gcstp & (GCSTPGC | GCSTPCLS) != 0 {
		return -1 // internal stop: all options are invalid
	}
	res := 0
	switch what {
	case LUA_GCSTOP:
		g.gcstp = GCSTPUSR // stopped by the user
	case LUA_GCRESTART:
		luaE_setdebt(g, 0)
		g.gcstp = 0 // (other bits must be zero here)
	case LUA_GCCOLLECT:
		luaC_fullgc(L, false)
	case LUA_GCCOUNT:
		// GC values are expressed in Kbytes: #bytes / 2^10.
		res = int(gettotalbytes(g) >> 10)
	case LUA_GCCOUNTB:
		res = int(gettotalbytes(g) & 0x3ff)
	case LUA_GCSTEP:
		oldstp := g.gcstp
		n: L_Mem = len(args) > 0 ? L_Mem(args[0]) : 0
		work := false
		g.gcstp = 0 // allow GC to run (other bits must be zero here)
		if n <= 0 {
			n = g.gc_debt // force to run one basic step
		}
		luaE_setdebt(g, g.gc_debt - n)
		// condGC: only steps when the debt has come due, mirroring `luaC_condGC`.
		if g.gc_debt <= 0 {
			luaC_step(L)
			work = true
		}
		if work && g.gcstate == GCSpause { // end of cycle?
			res = 1 // signal it
		}
		g.gcstp = oldstp // restore previous state
	case LUA_GCISRUNNING:
		res = gcrunning(g) ? 1 : 0
	case LUA_GCGEN:
		res = (g.gckind == KGC_INC) ? LUA_GCINC : LUA_GCGEN
		luaC_changemode(L, KGC_GENMINOR)
	case LUA_GCINC:
		res = (g.gckind == KGC_INC) ? LUA_GCINC : LUA_GCGEN
		luaC_changemode(L, KGC_INC)
	case LUA_GCPARAM:
		api_check(len(args) >= 1, "missing GC parameter index")
		param := args[0]
		api_check(0 <= param && param < LUA_GCPN, "invalid parameter")
		res = int(luaO_applyparam(g.gcparams[param], 100))
		value := len(args) >= 2 ? args[1] : -1
		if value >= 0 {
			g.gcparams[param] = luaO_codeparam(uint(value))
		}
	case:
		res = -1 // invalid option
	}
	return res
}

// ---------------------------------------------------------------------------
// 'load' and 'call' functions
// ---------------------------------------------------------------------------

// The payload bundle for the protected-call trampoline behind `lua_pcall`.
@(private = "file")
CallS :: struct {
	funcidx:  int,
	nresults: int,
}

@(private = "file")
f_call :: proc(L: ^Lua_State, ud: rawptr) -> Thread_Status {
	c := (^CallS)(ud)
	luaD_callnoyield(L, c.funcidx, c.nresults)
	return .Ok
}

// Call a function, optionally yieldable with a continuation -- reference
// `lua_callk`. When the caller supplies a continuation `k` *and* the current
// thread can yield, we route through `luaD_call` (which permits a yield to
// unwind and later resume into `k`); otherwise we forbid yields with
// `luaD_callnoyield`, exactly as reference Lua decides.
lua_callk :: proc(L: ^Lua_State, nargs, nresults: int, ctx: K_Context = 0, k: K_Function = nil) {
	api_checknelems(L, nargs + 1)
	api_check(L.status == .Ok, "cannot do calls on non-normal thread")
	funcidx := L.top - (nargs + 1)
	if k != nil && yieldable(L) {
		ci := &L.frames[L.ci]
		ci.u.c.k = k
		ci.u.c.ctx = ctx
		luaD_call(L, funcidx, nresults)
	} else {
		luaD_callnoyield(L, funcidx, nresults)
	}
	adjust_results(L, nresults)
}

lua_call :: proc(L: ^Lua_State, nargs, nresults: int) {
	lua_callk(L, nargs, nresults, 0, nil)
}

// Protected call, optionally yieldable with a continuation -- reference
// `lua_pcallk`. The conventional (non-yieldable, or no-continuation) path runs
// through `luaD_pcall`, which installs a fresh protected boundary and, on error,
// restores bookkeeping, closes pending to-be-closed variables, and relocates the
// error object. The yieldable path instead parks the continuation on the current
// C frame and marks it `CIST_YPCALL`, so a `pcall` boundary survives a yield and
// its `k` runs on resume with the right status -- the whole reason `pcallk`
// exists.
lua_pcallk :: proc(
	L: ^Lua_State,
	nargs, nresults, errfunc: int,
	ctx: K_Context = 0,
	k: K_Function = nil,
) -> Thread_Status {
	api_checknelems(L, nargs + 1)
	api_check(L.status == .Ok, "cannot do calls on non-normal thread")
	func_ef := 0
	if errfunc != 0 {
		func_ef = index2stack(L, errfunc)
	}
	funcidx := L.top - (nargs + 1)
	status: Thread_Status
	if k == nil || !yieldable(L) {
		// Conventional protected call.
		c := CallS{funcidx, nresults}
		status = luaD_pcall(L, f_call, &c, funcidx, func_ef)
	} else {
		// Yieldable protected call: retain the continuation across a possible yield.
		ci := &L.frames[L.ci]
		ci.u.c.k = k
		ci.u.c.ctx = ctx
		ci.u2 = funcidx
		ci.u.c.old_errfunc = L.errfunc
		L.errfunc = func_ef
		set_oah(ci, L.allowhook)
		ci.callstatus |= CIST_YPCALL
		luaD_call(L, funcidx, nresults) // yieldable call
		ci.callstatus &= ~CIST_YPCALL
		L.errfunc = ci.u.c.old_errfunc
		status = .Ok
	}
	adjust_results(L, nresults)
	return status
}

lua_pcall :: proc(L: ^Lua_State, nargs, nresults, errfunc: int) -> Thread_Status {
	return lua_pcallk(L, nargs, nresults, errfunc, 0, nil)
}

// Compile (or load precompiled) a chunk into a closure and push it -- reference
// `lua_load`. Parsing runs under `luaD_protectedparser`, which fully cleans up
// its scratch buffers on every path. On success we wire the loaded main
// function's sole upvalue (`_ENV`) to the globals table, mirroring reference Lua.
lua_load :: proc(
	L: ^Lua_State,
	reader: Reader,
	data: rawptr,
	chunkname: string,
	mode: string = "",
) -> Thread_Status {
	z: Zio
	zio_init(L, &z, reader, data)
	status := luaD_protectedparser(L, &z, chunkname, mode)
	if status == .Ok {
		f := lua_closure_value(stack_value(L, L.top - 1)) // the freshly loaded closure
		if f.nupvalues >= 1 {
			gt: TValue
			getGtable(L, &gt)
			set_obj(upval_value(f.upvals[0]), &gt)
			luaC_barrier(L, obj2gco(f.upvals[0]), gc_value(&gt))
		}
	}
	return status
}

// Serialize the function at the top of the stack to bytecode via `writer` --
// reference `lua_dump`. Reference does *not* pop the function itself, but it *does*
// save and restore `top` around the call so that the auxiliary de-duplication
// table `luaU_dump` anchors on the stack is cleaned up on return (leaving the
// stack exactly the size it came in at, with the function still on top). We
// mirror that save/restore precisely; forgetting it leaves the aux table dangling
// above the function.
lua_dump :: proc(L: ^Lua_State, writer: Lua_Writer, data: rawptr, strip: bool) -> i32 {
	api_checknelems(L, 1)
	otop := L.top // original top, restored after the dump
	o := stack_value(L, L.top - 1)
	status: i32 = 1 // not a Lua function: nothing dumped
	if is_lua_closure(o) {
		status = luaU_dump(L, lua_closure_value(o).p, writer, data, strip)
	}
	L.top = otop // drop the aux table luaU_dump anchored
	return status
}

// ---------------------------------------------------------------------------
// Miscellaneous
// ---------------------------------------------------------------------------

// The thread's current status -- reference `lua_status`.
lua_status :: proc(L: ^Lua_State) -> Thread_Status {
	return L.status
}

// Concatenate the `n` topmost values, honoring `__concat` -- reference
// `lua_concat`. `n == 0` pushes the empty string; `n == 1` is a no-op leaving the
// single value (numbers are *not* coerced in that case, per reference).
lua_concat :: proc(L: ^Lua_State, n: int) {
	api_checknelems(L, n)
	if n > 0 {
		luaV_concat(L, n)
	} else {
		set_string(stack_value(L, L.top), luaS_newlstr(L, raw_data([]u8{0}), 0))
		api_incr_top(L)
	}
	luaC_checkGC(L)
}

// Push `#v` for the value at `idx`, honoring `__len` -- reference `lua_len`.
lua_len :: proc(L: ^Lua_State, idx: int) {
	t := index2value(L, idx)
	luaV_objlen(L, L.top, t)
	api_incr_top(L)
}

// Advance a table traversal: pop a key, push the next key/value pair (or nothing
// at the end) -- reference `lua_next`. Returns whether a pair was produced.
lua_next :: proc(L: ^Lua_State, idx: int) -> bool {
	t := index2value(L, idx)
	api_check(is_table(t), "table expected")
	api_checkpop(L, 1)
	knext: TValue
	vnext: TValue
	more := luaH_next(L, table_value(t), stack_value(L, L.top - 1), &knext, &vnext)
	if more {
		set_obj(stack_value(L, L.top - 1), &knext) // replace the old key
		set_obj(stack_value(L, L.top), &vnext) // push the value
		api_incr_top(L)
		return true
	}
	L.top -= 1 // exhausted: remove the key
	return false
}

// Mark the value at `idx` as to-be-closed -- reference `lua_toclose`. When the
// enclosing block later unwinds past this slot (via `settop`/`closeslot`/error),
// its `__close` metamethod runs.
lua_toclose :: proc(L: ^Lua_State, idx: int) {
	level := index2stack(L, idx)
	api_check(L.tbclist < level, "given index below or equal a marked one")
	luaF_newtbcupval(L, level) // enroll the slot
	L.frames[L.ci].callstatus |= CIST_TBC
}

// Raise an error with the value at the top of the stack as the error object --
// reference `lua_error`. Never returns (it longjmps through the active boundary).
lua_error :: proc(L: ^Lua_State) -> ! {
	api_checknelems(L, 1)
	luaG_errormsg(L)
	unreachable() // luaG_errormsg always throws; this satisfies the `-> !` contract
}

// Parse a string into a pushed number -- reference `lua_stringtonumber`. Returns
// the number of bytes consumed on success, or 0 if the whole string was not a
// valid numeral.
lua_stringtonumber :: proc(L: ^Lua_State, s: string) -> uint {
	// Reuse the object-layer parser, which accepts the exact Lua numeral grammar
	// (decimal + hex integers and floats, surrounding spaces).
	buf := transmute([]u8)s
	o, sz := str_to_number(buf)
	if sz == 0 {
		return 0
	}
	set_obj(stack_value(L, L.top), &o)
	api_incr_top(L)
	return sz
}

// Retrieve / replace the allocator -- reference `lua_getallocf`/`lua_setallocf`.
// Our allocator bundles the function and its user pointer in one `Allocator`
// struct; we surface them separately here to match the reference C signatures.
lua_getallocf :: proc(L: ^Lua_State, ud: ^rawptr) -> Alloc_Proc {
	if ud != nil {
		ud^ = L.g.alloc.ud
	}
	return L.g.alloc.alloc
}

lua_setallocf :: proc(L: ^Lua_State, f: Alloc_Proc, ud: rawptr) {
	L.g.alloc.alloc = f
	L.g.alloc.ud = ud
}

// ---------------------------------------------------------------------------
// Threads (coroutines)
// ---------------------------------------------------------------------------

// Create a new thread sharing this global state and push it -- reference
// `lua_newthread`.
lua_newthread :: proc(L: ^Lua_State) -> ^Lua_State {
	th := luaE_newthread(L)
	set_gc(stack_value(L, L.top), obj2gco(th))
	api_incr_top(L)
	return th
}

// Whether the thread may currently yield -- reference `lua_isyieldable`.
lua_isyieldable :: proc(L: ^Lua_State) -> bool {
	return yieldable(L)
}

// ---------------------------------------------------------------------------
// Upvalue access
// ---------------------------------------------------------------------------

// Locate the storage of the n-th upvalue of the closure at `funcindex`, returning
// its name and a pointer to its live value slot -- the shared body behind
// `lua_getupvalue`/`lua_setupvalue`. Reference Lua's `aux_upvalue`. `owner`
// receives the closure object (for the write barrier on set).
@(private = "file")
aux_upvalue :: proc(fi: ^TValue, n: int) -> (name: string, val: ^TValue, owner: ^GCObject) {
	switch type_tag(fi) {
	case VCCL:
		f := c_closure_value(fi)
		if !(1 <= n && n <= int(f.nupvalues)) {
			return "", nil, nil
		}
		// Native closures capture nameless values -- reference reports "" for a
		// C upvalue (distinct from the "(no name)" a stripped Lua closure gives).
		return "", &f.upvalue[n - 1], obj2gco(f)
	case VLCL:
		f := lua_closure_value(fi)
		p := f.p
		if !(1 <= n && n <= int(p.sizeupvalues)) {
			return "", nil, nil
		}
		// A Lua closure always has a real upvalue; when its debug name is absent
		// (a chunk compiled/loaded with stripped debug info) reference reports the
		// placeholder "(no name)" rather than an empty string.
		nm := p.upvalues[n - 1].name
		name = nm == nil ? "(no name)" : string(str_slice(nm))
		return name, upval_value(f.upvals[n - 1]), obj2gco(f)
	case:
		return "", nil, nil
	}
}

// Push the n-th upvalue of the closure at `funcindex` and return its name --
// reference `lua_getupvalue`. An empty name means "no name" (a C upvalue).
lua_getupvalue :: proc(L: ^Lua_State, funcindex, n: int) -> (name: string, ok: bool) {
	fi := index2value(L, funcindex)
	nm, val, _ := aux_upvalue(fi, n)
	if val == nil {
		return "", false
	}
	set_obj(stack_value(L, L.top), val)
	api_incr_top(L)
	return nm, true
}

// Set the n-th upvalue of the closure at `funcindex` from the popped top value --
// reference `lua_setupvalue`.
lua_setupvalue :: proc(L: ^Lua_State, funcindex, n: int) -> (name: string, ok: bool) {
	fi := index2value(L, funcindex)
	nm, val, owner := aux_upvalue(fi, n)
	if val == nil {
		return "", false
	}
	L.top -= 1
	set_obj(val, stack_value(L, L.top))
	if is_collectable(stack_value(L, L.top)) {
		luaC_barrier(L, owner, gc_value(stack_value(L, L.top)))
	}
	return nm, true
}
