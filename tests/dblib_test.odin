package tests

// dblib_test.odin -- honest end-to-end tests for the debug library
// (src/stdlib/dblib.odin) and the luaL_traceback helper. Each test drives real
// Lua chunks that exercise observable debug semantics: introspecting functions and
// stack levels, reading/writing locals and upvalues, upvalue identity and joining,
// metatable/registry access, hooks, and traceback formatting.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

dbg_state :: proc() -> ^lua.State {
	L := lua.new_state(lua.default_allocator())
	lua.api_pushcfunction(L, aux.open_base)
	lua.api_call(L, 0, 0)
	lua.api_pushcfunction(L, aux.open_string)
	lua.api_call(L, 0, 1)
	lua.api_setglobal(L, "string")
	lua.api_pushcfunction(L, aux.open_debug)
	lua.api_call(L, 0, 1)
	lua.api_setglobal(L, "debug")
	return L
}

dbg_run :: proc(L: ^lua.State, src: string) -> lua.Thread_Status {
	if st := aux.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.api_pcall(L, 0, lua.MULTRET, 0)
}

dbg_eval :: proc(t: ^testing.T, L: ^lua.State, src: string) -> string {
	st := dbg_run(L, src)
	if st != .Ok {
		msg, _ := lua.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return ""
	}
	s, _ := lua.api_tolstring(L, -1)
	return s
}

@(test)
dbg_getinfo_function :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		"local function f(a, b) return a + b end\n" +
		"local info = debug.getinfo(f)\n" +
		"assert(type(info) == 'table')\n" +
		"assert(info.what == 'Lua')\n" +
		"assert(info.nparams == 2)\n" +
		"assert(info.isvararg == false)\n" +
		"assert(info.linedefined == 1)\n" +
		"assert(type(info.short_src) == 'string')\n" +
		"assert(type(info.source) == 'string')\n" +
		// a vararg function reports isvararg and zero fixed params
		"local g = function(...) end\n" +
		"local gi = debug.getinfo(g, 'u')\n" +
		"assert(gi.isvararg == true and gi.nparams == 0)\n" +
		// a C function reports what == 'C'
		"assert(debug.getinfo(print, 'S').what == 'C')\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.getinfo on functions")
}

@(test)
dbg_getinfo_level :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		"local function where() return debug.getinfo(1, 'l').currentline end\n" +
		"local ln = where()\n" +
		"assert(type(ln) == 'number' and ln > 0)\n" +
		// out-of-range level yields nil
		"assert(debug.getinfo(1000) == nil)\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.getinfo on stack levels")
}

@(test)
dbg_locals :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		// level form: read a running function's first local
		"local function probe()\n" +
		"  local x = 10\n" +
		"  local name, val = debug.getlocal(1, 1)\n" +
		"  return name, val\n" +
		"end\n" +
		"local n, v = probe()\n" +
		"assert(n == 'x' and v == 10)\n" +
		// setlocal changes it
		"local function probe2()\n" +
		"  local y = 1\n" +
		"  debug.setlocal(1, 1, 99)\n" +
		"  return y\n" +
		"end\n" +
		"assert(probe2() == 99)\n" +
		// function form of getlocal returns just the parameter name
		"local function f(alpha, beta) end\n" +
		"assert(debug.getlocal(f, 1) == 'alpha')\n" +
		"assert(debug.getlocal(f, 2) == 'beta')\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.getlocal/setlocal")
}

@(test)
dbg_upvalues :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		"local function counter()\n" +
		"  local c = 0\n" +
		"  return function() c = c + 1; return c end\n" +
		"end\n" +
		"local f = counter()\n" +
		"local name, val = debug.getupvalue(f, 1)\n" +
		"assert(name == 'c' and val == 0)\n" +
		"f()\n" +
		"assert(select(2, debug.getupvalue(f, 1)) == 1)\n" +
		"debug.setupvalue(f, 1, 100)\n" +
		"assert(f() == 101)\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.getupvalue/setupvalue")
}

@(test)
dbg_upvalue_id_join :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		// two closures over the same local share one upvalue id
		"local function mk()\n" +
		"  local s = 0\n" +
		"  return (function() return s end), (function() s = s + 1 end)\n" +
		"end\n" +
		"local get, inc = mk()\n" +
		"assert(debug.upvalueid(get, 1) ~= nil)\n" +
		"assert(debug.upvalueid(get, 1) == debug.upvalueid(inc, 1))\n" +
		// upvaluejoin makes one closure's upvalue alias another's
		"local function box(v) return function() return v end, function(nv) v = nv end end\n" +
		"local g1 = box(1)\n" +
		"local g2, s2 = box(2)\n" +
		"assert(g1() == 1 and g2() == 2)\n" +
		"debug.upvaluejoin(g1, 1, g2, 1)\n" +
		"assert(g1() == 2)\n" + // g1 now sees g2's upvalue
		"s2(5)\n" +
		"assert(g1() == 5)\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.upvalueid/upvaluejoin")
}

@(test)
dbg_metatable_registry :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		"local t = {}\n" +
		"assert(debug.getmetatable(t) == nil)\n" +
		"local mt = {}\n" +
		"assert(debug.setmetatable(t, mt) == t)\n" + // returns its first argument
		"assert(debug.getmetatable(t) == mt)\n" +
		"assert(debug.getmetatable(5) == nil)\n" + // non-collectable: no metatable
		// the registry is a real table containing the globals at the well-known index
		"local reg = debug.getregistry()\n" +
		"assert(type(reg) == 'table')\n" +
		"assert(reg[2] == _G)\n" + // LUA_RIDX_GLOBALS == 2
		// getuservalue on a non-userdata is fail
		"assert(debug.getuservalue(5) == nil)\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug metatable/registry/uservalue")
}

@(test)
dbg_hooks :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		// gethook reflects a registered call hook and its mask
		"local function myhook() end\n" +
		"debug.sethook(myhook, 'c')\n" +
		"local h, mask = debug.gethook()\n" +
		"assert(h == myhook)\n" +
		"assert(string.find(mask, 'c', 1, true))\n" +
		"debug.sethook()\n" + // clear
		"assert(debug.gethook() == nil)\n" +
		// a count hook actually fires while Lua code runs
		"local calls = 0\n" +
		"debug.sethook(function() calls = calls + 1 end, '', 10)\n" +
		"local s = 0\n" +
		"for i = 1, 200 do s = s + i end\n" +
		"debug.sethook()\n" +
		"assert(calls > 0)\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.sethook/gethook")
}

@(test)
dbg_traceback :: proc(t: ^testing.T) {
	L := dbg_state()
	defer lua.close_state(L)
	src :=
		"local tb = debug.traceback('my message')\n" +
		"assert(type(tb) == 'string')\n" +
		"assert(string.find(tb, 'my message', 1, true))\n" +
		"assert(string.find(tb, 'stack traceback:', 1, true))\n" +
		// a non-string, non-nil message is returned untouched
		"local obj = {}\n" +
		"assert(debug.traceback(obj) == obj)\n" +
		// no message: still a traceback string
		"assert(type(debug.traceback()) == 'string')\n" +
		"return 'ok'"
	testing.expect(t, dbg_eval(t, L, src) == "ok", "debug.traceback formatting")
}
