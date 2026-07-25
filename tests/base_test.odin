package tests

// base_test.odin -- honest end-to-end tests for the basic library
// (src/stdlib/base.odin). We install the library into a fresh state exactly as an
// embedder would, then run real Lua chunks and assert on their observable results.
// Nothing inspects a private field.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

// A fresh state with the basic library installed as globals.
base_state :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	lua.lua_pushcfunction(L, aux.luaopen_base)
	lua.lua_call(L, 0, 0) // luaopen_base installs into the global table
	return L
}

// Load and run `src`, returning the pcall status. Results are left on the stack.
base_run :: proc(L: ^lua.Lua_State, src: string) -> lua.Thread_Status {
	if st := aux.luaL_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0)
}

@(test)
base_type_and_tonumber :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)

	testing.expect(t, base_run(L, "return type(3)") == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "number", "type(3) == 'number'")
	lua.lua_settop(L, 0)

	testing.expect(t, base_run(L, "return tonumber('ff', 16)") == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 255, "tonumber('ff',16) == 255")
	lua.lua_settop(L, 0)

	testing.expect(t, base_run(L, "return tonumber('  -10  ', 2)") == .Ok)
	n2, ok2 := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok2 && n2 == -2, "binary -10 with padding == -2")
	lua.lua_settop(L, 0)

	testing.expect(t, base_run(L, "return tonumber('nope')") == .Ok)
	testing.expect(t, lua.lua_isnil(L, -1), "tonumber of garbage is nil")
}

@(test)
base_ipairs_sum :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)
	st := base_run(L, "local t={10,20,30}; local s=0; for i,v in ipairs(t) do s=s+v end; return s")
	testing.expect(t, st == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 60, "ipairs sum == 60")
}

@(test)
base_pairs_count :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)
	st := base_run(L, "local t={a=1,b=2,c=3}; local c=0; for k,v in pairs(t) do c=c+1 end; return c")
	testing.expect(t, st == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 3, "pairs visits all 3 keys")
}

@(test)
base_pcall_error :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)
	st := base_run(L, "local ok, err = pcall(function() error('boom') end); return ok, err")
	testing.expect(t, st == .Ok)
	// results: ok (false), err (string ending in 'boom')
	testing.expect(t, lua.lua_toboolean(L, -2) == false, "pcall reports failure")
	msg, _ := lua.lua_tolstring(L, -1)
	// The message carries a source:line prefix; assert it ends with our text.
	has := len(msg) >= 4 && msg[len(msg) - 4:] == "boom"
	testing.expect(t, has, "error message preserves 'boom'")
}

@(test)
base_select_and_assert :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)

	testing.expect(t, base_run(L, "return select('#', 1, 2, 3)") == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 3, "select('#',...) counts args")
	lua.lua_settop(L, 0)

	testing.expect(t, base_run(L, "return assert(5, 'unused')") == .Ok)
	// assert returns all its arguments; the passed-through value is at -2.
	n2, ok2 := lua.lua_tointegerx(L, -2)
	testing.expect(t, ok2 && n2 == 5, "assert passes through its value")
	lua.lua_settop(L, 0)

	// A failing assert must raise with the given message.
	st := base_run(L, "return assert(false, 'nope')")
	testing.expect(t, st != .Ok, "assert(false, ...) raises")
	msg, _ := lua.lua_tolstring(L, -1)
	// error() prepends a source:line prefix, so assert on the suffix.
	hasnope := len(msg) >= 4 && msg[len(msg) - 4:] == "nope"
	testing.expect(t, hasnope, "assert uses the supplied message verbatim")
}

@(test)
base_setmetatable_index :: proc(t: ^testing.T) {
	L := base_state()
	defer lua.close_state(L)
	st := base_run(
		L,
		"local base={x=7}; local t=setmetatable({}, {__index=base}); return t.x",
	)
	testing.expect(t, st == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 7, "__index metamethod resolves through setmetatable")
}
