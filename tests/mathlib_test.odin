package tests

// mathlib_test.odin -- honest end-to-end tests for the math library
// (src/stdlib/mathlib.odin). We install `math` as a global and drive real Lua
// chunks. RNG tests assert reproducibility (same explicit seed => same stream)
// and range membership, never a hard-coded magic draw.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

math_state :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	// base gives us assert/pcall for expressive chunks.
	lua.lua_pushcfunction(L, aux.luaopen_base)
	lua.lua_call(L, 0, 0)
	// install math as a global table
	lua.lua_pushcfunction(L, aux.luaopen_math)
	lua.lua_call(L, 0, 1)
	lua.lua_setglobal(L, "math")
	return L
}

math_run :: proc(L: ^lua.Lua_State, src: string) -> lua.Thread_Status {
	if st := aux.luaL_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0)
}

// Convenience: run a chunk that returns one integer and fetch it.
math_int :: proc(L: ^lua.Lua_State, src: string) -> (lua.Integer, bool) {
	if math_run(L, src) != .Ok {
		return 0, false
	}
	defer lua.lua_settop(L, 0)
	return lua.lua_tointegerx(L, -1)
}

math_num :: proc(L: ^lua.Lua_State, src: string) -> (lua.Number, bool) {
	if math_run(L, src) != .Ok {
		return 0, false
	}
	defer lua.lua_settop(L, 0)
	return lua.lua_tonumberx(L, -1)
}

@(test)
math_rounding_and_type :: proc(t: ^testing.T) {
	L := math_state()
	defer lua.close_state(L)

	n, ok := math_int(L, "return math.floor(3.7)")
	testing.expect(t, ok && n == 3, "floor(3.7)==3")
	n, ok = math_int(L, "return math.ceil(3.2)")
	testing.expect(t, ok && n == 4, "ceil(3.2)==4")
	n, ok = math_int(L, "return math.floor(5)") // integer passes through
	testing.expect(t, ok && n == 5, "floor(5)==5 as integer")

	testing.expect(t, math_run(L, "return math.type(3)") == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "integer", "type(3)=='integer'")
	lua.lua_settop(L, 0)
	testing.expect(t, math_run(L, "return math.type(3.0)") == .Ok)
	s, _ = lua.lua_tolstring(L, -1)
	testing.expect(t, s == "float", "type(3.0)=='float'")
	lua.lua_settop(L, 0)
	testing.expect(t, math_run(L, "return math.type('x')") == .Ok)
	testing.expect(t, lua.lua_isnil(L, -1), "type of non-number is nil")
}

@(test)
math_abs_fmod_minmax :: proc(t: ^testing.T) {
	L := math_state()
	defer lua.close_state(L)

	n, ok := math_int(L, "return math.abs(-5)")
	testing.expect(t, ok && n == 5, "abs(-5)==5")
	// abs(mininteger) must wrap to mininteger (two's complement), like reference.
	n, ok = math_int(L, "return math.abs(math.mininteger) == math.mininteger and 1 or 0")
	testing.expect(t, ok && n == 1, "abs(mininteger) wraps to mininteger")

	n, ok = math_int(L, "return math.fmod(7, 3)")
	testing.expect(t, ok && n == 1, "fmod(7,3)==1")
	f, okf := math_num(L, "return math.fmod(5.5, 2)")
	testing.expect(t, okf && f == 1.5, "fmod(5.5,2)==1.5")

	n, ok = math_int(L, "return math.max(1, 5, 3)")
	testing.expect(t, ok && n == 5, "max==5")
	n, ok = math_int(L, "return math.min(4, 2, 8)")
	testing.expect(t, ok && n == 2, "min==2")
}

@(test)
math_toint_sqrt_consts :: proc(t: ^testing.T) {
	L := math_state()
	defer lua.close_state(L)

	n, ok := math_int(L, "return math.tointeger(3.0)")
	testing.expect(t, ok && n == 3, "tointeger(3.0)==3")
	testing.expect(t, math_run(L, "return math.tointeger(3.5)") == .Ok)
	testing.expect(t, lua.lua_isnil(L, -1), "tointeger(3.5)==nil")
	lua.lua_settop(L, 0)

	f, okf := math_num(L, "return math.sqrt(16)")
	testing.expect(t, okf && f == 4.0, "sqrt(16)==4")

	// maxinteger/mininteger are the exact 64-bit bounds.
	n, ok = math_int(L, "return math.maxinteger")
	testing.expect(t, ok && n == max(i64), "maxinteger is 2^63-1")
	n, ok = math_int(L, "return math.mininteger")
	testing.expect(t, ok && n == min(i64), "mininteger is -2^63")

	// pi is close to the mathematical constant.
	f, okf = math_num(L, "return math.pi")
	testing.expect(t, okf && f > 3.14159 && f < 3.14160, "pi ~ 3.14159")
	// huge is +inf: bigger than any finite float.
	testing.expect(t, math_run(L, "return math.huge > 1e308") == .Ok)
	testing.expect(t, lua.lua_toboolean(L, -1), "huge > 1e308")
}

@(test)
math_random_reproducible :: proc(t: ^testing.T) {
	L := math_state()
	defer lua.close_state(L)
	// The same explicit seed must reproduce the same draw -- this proves our
	// xoshiro256** port is deterministic, without hard-coding any magic value.
	st := math_run(
		L,
		"math.randomseed(42, 0); local a = math.random(1, 1000000); " +
		"math.randomseed(42, 0); local b = math.random(1, 1000000); " +
		"return (a == b) and 1 or 0",
	)
	testing.expect(t, st == .Ok)
	n, _ := lua.lua_tointegerx(L, -1)
	testing.expect(t, n == 1, "same seed reproduces the same draw")
}

@(test)
math_random_ranges :: proc(t: ^testing.T) {
	L := math_state()
	defer lua.close_state(L)
	// math.random() must land in [0, 1); math.random(1,6) in [1,6]. We check many
	// draws so the bounds are meaningfully exercised.
	st := math_run(
		L,
		"math.randomseed(1, 2)\n" +
		"for i = 1, 1000 do\n" +
		"  local r = math.random()\n" +
		"  assert(r >= 0 and r < 1, 'unit range')\n" +
		"  local d = math.random(1, 6)\n" +
		"  assert(d >= 1 and d <= 6, 'dice range')\n" +
		"  assert(math.type(d) == 'integer', 'dice is integer')\n" +
		"end\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "1000 draws stay in range")
}
