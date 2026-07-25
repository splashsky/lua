package tests

// utf8lib_test.odin -- honest end-to-end tests for the utf8 library
// (src/stdlib/utf8lib.odin), driven through real Lua chunks. We exercise the
// round trip char<->codepoint, multi-byte length, byte offsets across variable-
// width characters, the codes() iterator, and the fail return on malformed input.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

utf8_state :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	lua.lua_pushcfunction(L, aux.luaopen_base)
	lua.lua_call(L, 0, 0)
	lua.lua_pushcfunction(L, aux.luaopen_utf8)
	lua.lua_call(L, 0, 1)
	lua.lua_setglobal(L, "utf8")
	return L
}

utf8_run :: proc(L: ^lua.Lua_State, src: string) -> lua.Thread_Status {
	if st := aux.luaL_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0)
}

@(test)
utf8_char_codepoint_roundtrip :: proc(t: ^testing.T) {
	L := utf8_state()
	defer lua.close_state(L)
	// H, é (U+00E9, 2 bytes), l, l, o -> 6 bytes, 5 characters.
	st := utf8_run(
		L,
		"local s = utf8.char(72, 233, 108, 108, 111)\n" +
		"assert(#s == 6, 'byte length')\n" +
		"assert(utf8.len(s) == 5, 'char length')\n" +
		"local a, b, c, d, e = utf8.codepoint(s, 1, #s)\n" +
		"assert(a == 72 and b == 233 and c == 108 and d == 108 and e == 111, 'codepoints')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "char/codepoint round trip preserves every code point")
}

@(test)
utf8_offset_navigation :: proc(t: ^testing.T) {
	L := utf8_state()
	defer lua.close_state(L)
	// A (1 byte), U+1F600 emoji (4 bytes), B (1 byte) -> 6 bytes.
	st := utf8_run(
		L,
		"local s = utf8.char(0x41, 0x1F600, 0x42)\n" +
		"assert(#s == 6, 'byte length')\n" +
		"assert(utf8.offset(s, 1) == 1, 'first char')\n" +
		"assert(utf8.offset(s, 2) == 2, 'emoji starts at byte 2')\n" +
		"assert(utf8.offset(s, 3) == 6, 'B starts at byte 6')\n" +
		"assert(utf8.offset(s, -1) == 6, 'last char from the end')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "offset walks variable-width characters correctly")
}

@(test)
utf8_codes_iterator :: proc(t: ^testing.T) {
	L := utf8_state()
	defer lua.close_state(L)
	// U+263A smiley (3 bytes) then A (1 byte).
	st := utf8_run(
		L,
		"local s = utf8.char(0x263A, 0x41)\n" +
		"local ps, cs = {}, {}\n" +
		"for p, c in utf8.codes(s) do ps[#ps+1] = p; cs[#cs+1] = c end\n" +
		"assert(#cs == 2, 'two characters')\n" +
		"assert(cs[1] == 0x263A and cs[2] == 0x41, 'code points')\n" +
		"assert(ps[1] == 1 and ps[2] == 4, 'byte positions')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "codes() yields (position, codepoint) for each character")
}

@(test)
utf8_len_invalid :: proc(t: ^testing.T) {
	L := utf8_state()
	defer lua.close_state(L)
	// 0xFF is never a valid lead byte -> len must report fail plus position 1.
	st := utf8_run(
		L,
		"local n, pos = utf8.len('\\xff\\xfe')\n" +
		"assert(n == nil, 'fail on malformed input')\n" +
		"assert(pos == 1, 'position of the bad byte')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "len reports failure and offending position on bad UTF-8")
}

@(test)
utf8_charpattern_and_ascii :: proc(t: ^testing.T) {
	L := utf8_state()
	defer lua.close_state(L)
	st := utf8_run(
		L,
		"assert(type(utf8.charpattern) == 'string', 'charpattern is a string')\n" +
		"assert(utf8.len('hello') == 5, 'ascii length')\n" +
		"assert(utf8.codepoint('hello', 1) == 104, 'first byte is h')\n" +
		"return utf8.charpattern",
	)
	testing.expect(t, st == .Ok)
	// The pattern begins with '[' and, being a byte string with an embedded NUL,
	// is 14 bytes long -- verify the observable shape without asserting internals.
	s, _ := lua.lua_tolstring(L, -1)
	testing.expect(t, len(s) == 14 && s[0] == '[', "charpattern has the reference bytes")
}
