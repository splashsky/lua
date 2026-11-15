package kernel
import "base:intrinsics"
import "base:runtime"
// vm.odin -- our analogue of reference Lua's `lvm.h` / `lvm.c`.
//
// The interpreter itself: the loop that decodes and executes bytecode. Unlike a
// naive port, ours is a *trampoline* over the explicit frame stack rather than a
// recursive walk of the native call stack. Frame transitions stay in the loop;
// errors and yields unwind through the protected longjmp boundary. That is what
// makes faithful coroutines and pcall/error possible in Odin (Decision 2).
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

// The reserved dispatch cases below cover NUM_OPCODES through 2^SIZE_OP - 1.
#assert(NUM_OPCODES == 85 && SIZE_OP == 7)

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
	// str_to_number reports the count INCLUDING the implicit trailing '\0'
	// (mirroring reference luaO_str2num), so a full parse consumes len(s)+1.
	return v, sz == uint(len(s)) + 1
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
lessthanothers :: proc(L: ^State, l, r: ^TValue) -> bool {
	if base_type(l) == TSTRING && base_type(r) == TSTRING {
		return l_strcmp(str_value(l), str_value(r)) < 0
	}
	return tm_callorderTM(L, l, r, TM_LT) > 0
}

// `l <= r` when at least one operand isn't a number -- reference `lessequalothers`.
@(private = "file")
lessequalothers :: proc(L: ^State, l, r: ^TValue) -> bool {
	if base_type(l) == TSTRING && base_type(r) == TSTRING {
		return l_strcmp(str_value(l), str_value(r)) <= 0
	}
	return tm_callorderTM(L, l, r, TM_LE) > 0
}

// Full `l < r` -- reference Lua's `luaV_lessthan`.
vm_lessthan :: proc(L: ^State, l, r: ^TValue) -> bool {
	if is_number(l) && is_number(r) {
		return LTnum(l, r)
	}
	return lessthanothers(L, l, r)
}

// Full `l <= r` -- reference Lua's `luaV_lessequal`.
vm_lessequal :: proc(L: ^State, l, r: ^TValue) -> bool {
	if is_number(l) && is_number(r) {
		return LEnum(l, r)
	}
	return lessequalothers(L, l, r)
}

// Full value equality, consulting `__eq` for tables/userdata -- reference Lua's
// `luaV_equalobj`. The raw, metamethod-free half is delegated to `raw_equal`
// (object.odin); only the table/userdata case can fall through to a metamethod.
// This small helper is on the interpreter's hottest path, and forcing it inline
// measurably improves primitive equality. The arithmetic helpers lost about 30%
// when growth of a large source file changed optimiser decisions, so this
// directive likewise records a measured requirement, not a stylistic preference.
vm_equalobj :: #force_inline proc(L: ^State, t1, t2: ^TValue) -> bool {
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
	tm_callTMres(L, tm, t1, t2, L.top)
	// `__eq`'s result is truthy unless nil or false (reference `!l_isfalse`).
	return !is_falsy(stack_value(L, L.top))
}

// ---------------------------------------------------------------------------
// Metatable fast-access
// ---------------------------------------------------------------------------

// Fetch a fast-access metamethod (`__index`/`__newindex`/`__len`/`__eq`) from a
// metatable, honoring the absence cache -- reference Lua's `fasttm`. Returns nil
// when there is no metatable or the event is cached-absent or genuinely missing.
@(private = "file")
fasttm :: proc(L: ^State, mt: ^Table, event: int) -> ^TValue {
	if mt == nil {
		return nil
	}
	if (mt.flags & Byte(u32(1) << u32(event))) != 0 { // cached as absent
		return nil
	}
	return tm_gettm(mt, event, L.g.tmname[event])
}

// ---------------------------------------------------------------------------
// Indexed access with metamethod fallback
// ---------------------------------------------------------------------------

// Finish `R[val] = t[key]` after the fast path missed -- reference Lua's
// `luaV_finishget`. Gets return the tag separately and materialise a value only
// on a hit, because the array's tags and payloads are about to be non-contiguous.
// Walk the `__index` chain, calling a function metamethod or continuing into a
// table.
vm_finishget :: proc(L: ^State, t_in: ^TValue, key: ^TValue, val: int) {
	t := t_in
	is_tab := base_type(t) == TTABLE
	for _ in 0 ..< MAXTAGLOOP {
		tm: ^TValue
		if !is_tab {
			tm = tm_gettmbyobj(L, t, TM_INDEX)
			if is_nil(tm) {
				debug_typeerror(L, t, "index") // no metamethod: hard error
			}
		} else {
			tm = fasttm(L, (^Table)(t.value_.gc).metatable, TM_INDEX)
			if tm == nil { // table, no __index: result is nil
				set_nil(stack_value(L, val))
				return
			}
		}
		if is_function_val(tm) { // __index is a function: call it
			tm_callTMres(L, tm, t, key, val)
			return
		}
		t = tm // __index is a table (or object): access t[key] next
		if base_type(t) == TTABLE {
			is_tab = true
			tag := table_get((^Table)(t.value_.gc), key, stack_value(L, val))
			if !tag_is_empty(tag) {
				return
			}
			// else empty: loop to consult this table's own __index
		} else {
			is_tab = false
		}
	}
	debug_runerror(L, "'__index' chain too long; possible loop")
}

// The VM's table read: `R[ra] = t[key]` -- the fast path plus `luaV_finishget`.
@(private = "file")
vm_gettable :: proc(
	L: ^State,
	ci_idx: int,
	pc: int,
	t: ^TValue,
	key: ^TValue,
	ra: int,
) {
	if base_type(t) == TTABLE {
		h := (^Table)(t.value_.gc)
		tag: Byte
		if is_integer(key) {
			tag = table_fastgeti(h, int_value(key), stack_value(L, ra))
		} else {
			tag = table_fastget(h, key, stack_value(L, ra))
		}
		if !tag_is_empty(tag) {
			return
		}
	}
	// Miss (empty slot or non-table): metamethod path. savestate for error line.
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	vm_finishget(L, t, key, ra)
}

// OP_GETI already carries an integer in the instruction, so do not manufacture
// a TValue and route it through the generic helper on every hit. This is the
// direct counterpart of reference's `luaV_fastgeti` macro: the array tag read is
// inlined into the interpreter loop, while only misses build a key for
// `luaV_finishget`.
@(private = "file")
vm_geti :: #force_inline proc(
	L: ^State,
	ci_idx: int,
	pc: int,
	t: ^TValue,
	key: Integer,
	ra: int,
) {
	tag := Byte(VNOTABLE)
	if base_type(t) == TTABLE {
		tag = table_fastgeti((^Table)(t.value_.gc), key, stack_value(L, ra))
		if !tag_is_empty(tag) {
			return
		}
	}
	key_value: TValue
	set_int(&key_value, key)
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	vm_finishget(L, t, &key_value, ra)
}

// Finish `t[key] = val` after a pre-set could not complete. `hres` identifies an
// absent key, a deleted hash node, or an empty array index without exposing a
// writable array TValue. This mirrors reference Lua's pset/finishset protocol.
vm_finishset :: proc(
	L: ^State,
	t_in: ^TValue,
	key: ^TValue,
	val: ^TValue,
	hres_in: int,
) {
	t := t_in
	hres := hres_in
	for _ in 0 ..< MAXTAGLOOP {
		if hres != HNOTATABLE {
			h := (^Table)(t.value_.gc)
			tm := fasttm(L, h.metatable, TM_NEWINDEX)
			if tm == nil { // absent, no __newindex: raw insert
				table_finishset(L, h, key, val, hres)
				invalidateTMcache(h)
				if is_collectable(val) {
					gc_barrierback(L, obj2gco(h))
				}
				return
			}
			if is_function_val(tm) { // __newindex is a function: call it
				tm_callTM(L, tm, t, key, val)
				return
			}
			t = tm // __newindex is a table: repeat assignment over it
		} else {
			tm := tm_gettmbyobj(L, t, TM_NEWINDEX)
			if is_nil(tm) {
				debug_typeerror(L, t, "index")
			}
			if is_function_val(tm) {
				tm_callTM(L, tm, t, key, val)
				return
			}
			t = tm
		}
		if base_type(t) == TTABLE {
			h := (^Table)(t.value_.gc)
			hres = table_pset(h, key, val)
			if hres == HOK {
				if is_collectable(val) {
					gc_barrierback(L, obj2gco(h))
				}
				return
			}
		} else {
			hres = HNOTATABLE
		}
	}
	debug_runerror(L, "'__newindex' chain too long; possible loop")
}

// The VM's table write: `t[key] = val` -- the fast path plus `luaV_finishset`.
// `hres` starts at HNOTATABLE so the non-table case and the failed-fast-path case
// share one tail instead of spelling the save-and-finish sequence out twice.
@(private)
vm_settable :: proc(
	L: ^State,
	ci_idx: int,
	pc: int,
	t: ^TValue,
	key: ^TValue,
	val: ^TValue,
) {
	hres := HNOTATABLE
	if base_type(t) == TTABLE {
		h := (^Table)(t.value_.gc)
		if is_integer(key) {
			hres = table_fastseti(h, int_value(key), val)
		} else {
			hres = table_fastpset(h, key, val)
		}
		if hres == HOK {
			if is_collectable(val) {
				gc_barrierback(L, obj2gco(h))
			}
			return
		}
	}
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	vm_finishset(L, t, key, val, hres)
}

// OP_SETI gets the same treatment as OP_GETI. Reference expands fastseti at the
// opcode, and keeping that shape here avoids a temporary key and a generic
// dispatch on every successful array write.
@(private = "file")
vm_seti :: #force_inline proc(
	L: ^State,
	ci_idx: int,
	pc: int,
	t: ^TValue,
	key: Integer,
	val: ^TValue,
) {
	hres := HNOTATABLE
	if base_type(t) == TTABLE {
		h := (^Table)(t.value_.gc)
		hres = table_fastseti(h, key, val)
		if hres == HOK {
			if is_collectable(val) {
				gc_barrierback(L, obj2gco(h))
			}
			return
		}
	}
	key_value: TValue
	set_int(&key_value, key)
	L.frames[ci_idx].u.l.savedpc = pc
	L.top = L.frames[ci_idx].top
	vm_finishset(L, t, &key_value, val, hres)
}

// ---------------------------------------------------------------------------
// Length, concatenation, number->string
// ---------------------------------------------------------------------------

// `R[ra] = #rb` -- reference Lua's `luaV_objlen`. Strings and metamethod-less
// tables have a primitive length; a `__len` metamethod overrides for tables and
// is the only option for other types.
vm_objlen :: proc(L: ^State, ra: int, rb: ^TValue) {
	tm: ^TValue
	switch type_tag(rb) {
	case VTABLE:
		h := (^Table)(rb.value_.gc)
		tm = fasttm(L, h.metatable, TM_LEN)
		if tm == nil { // no __len: primitive border length
			set_int(stack_value(L, ra), Integer(table_getn(L, h)))
			return
		}
	case VSHRSTR, VLNGSTR:
		set_int(stack_value(L, ra), Integer(str_value(rb).len))
		return
	case:
		tm = tm_gettmbyobj(L, rb, TM_LEN)
		if is_nil(tm) {
			debug_typeerror(L, rb, "get length of")
		}
	}
	tm_callTMres(L, tm, rb, rb, ra)
}

// Convert a number value in place to its string form -- reference Lua's
// `luaO_tostring`. Used by concatenation, which coerces numbers to strings.
@(private = "file")
object_tostring :: proc(L: ^State, o: ^TValue) {
	buf: [N2S_BUFF_SZ]u8
	n := number_to_str(o, buf[:])
	ts := string_newlstr(L, raw_data(buf[:]), uint(n))
	if ts == nil {
		throw(L, .Err_Mem)
	}
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
concat_tostr :: proc(L: ^State, o: ^TValue) -> bool {
	if base_type(o) == TSTRING {
		return true
	}
	if is_number(o) {
		object_tostring(L, o) // fold the number into a string, in place
		return true
	}
	return false
}

// Non-converting sibling of `concat_tostr` -- reference Lua's inline
// `ttisstring(o) || cvt2str(o)` test. `luaV_concat`'s guard must NOT convert the
// LEFT operand before deciding whether to invoke `__concat`: if the right operand
// is not string-able the metamethod fires, and it has to see the left operand in
// its ORIGINAL type (a number stays a number, not a folded string). Only the
// right operand is eagerly converted (via `concat_tostr`).
@(private = "file")
concat_can_str :: proc(o: ^TValue) -> bool {
	return base_type(o) == TSTRING || is_number(o)
}

// Concatenate the top `total` stack values into one -- reference Lua's
// `luaV_concat`. Runs right-to-left, folding runs of coercible values with one
// allocation each, and falling back to `__concat` for anything else.
vm_concat :: proc(L: ^State, total_in: int) {
	total := total_in
	if total == 1 {
		return // a single value is already "concatenated"
	}
	for {
		top := L.top
		n := 2 // values folded this pass (at least the top two)
		if !concat_can_str(stack_value(L, top - 2)) || !concat_tostr(L, stack_value(L, top - 1)) {
			tm_tryconcatTM(L) // a metamethod (may reshape the stack)
		} else if is_empty_str(stack_value(L, top - 1)) {
			// Second operand empty: result is the first operand -- but the guard
			// only CHECKED it, so fold it into a string now (reference does the
			// same `tostring(L, s2v(top-2))` here).
			concat_tostr(L, stack_value(L, top - 2))
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
					debug_runerror(L, "string length overflow")
				}
				tl += l
				n += 1
			}
			ts: ^TString
			if tl <= MAXSHORTLEN { // fold into a short string via a buffer
				buff: [MAXSHORTLEN]u8
				copy_concat_buff(L, top, n, buff[:])
				ts = string_newlstr(L, raw_data(buff[:]), tl)
			} else { // long string: copy directly into the final object
				ts = string_createlngstrobj(L, tl)
				if ts == nil {
					throw(L, .Err_Mem)
				}
				dst := str_bytes(ts)
				copy_concat_buff(L, top, n, dst[:tl])
			}
			if ts == nil {
				throw(L, .Err_Mem)
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
copy_concat_buff :: proc(L: ^State, top: int, n: int, buff: []u8) {
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

// The function slot belongs to the current register base. Resolve the
// non-moving closure's inline vector at the instruction that needs it; `regs`
// is refreshed after any stack move by the VM trap.
@(private = "file")
vm_upvals :: #force_inline proc "contextless" (regs: [^]StackValue) -> [^]^UpVal {
	return closure_upvals((^LClosure)(regs[-1].val.value_.gc))
}

// Create a Lua closure for `p`, anchor it at `ra`, and wire its upvalues --
// reference Lua's `pushclosure`. Keep allocation and error paths out of the
// dispatch loop; the enclosing closure and prototype are non-moving GC objects.
@(private = "file")
pushclosure :: #force_no_inline proc(L: ^State, p: ^Proto, enclosing: ^LClosure, base: int, ra: int) {
	// An emergency collection must see the whole frame while its new closure
	// and upvalues are being constructed.
	L.top = L.frames[L.ci].top
	encup := closure_upvals(enclosing)
	nup := int(p.sizeupvalues)
	uv := p.upvalues
	ncl := func_newLclosure(L, nup)
	if ncl == nil {
		throw(L, .Err_Mem)
	}
	ncl.p = p
	set_lua_closure(stack_value(L, ra), ncl)
	nupvals := closure_upvals(ncl)
	for i in 0 ..< nup {
		if uv[i].instack != 0 {
			nupvals[i] = func_findupval(L, base + int(uv[i].idx))
			if nupvals[i] == nil {
				throw(L, .Err_Mem)
			}
		} else {
			nupvals[i] = encup[uv[i].idx]
		}
		gc_barrier(L, obj2gco(ncl), obj2gco(nupvals[i]))
	}
}

// Convert a `for` limit to an integer, preserving loop semantics -- reference
// Lua's `forlimit`. Returns (limit, skip): `skip` true means the loop must not run.
@(private = "file")
forlimit :: proc(L: ^State, init: Integer, lim: ^TValue, step: Integer) -> (Integer, bool) {
	p, ok := vm_tointeger(lim, .Ceil if step < 0 else .Floor)
	if !ok { // not coercible to an integer: try as a float
		flim, okf := vm_tonumber(lim)
		if !okf {
			debug_forerror(L, lim, "limit")
		}
		if 0 < flim { // positive and out of range: clip high (or skip if descending)
			if step < 0 {
				return 0, true
			}
			p = MAX_INTEGER
		} else if flim < 0 { // negative and out of range: clip low (or skip if ascending)
			if step > 0 {
				return 0, true
			}
			p = MIN_INTEGER
		} else { // NaN: neither positive nor negative
			return 0, true
		}
	}
	skip := init > p if step > 0 else init < p
	return p, skip
}

// Prepare a numerical `for` -- reference Lua's `forprep`. Returns true to skip the
// loop entirely. On an integer loop it rewrites the three control slots into
// (count, step, index); on a float loop it makes all three floats.
@(private = "file")
forprep :: proc(L: ^State, ra: int) -> bool {
	pinit := stack_value(L, ra)
	plimit := stack_value(L, ra + 1)
	pstep := stack_value(L, ra + 2)
	if is_integer(pinit) && is_integer(pstep) { // integer loop
		init := int_value(pinit)
		step := int_value(pstep)
		if step == 0 {
			debug_runerror(L, "'for' step is zero")
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
			debug_forerror(L, plimit, "limit")
		}
		if !oks {
			debug_forerror(L, pstep, "step")
		}
		if !oki {
			debug_forerror(L, pinit, "initial value")
		}
		if step == 0 {
			debug_runerror(L, "'for' step is zero")
		}
		run := init >= limit if 0 >= step else limit >= init
		if !run {
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
floatforloop :: proc(L: ^State, ra: int) -> bool {
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

// Arithmetic shared by the register/immediate/K opcodes: fold `v1 op v2` straight
// into `R[ra]` if both are numeric, reporting the status so the caller can skip
// the following MMBIN* (on Ok) or let it run (on No_Number).
//
// Writing straight into the register is important here. Building a local TValue
// and taking its address makes the compiler spill that temporary to stack memory,
// only for us to reload and copy it into the register. Reference Lua's opcode
// macros avoid that extra round trip, and raw_arith_to gives this interpreter the
// same destination-writing shape without changing the cold API/metamethod paths.
// This tiny helper is on the interpreter's hottest path. Growth of its large
// callee's source file previously made the optimiser stop inlining this chain,
// costing about 30% of arithmetic throughput, so the directive is load-bearing.
@(private = "file")
vm_arith :: #force_inline proc(ra, v1, v2: ^TValue, op: Arith_Op) -> Arith_Status {
	return raw_arith_to(op, v1, v2, ra)
}

// ---------------------------------------------------------------------------
// The interpreter loop
// ---------------------------------------------------------------------------

// Completed prototypes have immutable code, kept alive by their closures. A
// loader reader can also obtain an unfinished closure via the debug API and
// suspend it; compilation can then move its code before that frame resumes.
// The local PC is used only while this VM activation runs. The persistent
// savedpc is an index, so a resumed frame re-derives it from the current code.
// Odin multipointers need these helpers for movement and index conversion.
@(private = "file")
vm_pc_add :: #force_inline proc "contextless" (pc: [^]Instruction, offset: int) -> [^]Instruction {
	// Unsigned arithmetic wraps, so converting a negative instruction offset
	// gives the same address as subtraction without a sign/absolute-value path.
	return ([^]Instruction)(rawptr(uintptr(pc) + uintptr(offset) * size_of(Instruction)))
}

@(private = "file")
vm_pc_index :: #force_inline proc "contextless" (pc, code: [^]Instruction) -> int {
	return int((uintptr(pc) - uintptr(code)) / size_of(Instruction))
}

// The console handler cannot safely touch Lua_State because Windows invokes it
// on another thread. It therefore leaves us a tiny atomic mailbox message, and
// the VM opens that mailbox only at control-flow edges: calls, returns, and loop
// back-edges. Those are the same places where an interrupt becomes observable in
// reference Lua, and every non-terminating Lua loop eventually crosses one.
//
// Please resist the tempting simplification of calling this at the top of the
// dispatch loop. That makes every ordinary bytecode instruction perform an
// atomic load for an event that almost never occurs. Here straight-line code pays
// nothing, while loops and frame transitions pay one atomic load per edge. Only
// a set global hint enters the cold mailbox/exchange and lua_sethook path.
// Freestanding Lua has no console or signal source at all, so the compile-time
// branch reduces `vm_poll_async_hook` to `return trap` and emits no mailbox access.
vm_apply_async_hook :: #force_no_inline proc(L: ^State, trap: i32) -> i32 {
	if api_apply_async_hook(L) {
		return 1
	}
	return trap
}

vm_poll_async_hook :: #force_inline proc(L: ^State, trap: i32) -> i32 {
	when ODIN_OS == .Freestanding {
		return trap
	} else {
		if intrinsics.atomic_load(&async_hook_pending) != 0 {
			return vm_apply_async_hook(L, trap)
		}
		return trap
	}
}

// Only this activation's register base may point into the value stack. Persistent
// stack/frame references remain indices. A call that can move the stack must
// reload the frame's trap before the next fetch, and any register pointer
// needed again within that instruction must be re-derived after the call. Cold
// helpers and top/result bookkeeping still use indices. A frame entry, hook or
// VARARGPREP refreshes the base immediately; other protected calls refresh the
// trap so the next fetch re-derives it before touching any register pointer.
// The VM keeps the frame index, not a frame pointer, across callouts; each frame
// access resolves the current array again after any frame move.
vm_execute :: proc(L: ^State, ci_idx_in: int) {
	when VM_THREADED {
		ctx := context
		_ = vm_thread_enter(L, nil, nil, nil, nil, ci_idx_in, 0, &ctx, 0)
		return
	}
	ci_idx := ci_idx_in

	// Each iteration of `newframe` (re)loads the per-frame locals for the frame
	// currently at `ci_idx` -- reference Lua's `startfunc`/`returning` labels.
	newframe: for {
		base := L.frames[ci_idx].func + 1 // stack index of R[0]
		regs := ([^]StackValue)(&L.stack[base])
		cl := (^LClosure)(regs[-1].val.value_.gc)
		k := cl.p.k
		code := cl.p.code
		pc := vm_pc_add(code, L.frames[ci_idx].u.l.savedpc)
		// Reference Lua's `luaG_tracecall`, inlined at the `startfunc`/`returning`
		// entry. `trap` starts from the hook mask; when any hook is active we arm
		// this frame's `u.l.trap` (so an `updatetrap` after a nested call reloads a
		// 1 and tracing survives the call) and, on a fresh (non-resuming) entry,
		// either suppress trapping until *after* the VARARGPREP instruction (vararg
		// functions) or fire the call hook right away (fixed-arity functions).
		trap: i32 = 0
		if L.hookmask != 0 {
			ci0 := &L.frames[ci_idx]
			ci0.u.l.trap = 1 // ensure hooks keep being checked after nested calls
			trap = 1
			if pc == code { // first instruction of a fresh (non-resuming) call?
				if (cl.p.flag & u8(PF_VAHID | PF_VATAB)) != 0 {
					trap = 0 // hooks begin at the VARARGPREP instruction
				} else if (ci0.callstatus & CIST_HOOKYIELD) == 0 {
					do_hookcall(L, ci_idx) // fire the 'call' hook now
					base = L.frames[ci_idx].func + 1
					regs = ([^]StackValue)(&L.stack[base])
				}
			}
		}

		// The dispatch loop. `pc` walks the code array; `savedpc` is synced as an index
		// before anything that can raise (so error line info is correct) and
		// before every frame switch (so the caller resumes correctly).
		for {
			// Hook trap: when a line/count hook is installed this frame is marked
			// trapping, and we consult `luaG_traceexec` before each instruction.
			// In the common (no-hook) case `trap` is 0 and this costs one branch.
			if trap != 0 {
				// traceexec saves the PC only for a line/count hook; a trap caused
				// solely by relocation must not otherwise change hook state.
				trap = debug_traceexec(L, vm_pc_index(pc, code))
				base = L.frames[ci_idx].func + 1
				regs = ([^]StackValue)(&L.stack[base]) // reference `updatebase`
			}
			i := pc[0]
			pc = vm_pc_add(pc, 1)
			switch get_opcode(i) {

			case .MOVE:
				set_obj(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val)

			case .LOADI:
				set_int(&regs[getarg_A(i)].val, Integer(getarg_sBx(i)))

			case .LOADF:
				set_float(&regs[getarg_A(i)].val, Number(getarg_sBx(i)))

			case .LOADK:
				set_obj(&regs[getarg_A(i)].val, &k[getarg_Bx(i)])

			case .LOADKX:
				set_obj(&regs[getarg_A(i)].val, &k[getarg_Ax(pc[0])])
				pc = vm_pc_add(pc, 1)

			case .LOADFALSE:
				set_bool(&regs[getarg_A(i)].val, false)

			case .LFALSESKIP:
				set_bool(&regs[getarg_A(i)].val, false)
				pc = vm_pc_add(pc, 1) // skip the next instruction (a LOADTRUE)

			case .LOADTRUE:
				set_bool(&regs[getarg_A(i)].val, true)

			case .LOADNIL:
				ra := getarg_A(i)
				b := getarg_B(i)
				for j := 0; j <= b; j += 1 {
					set_nil(&regs[ra + j].val)
				}

			case .GETUPVAL:
				set_obj(&regs[getarg_A(i)].val, upval_value(vm_upvals(regs)[getarg_B(i)]))

			case .SETUPVAL:
				ra := getarg_A(i)
				uv := vm_upvals(regs)[getarg_B(i)]
				rav := &regs[ra].val
				set_obj(upval_value(uv), rav)
				if is_collectable(rav) {
					gc_barrier(L, obj2gco(uv), rav.value_.gc)
				}

			case .GETTABUP:
				ra := base + getarg_A(i)
				upval := upval_value(vm_upvals(regs)[getarg_B(i)])
				rc := &k[getarg_C(i)]
				when VM_THREADED {
					if !vm_thread_tryget(upval, rc, stack_value(L, ra)) {
						thread_ctx := context
						trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), upval, rc, ra, &thread_ctx)
					}
				} else {
					vm_gettable(L, ci_idx, vm_pc_index(pc, code), upval, rc, ra)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .GETTABLE:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := stack_value(L, base + getarg_C(i))
				when VM_THREADED {
					if !vm_thread_tryget(rb, rc, stack_value(L, ra)) {
						thread_ctx := context
						trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, &thread_ctx)
					}
				} else {
					// The switch keeps only this variable-key fast path inline to
					// avoid enlarging its dispatch loop with field-read copies.
					#force_inline vm_gettable(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .GETI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				vm_geti(L, ci_idx, vm_pc_index(pc, code), rb, Integer(getarg_C(i)), ra)
				trap = L.frames[ci_idx].u.l.trap

			case .GETFIELD:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := &k[getarg_C(i)]
				when VM_THREADED {
					if !vm_thread_tryget(rb, rc, stack_value(L, ra)) {
						thread_ctx := context
						trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, &thread_ctx)
					}
				} else {
					vm_gettable(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .SETTABUP:
				upval := upval_value(vm_upvals(regs)[getarg_A(i)])
				rb := &k[getarg_B(i)]
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, vm_pc_index(pc, code), upval, rb, rc)
				trap = L.frames[ci_idx].u.l.trap

			case .SETTABLE:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				when VM_THREADED {
					rc := &k[getarg_C(i)] if testarg_k(i) != 0 else stack_value(L, base + getarg_C(i))
					if !vm_thread_tryset(ra, rb, rc) {
						thread_ctx := context
						trap = vm_thread_setslow(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc, &thread_ctx)
					}
				} else {
					rc := vm_rkc(L, base, k, i)
					#force_inline vm_settable(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .SETI:
				ra := stack_value(L, base + getarg_A(i))
				rc := vm_rkc(L, base, k, i)
				vm_seti(L, ci_idx, vm_pc_index(pc, code), ra, Integer(getarg_B(i)), rc)
				trap = L.frames[ci_idx].u.l.trap

			case .SETFIELD:
				ra := stack_value(L, base + getarg_A(i))
				rb := &k[getarg_B(i)]
				rc := vm_rkc(L, base, k, i)
				vm_settable(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc)
				trap = L.frames[ci_idx].u.l.trap

			case .NEWTABLE:
				ra := base + getarg_A(i)
				b := u32(getarg_vB(i))
				c := u32(getarg_vC(i))
				if b > 0 {
					b = u32(1) << (b - 1) // hash size is 2^(b-1)
				}
				if testarg_k(i) != 0 {
					c += u32(getarg_Ax(pc[0])) * u32(MAXARG_vC + 1)
				}
				pc = vm_pc_add(pc, 1) // skip the EXTRAARG
				L.top = ra + 1 // correct top in case allocation triggers a GC
				t := table_new(L)
				set_table(stack_value(L, ra), t)
				if b != 0 || c != 0 {
					table_resize(L, t, c, b)
				}
				gc_checkGC(L) // pace the collector (table anchored at ra)
				trap = L.frames[ci_idx].u.l.trap

			case .SELF:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				rc := &k[getarg_C(i)]
				set_obj(stack_value(L, ra + 1), rb) // R[A+1] := object
				when VM_THREADED {
					was_table := base_type(rb) == TTABLE
					if !vm_thread_tryself(L, rb, rc, stack_value(L, ra)) {
						thread_ctx := context
						trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, &thread_ctx)
					} else if !was_table {
						// The original non-table path saves these before the raw
						// metamethod lookup, even when that lookup cannot call out.
						L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
						L.top = L.frames[ci_idx].top
					}
				} else {
					vm_gettable(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra) // R[A] := object[method]
					trap = L.frames[ci_idx].u.l.trap
				}

			case .ADDI:
				ra := &regs[getarg_A(i)].val
				v1 := &regs[getarg_B(i)].val
				aux: TValue
				set_int(&aux, Integer(getarg_sC(i)))
				if vm_arith(ra, v1, &aux, .Add) == .Ok {
					pc = vm_pc_add(pc, 1)
				}

			case .ADDK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Add) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .SUBK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Sub) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .MULK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Mul) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .MODK:
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Mod)
				if st == .Ok {
					pc = vm_pc_add(pc, 1)
				} else if st == .Div_By_Zero {
					debug_runerror(L, "attempt to perform 'n%%0'")
				}
			case .POWK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Pow) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .DIVK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Div) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .IDIVK:
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .IDiv)
				if st == .Ok {
					pc = vm_pc_add(pc, 1)
				} else if st == .Div_By_Zero {
					debug_runerror(L, "attempt to divide by zero")
				}
			case .BANDK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Band) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .BORK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Bor) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .BXORK:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Bxor) == .Ok {
					pc = vm_pc_add(pc, 1)
				}

			case .SHLI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				ic := getarg_sC(i)
				if ib, ok := to_integer_no_string(rb, .Eq); ok {
					pc = vm_pc_add(pc, 1)
					set_int(stack_value(L, ra), vm_shiftl(Integer(ic), ib))
				}
			case .SHRI:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				ic := getarg_sC(i)
				if ib, ok := to_integer_no_string(rb, .Eq); ok {
					pc = vm_pc_add(pc, 1)
					set_int(stack_value(L, ra), vm_shiftl(ib, -Integer(ic)))
				}

			case .ADD:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Add) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .SUB:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Sub) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .MUL:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Mul) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .MOD:
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Mod)
				if st == .Ok {
					pc = vm_pc_add(pc, 1)
				} else if st == .Div_By_Zero {
					debug_runerror(L, "attempt to perform 'n%%0'")
				}
			case .POW:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Pow) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .DIV:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Div) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .IDIV:
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .IDiv)
				if st == .Ok {
					pc = vm_pc_add(pc, 1)
				} else if st == .Div_By_Zero {
					debug_runerror(L, "attempt to divide by zero")
				}
			case .BAND:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Band) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .BOR:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Bor) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .BXOR:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Bxor) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .SHL:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Shl) == .Ok {
					pc = vm_pc_add(pc, 1)
				}
			case .SHR:
				if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Shr) == .Ok {
					pc = vm_pc_add(pc, 1)
				}

			case .MMBIN:
				ra := stack_value(L, base + getarg_A(i))
				pi := pc[-2] // the original arithmetic instruction
				rb := stack_value(L, base + getarg_B(i))
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				tm_trybinTM(L, ra, rb, result, getarg_C(i))
				trap = L.frames[ci_idx].u.l.trap

			case .MMBINI:
				ra := stack_value(L, base + getarg_A(i))
				pi := pc[-2]
				imm := getarg_sB(i)
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				tm_trybiniTM(L, ra, Integer(imm), getarg_k(i) != 0, result, getarg_C(i))
				trap = L.frames[ci_idx].u.l.trap

			case .MMBINK:
				ra := stack_value(L, base + getarg_A(i))
				pi := pc[-2]
				imm := &k[getarg_B(i)]
				result := base + getarg_A(pi)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				tm_trybinassocTM(L, ra, imm, getarg_k(i) != 0, result, getarg_C(i))
				trap = L.frames[ci_idx].u.l.trap

			case .UNM:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if vm_arith(&regs[getarg_A(i)].val, rb, rb, .Unm) != .Ok {
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					L.top = L.frames[ci_idx].top
					tm_trybinTM(L, rb, rb, ra, TM_UNM)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .BNOT:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if vm_arith(&regs[getarg_A(i)].val, rb, rb, .Bnot) != .Ok {
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					L.top = L.frames[ci_idx].top
					tm_trybinTM(L, rb, rb, ra, TM_BNOT)
					trap = L.frames[ci_idx].u.l.trap
				}

			case .NOT:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				// `not x` is true exactly when x is *falsy* -- nil OR false --
				// mirroring reference Lua's `l_isfalse`. The strict `is_false`
				// (VFALSE tag only) would wrongly treat `not nil` as false.
				set_bool(stack_value(L, ra), is_falsy(rb))

			case .LEN:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				vm_objlen(L, ra, stack_value(L, base + getarg_B(i)))
				trap = L.frames[ci_idx].u.l.trap

			case .CONCAT:
				ra := base + getarg_A(i)
				n := getarg_B(i)
				L.top = ra + n // mark the end of the operand run
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				vm_concat(L, n)
				L.top = ra + 1 // result at ra; anchor it for the GC
				gc_checkGC(L)
				trap = L.frames[ci_idx].u.l.trap

			case .CLOSE:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				func_close(L, ra, int(Thread_Status.Ok), true)
				trap = L.frames[ci_idx].u.l.trap

			case .TBC:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				func_newtbcupval(L, ra)

			case .JMP:
				offset := getarg_sJ(i)
				pc = vm_pc_add(pc, offset)
				if offset < 0 {
					trap = vm_poll_async_hook(L, trap)
				}

			case .EQ:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				cond := vm_equalobj(L, ra, rb)
				trap = L.frames[ci_idx].u.l.trap
				oldpc := pc
				pc = docondjump(pc, i, cond)
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .LT:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				cond: bool
				if is_integer(ra) && is_integer(rb) {
					cond = int_value(ra) < int_value(rb)
				} else if is_number(ra) && is_number(rb) {
					cond = LTnum(ra, rb)
				} else {
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					L.top = L.frames[ci_idx].top
					cond = lessthanothers(L, ra, rb)
					trap = L.frames[ci_idx].u.l.trap
				}
				oldpc := pc
				pc = docondjump(pc, i, cond)
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .LE:
				ra := stack_value(L, base + getarg_A(i))
				rb := stack_value(L, base + getarg_B(i))
				cond: bool
				if is_integer(ra) && is_integer(rb) {
					cond = int_value(ra) <= int_value(rb)
				} else if is_number(ra) && is_number(rb) {
					cond = LEnum(ra, rb)
				} else {
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					L.top = L.frames[ci_idx].top
					cond = lessequalothers(L, ra, rb)
					trap = L.frames[ci_idx].u.l.trap
				}
				oldpc := pc
				pc = docondjump(pc, i, cond)
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .EQK:
				ra := stack_value(L, base + getarg_A(i))
				rb := &k[getarg_B(i)]
				oldpc := pc
				pc = docondjump(pc, i, raw_equal(ra, rb))
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .EQI:
				ra := stack_value(L, base + getarg_A(i))
				im := getarg_sB(i)
				cond: bool
				if is_integer(ra) {
					cond = int_value(ra) == Integer(im)
				} else if is_float(ra) {
					cond = flt_value(ra) == Number(im)
				}
				oldpc := pc
				pc = docondjump(pc, i, cond)
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .LTI:
				oldpc := pc
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Lt)
				trap = L.frames[ci_idx].u.l.trap
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}
			case .LEI:
				oldpc := pc
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Le)
				trap = L.frames[ci_idx].u.l.trap
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}
			case .GTI:
				oldpc := pc
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Gt)
				trap = L.frames[ci_idx].u.l.trap
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}
			case .GEI:
				oldpc := pc
				pc = vm_orderI(L, ci_idx, code, pc, base, i, .Ge)
				trap = L.frames[ci_idx].u.l.trap
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .TEST:
				ra := stack_value(L, base + getarg_A(i))
				oldpc := pc
				pc = docondjump(pc, i, !is_falsy(ra))
				if uintptr(pc) <= uintptr(oldpc) {
					trap = vm_poll_async_hook(L, trap)
				}

			case .TESTSET:
				ra := base + getarg_A(i)
				rb := stack_value(L, base + getarg_B(i))
				if is_falsy(rb) == (getarg_k(i) != 0) {
					pc = vm_pc_add(pc, 1)
				} else {
					set_obj(stack_value(L, ra), rb)
					ni := pc[0]
					offset := getarg_sJ(ni)
					pc = vm_pc_add(pc, offset + 1)
					if offset < 0 {
						trap = vm_poll_async_hook(L, trap)
					}
				}

			case .CALL:
				trap = vm_poll_async_hook(L, trap)
				ra := base + getarg_A(i)
				b := getarg_B(i)
				nresults := getarg_C(i) - 1
				if b != 0 {
					L.top = ra + b // fixed arg count
				}
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				newci: int
				when VM_THREADED {
					thread_ctx := context
					newci = vm_thread_precall(L, ra, nresults, &thread_ctx)
				} else {
					newci = do_precall_vm(L, ra, nresults)
				}
				if newci >= 0 { // Lua callee: run it in this same trampoline
					ci_idx = newci
					continue newframe
				}
				// C callee: already executed by precall; keep going.
				// A C call may have installed a debug hook (e.g. debug.sethook),
				// which arms this frame's trap. Reload it -- reference `updatetrap`.
				trap = L.frames[ci_idx].u.l.trap

			case .TAILCALL:
				trap = vm_poll_async_hook(L, trap)
				ra := base + getarg_A(i)
				b := getarg_B(i)
				nparams1 := getarg_C(i)
				delta := 0
				if nparams1 != 0 {
					delta = int(L.frames[ci_idx].u.l.nextraargs) + nparams1
				}
				if b != 0 {
					L.top = ra + b
				} else {
					b = L.top - ra
				}
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				if testarg_k(i) != 0 {
					func_closeupval(L, base) // close any open upvalues
				}
				n := do_pretailcall(L, ci_idx, ra, b, delta)
				if n < 0 { // Lua callee: reuses this frame; run it
					continue newframe
				}
				// C callee: finish and return through the tail.
				L.frames[ci_idx].func -= delta
				do_poscall(L, ci_idx, n)
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN:
				trap = vm_poll_async_hook(L, trap)
				ra := base + getarg_A(i)
				n := getarg_B(i) - 1
				nparams1 := getarg_C(i)
				if n < 0 {
					n = L.top - ra // variable results: take what's on the stack
				}
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				if testarg_k(i) != 0 { // there may be open upvalues / tbc vars
					L.frames[ci_idx].u2 = n
					if L.top < L.frames[ci_idx].top {
						L.top = L.frames[ci_idx].top
					}
					func_close(L, base, CLOSEKTOP, true)
				}
				if nparams1 != 0 { // vararg function: restore real func slot
					L.frames[ci_idx].func -= int(L.frames[ci_idx].u.l.nextraargs) + nparams1
				}
				L.top = ra + n
				do_poscall(L, ci_idx, n)
				if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN0:
				trap = vm_poll_async_hook(L, trap)
				callstatus: u32
				if L.hookmask != 0 {
					ra := base + getarg_A(i)
					L.top = ra
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					do_poscall(L, ci_idx, 0)
					callstatus = L.frames[ci_idx].callstatus // hook may move frames
				} else {
					callstatus = L.frames[ci_idx].callstatus
					nres := get_nresults(callstatus)
					L.ci = ci_idx - 1
					L.top = base - 1
					for nres > 0 {
						set_nil(stack_value(L, L.top))
						L.top += 1
						nres -= 1
					}
				}
				if (callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .RETURN1:
				trap = vm_poll_async_hook(L, trap)
				callstatus: u32
				if L.hookmask != 0 {
					ra := base + getarg_A(i)
					L.top = ra + 1
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					do_poscall(L, ci_idx, 1)
					callstatus = L.frames[ci_idx].callstatus // hook may move frames
				} else {
					callstatus = L.frames[ci_idx].callstatus
					nres := get_nresults(callstatus)
					L.ci = ci_idx - 1
					if nres == 0 {
						L.top = base - 1
					} else {
						set_obj(&regs[-1].val, &regs[getarg_A(i)].val)
						L.top = base
						for nres > 1 {
							set_nil(stack_value(L, L.top))
							L.top += 1
							nres -= 1
						}
					}
				}
				if (callstatus & CIST_FRESH) != 0 {
					return
				}
				ci_idx -= 1
				continue newframe

			case .FORLOOP:
				ra := getarg_A(i)
				if is_integer(&regs[ra + 1].val) { // integer loop
					count := s2u(int_value(&regs[ra].val))
					if count > 0 {
						step := int_value(&regs[ra + 1].val)
						idx := int_value(&regs[ra + 2].val)
						set_int(&regs[ra].val, u2s(count - 1)) // decrement counter
						set_int(&regs[ra + 2].val, int_add(idx, step)) // advance control
						pc = vm_pc_add(pc, -(getarg_Bx(i))) // jump back
						trap = vm_poll_async_hook(L, trap)
					}
				} else if floatforloop(L, base + ra) { // float loop
					pc = vm_pc_add(pc, -(getarg_Bx(i)))
					trap = vm_poll_async_hook(L, trap)
				}

			case .FORPREP:
				ra := base + getarg_A(i)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				if forprep(L, ra) {
					pc = vm_pc_add(pc, getarg_Bx(i) + 1) // skip the loop body entirely
				}

			case .TFORPREP:
				ra := base + getarg_A(i)
				// Swap control (ra+2) and closing (ra+3) variables, then mark the
				// closing variable to-be-closed.
				temp: TValue
				set_obj(&temp, stack_value(L, ra + 3))
				set_obj(stack_value(L, ra + 3), stack_value(L, ra + 2))
				set_obj(stack_value(L, ra + 2), &temp)
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				func_newtbcupval(L, ra + 2)
				pc = vm_pc_add(pc, getarg_Bx(i)) // fall through to the TFORCALL at the loop end

			case .TFORCALL:
				ra := base + getarg_A(i)
				set_obj(stack_value(L, ra + 5), stack_value(L, ra + 3)) // control var
				set_obj(stack_value(L, ra + 4), stack_value(L, ra + 1)) // state
				set_obj(stack_value(L, ra + 3), stack_value(L, ra)) // iterator func
				L.top = ra + 3 + 3
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				do_call(L, ra + 3, getarg_C(i)) // runs to completion
				trap = L.frames[ci_idx].u.l.trap
				// The following TFORLOOP is fetched normally next iteration.

			case .TFORLOOP:
				ra := base + getarg_A(i)
				if !is_nil(stack_value(L, ra + 3)) { // control var not nil: continue
					pc = vm_pc_add(pc, -(getarg_Bx(i)))
					trap = vm_poll_async_hook(L, trap)
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
					last += u32(getarg_Ax(pc[0])) * u32(MAXARG_vC + 1)
					pc = vm_pc_add(pc, 1)
				}
				if last > h.asize {
					table_resizearray(L, h, last)
					trap = L.frames[ci_idx].u.l.trap
				}
				for n > 0 {
					val := stack_value(L, ra + int(n))
					arr_set(h, last - 1, val)
					last -= 1
					if is_collectable(val) {
						gc_barrierback(L, obj2gco(h))
					}
					n -= 1
				}

			case .CLOSURE:
				ra := base + getarg_A(i)
				p := cl.p.p[getarg_Bx(i)]
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				when INTERNAL_ASSERTS {assert(ci_idx == L.ci)}
				pushclosure(L, p, cl, base, ra)
				L.top = ra + 1 // closure at ra; anchor it for the GC
				gc_checkGC(L)
				trap = L.frames[ci_idx].u.l.trap

			case .VARARG:
				ra := base + getarg_A(i)
				n := getarg_C(i) - 1
				vatab := getarg_B(i) if getarg_k(i) != 0 else -1
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
				tm_getvarargs(L, ci_idx, ra, n, vatab)
				trap = L.frames[ci_idx].u.l.trap

			case .GETVARG:
				ra := base + getarg_A(i)
				rc := stack_value(L, base + getarg_C(i))
				tm_getvararg(L, ci_idx, ra, rc)

			case .ERRNNIL:
				ra := stack_value(L, base + getarg_A(i))
				if !is_nil(ra) {
					L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
					debug_errnnil(L, cl, getarg_Bx(i))
				}

			case .VARARGPREP:
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				tm_adjustvarargs(L, ci_idx, cl.p)
				// `luaT_adjustvarargs` is a protected point that may have installed
				// a hook; reload `trap` from the frame (reference's `updatetrap`).
				// If a hook is now armed this is where a vararg function's call hook
				// fires, and we mark the *next* opcode as a new line so the line
				// hook restarts cleanly -- reference Lua's OP_VARARGPREP.
				trap = L.frames[ci_idx].u.l.trap
				if trap != 0 {
					do_hookcall(L, ci_idx)
					L.oldpc = 1 // next opcode is seen as a "new" line
				}
				base = L.frames[ci_idx].func + 1 // function has a new base now
				regs = ([^]StackValue)(&L.stack[base])

			case .EXTRAARG:
				// Always consumed as the operand of a preceding opcode; reaching it
				// on its own is a compiler bug.
				debug_runerror(L, "internal error: stray EXTRAARG")

			// Spell each unused encoding separately so LLVM can dispatch the whole
			// 7-bit domain with one dense jump table. Update this list if the opcode
			// set or field width changes; these are invalid, not enum members.
			case Op_Code(85), Op_Code(86), Op_Code(87), Op_Code(88), Op_Code(89),
			     Op_Code(90), Op_Code(91), Op_Code(92), Op_Code(93), Op_Code(94),
			     Op_Code(95), Op_Code(96), Op_Code(97), Op_Code(98), Op_Code(99),
			     Op_Code(100), Op_Code(101), Op_Code(102), Op_Code(103), Op_Code(104),
			     Op_Code(105), Op_Code(106), Op_Code(107), Op_Code(108), Op_Code(109),
			     Op_Code(110), Op_Code(111), Op_Code(112), Op_Code(113), Op_Code(114),
			     Op_Code(115), Op_Code(116), Op_Code(117), Op_Code(118), Op_Code(119),
			     Op_Code(120), Op_Code(121), Op_Code(122), Op_Code(123), Op_Code(124),
			     Op_Code(125), Op_Code(126), Op_Code(127):
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				debug_runerror(L, "invalid opcode")
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
vm_orderI :: proc(L: ^State, ci_idx: int, code: [^]Instruction, pc_in: [^]Instruction, base: int, i: Instruction, kind: Order_I) -> [^]Instruction {
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
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		cond = tm_callorderiTM(L, ra, im, flip, isf, event) > 0
	}
	return docondjump(pc, i, cond)
}

// A register-or-constant C operand -- reference Lua's `RKC(i)`. The `k` bit picks
// between the constant table and the register file.
@(private = "file")
vm_rkc :: proc(L: ^State, base: int, k: [^]TValue, i: Instruction) -> ^TValue {
	if testarg_k(i) != 0 {
		return &k[getarg_C(i)]
	}
	return stack_value(L, base + getarg_C(i))
}

// Perform a conditional jump -- reference Lua's `docondjump`. If `cond` matches the
// instruction's `k` bit, take the following JMP; otherwise skip it. Returns the
// updated `pc`.
@(private = "file")
docondjump :: proc "contextless" (pc: [^]Instruction, i: Instruction, cond: bool) -> [^]Instruction {
	if cond != (getarg_k(i) != 0) {
		return vm_pc_add(pc, 1) // condition failed: skip the jump
	}
	ni := pc[0] // the JMP that follows
	return vm_pc_add(pc, getarg_sJ(ni) + 1)
}

// Finish an opcode interrupted by a yield -- reference Lua's `luaV_finishOp`. The
// coroutine machinery calls this on resume to complete the operation whose
// metamethod yielded. (The set of resumable opcodes is exactly those that call a
// metamethod through the ordinary call protocol.)
vm_finishOp :: proc(L: ^State) {
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
		// A resumed comparison metamethod is truthy unless nil or false
		// (reference `!l_isfalse`), not merely when it is the boolean true.
		res := !is_falsy(stack_value(L, L.top - 1))
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
		vm_concat(L, total)
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
// BEGIN GENERATED THREADED VM -- tools/generate_threaded
// Do not edit this region; edit the switch and regenerate.
when VM_THREADED {
	#assert(ODIN_ARCH == .amd64 || ODIN_ARCH == .arm64)
	VM_Thread_Handler :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32
	vm_thread_table := [1 << SIZE_OP]VM_Thread_Handler{
		vm_thread_MOVE,
		vm_thread_LOADI,
		vm_thread_LOADF,
		vm_thread_LOADK,
		vm_thread_LOADKX,
		vm_thread_LOADFALSE,
		vm_thread_LFALSESKIP,
		vm_thread_LOADTRUE,
		vm_thread_LOADNIL,
		vm_thread_GETUPVAL,
		vm_thread_SETUPVAL,
		vm_thread_GETTABUP,
		vm_thread_GETTABLE,
		vm_thread_GETI,
		vm_thread_GETFIELD,
		vm_thread_SETTABUP,
		vm_thread_SETTABLE,
		vm_thread_SETI,
		vm_thread_SETFIELD,
		vm_thread_NEWTABLE,
		vm_thread_SELF,
		vm_thread_ADDI,
		vm_thread_ADDK,
		vm_thread_SUBK,
		vm_thread_MULK,
		vm_thread_MODK,
		vm_thread_POWK,
		vm_thread_DIVK,
		vm_thread_IDIVK,
		vm_thread_BANDK,
		vm_thread_BORK,
		vm_thread_BXORK,
		vm_thread_SHLI,
		vm_thread_SHRI,
		vm_thread_ADD,
		vm_thread_SUB,
		vm_thread_MUL,
		vm_thread_MOD,
		vm_thread_POW,
		vm_thread_DIV,
		vm_thread_IDIV,
		vm_thread_BAND,
		vm_thread_BOR,
		vm_thread_BXOR,
		vm_thread_SHL,
		vm_thread_SHR,
		vm_thread_MMBIN,
		vm_thread_MMBINI,
		vm_thread_MMBINK,
		vm_thread_UNM,
		vm_thread_BNOT,
		vm_thread_NOT,
		vm_thread_LEN,
		vm_thread_CONCAT,
		vm_thread_CLOSE,
		vm_thread_TBC,
		vm_thread_JMP,
		vm_thread_EQ,
		vm_thread_LT,
		vm_thread_LE,
		vm_thread_EQK,
		vm_thread_EQI,
		vm_thread_LTI,
		vm_thread_LEI,
		vm_thread_GTI,
		vm_thread_GEI,
		vm_thread_TEST,
		vm_thread_TESTSET,
		vm_thread_CALL,
		vm_thread_TAILCALL,
		vm_thread_RETURN,
		vm_thread_RETURN0,
		vm_thread_RETURN1,
		vm_thread_FORLOOP,
		vm_thread_FORPREP,
		vm_thread_TFORPREP,
		vm_thread_TFORCALL,
		vm_thread_TFORLOOP,
		vm_thread_SETLIST,
		vm_thread_CLOSURE,
		vm_thread_VARARG,
		vm_thread_GETVARG,
		vm_thread_ERRNNIL,
		vm_thread_VARARGPREP,
		vm_thread_EXTRAARG,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
		vm_thread_invalid,
	}

	vm_thread_enter :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k: [^]TValue
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		base = L.frames[ci_idx].func + 1 // stack index of R[0]
		regs = ([^]StackValue)(&L.stack[base])
		cl = (^LClosure)(regs[-1].val.value_.gc)
		k = cl.p.k
		code = cl.p.code
		pc = vm_pc_add(code, L.frames[ci_idx].u.l.savedpc)
		// Reference Lua's `luaG_tracecall`, inlined at the `startfunc`/`returning`
		// entry. `trap` starts from the hook mask; when any hook is active we arm
		// this frame's `u.l.trap` (so an `updatetrap` after a nested call reloads a
		// 1 and tracing survives the call) and, on a fresh (non-resuming) entry,
		// either suppress trapping until *after* the VARARGPREP instruction (vararg
		// functions) or fire the call hook right away (fixed-arity functions).
		trap = 0
		if L.hookmask != 0 {
			ci0 := &L.frames[ci_idx]
			ci0.u.l.trap = 1 // ensure hooks keep being checked after nested calls
			trap = 1
			if pc == code { // first instruction of a fresh (non-resuming) call?
				if (cl.p.flag & u8(PF_VAHID | PF_VATAB)) != 0 {
					trap = 0 // hooks begin at the VARARGPREP instruction
				} else if (ci0.callstatus & CIST_HOOKYIELD) == 0 {
					return #must_tail vm_thread_enterhook(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
				}
			}
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_enterhook :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		do_hookcall(L, ci_idx)
		base = L.frames[ci_idx].func + 1
		regs = ([^]StackValue)(&L.stack[base])
		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_trace :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		// traceexec saves the PC only for a line/count hook; a trap caused
		// solely by relocation must not otherwise change hook state.
		trap = debug_traceexec(L, vm_pc_index(pc, code))
		base = L.frames[ci_idx].func + 1
		regs = ([^]StackValue)(&L.stack[base]) // reference `updatebase`
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_poll :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		trap = vm_apply_async_hook(L, trap)
		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_gettable_miss :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := &regs[getarg_B(i)].val
		rc := &regs[getarg_C(i)].val
		trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, ctx)

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_gettable_other :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := &regs[getarg_B(i)].val
		rc := &regs[getarg_C(i)].val
		if !vm_thread_tryget(rb, rc, &regs[getarg_A(i)].val) {
			trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, ctx)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_concat_meta_op :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		L.top = ra + 2
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		tm_tryconcatTM(L)
		L.top -= 1
		L.top = ra + 1
		gc_checkGC(L)
		trap = L.frames[ci_idx].u.l.trap

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MOVE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_obj(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_int(&regs[getarg_A(i)].val, Integer(getarg_sBx(i)))


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADF :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_float(&regs[getarg_A(i)].val, Number(getarg_sBx(i)))


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_obj(&regs[getarg_A(i)].val, &k[getarg_Bx(i)])


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADKX :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_obj(&regs[getarg_A(i)].val, &k[getarg_Ax(pc[0])])
		pc = vm_pc_add(pc, 1)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADFALSE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_bool(&regs[getarg_A(i)].val, false)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LFALSESKIP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_bool(&regs[getarg_A(i)].val, false)
		pc = vm_pc_add(pc, 1) // skip the next instruction (a LOADTRUE)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADTRUE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_bool(&regs[getarg_A(i)].val, true)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LOADNIL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := getarg_A(i)
		b := getarg_B(i)
		for j := 0; j <= b; j += 1 {
			set_nil(&regs[ra + j].val)
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETUPVAL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		set_obj(&regs[getarg_A(i)].val, upval_value(closure_upvals(cl)[getarg_B(i)]))


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETUPVAL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := getarg_A(i)
		uv := closure_upvals(cl)[getarg_B(i)]
		rav := &regs[ra].val
		set_obj(upval_value(uv), rav)
		if is_collectable(rav) {
			gc_barrier(L, obj2gco(uv), rav.value_.gc)
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETTABUP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		upval := upval_value(closure_upvals(cl)[getarg_B(i)])
		rc := &k[getarg_C(i)]
		when VM_THREADED {
			if !vm_thread_tryget(upval, rc, stack_value(L, ra)) {
				_ = ctx
				trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), upval, rc, ra, ctx)
			}
		} else {
			vm_gettable(L, ci_idx, vm_pc_index(pc, code), upval, rc, ra)
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETTABLE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		rb := &regs[getarg_B(i)].val
		rc := &regs[getarg_C(i)].val
		if base_type(rb) != TTABLE {
			return #must_tail vm_thread_gettable_other(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		h := (^Table)(rb.value_.gc)
		if is_integer(rc) {
			key := int_value(rc)
			if Unsigned(key) - 1 >= Unsigned(h.asize) {
				return #must_tail vm_thread_gettable_other(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
			if tag_is_empty(table_fastgeti(h, key, &regs[getarg_A(i)].val)) {
				return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		} else if type_tag(rc) == VSHRSTR {
			if tag_is_empty(table_fastget(h, rc, &regs[getarg_A(i)].val)) {
				return #must_tail vm_thread_gettable_miss(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		} else {
			return #must_tail vm_thread_gettable_other(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		vm_geti(L, ci_idx, vm_pc_index(pc, code), rb, Integer(getarg_C(i)), ra)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETFIELD :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		rc := &k[getarg_C(i)]
		when VM_THREADED {
			if !vm_thread_tryget(rb, rc, stack_value(L, ra)) {
				_ = ctx
				trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, ctx)
			}
		} else {
			vm_gettable(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra)
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETTABUP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		upval := upval_value(closure_upvals(cl)[getarg_A(i)])
		rb := &k[getarg_B(i)]
		rc := vm_rkc(L, base, k, i)
		vm_settable(L, ci_idx, vm_pc_index(pc, code), upval, rb, rc)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETTABLE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := &regs[getarg_A(i)].val
		rb := &regs[getarg_B(i)].val
		when VM_THREADED {
			rc := &k[getarg_C(i)] if testarg_k(i) != 0 else &regs[getarg_C(i)].val
			if !vm_thread_tryset(ra, rb, rc) {
				_ = ctx
				trap = vm_thread_setslow(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc, ctx)
			}
		} else {
			rc := vm_rkc(L, base, k, i)
			#force_inline vm_settable(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc)
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		rc := vm_rkc(L, base, k, i)
		vm_seti(L, ci_idx, vm_pc_index(pc, code), ra, Integer(getarg_B(i)), rc)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETFIELD :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		rb := &k[getarg_B(i)]
		rc := vm_rkc(L, base, k, i)
		vm_settable(L, ci_idx, vm_pc_index(pc, code), ra, rb, rc)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_NEWTABLE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		b := u32(getarg_vB(i))
		c := u32(getarg_vC(i))
		if b > 0 {
			b = u32(1) << (b - 1) // hash size is 2^(b-1)
		}
		if testarg_k(i) != 0 {
			c += u32(getarg_Ax(pc[0])) * u32(MAXARG_vC + 1)
		}
		pc = vm_pc_add(pc, 1) // skip the EXTRAARG
		L.top = ra + 1 // correct top in case allocation triggers a GC
		t := table_new(L)
		set_table(stack_value(L, ra), t)
		if b != 0 || c != 0 {
			table_resize(L, t, c, b)
		}
		gc_checkGC(L) // pace the collector (table anchored at ra)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SELF :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		rc := &k[getarg_C(i)]
		set_obj(stack_value(L, ra + 1), rb) // R[A+1] := object
		when VM_THREADED {
			was_table := base_type(rb) == TTABLE
			if !vm_thread_tryself(L, rb, rc, stack_value(L, ra)) {
				_ = ctx
				trap = vm_thread_getslow(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra, ctx)
			} else if !was_table {
				// The original non-table path saves these before the raw
				// metamethod lookup, even when that lookup cannot call out.
				L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
				L.top = L.frames[ci_idx].top
			}
		} else {
			vm_gettable(L, ci_idx, vm_pc_index(pc, code), rb, rc, ra) // R[A] := object[method]
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_ADDI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := &regs[getarg_A(i)].val
		v1 := &regs[getarg_B(i)].val
		aux: TValue
		set_int(&aux, Integer(getarg_sC(i)))
		if vm_arith(ra, v1, &aux, .Add) == .Ok {
			pc = vm_pc_add(pc, 1)
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_ADDK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Add) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SUBK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Sub) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MULK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Mul) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MODK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		st := vm_thread_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Mod)
		if st == .Ok {
			pc = vm_pc_add(pc, 1)
		} else if st == .Div_By_Zero {
			vm_thread_aritherror(L, ctx, true)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_POWK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Pow) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_DIVK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Div) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_IDIVK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		st := vm_thread_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .IDiv)
		if st == .Ok {
			pc = vm_pc_add(pc, 1)
		} else if st == .Div_By_Zero {
			vm_thread_aritherror(L, ctx, false)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BANDK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Band) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BORK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Bor) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BXORK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &k[getarg_C(i)], .Bxor) == .Ok {
			pc = vm_pc_add(pc, 1)
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SHLI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		ic := getarg_sC(i)
		if ib, ok := to_integer_no_string(rb, .Eq); ok {
			pc = vm_pc_add(pc, 1)
			set_int(stack_value(L, ra), vm_shiftl(Integer(ic), ib))
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SHRI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		ic := getarg_sC(i)
		if ib, ok := to_integer_no_string(rb, .Eq); ok {
			pc = vm_pc_add(pc, 1)
			set_int(stack_value(L, ra), vm_shiftl(ib, -Integer(ic)))
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_ADD :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Add) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SUB :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Sub) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MUL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Mul) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MOD :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Mod)
		if st == .Ok {
			pc = vm_pc_add(pc, 1)
		} else if st == .Div_By_Zero {
			debug_runerror(L, "attempt to perform 'n%%0'")
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_POW :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Pow) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_DIV :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Div) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_IDIV :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		st := vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .IDiv)
		if st == .Ok {
			pc = vm_pc_add(pc, 1)
		} else if st == .Div_By_Zero {
			debug_runerror(L, "attempt to divide by zero")
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BAND :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Band) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BOR :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Bor) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BXOR :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Bxor) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SHL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Shl) == .Ok {
			pc = vm_pc_add(pc, 1)
		}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SHR :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if vm_arith(&regs[getarg_A(i)].val, &regs[getarg_B(i)].val, &regs[getarg_C(i)].val, .Shr) == .Ok {
			pc = vm_pc_add(pc, 1)
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MMBIN :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		pi := pc[-2] // the original arithmetic instruction
		rb := stack_value(L, base + getarg_B(i))
		result := base + getarg_A(pi)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		tm_trybinTM(L, ra, rb, result, getarg_C(i))
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MMBINI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		pi := pc[-2]
		imm := getarg_sB(i)
		result := base + getarg_A(pi)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		tm_trybiniTM(L, ra, Integer(imm), getarg_k(i) != 0, result, getarg_C(i))
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_MMBINK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		pi := pc[-2]
		imm := &k[getarg_B(i)]
		result := base + getarg_A(pi)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		tm_trybinassocTM(L, ra, imm, getarg_k(i) != 0, result, getarg_C(i))
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_UNM :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		if vm_arith(&regs[getarg_A(i)].val, rb, rb, .Unm) != .Ok {
			L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
			L.top = L.frames[ci_idx].top
			tm_trybinTM(L, rb, rb, ra, TM_UNM)
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_BNOT :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		if vm_arith(&regs[getarg_A(i)].val, rb, rb, .Bnot) != .Ok {
			L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
			L.top = L.frames[ci_idx].top
			tm_trybinTM(L, rb, rb, ra, TM_BNOT)
			trap = L.frames[ci_idx].u.l.trap
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_NOT :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rb := stack_value(L, base + getarg_B(i))
		// `not x` is true exactly when x is *falsy* -- nil OR false --
		// mirroring reference Lua's `l_isfalse`. The strict `is_false`
		// (VFALSE tag only) would wrongly treat `not nil` as false.
		set_bool(stack_value(L, ra), is_falsy(rb))


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LEN :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		rb := &regs[getarg_B(i)].val
		if is_string(rb) {
			set_int(&regs[getarg_A(i)].val, Integer(str_value(rb).len))
		} else {
			vm_thread_lenslow(L, ra, rb, ctx)
		}
		trap = L.frames[ci_idx].u.l.trap

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_CONCAT :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		if getarg_B(i) == 2 {
			a := getarg_A(i)
			left := &regs[a].val
			right := &regs[a + 1].val
			if !(is_string(left) || is_number(left)) || !(is_string(right) || is_number(right)) {
				return #must_tail vm_thread_concat_meta_op(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						ra := base + getarg_A(i)
						n := getarg_B(i)
						L.top = ra + n // mark the end of the operand run
						L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
						vm_thread_concat_run(L, n, ctx)
						L.top = ra + 1 // result at ra; anchor it for the GC
						if L.g.gc_debt <= 0 {vm_thread_concat_gc(L, ctx)}
						trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_CLOSE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		func_close(L, ra, int(Thread_Status.Ok), true)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TBC :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		func_newtbcupval(L, ra)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_JMP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						offset := getarg_sJ(i)
						pc = vm_pc_add(pc, offset)
						if offset < 0 {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_EQ :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						rb := stack_value(L, base + getarg_B(i))
						L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
						L.top = L.frames[ci_idx].top
						cond := vm_equalobj(L, ra, rb)
						trap = L.frames[ci_idx].u.l.trap
						oldpc := pc
						pc = docondjump(pc, i, cond)
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LT :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						rb := stack_value(L, base + getarg_B(i))
						cond: bool
						if is_integer(ra) && is_integer(rb) {
							cond = int_value(ra) < int_value(rb)
						} else if is_number(ra) && is_number(rb) {
							cond = LTnum(ra, rb)
						} else {
							L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
							L.top = L.frames[ci_idx].top
							cond = lessthanothers(L, ra, rb)
							trap = L.frames[ci_idx].u.l.trap
						}
						oldpc := pc
						pc = docondjump(pc, i, cond)
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						rb := stack_value(L, base + getarg_B(i))
						cond: bool
						if is_integer(ra) && is_integer(rb) {
							cond = int_value(ra) <= int_value(rb)
						} else if is_number(ra) && is_number(rb) {
							cond = LEnum(ra, rb)
						} else {
							L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
							L.top = L.frames[ci_idx].top
							cond = lessequalothers(L, ra, rb)
							trap = L.frames[ci_idx].u.l.trap
						}
						oldpc := pc
						pc = docondjump(pc, i, cond)
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_EQK :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						rb := &k[getarg_B(i)]
						oldpc := pc
						pc = docondjump(pc, i, raw_equal(ra, rb))
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_EQI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						im := getarg_sB(i)
						cond: bool
						if is_integer(ra) {
							cond = int_value(ra) == Integer(im)
						} else if is_float(ra) {
							cond = flt_value(ra) == Number(im)
						}
						oldpc := pc
						pc = docondjump(pc, i, cond)
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LTI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						oldpc := pc
						pc = vm_orderI(L, ci_idx, code, pc, base, i, .Lt)
						trap = L.frames[ci_idx].u.l.trap
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_LEI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						oldpc := pc
						pc = vm_orderI(L, ci_idx, code, pc, base, i, .Le)
						trap = L.frames[ci_idx].u.l.trap
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GTI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						oldpc := pc
						pc = vm_orderI(L, ci_idx, code, pc, base, i, .Gt)
						trap = L.frames[ci_idx].u.l.trap
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GEI :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						oldpc := pc
						pc = vm_orderI(L, ci_idx, code, pc, base, i, .Ge)
						trap = L.frames[ci_idx].u.l.trap
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TEST :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := stack_value(L, base + getarg_A(i))
						oldpc := pc
						pc = docondjump(pc, i, !is_falsy(ra))
						if uintptr(pc) <= uintptr(oldpc) {
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TESTSET :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := base + getarg_A(i)
						rb := stack_value(L, base + getarg_B(i))
						if is_falsy(rb) == (getarg_k(i) != 0) {
							pc = vm_pc_add(pc, 1)
						} else {
							set_obj(stack_value(L, ra), rb)
							ni := pc[0]
							offset := getarg_sJ(ni)
							pc = vm_pc_add(pc, offset + 1)
							if offset < 0 {
								when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
							}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_CALL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				trap = vm_thread_pollcall(L, trap, ctx)
			}
		}
						ra := base + getarg_A(i)
						b := getarg_B(i)
						nresults := getarg_C(i) - 1
						if b != 0 {
							L.top = ra + b // fixed arg count
						}
						L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
						newci: int
						when VM_THREADED {
							_ = ctx
							newci = vm_thread_precall(L, ra, nresults, ctx)
						} else {
							newci = do_precall_vm(L, ra, nresults)
						}
						if newci >= 0 { // Lua callee: run it in this same trampoline
							ci_idx = newci
							return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
						}
						// C callee: already executed by precall; keep going.
						// A C call may have installed a debug hook (e.g. debug.sethook),
						// which arms this frame's trap. Reload it -- reference `updatetrap`.
						trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TAILCALL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		trap = vm_poll_async_hook(L, trap)
		ra := base + getarg_A(i)
		b := getarg_B(i)
		nparams1 := getarg_C(i)
		delta := 0
		if nparams1 != 0 {
			delta = int(L.frames[ci_idx].u.l.nextraargs) + nparams1
		}
		if b != 0 {
			L.top = ra + b
		} else {
			b = L.top - ra
		}
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		if testarg_k(i) != 0 {
			func_closeupval(L, base) // close any open upvalues
		}
		n := do_pretailcall(L, ci_idx, ra, b, delta)
		if n < 0 { // Lua callee: reuses this frame; run it
			return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		// C callee: finish and return through the tail.
		L.frames[ci_idx].func -= delta
		do_poscall(L, ci_idx, n)
		if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
			return 0
		}
		ci_idx -= 1
		return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_RETURN :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		trap = vm_poll_async_hook(L, trap)
		ra := base + getarg_A(i)
		n := getarg_B(i) - 1
		nparams1 := getarg_C(i)
		if n < 0 {
			n = L.top - ra // variable results: take what's on the stack
		}
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		if testarg_k(i) != 0 { // there may be open upvalues / tbc vars
			L.frames[ci_idx].u2 = n
			if L.top < L.frames[ci_idx].top {
				L.top = L.frames[ci_idx].top
			}
			func_close(L, base, CLOSEKTOP, true)
		}
		if nparams1 != 0 { // vararg function: restore real func slot
			L.frames[ci_idx].func -= int(L.frames[ci_idx].u.l.nextraargs) + nparams1
		}
		L.top = ra + n
		do_poscall(L, ci_idx, n)
		if (L.frames[ci_idx].callstatus & CIST_FRESH) != 0 {
			return 0
		}
		ci_idx -= 1
		return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_RETURN0_slow :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				context = ctx^
				trap = vm_apply_async_hook(L, trap)
			}
		}
						callstatus: u32
						if L.hookmask != 0 {
							ra := base + getarg_A(i)
							L.top = ra
							L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
							context = ctx^
							do_poscall(L, ci_idx, 0)
							callstatus = L.frames[ci_idx].callstatus // hook may move frames
						} else {
							callstatus = L.frames[ci_idx].callstatus
							nres := get_nresults(callstatus)
							L.ci = ci_idx - 1
							L.top = base - 1
							for nres > 0 {
								set_nil(stack_value(L, L.top))
								L.top += 1
								nres -= 1
							}
						}
						if (callstatus & CIST_FRESH) != 0 {
							return 0
						}
						ci_idx -= 1
						return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_RETURN0 :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_RETURN0_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
		if L.hookmask != 0 {
			return #must_tail vm_thread_RETURN0_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		callstatus := L.frames[ci_idx].callstatus
		nres := get_nresults(callstatus)
		L.ci = ci_idx - 1
		L.top = base - 1
		for nres > 0 {
			set_nil(stack_value(L, L.top))
			L.top += 1
			nres -= 1
		}
		if (callstatus & CIST_FRESH) != 0 {
			return 0
		}
		ci_idx -= 1
		return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_RETURN1_slow :: #force_no_inline proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				context = ctx^
				trap = vm_apply_async_hook(L, trap)
			}
		}
						callstatus: u32
						if L.hookmask != 0 {
							ra := base + getarg_A(i)
							L.top = ra + 1
							L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
							context = ctx^
							do_poscall(L, ci_idx, 1)
							callstatus = L.frames[ci_idx].callstatus // hook may move frames
						} else {
							callstatus = L.frames[ci_idx].callstatus
							nres := get_nresults(callstatus)
							L.ci = ci_idx - 1
							if nres == 0 {
								L.top = base - 1
							} else {
								set_obj(&regs[-1].val, &regs[getarg_A(i)].val)
								L.top = base
								for nres > 1 {
									set_nil(stack_value(L, L.top))
									L.top += 1
									nres -= 1
								}
							}
						}
						if (callstatus & CIST_FRESH) != 0 {
							return 0
						}
						ci_idx -= 1
						return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_RETURN1 :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_RETURN1_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
		if L.hookmask != 0 {
			return #must_tail vm_thread_RETURN1_slow(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		callstatus := L.frames[ci_idx].callstatus
		nres := get_nresults(callstatus)
		L.ci = ci_idx - 1
		if nres == 0 {
			L.top = base - 1
		} else {
			set_obj(&regs[-1].val, &regs[getarg_A(i)].val)
			L.top = base
			for nres > 1 {
				set_nil(stack_value(L, L.top))
				L.top += 1
				nres -= 1
			}
		}
		if (callstatus & CIST_FRESH) != 0 {
			return 0
		}
		ci_idx -= 1
		return #must_tail vm_thread_enter(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
	}

	vm_thread_FORLOOP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := getarg_A(i)
		if is_integer(&regs[ra + 1].val) { // integer loop
			count := s2u(int_value(&regs[ra].val))
			if count > 0 {
				target := vm_pc_add(pc, -(getarg_Bx(i)))
				next_i := target[0]
				step := int_value(&regs[ra + 1].val)
				idx := int_value(&regs[ra + 2].val)
				set_int(&regs[ra].val, u2s(count - 1))
				set_int(&regs[ra + 2].val, int_add(idx, step))
				pc = target
				when ODIN_OS != .Freestanding {
					if intrinsics.atomic_load(&async_hook_pending) != 0 {
						return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
					}
				}
				if trap != 0 {
					return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
				}
				pc = vm_pc_add(pc, 1)
				return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
			}
		} else if floatforloop(L, base + ra) { // float loop
			pc = vm_pc_add(pc, -(getarg_Bx(i)))
			when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_FORPREP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		if forprep(L, ra) {
			pc = vm_pc_add(pc, getarg_Bx(i) + 1) // skip the loop body entirely
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TFORPREP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		// Swap control (ra+2) and closing (ra+3) variables, then mark the
		// closing variable to-be-closed.
		temp: TValue
		set_obj(&temp, stack_value(L, ra + 3))
		set_obj(stack_value(L, ra + 3), stack_value(L, ra + 2))
		set_obj(stack_value(L, ra + 2), &temp)
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		func_newtbcupval(L, ra + 2)
		pc = vm_pc_add(pc, getarg_Bx(i)) // fall through to the TFORCALL at the loop end


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TFORCALL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		set_obj(stack_value(L, ra + 5), stack_value(L, ra + 3)) // control var
		set_obj(stack_value(L, ra + 4), stack_value(L, ra + 1)) // state
		set_obj(stack_value(L, ra + 3), stack_value(L, ra)) // iterator func
		L.top = ra + 3 + 3
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		do_call(L, ra + 3, getarg_C(i)) // runs to completion
		trap = L.frames[ci_idx].u.l.trap
		// The following TFORLOOP is fetched normally next iteration.


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_TFORLOOP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
						ra := base + getarg_A(i)
						if !is_nil(stack_value(L, ra + 3)) { // control var not nil: continue
							pc = vm_pc_add(pc, -(getarg_Bx(i)))
							when ODIN_OS != .Freestanding {
			if intrinsics.atomic_load(&async_hook_pending) != 0 {
				return #must_tail vm_thread_poll(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
			}
		}
						}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_SETLIST :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
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
			last += u32(getarg_Ax(pc[0])) * u32(MAXARG_vC + 1)
			pc = vm_pc_add(pc, 1)
		}
		if last > h.asize {
			table_resizearray(L, h, last)
			trap = L.frames[ci_idx].u.l.trap
		}
		for n > 0 {
			val := stack_value(L, ra + int(n))
			arr_set(h, last - 1, val)
			last -= 1
			if is_collectable(val) {
				gc_barrierback(L, obj2gco(h))
			}
			n -= 1
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_CLOSURE :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		p := cl.p.p[getarg_Bx(i)]
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		when INTERNAL_ASSERTS {assert(ci_idx == L.ci)}
		pushclosure(L, p, cl, base, ra)
		L.top = ra + 1 // closure at ra; anchor it for the GC
		gc_checkGC(L)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_VARARG :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		n := getarg_C(i) - 1
		vatab := getarg_B(i) if getarg_k(i) != 0 else -1
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		L.top = L.frames[ci_idx].top
		tm_getvarargs(L, ci_idx, ra, n, vatab)
		trap = L.frames[ci_idx].u.l.trap


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_GETVARG :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := base + getarg_A(i)
		rc := stack_value(L, base + getarg_C(i))
		tm_getvararg(L, ci_idx, ra, rc)


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_ERRNNIL :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		ra := stack_value(L, base + getarg_A(i))
		if !is_nil(ra) {
			L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
			debug_errnnil(L, cl, getarg_Bx(i))
		}


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_VARARGPREP :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		tm_adjustvarargs(L, ci_idx, cl.p)
		// `luaT_adjustvarargs` is a protected point that may have installed
		// a hook; reload `trap` from the frame (reference's `updatetrap`).
		// If a hook is now armed this is where a vararg function's call hook
		// fires, and we mark the *next* opcode as a new line so the line
		// hook restarts cleanly -- reference Lua's OP_VARARGPREP.
		trap = L.frames[ci_idx].u.l.trap
		if trap != 0 {
			do_hookcall(L, ci_idx)
			L.oldpc = 1 // next opcode is seen as a "new" line
		}
		base = L.frames[ci_idx].func + 1 // function has a new base now
		regs = ([^]StackValue)(&L.stack[base])


		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_EXTRAARG :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		// Always consumed as the operand of a preceding opcode; reaching it
		// on its own is a compiler bug.
		debug_runerror(L, "internal error: stray EXTRAARG")

		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

	vm_thread_invalid :: proc "preserve/none" (L: ^State, pc_arg: [^]Instruction, regs_arg: [^]StackValue, cl_arg: ^LClosure, code_arg: [^]Instruction, ci_idx_arg: int, trap_arg: i32, ctx: ^runtime.Context, i_arg: Instruction) -> i32 {
		context = ctx^
		pc := pc_arg
		regs := regs_arg
		cl := cl_arg
		k := cl.p.k
		code := code_arg
		base := int((uintptr(regs) - uintptr(L.stack)) / size_of(StackValue))
		ci_idx := ci_idx_arg
		trap := trap_arg
		i := i_arg
		_ = pc; _ = regs; _ = cl; _ = k; _ = code; _ = base; _ = ci_idx; _ = trap; _ = i
		L.frames[ci_idx].u.l.savedpc = vm_pc_index(pc, code)
		debug_runerror(L, "invalid opcode")
		if trap != 0 {
			return #must_tail vm_thread_trace(L, pc, regs, cl, code, ci_idx, trap, ctx, i)
		}
		next_i := pc[0]
		pc = vm_pc_add(pc, 1)
		return #must_tail vm_thread_table[int(get_opcode(next_i))](L, pc, regs, cl, code, ci_idx, trap, ctx, next_i)
	}

}
// END GENERATED THREADED VM
