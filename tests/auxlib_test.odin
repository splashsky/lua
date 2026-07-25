package tests

// auxlib_test.odin -- honest, black-box tests for the auxiliary library
// (src/stdlib/auxlib.odin). Every assertion is made through the public API or the
// auxlib surface itself; none peeks at a private field. Each test proves an
// observable behaviour of the real reference-Lua auxlib contract.

import "base:runtime"
import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

aux_new :: proc() -> ^lua.Lua_State {
	return lua.new_state(lua.default_allocator())
}

// The reference system must hand out distinct keys, retrieve the stored values,
// and -- crucially for the 5.5 layout -- reuse a freed slot from the t[1] freelist.
@(test)
aux_ref_freelist_reuse :: proc(t: ^testing.T) {
	L := aux_new()
	defer lua.close_state(L)

	lua.lua_newtable(L) // the ref table lives at stack index 1
	tref := 1

	lua.lua_pushstring(L, "hello")
	r1 := aux.luaL_ref(L, tref)
	lua.lua_pushinteger(L, 42)
	r2 := aux.luaL_ref(L, tref)
	testing.expect(t, r1 != r2, "distinct references must differ")

	// Both values are retrievable through the table by their reference key.
	lua.lua_rawgeti(L, tref, lua.Integer(r1))
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "hello", "ref r1 must retrieve its value")
	lua.lua_pop(L, 1)

	// Free r1 and take a new reference: it must reuse r1's slot (freelist at t[1]).
	aux.luaL_unref(L, tref, r1)
	lua.lua_pushstring(L, "again")
	r3 := aux.luaL_ref(L, tref)
	testing.expect(t, r3 == r1, "a fresh ref must reuse the freed slot")

	// nil has the fixed REFNIL reference.
	lua.lua_pushnil(L)
	rn := aux.luaL_ref(L, tref)
	testing.expect(t, rn == aux.LUA_REFNIL, "nil must map to LUA_REFNIL")
}

// The growable Buffer must produce the exact bytes fed to it, even well past the
// inline scratch size (which forces the heap-box spill path).
@(test)
aux_buffer_spills_correctly :: proc(t: ^testing.T) {
	L := aux_new()
	defer lua.close_state(L)

	B: aux.Buffer
	aux.luaL_buffinit(L, &B)
	N :: 5000 // comfortably larger than LUAL_BUFFERSIZE (1024)
	for i in 0 ..< N {
		aux.luaL_addchar(&B, u8('a' + u8(i % 26)))
	}
	aux.luaL_pushresult(&B)

	s, ok := lua.lua_tolstring(L, -1)
	testing.expect(t, ok, "result must be a string")
	testing.expect(t, len(s) == N, "length must match bytes added")
	good := true
	for i in 0 ..< N {
		if s[i] != u8('a' + u8(i % 26)) {
			good = false
			break
		}
	}
	testing.expect(t, good, "every byte must survive the spill intact")
}

// newmetatable + testudata: a userdata carrying the registered metatable resolves
// to its payload pointer; a different type name does not.
@(test)
aux_udata_metatable_roundtrip :: proc(t: ^testing.T) {
	L := aux_new()
	defer lua.close_state(L)

	p := lua.lua_newuserdatauv(L, 16, 0) // userdata on top
	created := aux.luaL_newmetatable(L, "MyType") // metatable on top, userdata below
	testing.expect(t, created, "first newmetatable must create the table")
	lua.lua_setmetatable(L, -2) // attach metatable to the userdata

	got := aux.luaL_testudata(L, -1, "MyType")
	testing.expect(t, got == p, "matching type name must return the payload")

	wrong := aux.luaL_testudata(L, -1, "OtherType")
	testing.expect(t, wrong == nil, "mismatched type name must return nil")
}

// luaL_loadstring compiles a chunk that runs to a correct result.
@(test)
aux_loadstring_runs :: proc(t: ^testing.T) {
	L := aux_new()
	defer lua.close_state(L)

	st := aux.luaL_loadstring(L, "return 3 + 4")
	testing.expect(t, st == .Ok, "chunk must compile")
	call := lua.lua_pcall(L, 0, 1, 0)
	testing.expect(t, call == .Ok, "chunk must run")
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 7, "3 + 4 must be 7")
}

// A trivial registered function is callable through a table built by newlib.
aux_test_fn :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.Lua_State)(Lp)
	lua.lua_pushinteger(L, 99)
	return 1
}

@(test)
aux_newlib_registers :: proc(t: ^testing.T) {
	L := aux_new()
	defer lua.close_state(L)

	regs := []aux.Reg{{"f", aux_test_fn}}
	aux.luaL_newlib(L, regs) // table with field f on top
	lua.lua_getfield(L, -1, "f")
	lua.lua_call(L, 0, 1)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 99, "registered function must run")
}
