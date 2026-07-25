package lua

// vm.odin -- our analogue of reference Lua's `lvm.h` / `lvm.c`.
//
// The interpreter itself: the loop that decodes and executes bytecode. Unlike a
// naive port, ours is a *trampoline* over the explicit frame stack rather than a
// recursive walk of the native call stack -- so a call, a yield, or an error is
// a state transition returning an `Exec_Outcome`, not a native call/return. That
// is exactly what makes faithful coroutines and pcall/error possible in Odin
// (see docs/ARCHITECTURE.md, Decision 2).
//
// It also implements the numeric tower (integer/float arithmetic, coercions),
// comparisons and equality, table indexing, and the metamethod fallback paths
// for every operation.
//
// The trampoline model: `luaV_execute` runs Lua frames *in place* over the
// explicit frame array. A Lua->Lua call re-derives the loop's per-frame locals
// for the callee's frame (reference Lua's `goto startfunc`); a return either ends
// this invocation (a FRESH frame entered from C) or resumes the caller frame
// (`goto returning`). C functions, metamethods, and the iterator call all run to
// completion through the ordinary call protocol (`luaD_call`), which recursively
// re-enters `luaV_execute` for any Lua callee. Errors propagate by longjmp
// (checkpoint-008's real setjmp/longjmp boundary).

// The guard against a runaway `__index`/`__newindex` metamethod chain -- reference
// Lua's `MAXTAGLOOP`.
MAXTAGLOOP :: 2000

// ---------------------------------------------------------------------------
// Numeric coercions with string parsing (the `for`-loop / tonumber path)
// ---------------------------------------------------------------------------

// Try to read `o` as a number by parsing it if it is a string -- reference Lua's
// `l_strton`. Returns the parsed value and whether the whole string was a valid
// numeral. Non-strings never parse here (the caller has already handled the plain
// numeric cases).
@(private = "file")
l_strton :: proc (o: ^TValue) -> (TValue, bool) {
	if base_type(o) != TSTRING {
		return {}, false
	}
	s := str_slice(str_value(o))
	v, sz := str_to_number(s)
	return v, sz == uint(len(s)) && sz != 0
}

// Try to convert a value (including a numeric string) to a float -- reference
// Lua's `luaV_tonumber_` combined with the `tonumber` macro's float fast path.
// Package-visible (not file-private) because the C API's `lua_tonumberx` needs it.
vm_tonumber :: proc (o: ^TValue) -> (Number, bool) {
	if is_float(o) {
		return flt_value(o), true
	}
	if is_integer(o) {
		return Number(int_value(o)), true
	}
	if v, ok := l_strton(o); ok {
		return to_number_no_string(&v)
	}
	return 0, false
}

// Try to convert a value (including a numeric string) to an integer, rounding per
// `mode` -- reference Lua's `luaV_tointeger`. Package-visible for `lua_tointegerx`.
vm_tointeger :: proc (o: ^TValue, mode: F2I_Mode) -> (Integer, bool) {
	if v, ok := l_strton(o); ok {
		return to_integer_no_string(&v, mode)
	}
	return to_integer_no_string(o, mode)
}

// Left shift with a signed count; a negative count shifts right (logically) --
// reference Lua's `luaV_shiftl`. Shifts of `NBITS` or more clear the word.
@(private = "file")
vm_shiftl :: proc "contextless" (x, y: Integer) -> Integer {
	nbits := Integer(size_of(Integer) * 8)
	if y < 0 { // shift right
		if y <= -nbits {
			return 0
		}
		return u2s(s2u(x) >> u64(-y))
	}
	if y >= nbits { // shift left
		return 0
	}
	return u2s(s2u(x) << u64(y))
}

// ---------------------------------------------------------------------------
// Numeric comparison (with the int/float mixed-domain corner cases)
// ---------------------------------------------------------------------------
//
// Comparing an integer with a float is subtle: when the integer is too large to
// be represented exactly as a float, converting it loses precision, so we instead
// compare against the float's floor/ceiling in the integer domain. These four
// helpers mirror reference Lua's `LTintfloat`/`LEintfloat`/`LTfloatint`/
// `LEfloatint`; NaN always compares false.

// Whether integer `i` has an exact float representation -- reference `l_intfitsf`.
// Doubles have a 53-bit mantissa, so any |i| <= 2^53 is exact.
@(private = "file")
l_intfitsf :: proc "contextless" (i: Integer) -> bool {
	MAXINTFITSF :: u64(1) << 53
	return (MAXINTFITSF + s2u(i)) <= (2 * MAXINTFITSF)
}

@(private = "file")
LTintfloat :: proc "contextless" (i: Integer, f: Number) -> bool {
	if l_intfitsf(i) {
		return Number(i) < f
	}
	if fi, ok := float_to_integer(f, .Ceil); ok {
		return i < fi
	}
	return f > 0
}

@(private = "file")
LEintfloat :: proc "contextless" (i: Integer, f: Number) -> bool {
	if l_intfitsf(i) {
		return Number(i) <= f
	}
	if fi, ok := float_to_integer(f, .Floor); ok {
		return i <= fi
	}
	return f > 0
}

@(private = "file")
LTfloatint :: proc "contextless" (f: Number, i: Integer) -> bool {
	if l_intfitsf(i) {
		return f < Number(i)
	}
	if fi, ok := float_to_integer(f, .Floor); ok {
		return fi < i
	}
	return f < 0
}

@(private = "file")
LEfloatint :: proc "contextless" (f: Number, i: Integer) -> bool {
	if l_intfitsf(i) {
		return f <= Number(i)
	}
	if fi, ok := float_to_integer(f, .Ceil); ok {
		return fi <= i
	}
	return f < 0
}

// `l < r` for two numbers of any int/float mix -- reference Lua's `LTnum`.
@(private = "file")
LTnum :: proc "contextless" (l, r: ^TValue) -> bool {
	if is_integer(l) {
		li := int_value(l)
		if is_integer(r) {
			return li < int_value(r)
		}
		return LTintfloat(li, flt_value(r))
	}
	lf := flt_value(l)
	if is_float(r) {
		return lf < flt_value(r)
	}
	return LTfloatint(lf, int_value(r))
}

// `l <= r` for two numbers of any int/float mix -- reference Lua's `LEnum`.
@(private = "file")
LEnum :: proc "contextless" (l, r: ^TValue) -> bool {
	if is_integer(l) {
		li := int_value(l)
		if is_integer(r) {
			return li <= int_value(r)
		}
		return LEintfloat(li, flt_value(r))
	}
	lf := flt_value(l)
	if is_float(r) {
		return lf <= flt_value(r)
	}
	return LEfloatint(lf, int_value(r))
}

// Order two 0-terminated-embedding strings -- reference Lua's `l_strcmp`. Lua
// strings may contain embedded NULs, so we compare segment by segment. We compare
// bytes directly (the "C" locale); locale-aware collation is a deliberate,
// documented deviation (see the plan's scope decision).
@(private = "file")
l_strcmp :: proc "contextless" (ts1, ts2: ^TString) -> int {
	a := str_slice(ts1)
	b := str_slice(ts2)
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}

// `#tag(o) == TFUNCTION`? Any closure variant (Lua/C/light-C) qualifies.
@(private = "file")
is_function_val :: proc "contextless" (o: ^TValue) -> bool {
	return base_type(o) == TFUNCTION
}

// `l < r` when at least one operand isn't a number -- reference `lessthanothers`.
@(private = "file")
lessthanothers :: proc(L: ^Lua_State, l, r: ^TValue) -> bool {
	if base_type(l) == TSTRING && base_type(r) == TSTRING {
		return l_strcmp(str_value(l), str_value(r)) < 0
	}
	return luaT_callorderTM(L, l, r, TM_LT) > 0
}

// `l <= r` when at least one operand isn't a number -- reference `lessequalothers`.
@(private = "file")
lessequalothers :: proc(L: ^Lua_State, l, r: ^TValue) -> bool {
	if base_type(l) == TSTRING && base_type(r) == TSTRING {
		return l_strcmp(str_value(l), str_value(r)) <= 0
	}
	return luaT_callorderTM(L, l, r, TM_LE) > 0
}

// Full `l < r` -- reference Lua's `luaV_lessthan`.
luaV_lessthan :: proc(L: ^Lua_State, l, r: ^TValue) -> bool {
	if is_number(l) && is_number(r) {
		return LTnum(l, r)
	}
	return lessthanothers(L, l, r)
}

// Full `l <= r` -- reference Lua's `luaV_lessequal`.
luaV_lessequal :: proc(L: ^Lua_State, l, r: ^TValue) -> bool {
	if is_number(l) && is_number(r) {
		return LEnum(l, r)
	}
	return lessequalothers(L, l, r)
}

// Full value equality, consulting `__eq` for tables/userdata -- reference Lua's
// `luaV_equalobj`. The raw, metamethod-free half is delegated to `raw_equal`
// (object.odin); only the table/userdata case can fall through to a metamethod.
luaV_equalobj :: proc(L: ^Lua_State, t1, t2: ^TValue) -> bool {
	// Different base types never compare equal (a number is never a string).
	if no_variant(t1.tt_) != no_variant(t2.tt_) {
		return false
	}
	// Same base type: raw_equal decides everything except the table/userdata
	// __eq fallback, which it reports as `false` (it takes no state).
	if raw_equal(t1, t2) {
		return true
	}
	// Only tables and full userdata with distinct identity may still be equal
	// through an `__eq` metamethod; every other type's raw result was final.
	mt1, mt2: ^Table
	switch base_type(t1) {
	case TTABLE:
		mt1 = (^Table)(t1.value_.gc).metatable
		mt2 = (^Table)(t2.value_.gc).metatable
	case TUSERDATA:
		mt1 = udata_value(t1).metatable
		mt2 = udata_value(t2).metatable
	case:
		return false
	}
	tm := fasttm(L, mt1, TM_EQ)
	if tm == nil {
		tm = fasttm(L, mt2, TM_EQ)
	}
	if tm == nil {
		return false
	}
	luaT_callTMres(L, tm, t1, t2, L.top)
	return is_true(stack_value(L, L.top))
}

// ---------------------------------------------------------------------------
// Metatable fast-access
// ---------------------------------------------------------------------------

// Fetch a fast-access metamethod (`__index`/`__newindex`/`__len`/`__eq`) from a
// metatable, honoring the absence cache -- reference Lua's `fasttm`. Returns nil
// when there is no metatable or the event is cached-absent or genuinely missing.
@(private = "file")
fasttm :: proc(L: ^Lua_State, mt: ^Table, event: int) -> ^TValue {
	if mt == nil {
		return nil
	}
	if (mt.flags & Byte(u32(1) << u32(event))) != 0 { // cached as absent
		return nil
	}
	return luaT_gettm(mt, event, L.g.tmname[event])
}

// ---------------------------------------------------------------------------
// Indexed access with metamethod fallback
// ---------------------------------------------------------------------------

// Finish `R[val] = t[key]` after the fast path missed -- reference Lua's
// `luaV_finishget`, adapted to our slot-returning table API. Walks the `__index`
// chain, calling a function metamethod or continuing into a table.
luaV_finishget :: proc(L: ^Lua_State, t_in: ^TValue, key: ^TValue, val: int) {
	t := t_in
	is_tab := base_type(t) == TTABLE
	for _ in 0 ..< MAXTAGLOOP {
		tm: ^TValue
		if !is_tab {
			tm = luaT_gettmbyobj(L, t, TM_INDEX)
			if is_nil(tm) {
				luaG_typeerror(L, t, "index") // no metamethod: hard error
			}
		} else {
			tm = fasttm(L, (^Table)(t.value_.gc).metatable, TM_INDEX)
			if tm == nil { // table, no __index: result is nil
				set_nil(stack_value(L, val))
				return
			}
		}
		if is_function_val(tm) { // __index is a function: call it
			luaT_callTMres(L, tm, t, key, val)
			return
		}
		t = tm // __index is a table (or object): access t[key] next
		if base_type(t) == TTABLE {
			slot := luaH_getslot((^Table)(t.value_.gc), key)
			is_tab = true
			if !is_empty(slot) {
				set_obj(stack_value(L, val), slot)
				return
			}
			// else empty: loop to consult this table's own __index
		} else {
			is_tab = false
		}
	}
	luaG_runerror(L, "'__index' chain too long; possible loop")
}

// The VM's table read: `R[ra] = t[key]` -- the fast path plus `luaV_finishget`.
@(private = "file")
vm_gettable :: proc(L: ^Lua_State, ci_idx: int, pc: int, t: ^TValue, key: ^TValue, ra: int) {
	if base_type(t) == TTABLE {
		slot: ^TValue
		if is_integer(key) {
			slot = luaH_getint_slot((^Table)(t.value_.gc), int_value(key))
		} else {
			slot = luaH_getslot((^Table)(t.value_.gc), key)
		}
		if !is_empty(slot) {
			set_obj(stack_value(L, ra), slot)
			return
		}
	}
	// Miss (empty slot or non-table): metamethod path. savestate for error line.
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	luaV_finishget(L, t, key, ra)
}

// Finish `t[key] = val` after the fast path -- reference Lua's `luaV_finishset`,
// adapted to our slot API. When `key` is already present in a table it is a raw
// update (no `__newindex`); when absent, consult `__newindex`, else raw-insert.
luaV_finishset :: proc(L: ^Lua_State, t_in: ^TValue, key: ^TValue, val: ^TValue) {
	t := t_in
	for _ in 0 ..< MAXTAGLOOP {
		if base_type(t) == TTABLE {
			h := (^Table)(t.value_.gc)
			slot := luaH_getslot(h, key)
			if !is_empty(slot) { // present: plain update, no metamethod
				set_obj(slot, val)
				if is_collectable(val) {
					luaC_barrierback(L, &h.header)
				}
				return
			}
			tm := fasttm(L, h.metatable, TM_NEWINDEX)
			if tm == nil { // absent, no __newindex: raw insert
				luaH_set(L, h, key, val)
				invalidateTMcache(h)
				if is_collectable(val) {
					luaC_barrierback(L, &h.header)
				}
				return
			}
			if is_function_val(tm) { // __newindex is a function: call it
				luaT_callTM(L, tm, t, key, val)
				return
			}
			t = tm // __newindex is a table: repeat assignment over it
		} else {
			tm := luaT_gettmbyobj(L, t, TM_NEWINDEX)
			if is_nil(tm) {
				luaG_typeerror(L, t, "index")
			}
			if is_function_val(tm) {
				luaT_callTM(L, tm, t, key, val)
				return
			}
			t = tm
		}
	}
	luaG_runerror(L, "'__newindex' chain too long; possible loop")
}

// The VM's table write: `t[key] = val` -- the fast path plus `luaV_finishset`.
@(private = "file")
vm_settable :: proc(L: ^Lua_State, ci_idx: int, pc: int, t: ^TValue, key: ^TValue, val: ^TValue) {
	if base_type(t) == TTABLE {
		h := (^Table)(t.value_.gc)
		slot: ^TValue
		if is_integer(key) {
			slot = luaH_getint_slot(h, int_value(key))
		} else {
			slot = luaH_getslot(h, key)
		}
		if !is_empty(slot) { // present: raw update, no __newindex
			set_obj(slot, val)
			if is_collectable(val) {
				luaC_barrierback(L, &h.header)
			}
			return
		}
	}
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	luaV_finishset(L, t, key, val)
}

// ---------------------------------------------------------------------------
// Length, concatenation, number->string
// ---------------------------------------------------------------------------

// `R[ra] = #rb` -- reference Lua's `luaV_objlen`. Strings and metamethod-less
// tables have a primitive length; a `__len` metamethod overrides for tables and
// is the only option for other types.
luaV_objlen :: proc(L: ^Lua_State, ra: int, rb: ^TValue) {
	tm: ^TValue
	switch type_tag(rb) {
	case VTABLE:
		h := (^Table)(rb.value_.gc)
		tm = fasttm(L, h.metatable, TM_LEN)
		if tm == nil { // no __len: primitive border length
			set_int(stack_value(L, ra), Integer(luaH_getn(L, h)))
			return
		}
	case VSHRSTR, VLNGSTR:
		set_int(stack_value(L, ra), Integer(str_value(rb).len))
		return
	case:
		tm = luaT_gettmbyobj(L, rb, TM_LEN)
		if is_nil(tm) {
			luaG_typeerror(L, rb, "get length of")
		}
	}
	luaT_callTMres(L, tm, rb, rb, ra)
}

// Convert a number value in place to its string form -- reference Lua's
// `luaO_tostring`. Used by concatenation, which coerces numbers to strings.
@(private = "file")
luaO_tostring :: proc(L: ^Lua_State, o: ^TValue) {
	buf: [N2S_BUFF_SZ]u8
	n := number_to_str(o, buf[:])
	ts := luaS_newlstr(L, raw_data(buf[:]), uint(n))
	set_string(o, ts)
}

// Whether the top-of-stack value is a short string of length zero.
@(private = "file")
is_empty_str :: proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VSHRSTR && str_value(o).len == 0
}

// Whether a value can be coerced to a string for concatenation (it already is a
// string, or it is a number) -- reference Lua's `cvt2str`/`tostring` predicate.
@(private = "file")
concat_tostr :: proc(L: ^Lua_State, o: ^TValue) -> bool {
	if base_type(o) == TSTRING {
		return true
	}
	if is_number(o) {
		luaO_tostring(L, o) // fold the number into a string, in place
		return true
	}
	return false
}

// Concatenate the top `total` stack values into one -- reference Lua's
// `luaV_concat`. Runs right-to-left, folding runs of coercible values with one
// allocation each, and falling back to `__concat` for anything else.
luaV_concat :: proc(L: ^Lua_State, total_in: int) {
	total := total_in
	if total == 1 {
		return // a single value is already "concatenated"
	}
	for {
		top := L.top
		n := 2 // values folded this pass (at least the top two)
		if !concat_tostr(L, stack_value(L, top - 2)) || !concat_tostr(L, stack_value(L, top - 1)) {
			luaT_tryconcatTM(L) // a metamethod (may reshape the stack)
		} else if is_empty_str(stack_value(L, top - 1)) {
			// Second operand empty: result is the (already-string) first operand.
		} else if is_empty_str(stack_value(L, top - 2)) {
			set_obj(stack_value(L, top - 2), stack_value(L, top - 1)) // result is second
		} else {
			// At least two real strings: gather as many as fold cleanly.
			tl := uint(str_value(stack_value(L, top - 1)).len)
			n = 1
			for n < total && concat_tostr(L, stack_value(L, top - n - 1)) {
				l := uint(str_value(stack_value(L, top - n - 1)).len)
				if l >= MAX_SIZE - size_of(TString) - tl {
					L.top = top - total
					luaG_runerror(L, "string length overflow")
				}
				tl += l
				n += 1
			}
			ts: ^TString
			if tl <= MAXSHORTLEN { // fold into a short string via a buffer
				buff: [MAXSHORTLEN]u8
				copy_concat_buff(L, top, n, buff[:])
				ts = luaS_newlstr(L, raw_data(buff[:]), tl)
			} else { // long string: copy directly into the final object
				ts = luaS_createlngstrobj(L, tl)
				dst := str_bytes(ts)
				copy_concat_buff(L, top, n, dst[:tl])
			}
			set_string(stack_value(L, top - n), ts)
		}
		total -= n - 1 // folded `n` values into 1
		L.top -= n - 1
		if total <= 1 {
			break
		}
	}
}

// Copy the `n` strings at `top-n .. top-1` into `buff` -- reference `copy2buff`.
@(private = "file")
copy_concat_buff :: proc(L: ^Lua_State, top: int, n: int, buff: []u8) {
	tl := 0
	k := n
	for k > 0 {
		st := str_value(stack_value(L, top - k))
		s := str_slice(st)
		copy(buff[tl:], s)
		tl += len(s)
		k -= 1
	}
}

// ---------------------------------------------------------------------------
// Closures and the numerical for-loop
// ---------------------------------------------------------------------------

// Create a Lua closure for `p`, anchor it at `ra`, and wire its upvalues --
// reference Lua's `pushclosure`. In-stack upvalues share the open upvalue for the
// captured slot; the rest are inherited from the enclosing closure.
@(private = "file")
pushclosure :: proc(L: ^Lua_State, p: ^Proto, encup: [^]^UpVal, base: int, ra: int) {
	nup := int(p.sizeupvalues)
	uv := p.upvalues
	ncl := luaF_newLclosure(L, nup)
	ncl.p = p
	set_lua_closure(stack_value(L, ra), ncl) // anchor before allocating upvalues
	for i in 0 ..< nup {
		if uv[i].instack != 0 {
			ncl.upvals[i] = luaF_findupval(L, base + int(uv[i].idx))
		} else {
			ncl.upvals[i] = encup[uv[i].idx]
		}
		luaC_barrier(L, &ncl.header, &ncl.upvals[i].header)
	}
}

// Convert a `for` limit to an integer, preserving loop semantics -- reference
// Lua's `forlimit`. Returns (limit, skip): `skip` true means the loop must not run.
@(private = "file")
forlimit :: proc(L: ^Lua_State, init: Integer, lim: ^TValue, step: Integer) -> (Integer, bool) {
	p, ok := vm_tointeger(lim, .Ceil if step < 0 else .Floor)
	if !ok { // not coercible to an integer: try as a float
		flim, okf := vm_tonumber(lim)
		if !okf {
			luaG_forerror(L, lim, "limit")
		}
		if 0 < flim { // positive and out of range: clip high (or skip if descending)
			if step < 0 {
				return 0, true
			}
			p = MAX_INTEGER
		} else { // negative and out of range: clip low (or skip if ascending)
			if step > 0 {
				return 0, true
			}
			p = MIN_INTEGER
		}
	}
	skip := init > p if step > 0 else init < p
	return p, skip
}

// Prepare a numerical `for` -- reference Lua's `forprep`. Returns true to skip the
// loop entirely. On an integer loop it rewrites the three control slots into
// (count, step, index); on a float loop it makes all three floats.
@(private = "file")
forprep :: proc(L: ^Lua_State, ra: int) -> bool {
	pinit := stack_value(L, ra)
	plimit := stack_value(L, ra + 1)
	pstep := stack_value(L, ra + 2)
	if is_integer(pinit) && is_integer(pstep) { // integer loop
		init := int_value(pinit)
		step := int_value(pstep)
		if step == 0 {
			luaG_runerror(L, "'for' step is zero")
		}
		limit, skip := forlimit(L, init, plimit, step)
		if skip {
			return true
		}
		count: u64
		if step > 0 { // ascending
			count = s2u(limit) - s2u(init)
			if step != 1 {
				count /= s2u(step)
			}
		} else { // descending; 'step+1' dodges negating MIN_INTEGER
			count = s2u(init) - s2u(limit)
			count /= s2u(int_neg(step + 1)) + 1
		}
		set_int(stack_value(L, ra), u2s(count)) // init  -> loop counter
		set_int(stack_value(L, ra + 1), step) // limit -> step
		set_int(stack_value(L, ra + 2), init) // step  -> control variable
	} else { // float loop: coerce all three to floats
		init, oki := vm_tonumber(pinit)
		limit, okl := vm_tonumber(plimit)
		step, oks := vm_tonumber(pstep)
		if !okl {
			luaG_forerror(L, plimit, "limit")
		}
		if !oks {
			luaG_forerror(L, pstep, "step")
		}
		if !oki {
			luaG_forerror(L, pinit, "initial value")
		}
		if step == 0 {
			luaG_runerror(L, "'for' step is zero")
		}
		skip := limit < init if 0 < step else init < limit
		if skip {
			return true
		}
		set_float(stack_value(L, ra), limit)
		set_float(stack_value(L, ra + 1), step)
		set_float(stack_value(L, ra + 2), init) // control variable
	}
	return false
}

// One step of a float `for` loop -- reference Lua's `floatforloop`. Returns true
// (and updates the control variable) if the loop should continue.
@(private = "file")
floatforloop :: proc(L: ^Lua_State, ra: int) -> bool {
	step := flt_value(stack_value(L, ra + 1))
	limit := flt_value(stack_value(L, ra))
	idx := flt_value(stack_value(L, ra + 2)) + step
	cont := idx <= limit if 0 < step else limit <= idx
	if cont {
		set_float(stack_value(L, ra + 2), idx)
		return true
	}
	return false
}

// Arithmetic shared by the register/immediate/K opcodes: fold `v1 op v2` into
// `R[ra]` if both are numeric, reporting the `raw_arith` status so the caller can
// skip the following MMBIN* (on Ok) or let it run (on No_Number).
@(private = "file")
vm_arith :: proc(L: ^Lua_State, ra: int, v1, v2: ^TValue, op: Arith_Op) -> Arith_Status {
	res, st := raw_arith(op, v1, v2)
	if st == .Ok {
		set_obj(stack_value(L, ra), &res)
	}
	return st
}

// ---------------------------------------------------------------------------
// The interpreter loop
// ---------------------------------------------------------------------------

luaV_execute :: proc(L: ^Lua_State, ci_idx_in: int) {
	ci_idx := ci_idx_in

	// Each iteration of `newframe` (re)loads the per-frame locals for the frame
	// currently at `ci_idx` -- reference Lua's `startfunc`/`returning` labels.
	newframe: for {
		cl := ci_func(L, &L.frames[ci_idx])
		k := cl.p.k
		code := cl.p.code
		base := L.frames[ci_idx].func + 1 // stack index of R[0]
		pc := L.frames[ci_idx].u.l.savedpc
		trap := L.frames[ci_idx].u.l.trap // nonzero while tracing lines/counts
		// Reference Lua's `startfunc`/`returning` initialize `trap` from
		// `L->hookmask` on every frame (re)entry, so a hook installed *before* this
		// frame began executing still takes effect. `settraps` covers the inverse
		// case (a hook installed while this frame is already the running one).
		if L.hookmask & (LUA_MASKLINE | LUA_MASKCOUNT) != 0 {
			trap = 1
		}

		// The dispatch loop. `pc` indexes `code`; `savedpc` is synced from `pc`
		// before anything that can raise (so error line info is correct) and
		// before every frame switch (so the caller resumes correctly).
		for {
			// Hook trap: when a line/count hook is installed this frame is marked
			// trapping, and we consult `luaG_traceexec` before each instruction.
			// In the common (no-hook) case `trap` is 0 and this costs one branch.
			if trap != 0 {
				L.frames[ci_idx].u.l.savedpc = pc
				trap = luaG_traceexec(L, pc)
				base = L.frames[ci_idx].func + 1 // reference `updatebase` (no-op in the index model)
			}
			i := code[pc]
			pc += 1
			switch get_opcode(i) {

			case .MOVE:
				set_obj(stack_value(L, base + getarg_A(i)), stack_value(L, base + getarg_B(i)))

			case .LOADI:
				set_int(stack_value(L, base + getarg_A(i)), Integer(getarg_sBx(i)))

			case .LOADF:
				set_float(stack_value(L, base + getarg_A(i)), Number(getarg_sBx(i)))

			case .LOADK:
				set_obj(stack_value(L, base + getarg_A(i)), &k[getarg_Bx(i)])

			case .LOADKX:
				set_obj(stack_value(L, base + getarg_A(i)), &k[getarg_Ax(code[pc])])
				pc += 1

			case .LOADFALSE:
				set_bool(stack_value(L, base + getarg_A(i)), false)

			case .LFALSESKIP:
				set_bool(stack_value(L, base + getarg_A(i)), false)
				pc += 1 // skip the next instruction (a LOADTRUE)

			case .LOADTRUE:
				set_bool(stack_value(L, base + getarg_A(i)), true)

			case .LOADNIL:
				ra := base + getarg_A(i)
				b := getarg_B(i)
				for j := 0; j <= b; j += 1 {
					set_nil(stack_value(L, ra + j))
				}

			case .GETUPVAL:
				ra := base + getarg_A(i)
				set_obj(stack_value(L, ra), upval_value(cl.upvals[getarg_B(i)]))

			case .SETUPVAL:
				ra := base + getarg_A(i)
				uv := cl.upvals[getarg_B(i)]
				set_obj(upval_value(uv), stack_value(L, ra))
				rav := stack_value(L, ra)
				if is_collectable(rav) {
					luaC_barrier(L, &uv.header, rav.value_.gc)
				}

			case .GETTABUP:
				ra := base + getarg_A(i)
				upval := upval_value(cl.upvals[getarg_B(i)])
				rc := &k[getarg_C(i)]
				vm_gettable(L, ci_idx, pc, upval, rc, ra)

			case .GETTABLE:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := stack_value(L, base + getarg_C(i))
				vm_gettable(L, ci_idx, pc, rb, rc, ra)

			case .GETI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				c := getarg_C(i)
				key: TValue
				set_int(&key, Integer(c))
				vm_gettable(L, ci_idx, pc, rb, &key, ra)

			case .GETFIELD:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := &k[getarg_C(i)]
				vm_gettable(L, ci_idx, pc, rb, rc, ra)

			case .SETTABUP:
				upval := upval_value(cl.upvals[getarg_A(i)])
				rb := &k[getarg_B(i)]
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, pc, upval, rb, rc)

			case .SETTABLE:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, pc, ra, rb, rc)

			case .SETI:
				ra := stack_value(L, base + getarg_A(i))
				key: TValue
				set_int(&key, Integer(getarg_B(i)))
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, pc, ra, &key, rc)

			case .SETFIELD:
				ra := stack_value(L, base + getarg_A(i))
				rb := &k[getarg_B(i)]
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, pc, ra, rb, rc)

			case .NEWTABLE:
				ra := base + getarg_A(i)
				b := u32(getarg_vB(i))
				c := u32(getarg_vC(i))
				if b > 0 {
					b = u32(1) << (b - 1) // hash size is 2^(b-1)
				}
				if testarg_k(i) != 0 {
					c += u32(getarg_Ax(code[pc])) * u32(MAXARG_vC + 1)
				}
				pc += 1 // skip the EXTRAARG
				L.top = ra + 1 // correct top in case allocation triggers a GC
				t := luaH_new(L)
				set_table(stack_value(L, ra), t)
				if b != 0 || c != 0 {
					luaH_resize(L, t, c, b)
				}
				luaC_checkGC(L) // pace the collector (table anchored at ra)

			case .SELF:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := &k[getarg_C(i)]
				set_obj(stack_value(L, ra + 1), rb) // R[A+1] := object
				vm_gettable(L, ci_idx, pc, rb, rc, ra) // R[A] := object[method]

			case .ADDI:
				ra := base + getarg_A(i)
				v1 := stack_value(L, base + getarg_B(i))
				aux: TValue
				set_int(&aux, Integer(getarg_sC(i)))
				if vm_arith(L, ra, v1, &aux, .Add) == .Ok {
					pc += 1
				}

			case .ADDK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Add) == .Ok {
					pc += 1
				}
			case .SUBK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Sub) == .Ok {
					pc += 1
				}
			case .MULK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Mul) == .Ok {
					pc += 1
				}
			case .MODK:
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				st := vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Mod)
				if st == .Ok {
					pc += 1
				} else if st == .Div_By_Zero {
					luaG_runerror(L, "attempt to perform 'n%%0'")
				}
			case .POWK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Pow) == .Ok {
					pc += 1
				}
			case .DIVK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Div) == .Ok {
					pc += 1
				}
			case .IDIVK:
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				st := vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .IDiv)
				if st == .Ok {
					pc += 1
				} else if st == .Div_By_Zero {
					luaG_runerror(L, "attempt to divide by zero")
				}
			case .BANDK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Band) == .Ok {
					pc += 1
				}
			case .BORK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Bor) == .Ok {
					pc += 1
				}
			case .BXORK:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), &k[getarg_C(i)], .Bxor) == .Ok {
					pc += 1
				}

			case .SHLI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				ic := getarg_sC(i)
				if ib, ok := to_integer_no_string(rb, .Eq); ok {
					pc += 1
					set_int(stack_value(L, ra), vm_shiftl(Integer(ic), ib))
				}
			case .SHRI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				ic := getarg_sC(i)
				if ib, ok := to_integer_no_string(rb, .Eq); ok {
					pc += 1
					set_int(stack_value(L, ra), vm_shiftl(ib, -Integer(ic)))
				}

			case .ADD:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Add) == .Ok {
					pc += 1
				}
			case .SUB:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Sub) == .Ok {
					pc += 1
				}
			case .MUL:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Mul) == .Ok {
					pc += 1
				}
			case .MOD:
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				st := vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Mod)
				if st == .Ok {
					pc += 1
				} else if st == .Div_By_Zero {
					luaG_runerror(L, "attempt to perform 'n%%0'")
				}
			case .POW:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Pow) == .Ok {
					pc += 1
				}
			case .DIV:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Div) == .Ok {
					pc += 1
				}
			case .IDIV:
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				st := vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .IDiv)
				if st == .Ok {
					pc += 1
				} else if st == .Div_By_Zero {
					luaG_runerror(L, "attempt to divide by zero")
				}
			case .BAND:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Band) == .Ok {
					pc += 1
				}
			case .BOR:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Bor) == .Ok {
					pc += 1
				}
			case .BXOR:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Bxor) == .Ok {
					pc += 1
				}
			case .SHL:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Shl) == .Ok {
					pc += 1
				}
			case .SHR:
				if vm_arith(L, base + getarg_A(i), stack_value(L, base + getarg_B(i)), stack_value(L, base + getarg_C(i)), .Shr) == .Ok {
					pc += 1
				}

			case .MMBIN:
				ra := stack_value(L, base + getarg_A(i))
				pi := code[pc - 2] // the original arithmetic instruction
				rb := stack_value(L, base + getarg_B(i))
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaT_trybinTM(L, ra, rb, result, getarg_C(i))

			case .MMBINI:
				ra := stack_value(L, base + getarg_A(i))
				pi := code[pc - 2]
				imm := getarg_sB(i)
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaT_trybiniTM(L, ra, Integer(imm), getarg_k(i) != 0, result, getarg_C(i))

			case .MMBINK:
				ra := stack_value(L, base + getarg_A(i))
				pi := code[pc - 2]
				imm := &k[getarg_B(i)]
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaT_trybinassocTM(L, ra, imm, getarg_k(i) != 0, result, getarg_C(i))

			case .UNM:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if vm_arith(L, ra, rb, rb, .Unm) != .Ok {
					L.frames[ci_idx].u.l.savedpc = pc
					L.top = L.frames[ci_idx].top
					luaT_trybinTM(L, rb, rb, ra, TM_UNM)
				}

			case .BNOT:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if vm_arith(L, ra, rb, rb, .Bnot) != .Ok {
					L.frames[ci_idx].u.l.savedpc = pc
					L.top = L.frames[ci_idx].top
					luaT_trybinTM(L, rb, rb, ra, TM_BNOT)
				}

			case .NOT:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				set_bool(stack_value(L, ra), is_false(rb))

			case .LEN:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaV_objlen(L, ra, stack_value(L, base + getarg_B(i)))

			case .CONCAT:
				ra := base + getarg_A(i)
				n := getarg_B(i)
				L.top = ra + n // mark the end of the operand run
				L.frames[ci_idx].u.l.savedpc = pc
				luaV_concat(L, n)
				L.top = ra + 1 // result at ra; anchor it for the GC
				luaC_checkGC(L)

			case .CLOSE:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaF_close(L, ra, int(Thread_Status.Ok), true)

			case .TBC:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = pc
				luaF_newtbcupval(L, ra)

			case .JMP:
				pc += getarg_sJ(i)

			case .EQ:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				cond := luaV_equalobj(L, ra, rb)
				pc = docondjump(code, pc, i, cond)

			case .LT:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				cond: bool
				if is_integer(ra) && is_integer(rb) {
					cond = int_value(ra) < int_value(rb)
				} else if is_number(ra) && is_number(rb) {
					cond = LTnum(ra, rb)
				} else {
					L.frames[ci_idx].u.l.savedpc = pc
					L.top = L.frames[ci_idx].top
					cond = lessthanothers(L, ra, rb)
				}
				pc = docondjump(code, pc, i, cond)

			case .LE:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				cond: bool
				if is_integer(ra) && is_integer(rb) {
					cond = int_value(ra) <= int_value(rb)
				} else if is_number(ra) && is_number(rb) {
					cond = LEnum(ra, rb)
				} else {
					L.frames[ci_idx].u.l.savedpc = pc
					L.top = L.frames[ci_idx].top
					cond = lessequalothers(L, ra, rb)
				}
				pc = docondjump(code, pc, i, cond)

			case .EQK:
				ra := stack_value(L, base + getarg_A(i))
				rb := &k[getarg_B(i)]
				pc = docondjump(code, pc, i, raw_equal(ra, rb))

			case .EQI:
				ra := stack_value(L, base + getarg_A(i))
				im := getarg_sB(i)
				cond: bool
				if is_integer(ra) {
					cond = int_value(ra) == Integer(im)
				} else if is_float(ra) {
					cond = flt_value(ra) == Number(im)
				}
				pc = docondjump(code, pc, i, cond)

			case .LTI:
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Lt)
			case .LEI:
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Le)
			case .GTI:
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Gt)
			case .GEI:
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Ge)

			case .TEST:
				ra := stack_value(L, base + getarg_A(i))
				pc = docondjump(code, pc, i, !is_falsy(ra))

			case .TESTSET:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if is_falsy(rb) == (getarg_k(i) != 0) {
					pc += 1
				} else {
					set_obj(stack_value(L, ra), rb)
					ni := code[pc]
					pc += getarg_sJ(ni) + 1
				}

			case .CALL:
				ra := base + getarg_A(i)
				b := getarg_B(i)
				nresults := getarg_C(i) - 1
				if b != 0 {
					L.top = ra + b // fixed arg count
				}
				L.frames[ci_idx].u.l.savedpc = pc
				newci := luaD_precall(L, ra, nresults)
				if newci >= 0 { // Lua callee: run it in this same trampoline
					ci_idx = newci
					continue newframe
				}
				// C callee: already executed by precall; keep going.

			case .TAILCALL:
				ra := base + getarg_A(i)
				b := getarg_B(i)
				nparams1 := getarg_C(i)
				delta := 0
				if nparams1 != 0 {
					delta = L.frames[ci_idx].u.l.nextraargs + nparams1
				}
				if b != 0 {
					L.top = ra + b
				} else {
					b = L.top - ra
				}
				L.frames[ci_idx].u.l.savedpc = pc
				if testarg_k(i) != 0 {
					luaF_closeupval(L, base) // close any open upvalues
				}
				n := luaD_pretailcall(L, ci_idx, ra, b, delta)
				if n < 0 { // Lua callee: reuses this frame; run it
					continue newframe
				}
				// C callee: finish and return through the tail.
				L.frames[ci_idx].func -= delta
				luaD_poscall(L, ci_idx, n)
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN:
				ra := base + getarg_A(i)
				n := getarg_B(i) - 1
				nparams1 := getarg_C(i)
				if n < 0 {
					n = L.top - ra // variable results: take what's on the stack
				}
				L.frames[ci_idx].u.l.savedpc = pc
				if testarg_k(i) != 0 { // there may be open upvalues / tbc vars
					L.frames[ci_idx].u2 = n
					if L.top < L.frames[ci_idx].top {
						L.top = L.frames[ci_idx].top
					}
					luaF_close(L, base, CLOSEKTOP, true)
				}
				if nparams1 != 0 { // vararg function: restore real func slot
					L.frames[ci_idx].func -= L.frames[ci_idx].u.l.nextraargs + nparams1
				}
				L.top = ra + n
				luaD_poscall(L, ci_idx, n)
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN0:
				if L.hookmask != 0 {
					ra := base + getarg_A(i)
					L.top = ra
					L.frames[ci_idx].u.l.savedpc = pc
					luaD_poscall(L, ci_idx, 0)
				} else {
					nres := get_nresults(L.frames[ci_idx].callstatus)
					L.ci = ci_idx - 1
					L.nci = ci_idx
					L.top = base - 1
					for nres > 0 {
						set_nil(stack_value(L, L.top))
						L.top += 1
						nres -= 1
					}
				}
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN1:
				if L.hookmask != 0 {
					ra := base + getarg_A(i)
					L.top = ra + 1
					L.frames[ci_idx].u.l.savedpc = pc
					luaD_poscall(L, ci_idx, 1)
				} else {
					nres := get_nresults(L.frames[ci_idx].callstatus)
					L.ci = ci_idx - 1
					L.nci = ci_idx
					if nres == 0 {
						L.top = base - 1
					} else {
						set_obj(stack_value(L, base - 1), stack_value(L, base + getarg_A(i)))
						L.top = base
						for nres > 1 {
							set_nil(stack_value(L, L.top))
							L.top += 1
							nres -= 1
						}
					}
				}
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .FORLOOP:
				ra := base + getarg_A(i)
				if is_integer(stack_value(L, ra + 1)) { // integer loop
					count := s2u(int_value(stack_value(L, ra)))
					if count > 0 {
						step := int_value(stack_value(L, ra + 1))
						idx := int_value(stack_value(L, ra + 2))
						set_int(stack_value(L, ra), u2s(count - 1)) // decrement counter
						set_int(stack_value(L, ra + 2), int_add(idx, step)) // advance control
						pc -= getarg_Bx(i) // jump back
					}
				} else if floatforloop(L, ra) { // float loop
					pc -= getarg_Bx(i)
				}

			case .FORPREP:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				if forprep(L, ra) {
					pc += getarg_Bx(i) + 1 // skip the loop body entirely
				}

			case .TFORPREP:
				ra := base + getarg_A(i)
				// Swap control (ra+2) and closing (ra+3) variables, then mark the
				// closing variable to-be-closed.
				temp: TValue
				set_obj(&temp, stack_value(L, ra + 3))
				set_obj(stack_value(L, ra + 3), stack_value(L, ra + 2))
				set_obj(stack_value(L, ra + 2), &temp)
				L.frames[ci_idx].u.l.savedpc = pc
				luaF_newtbcupval(L, ra + 2)
				pc += getarg_Bx(i) // fall through to the TFORCALL at the loop end

			case .TFORCALL:
				ra := base + getarg_A(i)
				set_obj(stack_value(L, ra + 5), stack_value(L, ra + 3)) // control var
				set_obj(stack_value(L, ra + 4), stack_value(L, ra + 1)) // state
				set_obj(stack_value(L, ra + 3), stack_value(L, ra)) // iterator func
				L.top = ra + 3 + 3
				L.frames[ci_idx].u.l.savedpc = pc
				luaD_call(L, ra + 3, getarg_C(i)) // runs to completion
				// The following TFORLOOP is fetched normally next iteration.

			case .TFORLOOP:
				ra := base + getarg_A(i)
				if !is_nil(stack_value(L, ra + 3)) { // control var not nil: continue
					pc -= getarg_Bx(i)
				}

			case .SETLIST:
				ra := base + getarg_A(i)
				n := u32(getarg_vB(i))
				last := u32(getarg_vC(i))
				h := (^Table)(stack_value(L, ra).value_.gc)
				if n == 0 {
					n = u32(L.top - ra) - 1 // up to the top
				} else {
					L.top = L.frames[ci_idx].top // correct top for a possible GC
				}
				last += n
				if testarg_k(i) != 0 {
					last += u32(getarg_Ax(code[pc])) * u32(MAXARG_vC + 1)
					pc += 1
				}
				if last > h.asize {
					luaH_resizearray(L, h, last)
				}
				for n > 0 {
					val := stack_value(L, ra + int(n))
					set_obj(&h.array[last - 1], val)
					last -= 1
					if is_collectable(val) {
						luaC_barrierback(L, &h.header)
					}
					n -= 1
				}

			case .CLOSURE:
				ra := base + getarg_A(i)
				p := cl.p.p[getarg_Bx(i)]
				L.frames[ci_idx].u.l.savedpc = pc
				pushclosure(L, p, cl.upvals, base, ra)
				L.top = ra + 1 // closure at ra; anchor it for the GC
				luaC_checkGC(L)

			case .VARARG:
				ra := base + getarg_A(i)
				n := getarg_C(i) - 1
				vatab := getarg_B(i) if getarg_k(i) != 0 else -1
				L.frames[ci_idx].u.l.savedpc = pc
				L.top = L.frames[ci_idx].top
				luaT_getvarargs(L, ci_idx, ra, n, vatab)

			case .GETVARG:
				ra := base + getarg_A(i)
				rc := stack_value(L, base + getarg_C(i))
				luaT_getvararg(L, ci_idx, ra, rc)

			case .ERRNNIL:
				ra := stack_value(L, base + getarg_A(i))
				if !is_nil(ra) {
					L.frames[ci_idx].u.l.savedpc = pc
					luaG_errnnil(L, cl, getarg_Bx(i))
				}

			case .VARARGPREP:
				L.frames[ci_idx].u.l.savedpc = pc
				luaT_adjustvarargs(L, ci_idx, cl.p)
				base = L.frames[ci_idx].func + 1 // function has a new base now

			case .EXTRAARG:
				// Always consumed as the operand of a preceding opcode; reaching it
				// on its own is a compiler bug.
				luaG_runerror(L, "internal error: stray EXTRAARG")
			}
		}
	}
}

// Which immediate order comparison an OP_*I opcode performs.
@(private = "file")
Order_I :: enum {
	Lt,
	Le,
	Gt,
	Ge,
}

// The OP_LTI/LEI/GTI/GEI family -- reference Lua's `op_orderI`. Compares R[A]
// against a small immediate that always has an exact float representation, using a
// metamethod when R[A] isn't a number. Returns the updated `pc`.
@(private = "file")
vm_orderI :: proc(L: ^Lua_State, ci_idx: int, code: [^]Instruction, pc_in: int, base: int, i: Instruction, kind: Order_I) -> int {
	pc := pc_in
	ra := stack_value(L, base + getarg_A(i))
	im := getarg_sB(i)
	cond: bool
	if is_integer(ra) {
		ia := int_value(ra)
		ib := Integer(im)
		switch kind {
		case .Lt:
			cond = ia < ib
		case .Le:
			cond = ia <= ib
		case .Gt:
			cond = ia > ib
		case .Ge:
			cond = ia >= ib
		}
	} else if is_float(ra) {
		fa := flt_value(ra)
		fim := Number(im)
		switch kind {
		case .Lt:
			cond = fa < fim
		case .Le:
			cond = fa <= fim
		case .Gt:
			cond = fa > fim
		case .Ge:
			cond = fa >= fim
		}
	} else {
		// Metamethod path. GTI/GEI flip operands and reuse __lt/__le.
		event := TM_LT
		flip := false
		#partial switch kind {
		case .Le:
			event = TM_LE
		case .Gt:
			event = TM_LT
			flip = true
		case .Ge:
			event = TM_LE
			flip = true
		}
		isf := getarg_C(i) != 0
		L.frames[ci_idx].u.l.savedpc = pc
		L.top = L.frames[ci_idx].top
		cond = luaT_callorderiTM(L, ra, im, flip, isf, event) > 0
	}
	return docondjump(code, pc, i, cond)
}

// A register-or-constant C operand -- reference Lua's `RKC(i)`. The `k` bit picks
// between the constant table and the register file.
@(private = "file")
vm_rkc :: proc(L: ^Lua_State, base: int, k: [^]TValue, i: Instruction) -> ^TValue {
	if testarg_k(i) != 0 {
		return &k[getarg_C(i)]
	}
	return stack_value(L, base + getarg_C(i))
}

// Perform a conditional jump -- reference Lua's `docondjump`. If `cond` matches the
// instruction's `k` bit, take the following JMP; otherwise skip it. Returns the
// updated `pc`.
@(private = "file")
docondjump :: proc "contextless" (code: [^]Instruction, pc: int, i: Instruction, cond: bool) -> int {
	if cond != (getarg_k(i) != 0) {
		return pc + 1 // condition failed: skip the jump
	}
	ni := code[pc] // the JMP that follows
	return pc + getarg_sJ(ni) + 1
}

// Finish an opcode interrupted by a yield -- reference Lua's `luaV_finishOp`. The
// coroutine machinery calls this on resume to complete the operation whose
// metamethod yielded. (The set of resumable opcodes is exactly those that call a
// metamethod through the ordinary call protocol.)
luaV_finishOp :: proc(L: ^Lua_State) {
	ci_idx := L.ci
	base := L.frames[ci_idx].func + 1
	savedpc := L.frames[ci_idx].u.l.savedpc
	cl := ci_func(L, &L.frames[ci_idx])
	code := cl.p.code
	inst := code[savedpc - 1] // the interrupted instruction
	#partial switch get_opcode(inst) {
	case .MMBIN, .MMBINI, .MMBINK:
		// Result register comes from the arithmetic op two instructions back.
		L.top -= 1
		set_obj(stack_value(L, base + getarg_A(code[savedpc - 2])), stack_value(L, L.top))
	case .UNM, .BNOT, .LEN, .GETTABUP, .GETTABLE, .GETI, .GETFIELD, .SELF:
		L.top -= 1
		set_obj(stack_value(L, base + getarg_A(inst)), stack_value(L, L.top))
	case .LT, .LE, .LTI, .LEI, .GTI, .GEI, .EQ:
		res := is_true(stack_value(L, L.top - 1))
		L.top -= 1
		if res != (getarg_k(inst) != 0) {
			L.frames[ci_idx].u.l.savedpc += 1 // condition failed: skip the JMP
		}
	case .CONCAT:
		top := L.top - 1
		a := getarg_A(inst)
		total := top - 1 - (base + a)
		set_obj(stack_value(L, top - 2), stack_value(L, top))
		L.top = top - 1
		luaV_concat(L, total)
	case .CLOSE:
		L.frames[ci_idx].u.l.savedpc -= 1 // repeat to close remaining variables
	case .RETURN:
		ra := base + getarg_A(inst)
		L.top = ra + L.frames[ci_idx].u2
		L.frames[ci_idx].u.l.savedpc -= 1 // repeat to finish the return
	case:
		// The remaining yieldable opcodes (calls, sets) need no fixup.
	}
}
