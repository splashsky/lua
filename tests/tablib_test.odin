package tests

// tablib_test.odin -- honest end-to-end tests for the table library
// (src/stdlib/tablib.odin). Driven through real Lua chunks; the sort tests
// verify true ordering (including a shuffled 300-element array and a custom
// comparator) rather than any incidental internal.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

tab_state :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	lua.lua_pushcfunction(L, aux.luaopen_base)
	lua.lua_call(L, 0, 0)
	lua.lua_pushcfunction(L, aux.luaopen_table)
	lua.lua_call(L, 0, 1)
	lua.lua_setglobal(L, "table")
	return L
}

tab_run :: proc(L: ^lua.Lua_State, src: string) -> lua.Thread_Status {
	if st := aux.luaL_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0)
}

@(test)
tab_insert_remove :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	st := tab_run(
		L,
		"local t = {10, 20, 30}\n" +
		"table.insert(t, 40)\n" + // append -> {10,20,30,40}
		"table.insert(t, 1, 5)\n" + // shift -> {5,10,20,30,40}
		"local r = table.remove(t, 2)\n" + // remove 10 -> {5,20,30,40}
		"assert(r == 10, 'removed value')\n" +
		"assert(#t == 4, 'length')\n" +
		"return t[1]..','..t[2]..','..t[3]..','..t[4]",
	)
	testing.expect(t, st == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "5,20,30,40", "insert/remove reshape the sequence")
}

@(test)
tab_concat :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	testing.expect(t, tab_run(L, "return table.concat({'a','b','c'}, '-')") == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "a-b-c", "concat joins with the separator")

	testing.expect(t, tab_run(L, "return table.concat({1,2,3,4}, ',', 2, 3)") == .Ok)
	s, _ = lua.lua_tolstring(L, -1)
	testing.expect(t, s == "2,3", "concat honors the i..j range")
}

@(test)
tab_pack_unpack :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	st := tab_run(
		L,
		"local p = table.pack(7, 8, nil, 9)\n" +
		"assert(p.n == 4, 'pack records n including holes')\n" +
		"local a, b, c = table.unpack({100, 200, 300})\n" +
		"return a + b + c",
	)
	testing.expect(t, st == .Ok)
	n, ok := lua.lua_tointegerx(L, -1)
	testing.expect(t, ok && n == 600, "unpack yields all elements")
}

@(test)
tab_move :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	// Overlapping move within one table must not clobber unread elements.
	st := tab_run(
		L,
		"local t = {1, 2, 3, 4, 5}\n" +
		"table.move(t, 1, 3, 3)\n" + // t becomes {1,2,1,2,3}
		"return table.concat(t, ',')",
	)
	testing.expect(t, st == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "1,2,1,2,3", "overlapping move copies right-to-left")
}

@(test)
tab_sort_default :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	// Sort a shuffled 300-element array and verify it is fully ordered and a
	// permutation of the input (sum preserved). This genuinely exercises the
	// quicksort partition and the randomized-pivot fallback.
	st := tab_run(
		L,
		"local t = {}\n" +
		"local x = 12345\n" +
		"for i = 1, 300 do\n" +
		"  x = (x * 1103515245 + 12345) % 2147483648\n" + // simple LCG shuffle source
		"  t[i] = x % 1000\n" +
		"end\n" +
		"local before = 0\n" +
		"for i = 1, #t do before = before + t[i] end\n" +
		"table.sort(t)\n" +
		"local after = 0\n" +
		"for i = 1, #t do after = after + t[i] end\n" +
		"for i = 2, #t do assert(t[i-1] <= t[i], 'ascending') end\n" +
		"assert(before == after, 'sort is a permutation')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "300-element sort is correct and stable in multiset")
}

@(test)
tab_sort_comparator :: proc(t: ^testing.T) {
	L := tab_state()
	defer lua.close_state(L)
	st := tab_run(
		L,
		"local t = {3, 1, 4, 1, 5, 9, 2, 6}\n" +
		"table.sort(t, function(a, b) return a > b end)\n" + // descending
		"for i = 2, #t do assert(t[i-1] >= t[i], 'descending') end\n" +
		"return t[1]..','..t[#t]",
	)
	testing.expect(t, st == .Ok)
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, s == "9,1", "custom comparator sorts descending")
}
