package lua

// tm.odin -- our analogue of reference Lua's `ltm.h` / `ltm.c`.
//
// Tag methods, i.e. metamethods. This file defines the enumeration of events
// (__index, __newindex, __add, __eq, __call, __close, ...), caches their names,
// and provides the lookup that finds a metamethod on a value's metatable. The VM
// leans on this constantly for its fallback paths, so the event ordering must
// match reference Lua exactly.
//
// This file holds the TM event enum and its names, fast access to a type's
// metatable, and the metamethod lookup and invocation helpers.

// ---------------------------------------------------------------------------
// The metamethod event enumeration
// ---------------------------------------------------------------------------
//
// Every metamethod the language understands has an integer *event* id. The order
// here is load-bearing and lifted verbatim from reference Lua's `TMS` enum
// (ltm.h): the parser, VM, and this file all index arrays by these numbers, and
// several tricks below (the fast-access mask, ORDER-TM/ORDER-OP correspondence in
// Phase 4/5) depend on the exact sequence. Do not reorder.
//
// The first six (up to and including `TM_EQ`) are the "fast access" events: a
// table caches, in its `flags` byte, a one-bit-per-event note that it *lacks* that
// metamethod, so the common no-metamethod case skips the hash lookup entirely.
TM_INDEX :: 0
TM_NEWINDEX :: 1
TM_GC :: 2
TM_MODE :: 3
TM_LEN :: 4
TM_EQ :: 5 // last event with fast (flag-cached) access
TM_ADD :: 6
TM_SUB :: 7
TM_MUL :: 8
TM_MOD :: 9
TM_POW :: 10
TM_DIV :: 11
TM_IDIV :: 12
TM_BAND :: 13
TM_BOR :: 14
TM_BXOR :: 15
TM_SHL :: 16
TM_SHR :: 17
TM_UNM :: 18
TM_BNOT :: 19
TM_LT :: 20
TM_LE :: 21
TM_CONCAT :: 22
TM_CALL :: 23
TM_CLOSE :: 24
TM_N :: 25 // number of events (NOT an event itself)

// The metamethod names, indexed by event id -- reference Lua's `luaT_eventname`.
// These are interned once (in `luaT_init`) and pinned for the life of the state.
// The array order MUST match the `TM_*` ids above.
tm_event_names := [TM_N]string {
	"__index",
	"__newindex",
	"__gc",
	"__mode",
	"__len",
	"__eq",
	"__add",
	"__sub",
	"__mul",
	"__mod",
	"__pow",
	"__div",
	"__idiv",
	"__band",
	"__bor",
	"__bxor",
	"__shl",
	"__shr",
	"__unm",
	"__bnot",
	"__lt",
	"__le",
	"__concat",
	"__call",
	"__close",
}

// A one bit in each fast-access event position -- reference Lua's `maskflags`.
// A table's `flags` byte carries these bits set to mean "this table definitely has
// no metamethod for that event", so the fast path can answer without a lookup.
// Bits above `TM_EQ` are reused by the table for other purposes (the dummy-node
// marker), which is exactly why only the fast events get flag caching. The value
// is the low `TM_EQ + 1` bits set: `(1 << (TM_EQ + 1)) - 1`.
maskflags :: Byte((1 << (TM_EQ + 1)) - 1)

// ---------------------------------------------------------------------------
// Type names
// ---------------------------------------------------------------------------
//
// The number of distinct type tags, including the two internal-only tags
// (`upvalue`, `proto`) that surface only in debug/test contexts, plus the "no
// value" pseudo-type for an absent stack slot. Reference Lua's `LUA_TOTALTYPES`.
TOTAL_TYPES :: 12

// Human-readable type names, indexed by `ttype + 1` (so index 0 is the "no value"
// pseudo-type for `LUA_TNONE`) -- reference Lua's `luaT_typenames_`. `ttypename`
// does the `+1` shift for you.
tm_typenames := [TOTAL_TYPES]string {
	"no value",
	"nil",
	"boolean",
	"userdata",
	"number",
	"string",
	"table",
	"function",
	"userdata",
	"thread",
	"upvalue",
	"proto",
}

// The name of a base type tag -- reference Lua's `ttypename`. Callers pass a base
// type (0..`TPROTO`); the `+1` maps it onto the names table, where slot 0 is the
// "no value" pseudo-type.
ttypename :: #force_inline proc "contextless" (t: int) -> string {
	return tm_typenames[t + 1]
}

// ---------------------------------------------------------------------------
// Initialization and lookup
// ---------------------------------------------------------------------------

// Intern every metamethod name and pin it for the life of the state -- reference
// Lua's `luaT_init`. Fixing the names (moving them off the sweepable list) means a
// metamethod lookup never has to worry about its key name being collected, and the
// names cost exactly one allocation each, ever. Returns an error status if any
// name allocation fails.
tm_init :: proc(L: ^State) -> Thread_Status {
	g := L.g
	for i in 0 ..< TM_N {
		ts := string_new(L, tm_event_names[i])
		if ts == nil {
			return throw(L, .Err_Mem)
		}
		g.tmname[i] = ts
		gc_fix(L, obj2gco(ts)) // never collect these names
	}
	return .Ok
}

// Look up a fast-access metamethod on a metatable, updating the absence cache --
// reference Lua's `luaT_gettm`. If the event is missing, we set its bit in the
// table's `flags` so future fast-path checks skip straight past. Only valid for
// the fast events (id <= `TM_EQ`); the caller guarantees that. Returns nil when
// the metamethod is absent (an "empty"/nil raw slot counts as absent).
tm_gettm :: proc "contextless" (events: ^Table, event: int, ename: ^TString) -> ^TValue {
	tm := table_Hgetshortstr(events, ename)
	assert_contextless(event <= TM_EQ)
	if is_nil(tm) { // no such metamethod
		events.flags |= Byte(u32(1) << u32(event)) // remember its absence
		return nil
	}
	return tm
}

// Find event `event`'s metamethod for value `o` -- reference Lua's
// `luaT_gettmbyobj`. Tables and full userdata carry their own metatable; every
// other type shares a single per-type metatable held on the global state. When
// there is no metatable at all we return the state's shared nil sentinel rather
// than a null pointer, so callers can always dereference the result. Note this
// uses a *raw* lookup (no `__index` chaining) -- metamethods are always fetched
// raw.
tm_gettmbyobj :: proc "contextless" (L: ^State, o: ^TValue, event: int) -> ^TValue {
	g := L.g
	mt: ^Table
	switch no_variant(o.tt_) {
	case TTABLE:
		mt = (^Table)(o.value_.gc).metatable
	case TUSERDATA:
		mt = udata_value(o).metatable
	case:
		mt = g.mt[no_variant(o.tt_)]
	}
	if mt != nil {
		return table_Hgetshortstr(mt, g.tmname[event])
	}
	return &g.nilvalue
}

// The type name to show for a value in an error message -- reference Lua's
// `luaT_objtypename`. A table or full userdata with a `__name` string in its
// metatable reports that custom name; everything else falls back to the standard
// type name. This is what makes "attempt to index a Point value" possible for a
// tagged userdata/table.
tm_objtypename :: proc(L: ^State, o: ^TValue) -> string {
	mt: ^Table
	if base_type(o) == TTABLE {
		mt = (^Table)(o.value_.gc).metatable
	} else if base_type(o) == TUSERDATA {
		mt = udata_value(o).metatable
	}
	if mt != nil {
		name := table_Hgetshortstr(mt, string_new(L, "__name"))
		if base_type(name) == TSTRING {
			return string(str_slice(str_value(name)))
		}
	}
	return ttypename(int(no_variant(o.tt_)))
}

// ---------------------------------------------------------------------------
// Metamethod invocation (the VM's fallback paths)
// ---------------------------------------------------------------------------
//
// When the VM meets an operation it can't resolve natively (indexing a
// non-table, adding a table, comparing mismatched types, ...) it hands off to a
// metamethod. All of that funnels through the helpers below, which push the
// metamethod and its operands onto the stack and drive the ordinary call
// protocol. Because a metamethod can grow the stack, these take/produce *stack
// indices* for their result slot, never retained pointers.

// Call a metamethod `f` with three arguments and no wanted result -- reference
// Lua's `luaT_callTM`. Used by `__newindex` and the finalizer/close paths, where
// the metamethod's return value is discarded.
tm_callTM :: proc(L: ^State, f: ^TValue, p1: ^TValue, p2: ^TValue, p3: ^TValue) {
	func := L.top
	set_obj(stack_value(L, func), f)
	set_obj(stack_value(L, func + 1), p1)
	set_obj(stack_value(L, func + 2), p2)
	set_obj(stack_value(L, func + 3), p3)
	L.top = func + 4
	// A metamethod may yield only when it is called from Lua code; from a C
	// frame we must forbid the yield (reference gates on `isLuacode(L->ci)`).
	if is_lua_code(&L.frames[L.ci]) {
		do_call(L, func, 0)
	} else {
		do_callnoyield(L, func, 0)
	}
}

// Call a metamethod `f` with two arguments and one wanted result, storing that
// result at stack index `res` -- reference Lua's `luaT_callTMres`. Since `res` is
// an index it survives any stack reallocation the call triggers (the payoff of
// the index model over reference Lua's savestack/restorestack dance).
tm_callTMres :: proc(L: ^State, f: ^TValue, p1: ^TValue, p2: ^TValue, res: int) {
	func := L.top
	set_obj(stack_value(L, func), f)
	set_obj(stack_value(L, func + 1), p1)
	set_obj(stack_value(L, func + 2), p2)
	L.top = func + 3
	// A metamethod may yield only when it is called from Lua code; from a C
	// frame we must forbid the yield (reference gates on `isLuacode(L->ci)`).
	if is_lua_code(&L.frames[L.ci]) {
		do_call(L, func, 1)
	} else {
		do_callnoyield(L, func, 1)
	}
	L.top -= 1 // pop the single result...
	set_obj(stack_value(L, res), stack_value(L, L.top)) // ...into its place
}

// Try a binary metamethod for `event`, looking on `p1` first then `p2` --
// reference Lua's `callbinTM`. Returns true and writes `res` if a metamethod was
// found and called; false (leaving `res` untouched) if neither operand offers one.
callbinTM :: proc(L: ^State, p1: ^TValue, p2: ^TValue, res: int, event: int) -> bool {
	tm := tm_gettmbyobj(L, p1, event)
	if is_nil(tm) {
		tm = tm_gettmbyobj(L, p2, event)
	}
	if is_nil(tm) {
		return false
	}
	tm_callTMres(L, tm, p1, p2, res)
	return true
}

// Try a binary metamethod, raising the appropriate error if none exists --
// reference Lua's `luaT_trybinTM`. The error wording depends on the event: the
// bitwise operators complain about integer representation when both operands are
// numbers, otherwise about the operand types.
tm_trybinTM :: proc(L: ^State, p1: ^TValue, p2: ^TValue, res: int, event: int) {
	if !callbinTM(L, p1, p2, res, event) {
		switch event {
		case TM_BAND, TM_BOR, TM_BXOR, TM_SHL, TM_SHR, TM_BNOT:
			if is_number(p1) && is_number(p2) {
				debug_tointerror(L, p1, p2)
			} else {
				debug_opinterror(L, p1, p2, "perform bitwise operation on")
			}
		case:
			debug_opinterror(L, p1, p2, "perform arithmetic on")
		}
	}
}

// A binary metamethod for a commutative-in-lookup operation, honoring the `flip`
// flag that records whether the code generator swapped the operands (so a `K`/`I`
// constant could ride in the second slot) -- reference Lua's `luaT_trybinassocTM`.
tm_trybinassocTM :: proc(L: ^State, p1: ^TValue, p2: ^TValue, flip: bool, res: int, event: int) {
	if flip {
		tm_trybinTM(L, p2, p1, res, event)
	} else {
		tm_trybinTM(L, p1, p2, res, event)
	}
}

// Like `trybinassocTM` but with an immediate integer second operand -- reference
// Lua's `luaT_trybiniTM`. The immediate is wrapped in a throwaway TValue.
tm_trybiniTM :: proc(L: ^State, p1: ^TValue, i2: Integer, flip: bool, res: int, event: int) {
	aux: TValue
	set_int(&aux, i2)
	tm_trybinassocTM(L, p1, &aux, flip, res, event)
}

// The concatenation metamethod for the top two stack values -- reference Lua's
// `luaT_tryconcatTM`. `luaV_concat` calls this when it hits a pair it can't fold
// natively; the result lands where the left operand was (`top - 2`).
tm_tryconcatTM :: proc(L: ^State) {
	top := L.top
	if !callbinTM(L, stack_value(L, top - 2), stack_value(L, top - 1), top - 2, TM_CONCAT) {
		debug_concaterror(L, stack_value(L, top - 2), stack_value(L, top - 1))
	}
}

// An ordering metamethod (`__lt` / `__le`) -- reference Lua's `luaT_callorderTM`.
// Returns 1 if the metamethod ran and its result is truthy, 0 if it ran and is
// falsy. When NO metamethod exists reference raises the "attempt to compare"
// order error *inside* this routine (it never returns a "not found" sentinel);
// we do the same so every caller (`lessthanothers`, `callorderiTM`) inherits the
// error without having to test for it. The scratch result rides `L.top`.
tm_callorderTM :: proc(L: ^State, p1: ^TValue, p2: ^TValue, event: int) -> int {
	if callbinTM(L, p1, p2, L.top, event) {
		// The metamethod's result is truthy unless it is nil or false
		// (reference `!l_isfalse`); a truthy non-boolean must count as "yes".
		if !is_falsy(stack_value(L, L.top)) {
			return 1
		}
		return 0
	}
	debug_ordererror(L, p1, p2) // no metamethod: raise "attempt to compare ..."
	return 0 // unreachable (luaG_ordererror diverges); keeps the type checker happy
}

// An ordering metamethod with one immediate numeric operand -- reference Lua's
// `luaT_callorderiTM`. `flip` records operand-swap; `isfloat` chooses the aux
// value's numeric kind.
tm_callorderiTM :: proc(L: ^State, p1: ^TValue, v2: int, flip: bool, isfloat: bool, event: int) -> int {
	aux: TValue
	if isfloat {
		set_float(&aux, Number(v2))
	} else {
		set_int(&aux, Integer(v2))
	}
	pa := p1
	pb := &aux
	if flip { // arguments were exchanged by the code generator
		pb = p1
		pa = &aux
	}
	return tm_callorderTM(L, pa, pb, event)
}

// ---------------------------------------------------------------------------
// Vararg support
// ---------------------------------------------------------------------------
//
// Lua 5.5 has two vararg strategies chosen per prototype by the code generator:
// PF_VAHID keeps the extra arguments hidden below the frame (the classic model),
// and PF_VATAB materializes them into a real table (`...` used as a table). The
// three helpers below implement both; the VM's VARARGPREP/VARARG/GETVARG opcodes
// call straight into them.

// Build a vararg table holding `n` values starting at stack index `f`, leaving it
// on top of the stack -- reference Lua's `createvarargtab`. It carries an `n`
// field so `select('#', ...)`-style queries are O(1).
@(private = "file")
createvarargtab :: proc(L: ^State, f: int, n: int) {
	t := table_new(L)
	set_table(stack_value(L, L.top), t)
	L.top += 1
	table_resize(L, t, u32(n), 1)
	key: TValue
	set_string(&key, string_new(L, "n"))
	value: TValue
	set_int(&value, Integer(n))
	// No need to anchor the key: the resize just ran, so the following set
	// cannot trigger a collection.
	table_set(L, t, &key, &value) // t.n = n
	for i in 0 ..< n {
		table_setint(L, t, Integer(i + 1), stack_value(L, f + i))
	}
	gc_checkGC(L) // the vararg table just allocated; pace the collector
}

// Move fixed parameters above a copy of the function so the extra (vararg)
// arguments sit hidden below the frame -- reference Lua's `buildhiddenargs`.
// After this the frame's `func` points *past* the hidden arguments.
@(private = "file")
buildhiddenargs :: proc(L: ^State, ci_idx: int, p: ^Proto, totalargs: int, nfixparams: int, nextra: int) {
	ci := &L.frames[ci_idx]
	ci.u.l.nextraargs = nextra
	check_stack_p(L, int(p.maxstacksize) + 1)
	ci = &L.frames[ci_idx]
	oldfunc := ci.func
	// Copy the function to the new top, after the extra arguments.
	set_obj(stack_value(L, L.top), stack_value(L, oldfunc))
	L.top += 1
	// Move fixed parameters after the copied function, erasing the originals so
	// the GC never sees a stale duplicate.
	for i in 1 ..= nfixparams {
		set_obj(stack_value(L, L.top), stack_value(L, oldfunc + i))
		L.top += 1
		set_nil(stack_value(L, oldfunc + i))
	}
	ci.func += totalargs + 1 // 'func' now lives after the hidden arguments
	ci.top += totalargs + 1
}

// Reshape the incoming arguments for a vararg function's frame -- reference Lua's
// `luaT_adjustvarargs`. Either materializes a vararg table (PF_VATAB) or hides the
// extras below the frame (PF_VAHID).
tm_adjustvarargs :: proc(L: ^State, ci_idx: int, p: ^Proto) {
	ci := &L.frames[ci_idx]
	totalargs := L.top - ci.func - 1
	nfixparams := int(p.numparams)
	nextra := totalargs - nfixparams
	if (p.flag & PF_VATAB) != 0 { // needs a vararg table?
		createvarargtab(L, ci.func + nfixparams + 1, nextra)
		ci = &L.frames[ci_idx]
		// Move the table (currently on top) into the last-parameter slot.
		set_obj(stack_value(L, ci.func + nfixparams + 1), stack_value(L, L.top - 1))
	} else { // hidden-argument model
		buildhiddenargs(L, ci_idx, p, totalargs, nfixparams, nextra)
		ci = &L.frames[ci_idx]
		set_nil(stack_value(L, ci.func + nfixparams + 1)) // vararg param is nil
	}
}

// Resolve `...[rc]` -- reference Lua's `luaT_getvararg` (the GETVARG opcode). An
// integer key selects the k-th hidden extra argument; the string key "n" reports
// the count; anything else yields nil. Only reachable in the PF_VAHID model.
tm_getvararg :: proc(L: ^State, ci_idx: int, ra: int, rc: ^TValue) {
	ci := &L.frames[ci_idx]
	nextra := ci.u.l.nextraargs
	if n, ok := to_integer_no_string(rc, .Eq); ok { // integral index?
		if u64(n) - 1 < u64(nextra) {
			slot := ci.func - nextra + int(n) - 1
			set_obj(stack_value(L, ra), stack_value(L, slot))
			return
		}
	} else if base_type(rc) == TSTRING {
		s := str_slice(str_value(rc))
		if len(s) == 1 && s[0] == 'n' { // key is "n"?
			set_int(stack_value(L, ra), Integer(nextra))
			return
		}
	}
	set_nil(stack_value(L, ra)) // else nil
}

// How many extra vararg arguments are available -- reference Lua's `getnumargs`.
// With a vararg table we read (and validate) its `n` field; otherwise the count
// was stashed on the call frame.
@(private = "file")
getnumargs :: proc(L: ^State, ci_idx: int, h: ^Table) -> int {
	if h == nil {
		return L.frames[ci_idx].u.l.nextraargs
	}
	res := table_Hgetshortstr(h, string_new(L, "n"))
	if type_tag(res) != VNUMINT || u64(int_value(res)) > u64(MAX_INT / 2) {
		debug_runerror(L, "vararg table has no proper 'n'")
	}
	return int(int_value(res))
}

// Copy `wanted` vararg values (all of them if `wanted < 0`) to stack index
// `where` -- reference Lua's `luaT_getvarargs` (the VARARG opcode). `vatab` is the
// vararg table's register, or -1 for the hidden-argument model.
tm_getvarargs :: proc(L: ^State, ci_idx: int, dst_at: int, wanted_in: int, vatab: int) {
	wanted := wanted_in
	h: ^Table
	if vatab >= 0 {
		h = (^Table)(stack_value(L, L.frames[ci_idx].func + vatab + 1).value_.gc)
	}
	nargs := getnumargs(L, ci_idx, h)
	touse: int
	if wanted < 0 {
		touse = nargs
		wanted = nargs // get every available extra argument
		check_stack_p(L, nargs)
		L.top = dst_at + nargs // the next instruction will read top
	} else {
		touse = nargs if nargs <= wanted else wanted
	}
	i := 0
	if h == nil { // hidden model: pull from below the frame
		fbase := L.frames[ci_idx].func
		for ; i < touse; i += 1 {
			set_obj(stack_value(L, dst_at + i), stack_value(L, fbase - nargs + i))
		}
	} else { // table model: index the vararg table
		for ; i < touse; i += 1 {
			tag := table_getint(h, Integer(i + 1), stack_value(L, dst_at + i))
			if tag_is_empty(tag) {
				set_nil(stack_value(L, dst_at + i))
			}
		}
	}
	for ; i < wanted; i += 1 { // pad the remaining wanted slots with nil
		set_nil(stack_value(L, dst_at + i))
	}
}
