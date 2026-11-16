package tests

// tablib_test.odin -- honest end-to-end tests for the table library
// (src/stdlib/tablib.odin). Driven through real Lua chunks; the sort tests
// verify true ordering (including a shuffled 300-element array and a custom
// comparator) rather than any incidental internal.

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

tab_state :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	kernel.api_pushcfunction(L, stdlib.open_base)
	kernel.api_call(L, 0, 0)
	kernel.api_pushcfunction(L, stdlib.open_table)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "table")
	return L
}

tab_run :: proc(L: ^kernel.State, src: string) -> kernel.Thread_Status {
	if st := stdlib.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return kernel.api_pcall(L, 0, kernel.MULTRET, 0)
}

@(test)
tab_insert_remove :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
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
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, s == "5,20,30,40", "insert/remove reshape the sequence")
}

@(test)
tab_concat :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	testing.expect(t, tab_run(L, "return table.concat({'a','b','c'}, '-')") == .Ok)
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, s == "a-b-c", "concat joins with the separator")

	testing.expect(t, tab_run(L, "return table.concat({1,2,3,4}, ',', 2, 3)") == .Ok)
	s, _ = kernel.api_tolstring(L, -1)
	testing.expect(t, s == "2,3", "concat honors the i..j range")
}

@(test)
tab_pack_unpack :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	st := tab_run(
		L,
		"local p = table.pack(7, 8, nil, 9)\n" +
		"assert(p.n == 4, 'pack records n including holes')\n" +
		"local a, b, c = table.unpack({100, 200, 300})\n" +
		"return a + b + c",
	)
	testing.expect(t, st == .Ok)
	n, ok := kernel.api_tointegerx(L, -1)
	testing.expect(t, ok && n == 600, "unpack yields all elements")
}

@(test)
tab_unpack_non_tables :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stdlib.open_string)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "string")
	kernel.api_pushcfunction(L, stdlib.open_debug)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "debug")
	st := tab_run(L, `
		-- The non-table example from upstream sort.lua.
		local oldmt = debug.getmetatable(0)
		local str = 'hello'
		debug.setmetatable(0, {
		  __len = function() return #str end,
		  __index = function(_, i) return string.sub(str, i, i) end
		})
		assert(table.concat({table.unpack(0)}) == str)
		debug.setmetatable(0, oldmt)

		-- A string needs __index, but has an intrinsic length, not __len.
		local oldstrmt = debug.getmetatable(str)
		debug.setmetatable(str, {__index = function(s, i) return string.sub(s, i, i) end})
		assert(table.concat({table.unpack(str)}) == str)
		assert(table.concat(str) == str)
		debug.setmetatable(str, nil)
		assert(not pcall(table.unpack, str)) -- strings still need __index
		debug.setmetatable(str, oldstrmt)
	`)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "non-table unpack: %s", msg)
	}
}

@(test)
tab_unpack_checks_argument :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stdlib.open_string)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "string")
	st := tab_run(L, `
		local ok, err = pcall(function() table.unpack(nil) end)
		assert(not ok and err:find("bad argument #1 to 'unpack' %(table expected, got nil%)"))
		ok, err = pcall(function() table.unpack(nil, 'bad', 0) end)
		assert(not ok and err:find("bad argument #1 to 'unpack' %(table expected, got nil%)"))
		ok, err = pcall(function() table.unpack(42, 2, 1) end)
		assert(not ok and err:find("bad argument #1 to 'unpack' %(table expected, got number%)"))
	`)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "unpack argument check: %s", msg)
	}
}

@(test)
tab_unpack_length_before_indices :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	st := tab_run(L, `
		local calls = 0
		local t = setmetatable({10, 20}, {__len = function() calls = calls + 1; return 2 end})
		assert(table.unpack(t, 2, 2) == 20 and calls == 1)
		local ok = pcall(table.unpack, t, 'bad', 1)
		assert(not ok and calls == 2) -- __len runs before checking argument #2
	`)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "unpack length ordering: %s", msg)
	}
}

@(test)
tab_move :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	// Overlapping move within one table must not clobber unread elements.
	st := tab_run(
		L,
		"local t = {1, 2, 3, 4, 5}\n" +
		"table.move(t, 1, 3, 3)\n" + // t becomes {1,2,1,2,3}
		"return table.concat(t, ',')",
	)
	testing.expect(t, st == .Ok)
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, s == "1,2,1,2,3", "overlapping move copies right-to-left")
}

@(test)
tab_sort_default :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
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
	defer kernel.close_state(L)
	st := tab_run(
		L,
		"local t = {3, 1, 4, 1, 5, 9, 2, 6}\n" +
		"table.sort(t, function(a, b) return a > b end)\n" + // descending
		"for i = 2, #t do assert(t[i-1] >= t[i], 'descending') end\n" +
		"return t[1]..','..t[#t]",
	)
	testing.expect(t, st == .Ok)
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, s == "9,1", "custom comparator sorts descending")
}

@(test)
tab_sort_proxy_and_order_metamethods :: proc(t: ^testing.T) {
	L := tab_state()
	defer kernel.close_state(L)
	st := tab_run(L, `
		local reads, writes, comparisons = 0, 0, 0
		local mt = {__lt = function(a, b)
			comparisons = comparisons + 1
			collectgarbage('collect')
			return a.v < b.v
		end}
		local values = {}
		for i = 1, 24 do values[i] = setmetatable({v = (i * 13) % 25}, mt) end
		local proxy = setmetatable({}, {
			__len = function() return #values end,
			__index = function(_, k) reads = reads + 1; return values[k] end,
			__newindex = function(_, k, v) writes = writes + 1; values[k] = v end,
		})
		table.sort(proxy)
		for i = 2, #values do assert(values[i-1].v <= values[i].v) end
		assert(reads > 0 and writes > 0 and comparisons > 0)
		local ok, err = pcall(table.sort, {1,2,3,4,5}, function() return true end)
		assert(not ok)
		return err
	`)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "proxy sort: %s", msg)
	} else {
		msg, ok := kernel.api_tolstring(L, -1)
		testing.expect(t, ok && msg == "invalid order function for sorting")
	}
}
