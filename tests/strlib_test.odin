package tests

// strlib_test.odin -- honest end-to-end tests for the string library
// (src/stdlib/strlib.odin). Everything is driven through real Lua chunks that
// assert observable Lua semantics: pattern matches against hand-computed results,
// pack/unpack round-trips whose bytes we independently reason about, and %q values
// round-tripped back through `load`. No test inspects an incidental internal.

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

str_state :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	kernel.api_pushcfunction(L, stdlib.open_base)
	kernel.api_call(L, 0, 0)
	kernel.api_pushcfunction(L, stdlib.open_string)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "string")
	return L
}

str_run :: proc(L: ^kernel.State, src: string) -> kernel.Thread_Status {
	if st := stdlib.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return kernel.api_pcall(L, 0, kernel.MULTRET, 0)
}

// Convenience: run a chunk, expect success, return the top string.
str_eval :: proc(t: ^testing.T, L: ^kernel.State, src: string) -> string {
	st := str_run(L, src)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return ""
	}
	s, _ := kernel.api_tolstring(L, -1)
	return s
}

@(test)
str_basic_ops :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	// sub with negatives, rep with separator, reverse, upper/lower, byte/char, len.
	src :=
		"local s = 'Hello, World'\n" +
		"assert(#s == 12)\n" +
		"assert(s:sub(1,5) == 'Hello')\n" +
		"assert(s:sub(-5) == 'World')\n" +
		"assert(s:sub(-5,-2) == 'Worl')\n" +
		"assert(('ab'):rep(3, '-') == 'ab-ab-ab')\n" +
		"assert(('ab'):rep(0) == '')\n" +
		"assert(('abc'):reverse() == 'cba')\n" +
		"assert(('AbC'):upper() == 'ABC' and ('AbC'):lower() == 'abc')\n" +
		"assert(string.char(72,105) == 'Hi')\n" +
		"assert(select('#', ('Hi'):byte(1,-1)) == 2)\n" +
		"local a,b = ('Hi'):byte(1,2)\n" +
		"assert(a == 72 and b == 105)\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "basic string operations")
}

@(test)
str_find_and_match :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		// plain find returns 1-based start/end
		"local i,j = string.find('abcXYZ', 'XYZ')\n" +
		"assert(i == 4 and j == 6)\n" +
		// plain search with the 'plain' flag ignores magic chars
		"assert(string.find('a.b', '.', 1, true) == 2)\n" +
		// pattern find with a capture
		"local s,e,cap = string.find('key=value', '(%w+)=')\n" +
		"assert(s == 1 and e == 4 and cap == 'key')\n" +
		// match returns the capture(s)
		"assert(string.match('  2024-01-31', '(%d+)-(%d+)-(%d+)') == '2024')\n" +
		"local y,m,d = string.match('2024-01-31', '(%d+)-(%d+)-(%d+)')\n" +
		"assert(y=='2024' and m=='01' and d=='31')\n" +
		// anchored match only at the start
		"assert(string.match('xabc', '^abc') == nil)\n" +
		"assert(string.match('abcx', '^abc') == 'abc')\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "find/match semantics")
}

@(test)
str_gmatch_iterates :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		"local words = {}\n" +
		"for w in string.gmatch('the quick brown fox', '%a+') do words[#words+1] = w end\n" +
		"assert(#words == 4)\n" +
		"assert(words[1]=='the' and words[4]=='fox')\n" +
		// key=value pairs with two captures
		"local sum = 0\n" +
		"for k,v in string.gmatch('a=1, b=2, c=3', '(%a+)=(%d+)') do sum = sum + tonumber(v) end\n" +
		"assert(sum == 6)\n" +
		// empty-match progression must terminate and visit each position once
		"local n = 0\n" +
		"for _ in string.gmatch('abc', '') do n = n + 1 end\n" +
		"assert(n == 4)\n" + // positions before a,b,c and at the end
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "gmatch iteration")
}

@(test)
str_gsub_replacements :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		// string replacement with a capture reference and a count
		"local r,n = string.gsub('hello world', '(%w+)', '<%1>')\n" +
		"assert(r == '<hello> <world>' and n == 2)\n" +
		// capped replacements
		"assert(string.gsub('aaaa', 'a', 'b', 2) == 'bbaa')\n" +
		// function replacement
		"local up = string.gsub('abc', '%a', function(c) return c:upper() end)\n" +
		"assert(up == 'ABC')\n" +
		// table replacement; nil result keeps the original text
		"local map = {foo='FOO'}\n" +
		"local tr = string.gsub('foo bar', '%a+', map)\n" +
		"assert(tr == 'FOO bar')\n" +
		// function returning nil leaves text unchanged but still counts
		"local rr, cnt = string.gsub('xyz', '%a', function() return nil end)\n" +
		"assert(rr == 'xyz' and cnt == 3)\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "gsub replacement forms")
}

@(test)
str_pattern_specials :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		// %b balanced match
		"assert(string.match('(a(b)c)d', '%b()') == '(a(b)c)')\n" +
		// %f frontier: find a whole word 'THE'
		"assert(string.find('THEATER is not THE', '%f[%u]THE%f[%A]') == 16)\n" +
		// backreference: doubled word
		"assert(string.match('hello hello there', '(%a+) %1') == 'hello')\n" +
		// position capture () yields an integer position
		"local p = string.match('abc', 'b()')\n" +
		"assert(p == 3)\n" +
		// character set with a range and negation
		"assert(string.match('a1b2', '[^%d]') == 'a')\n" +
		"assert(string.match('  x', '[ ]+') == '  ')\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "special pattern items")
}

@(test)
str_format_numbers :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		"assert(string.format('%d', 42) == '42')\n" +
		"assert(string.format('%5d', 42) == '   42')\n" +
		"assert(string.format('%-5d|', 42) == '42   |')\n" +
		"assert(string.format('%05d', 42) == '00042')\n" +
		"assert(string.format('%x', 255) == 'ff')\n" +
		"assert(string.format('%X', 255) == 'FF')\n" +
		"assert(string.format('%o', 8) == '10')\n" +
		"assert(string.format('%c%c', 72, 105) == 'Hi')\n" +
		"assert(string.format('%.2f', 3.14159) == '3.14')\n" +
		"assert(string.format('%g', 0.5) == '0.5')\n" +
		// Reference Lua's bare hexadecimal floats use the shortest exact
		// mantissa, normalize subnormals, and uppercase the whole spelling for %A.
		"assert(string.format('%a', 1.5) == '0x1.8p+0')\n" +
		"assert(string.format('%a', 1.0) == '0x1p+0')\n" +
		"assert(string.format('%a', 0.0) == '0x0p+0')\n" +
		"assert(string.format('%a', -0.0) == '-0x0p+0')\n" +
		"assert(string.format('%a', 2^-1074) == '0x1p-1074')\n" +
		"assert(string.format('%a', 2^1023) == '0x1p+1023')\n" +
		"assert(string.format('%a', 0.1) == '0x1.999999999999ap-4')\n" +
		"assert(string.format('%A', 1.5) == '0X1.8P+0')\n" +
		"assert(string.format('%A', 1/0) == 'INF')\n" +
		"assert(string.format('%a', -1/0) == '-inf')\n" +
		"assert(string.format('%A', -(0/0)) == 'NAN')\n" +
		// `%a`/`%A` modifiers are intentionally unavailable in PUC Lua.
		"local expected = \"modifiers for format '%a'/'%A' not implemented\"\n" +
		"for _, f in ipairs{'%5.2a', '%-10a', '%#a', '%5.2A', '%-10A', '%#A'} do\n" +
		"  local ok, err = pcall(string.format, f, 1.5)\n" +
		"  assert(not ok and err:sub(-#expected) == expected)\n" +
		"end\n" +
		"assert(string.format('%d and %s', 1, 'two') == '1 and two')\n" +
		// %% is a literal percent
		"assert(string.format('100%%') == '100%')\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "numeric/format specifiers")
}

@(test)
str_format_q_roundtrip :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	// %q must produce something `load` can read back to the original value. This is
	// an honest oracle: we don't assert the exact escaping, only that round-tripping
	// through the Lua reader recovers each value.
	src :=
		"local function rt(v) return load('return ' .. string.format('%q', v))() end\n" +
		"assert(rt('a\\nb\\t\"c\"') == 'a\\nb\\t\"c\"')\n" +
		"assert(rt('with\\0zero') == 'with\\0zero')\n" +
		"assert(rt(42) == 42)\n" +
		"assert(rt(-9223372036854775808) == -9223372036854775808)\n" + // MININTEGER corner
		"assert(rt(3.5) == 3.5)\n" +
		"assert(rt(1/0) == 1/0 and rt(-1/0) == -1/0)\n" +
		"local nan = rt(0/0); assert(nan ~= nan)\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "%q round-trips through load")
}

@(test)
str_pack_integers :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		// little- vs big-endian byte order for a 4-byte unsigned
		"assert(string.pack('<I4', 0x01020304) == '\\4\\3\\2\\1')\n" +
		"assert(string.pack('>I4', 0x01020304) == '\\1\\2\\3\\4')\n" +
		// round-trip signed/unsigned of various widths
		"local s = string.pack('<i2 i8 B', -1, -1, 200)\n" +
		"local a, b, c, nextpos = string.unpack('<i2 i8 B', s)\n" +
		"assert(a == -1 and b == -1 and c == 200)\n" +
		"assert(nextpos == #s + 1)\n" +
		// packsize agrees with the packed length for fixed formats
		"assert(string.packsize('<i2 i8 B') == 11)\n" +
		// overflow is rejected
		"assert(not pcall(string.pack, 'B', 256))\n" +
		"assert(not pcall(string.pack, 'b', 200))\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "integer pack/unpack")
}

@(test)
str_pack_floats_and_strings :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	src :=
		// double round-trips exactly
		"local d = string.pack('<d', 3.141592653589793)\n" +
		"assert(string.unpack('<d', d) == 3.141592653589793)\n" +
		// single-precision loses precision but round-trips a representable value
		"local f = string.pack('<f', 0.5)\n" +
		"assert(string.unpack('<f', f) == 0.5)\n" +
		// length-prefixed string
		"local sp = string.pack('<s4', 'hello')\n" +
		"assert(#sp == 4 + 5)\n" +
		"assert(string.unpack('<s4', sp) == 'hello')\n" +
		// zero-terminated string
		"local zp = string.pack('z', 'hi')\n" +
		"assert(zp == 'hi\\0')\n" +
		"local zs, np = string.unpack('z', zp)\n" +
		"assert(zs == 'hi' and np == 4)\n" +
		// fixed-size string is padded
		"assert(string.pack('c5', 'ab') == 'ab\\0\\0\\0')\n" +
		// c<n> unpack returns exactly n bytes, padding included (no trimming)
		"assert(string.unpack('c5', 'ab\\0\\0\\0') == 'ab\\0\\0\\0')\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "float/string pack/unpack")
}

@(test)
str_metatable_methods :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	// The string metatable makes method syntax and numeric-string arithmetic work.
	src :=
		"assert(('hello'):upper() == 'HELLO')\n" +
		"assert(('hello'):len() == 5)\n" +
		"assert(('10') + 5 == 15)\n" + // string arithmetic metamethod
		"assert(('3') * ('4') == 12)\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "string metatable methods")
}

@(test)
str_format_pointer_padding :: proc(t: ^testing.T) {
	L := str_state()
	defer kernel.close_state(L)
	// %p goes through the same width/flag machinery as every other conversion.
	// The pointer value itself is not reproducible, so assert on the field shape:
	// width, which side the padding lands on, and the null spelling.
	//
	// The `%--30p` case is the one that regressed historically: printf allows a
	// flag to repeat, and a parser that reads a single '-' and then demands a
	// digit silently drops the width.
	src :=
		"local t = {}\n" +
		"local bare = string.format('%p', t)\n" +
		"assert(#bare > 0)\n" +
		"local right = string.format('%30p', t)\n" +
		"assert(#right == 30, 'width applies')\n" +
		"assert(right:sub(-#bare) == bare, 'right justified by default')\n" +
		"assert(right:sub(1, 1) == ' ', 'pads with spaces, not zeros')\n" +
		"local left = string.format('%-30p', t)\n" +
		"assert(#left == 30, 'width applies with -')\n" +
		"assert(left:sub(1, #bare) == bare, 'left justified with -')\n" +
		"local twice = string.format('%--30p', t)\n" +
		"assert(#twice == 30, 'repeated - keeps the width')\n" +
		"assert(twice == left, 'repeated - matches a single -')\n" +
		"assert(string.format('%p', nil) == '(null)')\n" +
		"assert(string.format('%10p', nil) == '    (null)')\n" +
		"return 'ok'"
	testing.expect(t, str_eval(t, L, src) == "ok", "%p width and flag handling")
}
