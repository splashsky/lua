package tests

// userdata_meta_test.odin -- tests for the Phase-6 completion that gives *full
// userdata* its own metatable everywhere metamethods are resolved. Before this,
// `luaT_gettmbyobj` and friends only honored a table's metatable, so userdata
// `__index`/`__eq`/`__gc`/`__name` were silently ignored. These tests prove, by
// observation, that a userdata's own metatable is now consulted:
//   * the raw event lookup (`luaT_gettmbyobj`) finds a userdata's metamethods,
//   * `__eq` between two distinct userdata is honored by `luaV_equalobj`,
//   * `__name` on a userdata is reported by `luaT_objtypename`,
//   * a userdata `__gc` finalizer actually runs during collection.

import "core:testing"
import lua "luao:lua"

// Build a fresh full userdata (no user values, minimal payload) and return it.
@(private = "file")
new_udata :: proc(L: ^lua.Lua_State) -> ^lua.Udata {
	return lua.luaS_newudata(L, 1, 0)
}

// Install `key = value` (both by string key) into table `mt`.
@(private = "file")
set_str_field :: proc(L: ^lua.Lua_State, mt: ^lua.Table, key: string, value: ^lua.TValue) {
	k: lua.TValue
	lua.set_string(&k, lua.luaS_new(L, key))
	_ = lua.luaH_set(L, mt, &k, value)
}

// `luaT_gettmbyobj` must resolve an event through the userdata's *own* metatable,
// exactly as it does for a table. We install a sentinel `__index` value on a
// userdata's metatable and confirm the raw event lookup hands it back.
@(test)
udata_gettmbyobj_uses_own_metatable :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	u := new_udata(L)
	uo: lua.TValue
	lua.set_userdata(&uo, u)
	push_root(L, lua.obj2gco(u))

	mt := lua.luaH_new(L)
	push_root(L, lua.obj2gco(mt))
	sentinel: lua.TValue
	lua.set_string(&sentinel, lua.luaS_new(L, "userdata-index-hook"))
	set_str_field(L, mt, "__index", &sentinel)
	u.metatable = mt

	tm := lua.luaT_gettmbyobj(L, &uo, lua.TM_INDEX)
	testing.expect(t, !lua.is_nil(tm), "userdata's own __index is found")
	testing.expect(t, lua.is_string(tm), "the resolved metamethod is our sentinel")
	testing.expect_value(t, str_contents(lua.str_value(tm)), "userdata-index-hook")

	// A different event with no entry must still report absent.
	none := lua.luaT_gettmbyobj(L, &uo, lua.TM_ADD)
	testing.expect(t, lua.is_nil(none), "an unset event is absent, not spuriously found")
}

// `luaT_objtypename` must report a userdata's `__name` for error messages.
@(test)
udata_objtypename_reports_name :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	u := new_udata(L)
	uo: lua.TValue
	lua.set_userdata(&uo, u)
	push_root(L, lua.obj2gco(u))

	// Without a metatable, the generic type name is used.
	testing.expect_value(t, lua.luaT_objtypename(L, &uo), "userdata")

	mt := lua.luaH_new(L)
	push_root(L, lua.obj2gco(mt))
	nameval: lua.TValue
	lua.set_string(&nameval, lua.luaS_new(L, "Point"))
	set_str_field(L, mt, "__name", &nameval)
	u.metatable = mt

	testing.expect_value(t, lua.luaT_objtypename(L, &uo), "Point")
}

// `luaV_equalobj` must consult `__eq` when two *distinct* userdata share (or each
// carry) a metatable defining it. We wire an `__eq` that always returns true and
// confirm two different userdata now compare equal; raw identity still says they
// are not the same object.
@(test)
udata_eq_metamethod_honored :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	a := new_udata(L)
	b := new_udata(L)
	ao: lua.TValue
	bo: lua.TValue
	lua.set_userdata(&ao, a)
	lua.set_userdata(&bo, b)
	push_root(L, lua.obj2gco(a))
	push_root(L, lua.obj2gco(b))

	mt := lua.luaH_new(L)
	push_root(L, lua.obj2gco(mt))
	eqval: lua.TValue
	lua.set_c_function(&eqval, udata_eq_true)
	set_str_field(L, mt, "__eq", &eqval)
	a.metatable = mt
	b.metatable = mt

	// Distinct objects: raw equality is false, but __eq makes them equal.
	testing.expect(t, !lua.raw_equal(&ao, &bo), "distinct userdata are not raw-equal")
	testing.expect(t, lua.luaV_equalobj(L, &ao, &bo), "__eq reports them equal")

	pop_root(L) // mt
	pop_root(L) // b
	pop_root(L) // a
}

// An `__eq` metamethod that unconditionally returns true. It leaves a single
// truthy result on the stack, matching the C-function calling convention.
@(private = "file")
udata_eq_true :: proc "c" (Lp: rawptr) -> i32 {
	L := (^lua.Lua_State)(Lp)
	// Push `true` as the single return value.
	lua.set_bool(&L.stack[L.top].val, true)
	L.top += 1
	return 1
}

// The count of userdata finalizer runs, bumped by `udata_finalizer`.
@(private = "file")
udata_final_count: int

// A `__gc` finalizer for userdata: records that it ran.
@(private = "file")
udata_finalizer :: proc "c" (Lp: rawptr) -> i32 {
	udata_final_count += 1
	return 0
}

// A full userdata whose metatable defines `__gc` must have that finalizer run
// when the userdata is collected -- the capability that was blocked until
// `luaT_gettmbyobj` learned about userdata metatables (GCTM fetches `__gc`
// through it). We enroll an unrooted userdata and confirm its `__gc` fired once.
@(test)
udata_gc_finalizer_runs :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	udata_final_count = 0

	mt := lua.luaH_new(L)
	push_root(L, lua.obj2gco(mt))
	gcval: lua.TValue
	lua.set_c_function(&gcval, udata_finalizer)
	set_str_field(L, mt, "__gc", &gcval)

	victim := new_udata(L) // deliberately not rooted
	victim.metatable = mt
	lua.luaC_checkfinalizer(L, lua.obj2gco(victim), mt)

	lua.lua_gc(L, lua.LUA_GCCOLLECT)
	testing.expect_value(t, udata_final_count, 1)

	pop_root(L) // mt
}
