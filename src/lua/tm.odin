package lua

// tm.odin -- our analogue of reference Lua's `ltm.h` / `ltm.c`.
//
// Tag methods, i.e. metamethods. This file defines the enumeration of events
// (__index, __newindex, __add, __eq, __call, __close, ...), caches their names,
// and provides the lookup that finds a metamethod on a value's metatable. The VM
// leans on this constantly for its fallback paths, so the event ordering must
// match reference Lua exactly.
//
// TODO(phase-3): the TM event enum + names, fast access to a type's metatable,
// and the metamethod lookup helpers.

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
luaT_init :: proc(L: ^Lua_State) -> Thread_Status {
	g := L.g
	for i in 0 ..< TM_N {
		ts := luaS_new(L, tm_event_names[i])
		if ts == nil {
			return throw(L, .Err_Mem)
		}
		g.tmname[i] = ts
		luaC_fix(L, &ts.header) // never collect these names
	}
	return .Ok
}

// Look up a fast-access metamethod on a metatable, updating the absence cache --
// reference Lua's `luaT_gettm`. If the event is missing, we set its bit in the
// table's `flags` so future fast-path checks skip straight past. Only valid for
// the fast events (id <= `TM_EQ`); the caller guarantees that. Returns nil when
// the metamethod is absent (an "empty"/nil raw slot counts as absent).
luaT_gettm :: proc "contextless" (events: ^Table, event: int, ename: ^TString) -> ^TValue {
	tm := luaH_Hgetshortstr(events, ename)
	assert_contextless(event <= TM_EQ)
	if is_nil(tm) { // no such metamethod
		events.flags |= Byte(u32(1) << u32(event)) // remember its absence
		return nil
	}
	return tm
}

// Find event `event`'s metamethod for value `o` -- reference Lua's
// `luaT_gettmbyobj`. Tables (and, later, full userdata) carry their own
// metatable; every other type shares a single per-type metatable held on the
// global state. When there is no metatable at all we return the state's shared nil
// sentinel rather than a null pointer, so callers can always dereference the
// result. Note this uses a *raw* lookup (no `__index` chaining) -- metamethods are
// always fetched raw.
luaT_gettmbyobj :: proc "contextless" (L: ^Lua_State, o: ^TValue, event: int) -> ^TValue {
	g := L.g
	mt: ^Table
	switch no_variant(o.tt_) {
	case TTABLE:
		mt = (^Table)(o.value_.gc).metatable
	// TODO(phase-6): case TUSERDATA -> the userdata's own metatable.
	case:
		mt = g.mt[no_variant(o.tt_)]
	}
	if mt != nil {
		return luaH_Hgetshortstr(mt, g.tmname[event])
	}
	return &g.nilvalue
}

// TODO(phase-5): luaT_callTM / luaT_callTMres / luaT_trybinTM / luaT_tryconcatTM /
// luaT_callorderTM and the vararg helpers -- they invoke the VM's call protocol,
// which does not exist until the trampoline lands.
