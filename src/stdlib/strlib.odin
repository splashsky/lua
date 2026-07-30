package stdlib

// strlib.odin -- our analogue of reference Lua's `lstrlib.c`.
//
// The string library, and the biggest of the standard libraries. It has three
// distinct personalities:
//   * the simple byte operations -- len/sub/rep/reverse/lower/upper/byte/char/dump,
//   * the Lua *pattern* engine -- find/match/gmatch/gsub (a bespoke matcher, not
//     regular expressions), and
//   * printf-style formatting and binary (un)packing -- format/pack/unpack/packsize.
//
// Two deliberate porting decisions, both ducked before implementation:
//
//   1. The reference matcher walks the subject and pattern with raw `const char*`
//      pointers and pointer arithmetic. We keep the subject and pattern as byte
//      slices (`[]u8`) and drive the whole thing with *integer indices*. This is a
//      touch more verbose but far safer: an index can never wander into unrelated
//      memory the way a stray pointer can. The one thing we must reproduce is the
//      reference's habit of reading the byte *at* the logical end of a string -- the
//      terminating NUL -- in a handful of spots ('[' scanning, `$`, `%f`, `%b`,
//      quoting). We model that virtual NUL explicitly with the `pb`/`sb` helpers
//      (pattern-byte / subject-byte) that return 0 exactly at `len`, and never index
//      out of range.
//
//   2. Numeric formatting is freestanding too. Reference Lua delegates
//      string.format to C's sprintf, so seemingly cosmetic details (where zero
//      padding goes, whether `%#g` keeps a radix point, exponent width, and
//      halfway rounding) are observable language behaviour. The engine below
//      parses Lua's deliberately small printf grammar and reproduces those bytes
//      without constructing or executing a C varargs call.
//
// Locale note: the pattern classes (`%a`, `%d`, ...) and the ctype used by quoting
// go through Lua's explicit C-locale byte predicates. This deliberately keeps
// bytes 0x80..0xff out of the alphabetic/printable classes even if the process
// locale changes. Locale-sensitive collation is a documented, project-wide
// deviation (we compare bytes).

import "base:runtime"
import "core:c"
import "core:math"
import lua "luao:lua"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// ===========================================================================
// Small shared helpers
// ===========================================================================

// Length of a NUL-terminated region inside a byte buffer -- our `strlen`. Used to
// find how far a format buffer or a Lua string extends before its first zero byte.
@(private = "file")
c_strlen :: proc(buf: []u8) -> int {
	for i in 0 ..< len(buf) {
		if buf[i] == 0 {
			return i
		}
	}
	return len(buf)
}

@(private = "file")
is_digit_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return '0' <= c && c <= '9'
}

// ===========================================================================
// Basic operations
// ===========================================================================

// Translate a relative *initial* position (1-based; negative counts back from the
// end) and clip the result into [1, +inf). Faithful to reference `posrelatI`,
// including the "inverted comparison" `pos < -len` that avoids ever computing
// `-pos` (which would overflow for the most-negative integer).
@(private = "file")
posrelatI :: proc(pos: lua.Integer, l: int) -> int {
	if pos > 0 {
		return int(pos)
	} else if pos == 0 {
		return 1
	} else if pos < -lua.Integer(l) {
		return 1
	} else {
		return l + int(pos) + 1
	}
}

// Optional *ending* position, defaulting to `def`, clipped into [0, len]. Reference
// `getendpos`. Note the different clipping range from `posrelatI`.
@(private = "file")
getendpos :: proc(L: ^lua.Lua_State, arg: int, def: lua.Integer, l: int) -> int {
	pos := luaL_optinteger(L, arg, def)
	if pos > lua.Integer(l) {
		return l
	} else if pos >= 0 {
		return int(pos)
	} else if pos < -lua.Integer(l) {
		return 0
	} else {
		return l + int(pos) + 1
	}
}

@(private = "file")
str_len :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := luaL_checklstring(L, 1)
	lua.lua_pushinteger(L, lua.Integer(len(s)))
	return 1
}

@(private = "file")
str_sub :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	l := len(s)
	start := posrelatI(luaL_checkinteger(L, 2), l)
	end := getendpos(L, 3, -1, l)
	if start <= end {
		lua.lua_pushlstring(L, s[start - 1:end])
	} else {
		lua.lua_pushstring(L, "")
	}
	return 1
}

@(private = "file")
str_reverse :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	l := len(s)
	b: Buffer
	p := luaL_buffinitsize(L, &b, uint(l))
	for i in 0 ..< l {
		p[i] = s[l - i - 1]
	}
	luaL_pushresultsize(&b, uint(l))
	return 1
}

@(private = "file")
str_lower :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	l := len(s)
	b: Buffer
	p := luaL_buffinitsize(L, &b, uint(l))
	for i in 0 ..< l {
		p[i] = u8(lua.to_lower(int(s[i])))
	}
	luaL_pushresultsize(&b, uint(l))
	return 1
}

@(private = "file")
str_upper :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	l := len(s)
	b: Buffer
	p := luaL_buffinitsize(L, &b, uint(l))
	for i in 0 ..< l {
		p[i] = u8(lua.to_upper(int(s[i])))
	}
	luaL_pushresultsize(&b, uint(l))
	return 1
}

@(private = "file")
str_rep :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	n := luaL_checkinteger(L, 2)
	sep := transmute([]u8)luaL_optlstring(L, 3, "")
	length := uint(len(s))
	lsep := uint(len(sep))
	if n <= 0 {
		lua.lua_pushstring(L, "")
	} else if length > lua.MAX_SIZE - lsep || (length + lsep) > lua.MAX_SIZE / uint(n) {
		// The two-part test mirrors reference: first make sure `len + lsep` itself
		// doesn't overflow, then make sure multiplying by `n` won't either.
		luaL_error(L, "resulting string too large")
	} else {
		totallen := uint(n) * (length + lsep) - lsep
		b: Buffer
		p := luaL_buffinitsize(L, &b, totallen)
		off := 0
		// First n-1 copies each followed by the separator...
		for k := n; k > 1; k -= 1 {
			for j in 0 ..< len(s) {
				p[off + j] = s[j]
			}
			off += len(s)
			for j in 0 ..< len(sep) {
				p[off + j] = sep[j]
			}
			off += len(sep)
		}
		// ...and a final copy with no trailing separator.
		for j in 0 ..< len(s) {
			p[off + j] = s[j]
		}
		luaL_pushresultsize(&b, totallen)
	}
	return 1
}

@(private = "file")
str_byte :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	l := len(s)
	pi := luaL_optinteger(L, 2, 1)
	posi := posrelatI(pi, l)
	pose := getendpos(L, 3, pi, l)
	if posi > pose {
		return 0 // empty interval; return no values
	}
	n := pose - posi + 1
	luaL_checkstack(L, n, "string slice too long")
	for i in 0 ..< n {
		lua.lua_pushinteger(L, lua.Integer(s[posi + i - 1]))
	}
	return i32(n)
}

@(private = "file")
str_char :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	b: Buffer
	p := luaL_buffinitsize(L, &b, uint(n))
	for i in 1 ..= n {
		c := lua.Unsigned(luaL_checkinteger(L, i))
		luaL_argcheck(L, c <= 255, i, "value out of range")
		p[i - 1] = u8(c)
	}
	luaL_pushresultsize(&b, uint(n))
	return 1
}

// -- string.dump -----------------------------------------------------------

// Buffer state threaded through `lua_dump`'s writer callback. It is only
// initialised on the first write so that `luaL_buffinit` (which may push a value)
// runs while the function to dump is safely on top of the stack.
@(private = "file")
Str_Writer :: struct {
	init: bool,
	B:    Buffer,
}

@(private = "file")
dump_writer :: proc "c" (Lp: rawptr, p: rawptr, sz: uint, ud: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st := (^Str_Writer)(ud)
	if !st.init {
		st.init = true
		luaL_buffinit(L, &st.B)
	}
	if p == nil {
		// Finishing the dump: push the accumulated bytes and move them into the
		// reserved slot 1.
		luaL_pushresult(&st.B)
		lua.lua_replace(L, 1)
	} else {
		luaL_addlstring(&st.B, (cast([^]u8)p)[:sz])
	}
	return 0
}

@(private = "file")
str_dump :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st: Str_Writer
	strip := lua.lua_toboolean(L, 2)
	luaL_argcheck(
		L,
		lua.lua_type(L, 1) == lua.LUA_TFUNCTION && !lua.lua_iscfunction(L, 1),
		1,
		"Lua function expected",
	)
	// Put the function on top and vacate slot 1 for the eventual result.
	lua.lua_pushvalue(L, 1)
	st.init = false
	lua.lua_dump(L, dump_writer, &st, strip)
	lua.lua_settop(L, 1)
	return 1
}

// ===========================================================================
// String metamethods (arithmetic on numeric strings)
// ===========================================================================
//
// Lua lets you write `"10" + 5`; the string metatable provides the arithmetic
// metamethods that coerce numeric strings and fall back to the *other* operand's
// metamethod when coercion fails.

@(private = "file")
tonum :: proc(L: ^lua.Lua_State, arg: int) -> bool {
	if lua.lua_type(L, arg) == lua.LUA_TNUMBER {
		lua.lua_pushvalue(L, arg)
		return true
	} else {
		s, ok := lua.lua_tolstring(L, arg)
		if !ok {
			return false
		}
		// `lua_stringtonumber` returns len+1 on a fully-consumed numeric string.
		return lua.lua_stringtonumber(L, s) == uint(len(s)) + 1
	}
}

@(private = "file")
trymt :: proc(L: ^lua.Lua_State, mtkey: string, opname: string) {
	lua.lua_settop(L, 2) // back to the original two arguments
	if lua.lua_type(L, 2) == lua.LUA_TSTRING || luaL_getmetafield(L, 2, mtkey) == lua.LUA_TNIL {
		luaL_error(
			L,
			"attempt to %s a '%s' with a '%s'",
			opname,
			luaL_typename(L, -2),
			luaL_typename(L, -1),
		)
	}
	lua.lua_insert(L, -3) // put the metamethod before its arguments
	lua.lua_call(L, 2, 1)
}

@(private = "file")
arith :: proc(L: ^lua.Lua_State, op: int, mtname: string, opname: string) -> i32 {
	if tonum(L, 1) && tonum(L, 2) {
		lua.lua_arith(L, op) // result ends up on top
	} else {
		trymt(L, mtname, opname)
	}
	return 1
}

@(private = "file")
arith_add :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPADD, "__add", "add")
}
@(private = "file")
arith_sub :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPSUB, "__sub", "sub")
}
@(private = "file")
arith_mul :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPMUL, "__mul", "mul")
}
@(private = "file")
arith_mod :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPMOD, "__mod", "mod")
}
@(private = "file")
arith_pow :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPPOW, "__pow", "pow")
}
@(private = "file")
arith_div :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPDIV, "__div", "div")
}
@(private = "file")
arith_idiv :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPIDIV, "__idiv", "idiv")
}
@(private = "file")
arith_unm :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return arith(state(Lp), lua.LUA_OPUNM, "__unm", "unm")
}

@(private = "file")
stringmetamethods := []Reg {
	{"__add", arith_add},
	{"__sub", arith_sub},
	{"__mul", arith_mul},
	{"__mod", arith_mod},
	{"__pow", arith_pow},
	{"__div", arith_div},
	{"__idiv", arith_idiv},
	{"__unm", arith_unm},
	{"__index", nil}, // placeholder; filled in with the string library itself
}

// ===========================================================================
// PATTERN MATCHING
// ===========================================================================

@(private = "file")
LUA_MAXCAPTURES :: 32
@(private = "file")
MAXCCALLS :: 200
@(private = "file")
L_ESC :: '%'
// A capture whose `len` field holds one of these sentinels is not an ordinary
// string capture: UNFINISHED means "still open" and POSITION means "a position
// capture `()`". Real lengths are always >= 0, so the negatives are unambiguous.
@(private = "file")
CAP_UNFINISHED :: -1
@(private = "file")
CAP_POSITION :: -2
// A no-match result. Indices are always >= 0, so -1 is a safe "NULL".
@(private = "file")
NO_MATCH :: -1

@(private = "file")
Capture :: struct {
	init: int, // start index into the subject
	len:  int, // length, or a CAP_* sentinel
}

@(private = "file")
Match_State :: struct {
	L:          ^lua.Lua_State,
	src:        []u8, // subject bytes
	pat:        []u8, // pattern bytes
	matchdepth: int, // remaining recursion budget (guards against pathological patterns)
	level:      int, // number of captures opened so far
	capture:    [LUA_MAXCAPTURES]Capture,
}

// Pattern byte / subject byte with a virtual trailing NUL. Reference Lua reads the
// terminating '\0' in several places (scanning '[', `$`, `%f`, `%b`, replacement
// parsing); returning 0 exactly at `len` reproduces that without ever indexing out
// of bounds.
@(private = "file")
pb :: #force_inline proc "contextless" (ms: ^Match_State, i: int) -> u8 {
	return i < len(ms.pat) ? ms.pat[i] : 0
}

@(private = "file")
sb :: #force_inline proc "contextless" (ms: ^Match_State, i: int) -> u8 {
	return i < len(ms.src) ? ms.src[i] : 0
}

@(private = "file")
check_capture :: proc(ms: ^Match_State, ll: int) -> int {
	l := ll - '1'
	if l < 0 || l >= ms.level || ms.capture[l].len == CAP_UNFINISHED {
		luaL_error(ms.L, "invalid capture index %%%d", l + 1)
	}
	return l
}

@(private = "file")
capture_to_close :: proc(ms: ^Match_State) -> int {
	for level := ms.level - 1; level >= 0; level -= 1 {
		if ms.capture[level].len == CAP_UNFINISHED {
			return level
		}
	}
	luaL_error(ms.L, "invalid pattern capture")
}

// Given `p` at the start of a pattern *class* (a literal, `%x`, or `[...]`), return
// the index just past that class -- where an optional suffix (`*+-?`) would sit.
@(private = "file")
classend :: proc(ms: ^Match_State, p_in: int) -> int {
	p := p_in
	c := ms.pat[p] // callers only invoke classend at a real class start (p < p_end)
	p += 1
	switch c {
	case L_ESC:
		if p == len(ms.pat) {
			luaL_error(ms.L, "malformed pattern (ends with '%%')")
		}
		return p + 1
	case '[':
		if pb(ms, p) == '^' {
			p += 1
		}
		// Scan for the closing ']'. `%]` and friends are skipped as escapes.
		for {
			if p == len(ms.pat) {
				luaL_error(ms.L, "malformed pattern (missing ']')")
			}
			cc := ms.pat[p]
			p += 1
			if cc == L_ESC && p < len(ms.pat) {
				p += 1
			}
			if pb(ms, p) == ']' {
				break
			}
		}
		return p + 1
	case:
		return p
	}
}

// Does character `c` belong to class `cl` (a single class letter like 'a', 'd',
// ...)? Uppercase letters mean the complemented class. Unknown letters match
// literally. Goes through Lua's explicit C-locale predicates.
@(private = "file")
match_class :: proc(c: u8, cl: u8) -> bool {
	res: bool
	switch u8(lua.to_lower(int(cl))) {
	case 'a':
		res = lua.is_alpha(int(c))
	case 'c':
		res = lua.is_cntrl(int(c))
	case 'd':
		res = lua.is_digit(int(c))
	case 'g':
		res = lua.is_graph(int(c))
	case 'l':
		res = lua.is_lower(int(c))
	case 'p':
		res = lua.is_punct(int(c))
	case 's':
		res = lua.is_space(int(c))
	case 'u':
		res = lua.is_upper(int(c))
	case 'w':
		res = lua.is_alnum(int(c))
	case 'x':
		res = lua.is_xdigit(int(c))
	case 'z':
		res = c == 0 // deprecated option
	case:
		return cl == c
	}
	// A lowercase class letter keeps `res`; an uppercase one complements it.
	return lua.is_lower(int(cl)) ? res : !res
}

// Match a character against a bracket set `[...]`. `p` points at the '[', `ec`
// points at the closing ']'.
@(private = "file")
matchbracketclass :: proc(ms: ^Match_State, c: u8, p_in: int, ec: int) -> bool {
	sig := true
	p := p_in
	if pb(ms, p + 1) == '^' {
		sig = false
		p += 1 // skip the '^'
	}
	for {
		p += 1
		if p >= ec {
			break
		}
		if ms.pat[p] == L_ESC {
			p += 1
			if match_class(c, pb(ms, p)) {
				return sig
			}
		} else if pb(ms, p + 1) == '-' && p + 2 < ec {
			// A range like 'a-z'.
			p += 2
			if pb(ms, p - 2) <= c && c <= pb(ms, p) {
				return sig
			}
		} else if ms.pat[p] == c {
			return sig
		}
	}
	return !sig
}

// Does the single subject char at `s` match the single-class at `p` (whose end is
// `ep`)? `.` matches anything, `%x` a class, `[...]` a set, else a literal.
@(private = "file")
singlematch :: proc(ms: ^Match_State, s: int, p: int, ep: int) -> bool {
	if s >= len(ms.src) {
		return false
	}
	c := ms.src[s]
	switch ms.pat[p] {
	case '.':
		return true
	case L_ESC:
		return match_class(c, pb(ms, p + 1))
	case '[':
		return matchbracketclass(ms, c, p, ep - 1)
	case:
		return ms.pat[p] == c
	}
}

// `%bxy` -- match a balanced run that starts with byte x and ends with the matching
// y (like balanced parentheses). Returns the index just past the run.
@(private = "file")
matchbalance :: proc(ms: ^Match_State, s_in: int, p: int) -> (int, bool) {
	if p >= len(ms.pat) - 1 {
		luaL_error(ms.L, "malformed pattern (missing arguments to '%%b')")
	}
	if sb(ms, s_in) != ms.pat[p] {
		return NO_MATCH, false
	}
	b := ms.pat[p]
	e := ms.pat[p + 1]
	cont := 1
	s := s_in
	for {
		s += 1
		if s >= len(ms.src) {
			break
		}
		if ms.src[s] == e {
			cont -= 1
			if cont == 0 {
				return s + 1, true
			}
		} else if ms.src[s] == b {
			cont += 1
		}
	}
	return NO_MATCH, false // string ends out of balance
}

// Greedy `*`/`+`: consume as many repetitions as possible, then back off one at a
// time until the rest of the pattern (`ep+1`) matches.
@(private = "file")
max_expand :: proc(ms: ^Match_State, s: int, p: int, ep: int) -> (int, bool) {
	i := 0
	for singlematch(ms, s + i, p, ep) {
		i += 1
	}
	for i >= 0 {
		res, ok := match(ms, s + i, ep + 1)
		if ok {
			return res, true
		}
		i -= 1
	}
	return NO_MATCH, false
}

// Lazy `-`: try the rest of the pattern first, consuming one repetition at a time
// only when it fails.
@(private = "file")
min_expand :: proc(ms: ^Match_State, s_in: int, p: int, ep: int) -> (int, bool) {
	s := s_in
	for {
		res, ok := match(ms, s, ep + 1)
		if ok {
			return res, true
		} else if singlematch(ms, s, p, ep) {
			s += 1
		} else {
			return NO_MATCH, false
		}
	}
}

@(private = "file")
start_capture :: proc(ms: ^Match_State, s: int, p: int, what: int) -> (int, bool) {
	level := ms.level
	if level >= LUA_MAXCAPTURES {
		luaL_error(ms.L, "too many captures")
	}
	ms.capture[level].init = s
	ms.capture[level].len = what
	ms.level = level + 1
	res, ok := match(ms, s, p)
	if !ok {
		ms.level -= 1 // undo the capture on failure
	}
	return res, ok
}

@(private = "file")
end_capture :: proc(ms: ^Match_State, s: int, p: int) -> (int, bool) {
	l := capture_to_close(ms)
	ms.capture[l].len = s - ms.capture[l].init // close it
	res, ok := match(ms, s, p)
	if !ok {
		ms.capture[l].len = CAP_UNFINISHED // reopen on failure
	}
	return res, ok
}

// Back-reference `%1`..`%9`: the subject at `s` must repeat capture `ll`.
@(private = "file")
match_capture :: proc(ms: ^Match_State, s: int, ll: int) -> (int, bool) {
	l := check_capture(ms, ll)
	length := ms.capture[l].len
	if len(ms.src) - s >= length {
		a := ms.capture[l].init
		matched := true
		for i in 0 ..< length {
			if ms.src[a + i] != ms.src[s + i] {
				matched = false
				break
			}
		}
		if matched {
			return s + length, true
		}
	}
	return NO_MATCH, false
}

// The default class-plus-suffix handler (reference's `dflt:` label). Returns true if
// the caller should loop again (reference's `goto init`); false if `s` has been set
// to the final result (a match position or NO_MATCH) and matching should return.
@(private = "file")
match_default :: proc(ms: ^Match_State, s: ^int, p: ^int) -> bool {
	ep := classend(ms, p^)
	if !singlematch(ms, s^, p^, ep) {
		suffix := pb(ms, ep)
		if suffix == '*' || suffix == '?' || suffix == '-' {
			p^ = ep + 1 // accept zero repetitions; loop with the rest of the pattern
			return true
		} else {
			s^ = NO_MATCH // '+' or no suffix: a required match failed
			return false
		}
	} else {
		suffix := pb(ms, ep)
		switch suffix {
		case '?':
			res, ok := match(ms, s^ + 1, ep + 1)
			if ok {
				s^ = res
				return false
			}
			p^ = ep + 1
			return true
		case '+':
			s^ += 1 // one repetition already matched
			res, ok := max_expand(ms, s^, p^, ep)
			s^ = ok ? res : NO_MATCH
			return false
		case '*':
			res, ok := max_expand(ms, s^, p^, ep)
			s^ = ok ? res : NO_MATCH
			return false
		case '-':
			res, ok := min_expand(ms, s^, p^, ep)
			s^ = ok ? res : NO_MATCH
			return false
		case:
			s^ += 1 // no suffix: consume one char and continue
			p^ = ep
			return true
		}
	}
}

// The heart of the matcher. Returns the subject index just past the match, plus a
// success flag. The `matchdepth` budget is decremented once per *real* recursive
// call and restored on every non-diverging return; tail transitions (reference's
// `goto init`) just loop and consume no extra depth.
@(private = "file")
match :: proc(ms: ^Match_State, s_in: int, p_in: int) -> (int, bool) {
	if ms.matchdepth == 0 {
		luaL_error(ms.L, "pattern too complex")
	}
	ms.matchdepth -= 1
	s := s_in
	p := p_in
	loop: for {
		if p == len(ms.pat) {
			break loop // end of pattern: success, `s` is the result
		}
		switch ms.pat[p] {
		case '(':
			if pb(ms, p + 1) == ')' {
				s = to_pos(start_capture(ms, s, p + 2, CAP_POSITION))
			} else {
				s = to_pos(start_capture(ms, s, p + 1, CAP_UNFINISHED))
			}
			break loop
		case ')':
			s = to_pos(end_capture(ms, s, p + 1))
			break loop
		case '$':
			if p + 1 != len(ms.pat) {
				if match_default(ms, &s, &p) {
					continue loop
				}
				break loop
			}
			// A trailing `$` matches only at end of subject.
			s = (s == len(ms.src)) ? s : NO_MATCH
			break loop
		case L_ESC:
			switch pb(ms, p + 1) {
			case 'b':
				res, ok := matchbalance(ms, s, p + 2)
				if ok {
					s = res
					p += 4
					continue loop
				}
				s = NO_MATCH
				break loop
			case 'f':
				p += 2
				if pb(ms, p) != '[' {
					luaL_error(ms.L, "missing '[' after '%%f' in pattern")
				}
				ep := classend(ms, p)
				prev := (s == 0) ? u8(0) : ms.src[s - 1]
				cur := sb(ms, s)
				if !matchbracketclass(ms, prev, p, ep - 1) &&
				   matchbracketclass(ms, cur, p, ep - 1) {
					p = ep
					continue loop
				}
				s = NO_MATCH
				break loop
			case '0' ..= '9':
				res, ok := match_capture(ms, s, int(pb(ms, p + 1)))
				if ok {
					s = res
					p += 2
					continue loop
				}
				s = NO_MATCH
				break loop
			case:
				if match_default(ms, &s, &p) {
					continue loop
				}
				break loop
			}
		case:
			if match_default(ms, &s, &p) {
				continue loop
			}
			break loop
		}
	}
	ms.matchdepth += 1
	return s, s != NO_MATCH
}

// Collapse a (pos, ok) pair into a single index, using NO_MATCH for failure.
@(private = "file")
to_pos :: #force_inline proc "contextless" (pos: int, ok: bool) -> int {
	return ok ? pos : NO_MATCH
}

// Plain (non-pattern) substring search: index of the first occurrence of `p` in
// `s`, or NO_MATCH.
@(private = "file")
lmemfind :: proc(s: []u8, p: []u8) -> int {
	l2 := len(p)
	if l2 == 0 {
		return 0 // empty needles are everywhere
	}
	if l2 > len(s) {
		return NO_MATCH
	}
	last := len(s) - l2
	for i in 0 ..= last {
		if s[i] == p[0] {
			matched := true
			for k in 1 ..< l2 {
				if s[i + k] != p[k] {
					matched = false
					break
				}
			}
			if matched {
				return i
			}
		}
	}
	return NO_MATCH
}

// Information about the i-th capture: its length (or CAP_POSITION, already pushed)
// and its start index. Capture 0 with no captures means "the whole match" s..e.
@(private = "file")
get_onecapture :: proc(ms: ^Match_State, i: int, s: int, e: int) -> (int, int) {
	if i >= ms.level {
		if i != 0 {
			luaL_error(ms.L, "invalid capture index %%%d", i + 1)
		}
		return e - s, s
	} else {
		capl := ms.capture[i].len
		cap_i := ms.capture[i].init
		if capl == CAP_UNFINISHED {
			luaL_error(ms.L, "unfinished capture")
		} else if capl == CAP_POSITION {
			lua.lua_pushinteger(ms.L, lua.Integer(ms.capture[i].init) + 1)
		}
		return capl, cap_i
	}
}

@(private = "file")
push_onecapture :: proc(ms: ^Match_State, i: int, s: int, e: int) {
	l, cap_i := get_onecapture(ms, i, s, e)
	if l != CAP_POSITION {
		lua.lua_pushlstring(ms.L, ms.src[cap_i:cap_i + l])
	}
	// else: a position was already pushed by get_onecapture
}

// Push all captures. `has_s` distinguishes the "whole match" case (find with no
// captures pushes one string) from the capture-only case (find already pushed
// start/end and just wants any explicit captures).
@(private = "file")
push_captures :: proc(ms: ^Match_State, s: int, e: int, has_s: bool) -> int {
	nlevels := (ms.level == 0 && has_s) ? 1 : ms.level
	luaL_checkstack(ms.L, nlevels, "too many captures")
	for i in 0 ..< nlevels {
		push_onecapture(ms, i, s, e)
	}
	return nlevels
}

@(private = "file")
is_special :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case '^', '$', '*', '+', '?', '.', '(', '[', '%', '-':
		return true
	}
	return false
}

// Does the pattern contain no special characters (so a plain search suffices)? We
// scan every byte, which correctly handles embedded NULs too.
@(private = "file")
nospecials :: proc(p: []u8) -> bool {
	for c in p {
		if is_special(c) {
			return false
		}
	}
	return true
}

@(private = "file")
str_find_aux :: proc(L: ^lua.Lua_State, find: bool) -> i32 {
	s := transmute([]u8)luaL_checklstring(L, 1)
	p := transmute([]u8)luaL_checklstring(L, 2)
	ls := len(s)
	init := posrelatI(luaL_optinteger(L, 3, 1), ls) - 1 // 0-based start
	if init > ls {
		luaL_pushfail(L) // start past the end: nothing to find
		return 1
	}
	// Plain search when explicitly requested (find + a truthy 4th arg) or when the
	// pattern has no magic characters.
	if find && (lua.lua_toboolean(L, 4) || nospecials(p)) {
		pos := lmemfind(s[init:], p)
		if pos >= 0 {
			lua.lua_pushinteger(L, lua.Integer(init + pos) + 1)
			lua.lua_pushinteger(L, lua.Integer(init + pos + len(p)))
			return 2
		}
	} else {
		ms: Match_State
		ms.L = L
		ms.src = s
		ms.matchdepth = MAXCCALLS
		pp := p
		anchor := len(p) > 0 && p[0] == '^'
		if anchor {
			pp = p[1:] // skip the anchor
		}
		ms.pat = pp
		s1 := init
		for {
			ms.level = 0
			res, ok := match(&ms, s1, 0)
			if ok {
				if find {
					lua.lua_pushinteger(L, lua.Integer(s1) + 1) // start
					lua.lua_pushinteger(L, lua.Integer(res)) // end
					return i32(push_captures(&ms, 0, 0, false) + 2)
				} else {
					return i32(push_captures(&ms, s1, res, true))
				}
			}
			// Reference's `while (s1++ < src_end && !anchor)`: test with the old s1,
			// then advance. Note the body runs once with s1 == src_end.
			cond := s1 < len(ms.src) && !anchor
			s1 += 1
			if !cond {
				break
			}
		}
	}
	luaL_pushfail(L)
	return 1
}

@(private = "file")
str_find :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return str_find_aux(state(Lp), true)
}

@(private = "file")
str_match :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return str_find_aux(state(Lp), false)
}

// State for a gmatch iterator, kept alive as a userdata upvalue. Our non-moving GC
// means the byte slices pinned on the closure stay valid for the iterator's life.
@(private = "file")
GMatch_State :: struct {
	src:       []u8,
	pat:       []u8,
	pos:       int, // current search position
	lastmatch: int, // end of the previous match, or NO_MATCH
}

@(private = "file")
gmatch_aux :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	gm := (^GMatch_State)(lua.lua_touserdata(L, lua.lua_upvalueindex(3)))
	ms: Match_State
	ms.L = L
	ms.src = gm.src
	ms.pat = gm.pat
	ms.matchdepth = MAXCCALLS
	for src := gm.pos; src <= len(ms.src); src += 1 {
		ms.level = 0
		e, ok := match(&ms, src, 0)
		// Skip empty matches that just repeat the previous end position.
		if ok && e != gm.lastmatch {
			gm.pos = e
			gm.lastmatch = e
			return i32(push_captures(&ms, src, e, true))
		}
	}
	return 0 // iterator exhausted
}

@(private = "file")
gmatch :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_checklstring(L, 1)
	p := transmute([]u8)luaL_checklstring(L, 2)
	init := posrelatI(luaL_optinteger(L, 3, 1), len(s)) - 1
	lua.lua_settop(L, 2) // keep the strings as upvalues so they aren't collected
	gm := (^GMatch_State)(lua.lua_newuserdatauv(L, size_of(GMatch_State), 0))
	if init > len(s) {
		init = len(s) + 1 // clamp so `pos` can't run off the end
	}
	gm.src = s
	gm.pat = p
	gm.pos = init
	gm.lastmatch = NO_MATCH
	lua.lua_pushcclosure(L, gmatch_aux, 3)
	return 1
}

// -- gsub ------------------------------------------------------------------

// Append the replacement *string* for one match, expanding `%0` (whole match),
// `%1`..`%9` (captures) and `%%`.
@(private = "file")
add_s :: proc(ms: ^Match_State, b: ^Buffer, s: int, e: int) {
	L := ms.L
	news, _ := lua.lua_tolstring(L, 3)
	nb := transmute([]u8)news
	i := 0
	for i < len(nb) {
		if nb[i] != L_ESC {
			luaL_addchar(b, nb[i])
			i += 1
			continue
		}
		i += 1 // skip the ESC
		if i >= len(nb) {
			luaL_error(L, "invalid use of '%c' in replacement string", int(L_ESC))
		}
		c := nb[i]
		if c == L_ESC {
			luaL_addchar(b, c)
		} else if c == '0' {
			luaL_addlstring(b, ms.src[s:e])
		} else if lua.is_digit(int(c)) {
			resl, cap_i := get_onecapture(ms, int(c) - '1', s, e)
			if resl == CAP_POSITION {
				luaL_addvalue(b) // position was pushed; fold it in
			} else {
				luaL_addlstring(b, ms.src[cap_i:cap_i + resl])
			}
		} else {
			luaL_error(L, "invalid use of '%c' in replacement string", int(L_ESC))
		}
		i += 1
	}
}

// Compute and append the replacement value for one match. Returns whether the
// subject text actually changed (a function/table replacement returning nil/false
// leaves the original text in place).
@(private = "file")
add_value :: proc(ms: ^Match_State, b: ^Buffer, s: int, e: int, tr: int) -> bool {
	L := ms.L
	switch tr {
	case lua.LUA_TFUNCTION:
		lua.lua_pushvalue(L, 3)
		nn := push_captures(ms, s, e, true)
		lua.lua_call(L, nn, 1)
	case lua.LUA_TTABLE:
		push_onecapture(ms, 0, s, e)
		lua.lua_gettable(L, 3)
	case:
		add_s(ms, b, s, e)
		return true
	}
	if !lua.lua_toboolean(L, -1) {
		lua.lua_pop(L, 1)
		luaL_addlstring(b, ms.src[s:e]) // keep the original text
		return false
	} else if !lua.lua_isstring(L, -1) {
		luaL_error(L, "invalid replacement value (a %s)", luaL_typename(L, -1))
	} else {
		luaL_addvalue(b)
	}
	return true
}

@(private = "file")
str_gsub :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	src := transmute([]u8)luaL_checklstring(L, 1)
	p := transmute([]u8)luaL_checklstring(L, 2)
	tr := lua.lua_type(L, 3)
	max_s := luaL_optinteger(L, 4, lua.Integer(len(src)) + 1)
	anchor := len(p) > 0 && p[0] == '^'
	luaL_argexpected(
		L,
		tr == lua.LUA_TNUMBER ||
		tr == lua.LUA_TSTRING ||
		tr == lua.LUA_TFUNCTION ||
		tr == lua.LUA_TTABLE,
		3,
		"string/function/table",
	)
	b: Buffer
	luaL_buffinit(L, &b)
	pp := p
	if anchor {
		pp = p[1:]
	}
	ms: Match_State
	ms.L = L
	ms.src = src
	ms.pat = pp
	ms.matchdepth = MAXCCALLS
	lastmatch := NO_MATCH
	n: lua.Integer = 0
	changed := false
	srcpos := 0
	for n < max_s {
		ms.level = 0
		e, ok := match(&ms, srcpos, 0)
		if ok && e != lastmatch {
			n += 1
			c := add_value(&ms, &b, srcpos, e, tr)
			changed = changed || c
			srcpos = e
			lastmatch = e
		} else if srcpos < len(ms.src) {
			luaL_addchar(&b, ms.src[srcpos]) // no match here: copy one char
			srcpos += 1
		} else {
			break
		}
		if anchor {
			break
		}
	}
	if !changed {
		lua.lua_pushvalue(L, 1) // return the original string unchanged
	} else {
		luaL_addlstring(&b, ms.src[srcpos:])
		luaL_pushresult(&b)
	}
	lua.lua_pushinteger(L, n)
	return 2
}

// ===========================================================================
// STRING FORMAT
// ===========================================================================

@(private = "file")
MAX_FORMAT :: 32
@(private = "file")
MAX_ITEM :: 120
// Enough room for `%.99f` of the largest double: 110 + DBL_MAX_10_EXP (308).
@(private = "file")
MAX_ITEMF :: 110 + 308

// Valid flag sets per conversion (reference L_FMTFLAGS*).
@(private = "file")
FMTFLAGS_F :: "-+#0 " // a A e E f F g G
@(private = "file")
FMTFLAGS_X :: "-#0" // o x X
@(private = "file")
FMTFLAGS_I :: "-+0 " // d i
@(private = "file")
FMTFLAGS_U :: "-0" // u
@(private = "file")
FMTFLAGS_C :: "-" // c p s
// The span of flag/width/precision characters getformat is allowed to copy.
@(private = "file")
FMT_SPAN :: "-+#0 123456789."

// Count how many consecutive bytes of `buf` from `start` belong to `set` (our
// `strspn`). Stops at the buffer end or the first byte not in the set.
@(private = "file")
strspn :: proc(buf: []u8, start: int, set: string) -> int {
	setb := transmute([]u8)set
	i := start
	outer: for i < len(buf) {
		c := buf[i]
		for sc in setb {
			if sc == c {
				i += 1
				continue outer
			}
		}
		break
	}
	return i - start
}

// Copy one conversion specification out of the format string into `form` (as
// "%...spec\0"). Returns the index of the specifier byte in the source.
@(private = "file")
getformat :: proc(L: ^lua.Lua_State, sf: []u8, start: int, form: []u8) -> int {
	span := strspn(sf, start, FMT_SPAN)
	total := span + 1 // include the following character (the specifier)
	if total >= MAX_FORMAT - 10 {
		luaL_error(L, "invalid format (too long)")
	}
	form[0] = '%'
	avail := len(sf) - start
	ncopy := min(total, avail)
	if ncopy > 0 {
		copy(form[1:], sf[start:start + ncopy])
	}
	// `form` is zero-initialised, so any missing specifier slot and the terminator
	// are already NUL.
	return start + total - 1
}

@(private = "file")
get2digits :: proc(form: []u8, s_in: int) -> int {
	s := s_in
	if lua.is_digit(int(form[s])) {
		s += 1
		if lua.is_digit(int(form[s])) {
			s += 1 // at most two digits
		}
	}
	return s
}

// Validate a conversion spec: allowed flags, an optional two-digit width, and an
// optional two-digit precision (only when `precision`), ending in a letter.
@(private = "file")
checkformat :: proc(L: ^lua.Lua_State, form: []u8, flags: string, precision: bool) {
	spec := 1 // skip '%'
	spec += strspn(form, spec, flags)
	if form[spec] != '0' { // a width cannot start with '0'
		spec = get2digits(form, spec)
		if form[spec] == '.' && precision {
			spec += 1
			spec = get2digits(form, spec)
		}
	}
	if !lua.is_alpha(int(form[spec])) {
		luaL_error(L, "invalid conversion specification: '%s'", string(form[:c_strlen(form)]))
	}
}

// -- %q literal serialisation ----------------------------------------------

@(private = "file")
addquoted :: proc(b: ^Buffer, s: []u8) {
	luaL_addchar(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '"' || c == '\\' || c == '\n' {
			luaL_addchar(b, '\\')
			luaL_addchar(b, c)
		} else if lua.is_cntrl(int(c)) {
			buf: [10]u8
			// A following digit forces three-digit escaping so it can't merge with
			// the control-code escape (reference reads the *next* byte, or the NUL).
			nxt := (i + 1 < len(s)) ? s[i + 1] : 0
			n := 0
			buf[n] = '\\'
			n += 1
			if !lua.is_digit(int(nxt)) {
				if c >= 100 {
					buf[n] = '0' + c / 100
					n += 1
				}
				if c >= 10 {
					buf[n] = '0' + (c / 10) % 10
					n += 1
				}
				buf[n] = '0' + c % 10
				n += 1
			} else {
				buf[n] = '0' + c / 100
				buf[n + 1] = '0' + (c / 10) % 10
				buf[n + 2] = '0' + c % 10
				n += 3
			}
			luaL_addlstring(b, buf[:n])
		} else {
			luaL_addchar(b, c)
		}
	}
	luaL_addchar(b, '"')
}

// Serialise a float so Lua can read it back exactly. inf/-inf/NaN have no numeral,
// so we spell them; finite values use an exact C99 hexadecimal form assembled
// from their binary64 fields. The radix is always '.', matching our documented
// freestanding C-locale behavior.
@(private = "file")
quotefloat :: proc(buff: [^]u8, n: lua.Number) -> int {
	if n == lua.Number(math.inf_f64(1)) {
		return copy(buff[:MAX_ITEM], "1e9999")
	} else if n == lua.Number(math.inf_f64(-1)) {
		return copy(buff[:MAX_ITEM], "-1e9999")
	} else if n != n {
		return copy(buff[:MAX_ITEM], "(0/0)")
	}
	return lua.number_to_hex_str(buff[:MAX_ITEM], n)
}

@(private = "file")
literal_integer :: proc "contextless" (buf: []u8, n: lua.Integer) -> int {
	if n == lua.MIN_INTEGER {
		buf[0] = '0'
		buf[1] = 'x'
		return 2 + lua.unsigned_to_hex_str(buf[2:], u64(n))
	}
	neg := n < 0
	mag := neg ? u64(0 - u64(n)) : u64(n)
	tmp: [20]u8
	pos := len(tmp)
	for {
		pos -= 1
		tmp[pos] = '0' + byte(mag % 10)
		mag /= 10
		if mag == 0 {break}
	}
	out := 0
	if neg {
		buf[out] = '-'
		out += 1
	}
	out += copy(buf[out:], tmp[pos:])
	return out
}

// Lua accepts a compact, positional-free subset of printf: flags, a decimal
// width, an optional ".precision", then one conversion byte. checkformat above
// remains the authority for rejecting malformed specifications; this parser runs
// only afterwards and therefore does not need an error path of its own.
@(private = "file")
Format_Options :: struct {
	left:          bool,
	plus:          bool,
	space:         bool,
	alternate:     bool,
	zero:          bool,
	width:         int,
	has_precision: bool,
	precision:     int,
	spec:          u8,
}

@(private = "file")
parse_format_options :: proc "contextless" (form: []u8) -> Format_Options {
	o: Format_Options
	i := 1
	flags: for {
		switch form[i] {
		case '-': o.left = true
		case '+': o.plus = true
		case ' ': o.space = true
		case '#': o.alternate = true
		case '0': o.zero = true
		case: break flags
		}
		i += 1
	}
	for is_digit_byte(form[i]) {
		o.width = o.width * 10 + int(form[i] - '0')
		i += 1
	}
	if form[i] == '.' {
		o.has_precision = true
		i += 1
		for is_digit_byte(form[i]) {
			o.precision = o.precision * 10 + int(form[i] - '0')
			i += 1
		}
	}
	o.spec = form[i]
	return o
}

@(private = "file")
put_repeat :: proc "contextless" (buf: []u8, at: ^int, c: u8, count: int) {
	for _ in 0 ..< count {
		buf[at^] = c
		at^ += 1
	}
}

// Apply printf's field width around a fully-rendered item. Numeric callers pass
// the sign/prefix separately because zero padding belongs after `-`/`+`/space and
// after `0x`, never before them. Strings and characters simply use an empty
// prefix and disable zero padding.
@(private = "file")
assemble_field :: proc "contextless" (
	buf: []u8,
	o: Format_Options,
	prefix, body: []u8,
	allow_zero: bool,
) -> int {
	total := len(prefix) + len(body)
	padding := max(o.width - total, 0)
	zero_pad := allow_zero && o.zero && !o.left
	out := 0
	if !o.left && !zero_pad {
		put_repeat(buf, &out, ' ', padding)
	}
	out += copy(buf[out:], prefix)
	if zero_pad {
		put_repeat(buf, &out, '0', padding)
	}
	out += copy(buf[out:], body)
	if o.left {
		put_repeat(buf, &out, ' ', padding)
	}
	return out
}

@(private = "file")
format_integer :: proc "contextless" (
	buf: []u8,
	form: []u8,
	n: lua.Integer,
) -> int {
	o := parse_format_options(form)
	base: u64 = 10
	uppercase := false
	signed := o.spec == 'd' || o.spec == 'i'
	switch o.spec {
	case 'o': base = 8
	case 'x': base = 16
	case 'X':
		base = 16
		uppercase = true
	}

	negative := signed && n < 0
	value := u64(n)
	if negative {
		value = 0 - value // magnitude in unsigned space, including MIN_INTEGER
	}
	nonzero := value != 0
	digits_table := uppercase ? "0123456789ABCDEF" : "0123456789abcdef"
	tmp: [64]u8
	pos := len(tmp)
	if value != 0 {
		for value != 0 {
			pos -= 1
			tmp[pos] = digits_table[int(value % base)]
			value /= base
		}
	} else if !(o.has_precision && o.precision == 0) {
		pos -= 1
		tmp[pos] = '0'
	}

	// Integer precision supplies leading zeroes and, per C, suppresses the `0`
	// flag. Alternate octal is special: it guarantees that the first digit is
	// zero, including the otherwise-empty "%.0o" representation.
	digit_count := len(tmp) - pos
	precision_zeroes := o.has_precision ? max(o.precision - digit_count, 0) : 0
	if o.spec == 'o' && o.alternate &&
	   (digit_count == 0 || tmp[pos] != '0') && precision_zeroes == 0 {
		precision_zeroes = 1
	}

	prefix: [3]u8
	prefix_len := 0
	if signed {
		if negative {
			prefix[prefix_len] = '-'
			prefix_len += 1
		} else if o.plus {
			prefix[prefix_len] = '+'
			prefix_len += 1
		} else if o.space {
			prefix[prefix_len] = ' '
			prefix_len += 1
		}
	} else if o.alternate && nonzero &&
	          (o.spec == 'x' || o.spec == 'X') {
		prefix[prefix_len] = '0'
		prefix[prefix_len + 1] = o.spec
		prefix_len += 2
	}

	body: [128]u8
	body_len := 0
	put_repeat(body[:], &body_len, '0', precision_zeroes)
	body_len += copy(body[body_len:], tmp[pos:])
	if o.has_precision {
		o.zero = false
	}
	return assemble_field(buf, o, prefix[:prefix_len], body[:body_len], true)
}

@(private = "file")
format_char :: proc "contextless" (buf, form: []u8, n: lua.Integer) -> int {
	o := parse_format_options(form)
	body := [1]u8{u8(n)}
	return assemble_field(buf, o, nil, body[:], false)
}

@(private = "file")
format_string :: proc "contextless" (buf, form, s: []u8) -> int {
	o := parse_format_options(form)
	n := len(s)
	if o.has_precision {
		n = min(n, o.precision)
	}
	return assemble_field(buf, o, nil, s[:n], false)
}

// Add the decimal point and insignificant zeroes required by `#` on `%g`.
// strconv intentionally emits the ordinary `%g` spelling with trailing zeroes
// removed, so this is the small compatibility layer which turns (say) 1.5 into
// "1.50000" at precision six while leaving the exponent untouched.
@(private = "file")
alternate_g :: proc "contextless" (buf: []u8, n: int, precision: int) -> int {
	length := n
	exp_at := length
	dot_at := -1
	digits := 0
	for i in 0 ..< length {
		c := buf[i]
		if c == 'e' || c == 'E' {
			exp_at = i
			break
		}
		if c == '.' {
			dot_at = i
		} else if is_digit_byte(c) {
			digits += 1
		}
	}
	need := max(precision - digits, 0)
	if dot_at < 0 {
		copy(buf[exp_at + 1:], buf[exp_at:length])
		buf[exp_at] = '.'
		exp_at += 1
		length += 1
	}
	if need > 0 {
		copy(buf[exp_at + need:], buf[exp_at:length])
		for i in 0 ..< need {
			buf[exp_at + i] = '0'
		}
		length += need
	}
	return length
}

@(private = "file")
uppercase_ascii :: proc "contextless" (buf: []u8) {
	for &c in buf {
		if 'a' <= c && c <= 'z' {
			c -= 'a' - 'A'
		}
	}
}

// Render the magnitude of a finite hexadecimal float in exactly the compact form
// used by the reference's num2straux fallback. In particular, bare `%a` is not
// the same thing as asking a C printf for thirteen hexadecimal fraction digits:
// we deliberately remove trailing zero nibbles and omit the radix point when no
// fraction remains. Keeping that rule here also makes `%a` agree with the exact
// finite-number spelling already used by `%q`, without changing `%q` itself.
//
// Subnormals are normalized too, so the least one is `0x1p-1074`, while zero is
// `0x0p+0`. The caller handles the sign and non-finite values.
@(private = "file")
format_hex_float_magnitude :: proc "contextless" (
	buf: []u8,
	x: lua.Number,
	upper: bool,
) -> int {
	bits := transmute(u64)x
	exp_field := int((bits >> 52) & 0x7ff)
	frac := bits & 0x000f_ffff_ffff_ffff
	exponent := 0
	sig := u64(0)
	if exp_field == 0 {
		if frac == 0 {
			sig = 0
		} else {
			highest := 0
			for v := frac; v > 1; v >>= 1 {
				highest += 1
			}
			exponent = highest - 1074
			sig = frac << uint(52 - highest)
		}
	} else {
		exponent = exp_field - 1023
		sig = (u64(1) << 52) | frac
	}

	precision := 13
	trim := sig
	for precision > 0 && (trim & 15) == 0 {
		trim >>= 4
		precision -= 1
	}

	digits := upper ? "0123456789ABCDEF" : "0123456789abcdef"
	out := 0
	buf[out] = '0'
	buf[out + 1] = upper ? 'X' : 'x'
	out += 2
	buf[out] = digits[int(sig >> 52)]
	out += 1
	if precision > 0 {
		buf[out] = '.'
		out += 1
	}
	for i in 0 ..< precision {
		nibble := 0
		if i < 13 {
			nibble = int((sig >> uint(48 - i * 4)) & 15)
		}
		buf[out] = digits[nibble]
		out += 1
	}
	buf[out] = upper ? 'P' : 'p'
	out += 1
	if exponent < 0 {
		buf[out] = '-'
		exponent = -exponent
	} else {
		buf[out] = '+'
	}
	out += 1
	tmp: [4]u8
	pos := len(tmp)
	for {
		pos -= 1
		tmp[pos] = '0' + u8(exponent % 10)
		exponent /= 10
		if exponent == 0 {break}
	}
	out += copy(buf[out:], tmp[pos:])
	return out
}

@(private = "file")
format_float :: proc "contextless" (
	buf: []u8,
	form: []u8,
	x: lua.Number,
) -> int {
	o := parse_format_options(form)
	bits := transmute(u64)x
	negative := bits >> 63 != 0
	exp_field := (bits >> 52) & 0x7ff
	frac := bits & 0x000f_ffff_ffff_ffff
	special := exp_field == 0x7ff
	special_radix_wart := special && o.alternate && o.has_precision &&
	                     o.precision == 0 &&
	                     (o.spec == 'f' || o.spec == 'F' ||
	                      o.spec == 'e' || o.spec == 'E')

	body: [MAX_ITEMF]u8
	body_len := 0
	if special {
		if frac == 0 {
			body_len = copy(body[:], "inf")
		} else {
			body_len = copy(body[:], negative ? "nan(ind)" : "nan")
		}
		if o.spec == 'F' || o.spec == 'E' || o.spec == 'G' || o.spec == 'A' {
			uppercase_ascii(body[:body_len])
		}
		// This odd placement is an MSVC compatibility wart. Its alternate
		// precision-zero f/e path inserts the radix into non-finite spellings too.
		if special_radix_wart {
			at := negative ? 0 : 1
			copy(body[at + 1:], body[at:body_len])
			body[at] = '.'
			body_len += 1
		}
	} else if o.spec == 'a' || o.spec == 'A' {
		body_len = format_hex_float_magnitude(
			body[:],
			x,
			o.spec == 'A',
		)
	} else {
		precision := o.has_precision ? o.precision : 6
		fmt := o.spec
		body_len = lua.format_float_decimal(body[:], x, fmt, precision)
		// strconv returns a sign for every finite number. Width assembly owns it.
		if body_len > 0 && (body[0] == '+' || body[0] == '-') {
			copy(body[:], body[1:body_len])
			body_len -= 1
		}
		if o.alternate {
			if o.spec == 'g' || o.spec == 'G' {
				p := precision == 0 ? 1 : precision
				body_len = alternate_g(body[:], body_len, p)
			} else if precision == 0 {
				exp_at := body_len
				for k in 0 ..< body_len {
					if body[k] == 'e' || body[k] == 'E' {
						exp_at = k
						break
					}
				}
				copy(body[exp_at + 1:], body[exp_at:body_len])
				body[exp_at] = '.'
				body_len += 1
			}
		}
	}

	prefix: [3]u8
	prefix_len := 0
	if negative {
		prefix[0] = '-'
		prefix_len = 1
	} else if o.plus {
		prefix[0] = '+'
		prefix_len = 1
	} else if o.space {
		prefix[0] = ' '
		prefix_len = 1
	}
	if !special && (o.spec == 'a' || o.spec == 'A') {
		prefix[prefix_len] = body[0]
		prefix[prefix_len + 1] = body[1]
		prefix_len += 2
		copy(body[:], body[2:body_len])
		body_len -= 2
	}
	// MSVC pads inf/nan with spaces even when the `0` flag is present.
	return assemble_field(
		buf,
		o,
		prefix[:prefix_len],
		body[:body_len],
		!special || (special_radix_wart && negative),
	)
}

@(private = "file")
format_pointer :: proc "contextless" (buf, form: []u8, p: rawptr) -> int {
	i := 1
	left := form[i] == '-'
	if left {i += 1}
	width := 0
	for lua.is_digit(int(form[i])) {
		width = width * 10 + int(form[i] - '0')
		i += 1
	}
	value: [32]u8
	n := 0
	if p == nil {
		n = copy(value[:], "(null)")
	} else {
		n = lua.pointer_to_str(value[:], p)
	}
	padding := max(width - n, 0)
	out := 0
	if !left {
		for _ in 0..<padding {
			buf[out] = ' '
			out += 1
		}
	}
	out += copy(buf[out:], value[:n])
	if left {
		for _ in 0..<padding {
			buf[out] = ' '
			out += 1
		}
	}
	return out
}

@(private = "file")
addliteral :: proc(L: ^lua.Lua_State, b: ^Buffer, arg: int) {
	switch lua.lua_type(L, arg) {
	case lua.LUA_TSTRING:
		s, _ := lua.lua_tolstring(L, arg)
		addquoted(b, transmute([]u8)s)
	case lua.LUA_TNUMBER:
		buff := luaL_prepbuffsize(b, MAX_ITEM)
		nb := 0
		if !lua.lua_isinteger(L, arg) {
			nb = quotefloat(buff, lua.lua_tonumber(L, arg))
		} else {
			nb = literal_integer(buff[:MAX_ITEM], lua.lua_tointeger(L, arg))
		}
		luaL_addsize(b, uint(nb))
	case lua.LUA_TNIL, lua.LUA_TBOOLEAN:
		luaL_tolstring(L, arg)
		luaL_addvalue(b)
	case:
		luaL_argerror(L, arg, "value has no literal form")
	}
}

@(private = "file")
str_format :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	top := lua.lua_gettop(L)
	arg := 1
	sf := transmute([]u8)luaL_checklstring(L, 1)
	b: Buffer
	luaL_buffinit(L, &b)
	i := 0
	for i < len(sf) {
		if sf[i] != L_ESC {
			luaL_addchar(&b, sf[i])
			i += 1
			continue
		}
		i += 1
		if i < len(sf) && sf[i] == L_ESC {
			luaL_addchar(&b, L_ESC) // %%
			i += 1
			continue
		}
		// A real format item.
		form: [MAX_FORMAT]u8
		maxitem: uint = MAX_ITEM
		buff := luaL_prepbuffsize(&b, maxitem)
		nb := 0
		arg += 1
		if arg > top {
			luaL_argerror(L, arg, "no value")
		}
		i = getformat(L, sf, i, form[:])
		spec := i < len(sf) ? sf[i] : 0
		i += 1
		switch spec {
		case 'c':
			checkformat(L, form[:], FMTFLAGS_C, false)
			nb = format_char(buff[:maxitem], form[:], luaL_checkinteger(L, arg))
		case 'd', 'i':
			n := luaL_checkinteger(L, arg)
			checkformat(L, form[:], FMTFLAGS_I, true)
			nb = format_integer(buff[:maxitem], form[:], n)
		case 'u':
			n := luaL_checkinteger(L, arg)
			checkformat(L, form[:], FMTFLAGS_U, true)
			nb = format_integer(buff[:maxitem], form[:], n)
		case 'o', 'x', 'X':
			n := luaL_checkinteger(L, arg)
			checkformat(L, form[:], FMTFLAGS_X, true)
			nb = format_integer(buff[:maxitem], form[:], n)
		case 'a', 'A':
			checkformat(L, form[:], FMTFLAGS_F, true)
			// PUC Lua's lua_number2strx accepts only the literal forms `%a` and
			// `%A`: after validation, anything between '%' and the conversion
			// byte raises this exact error. It may look tempting to support normal
			// printf flags, widths, or precisions here, but reference Lua
			// deliberately rejects every such modifier, so byte-faithful behavior
			// requires us to reject them too.
			if form[1] != spec {
				luaL_error(L, "modifiers for format '%%a'/'%%A' not implemented")
			}
			nb = format_float(buff[:maxitem], form[:], luaL_checknumber(L, arg))
		case 'f':
			maxitem = MAX_ITEMF // %f may need a lot of room
			buff = luaL_prepbuffsize(&b, maxitem)
			fallthrough
		case 'e', 'E', 'g', 'G':
			n := luaL_checknumber(L, arg)
			checkformat(L, form[:], FMTFLAGS_F, true)
			nb = format_float(buff[:maxitem], form[:], n)
		case 'p':
			pptr := lua.lua_topointer(L, arg)
			checkformat(L, form[:], FMTFLAGS_C, false)
			nb = format_pointer(buff[:maxitem], form[:], pptr)
		case 'q':
			if form[2] != 0 {
				luaL_error(L, "specifier '%%q' cannot have modifiers")
			}
			addliteral(L, &b, arg)
		case 's':
			ss := luaL_tolstring(L, arg)
			if form[2] == 0 {
				luaL_addvalue(&b) // no modifiers: keep the whole string
			} else {
				sbytes := transmute([]u8)ss
				luaL_argcheck(L, len(ss) == c_strlen(sbytes), arg, "string contains zeros")
				checkformat(L, form[:], FMTFLAGS_C, true)
				has_dot := false
				for k in 0 ..< c_strlen(form[:]) {
					if form[k] == '.' {
						has_dot = true
						break
					}
				}
				if !has_dot && len(ss) >= 100 {
					luaL_addvalue(&b) // too long and no precision: keep whole string
				} else {
					nb = format_string(buff[:maxitem], form[:], sbytes)
					lua.lua_pop(L, 1) // drop the luaL_tolstring result
				}
			}
		case:
			luaL_error(L, "invalid conversion '%s' to 'format'", string(form[:c_strlen(form[:])]))
		}
		luaL_addsize(&b, uint(nb))
	}
	luaL_pushresult(&b)
	return 1
}

// ===========================================================================
// PACK / UNPACK
// ===========================================================================

@(private = "file")
LUAL_PACKPADBYTE :: 0x00
@(private = "file")
MAXINTSIZE :: 16
@(private = "file")
NB :: 8 // bits per byte
@(private = "file")
MC :: (1 << NB) - 1 // one-byte mask
@(private = "file")
SZINT :: size_of(lua.Integer)
// Native maximum alignment: the widest scalar we pack (double / lua_Integer = 8).
@(private = "file")
NATIVE_MAXALIGN :: 8
// Our target is little-endian; this drives byte-order correction.
@(private = "file")
NATIVE_LITTLE :: ODIN_ENDIAN == .Little

@(private = "file")
KOption :: enum {
	Int, // signed integers
	Uint, // unsigned integers
	Float, // single-precision float
	Number, // lua_Number (double)
	Double, // double
	Char, // fixed-length string
	String, // length-prefixed string
	Zstr, // zero-terminated string
	Padding, // one pad byte
	Paddalign, // alignment padding
	Nop, // configuration / spaces
}

@(private = "file")
Header :: struct {
	L:        ^lua.Lua_State,
	islittle: bool,
	maxalign: uint,
}

@(private = "file")
initheader :: proc(L: ^lua.Lua_State, h: ^Header) {
	h.L = L
	h.islittle = NATIVE_LITTLE
	h.maxalign = 1
}

@(private = "file")
is_pow2 :: #force_inline proc "contextless" (x: uint) -> bool {
	return x != 0 && (x & (x - 1)) == 0
}

// Read an unsigned numeral from the format string (or return `df`). `pos` advances
// past the digits. Refuses to overflow.
@(private = "file")
getnum :: proc(fmt: []u8, pos: ^int, df: uint) -> uint {
	if !(pos^ < len(fmt) && is_digit_byte(fmt[pos^])) {
		return df
	}
	a: uint = 0
	for pos^ < len(fmt) && is_digit_byte(fmt[pos^]) && a <= (lua.MAX_SIZE - 9) / 10 {
		a = a * 10 + uint(fmt[pos^] - '0')
		pos^ += 1
	}
	return a
}

// Like getnum, but bounds the result to a legal integral size [1, MAXINTSIZE].
@(private = "file")
getnumlimit :: proc(h: ^Header, fmt: []u8, pos: ^int, df: uint) -> uint {
	sz := getnum(fmt, pos, df)
	if (sz - 1) >= MAXINTSIZE {
		luaL_error(h.L, "integral size (%d) out of limits [1,%d]", int(sz), MAXINTSIZE)
	}
	return sz
}

// Read and classify the next option, filling `size` with its byte size.
@(private = "file")
getoption :: proc(h: ^Header, fmt: []u8, pos: ^int, size: ^uint) -> KOption {
	opt := fmt[pos^]
	pos^ += 1
	size^ = 0
	switch opt {
	case 'b':
		size^ = size_of(u8);return .Int
	case 'B':
		size^ = size_of(u8);return .Uint
	case 'h':
		size^ = size_of(c.short);return .Int
	case 'H':
		size^ = size_of(c.short);return .Uint
	case 'l':
		size^ = size_of(c.long);return .Int
	case 'L':
		size^ = size_of(c.long);return .Uint
	case 'j':
		size^ = size_of(lua.Integer);return .Int
	case 'J':
		size^ = size_of(lua.Integer);return .Uint
	case 'T':
		size^ = size_of(c.size_t);return .Uint
	case 'f':
		size^ = size_of(f32);return .Float
	case 'n':
		size^ = size_of(lua.Number);return .Number
	case 'd':
		size^ = size_of(f64);return .Double
	case 'i':
		size^ = getnumlimit(h, fmt, pos, size_of(c.int));return .Int
	case 'I':
		size^ = getnumlimit(h, fmt, pos, size_of(c.int));return .Uint
	case 's':
		size^ = getnumlimit(h, fmt, pos, size_of(c.size_t));return .String
	case 'c':
		size^ = getnum(fmt, pos, ~uint(0))
		if size^ == ~uint(0) {
			luaL_error(h.L, "missing size for format option 'c'")
		}
		return .Char
	case 'z':
		return .Zstr
	case 'x':
		size^ = 1;return .Padding
	case 'X':
		return .Paddalign
	case ' ':
	// nothing
	case '<':
		h.islittle = true
	case '>':
		h.islittle = false
	case '=':
		h.islittle = NATIVE_LITTLE
	case '!':
		h.maxalign = getnumlimit(h, fmt, pos, NATIVE_MAXALIGN)
	case:
		luaL_error(h.L, "invalid format option '%c'", int(opt))
	}
	return .Nop
}

// Fill in size and alignment for the next option (reference `getdetails`).
@(private = "file")
getdetails :: proc(
	h: ^Header,
	totalsize: uint,
	fmt: []u8,
	pos: ^int,
	psize: ^uint,
	ntoalign: ^uint,
) -> KOption {
	opt := getoption(h, fmt, pos, psize)
	align := psize^ // usually alignment follows size
	if opt == .Paddalign {
		// 'X' borrows the alignment of the following option.
		dummy: uint
		if pos^ >= len(fmt) || getoption(h, fmt, pos, &dummy) == .Char || dummy == 0 {
			luaL_argerror(h.L, 1, "invalid next option for option 'X'")
		}
		align = dummy
	}
	if align <= 1 || opt == .Char {
		ntoalign^ = 0 // no alignment needed
	} else {
		if align > h.maxalign {
			align = h.maxalign // cap at the requested maximum
		}
		if !is_pow2(align) {
			ntoalign^ = 0
			luaL_argerror(h.L, 1, "format asks for alignment not power of 2")
		}
		szmoda := totalsize & (align - 1)
		ntoalign^ = (align - szmoda) & (align - 1)
	}
	return opt
}

// Pack integer `n` into `size` bytes with the requested endianness, sign-extending
// if `neg` and `size` exceeds a Lua integer.
@(private = "file")
packint :: proc(b: ^Buffer, n: lua.Unsigned, islittle: bool, size: uint, neg: bool) {
	buff := luaL_prepbuffsize(b, size)
	v := n
	buff[islittle ? 0 : int(size) - 1] = u8(v & MC)
	for i: uint = 1; i < size; i += 1 {
		v >>= NB
		buff[islittle ? int(i) : int(size) - 1 - int(i)] = u8(v & MC)
	}
	if neg && size > SZINT {
		for i: uint = SZINT; i < size; i += 1 {
			buff[islittle ? int(i) : int(size) - 1 - int(i)] = u8(MC)
		}
	}
	luaL_addsize(b, size)
}

// Copy `size` bytes from `src` to `dest`, reversing if the requested endianness
// differs from native.
@(private = "file")
copywithendian :: proc(dest: [^]u8, src: []u8, size: uint, islittle: bool) {
	if islittle == NATIVE_LITTLE {
		for i in 0 ..< int(size) {
			dest[i] = src[i]
		}
	} else {
		for i in 0 ..< int(size) {
			dest[i] = src[int(size) - 1 - i]
		}
	}
}

@(private = "file")
str_pack :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fmt_str := luaL_checkstring(L, 1)
	fmt := transmute([]u8)fmt_str
	flen := c_strlen(fmt) // pack formats are NUL-terminated
	h: Header
	initheader(L, &h)
	arg := 1
	totalsize: uint = 0
	lua.lua_pushnil(L) // separate arguments from the buffer
	b: Buffer
	luaL_buffinit(L, &b)
	pos := 0
	for pos < flen {
		ntoalign: uint
		size: uint
		opt := getdetails(&h, totalsize, fmt[:flen], &pos, &size, &ntoalign)
		luaL_argcheck(L, size + ntoalign <= lua.MAX_SIZE - totalsize, arg, "result too long")
		totalsize += ntoalign + size
		for ntoalign > 0 {
			luaL_addchar(&b, LUAL_PACKPADBYTE)
			ntoalign -= 1
		}
		arg += 1
		switch opt {
		case .Int:
			n := luaL_checkinteger(L, arg)
			if size < SZINT {
				lim := lua.Integer(1) << uint(size * NB - 1)
				luaL_argcheck(L, -lim <= n && n < lim, arg, "integer overflow")
			}
			packint(&b, lua.Unsigned(n), h.islittle, size, n < 0)
		case .Uint:
			n := luaL_checkinteger(L, arg)
			if size < SZINT {
				luaL_argcheck(
					L,
					lua.Unsigned(n) < (lua.Unsigned(1) << uint(size * NB)),
					arg,
					"unsigned overflow",
				)
			}
			packint(&b, lua.Unsigned(n), h.islittle, size, false)
		case .Float:
			f := f32(luaL_checknumber(L, arg))
			raw := transmute([size_of(f32)]u8)f
			buff := luaL_prepbuffsize(&b, size_of(f32))
			copywithendian(buff, raw[:], size, h.islittle)
			luaL_addsize(&b, size)
		case .Number:
			f := lua.Number(luaL_checknumber(L, arg))
			raw := transmute([size_of(lua.Number)]u8)f
			buff := luaL_prepbuffsize(&b, size_of(lua.Number))
			copywithendian(buff, raw[:], size, h.islittle)
			luaL_addsize(&b, size)
		case .Double:
			f := f64(luaL_checknumber(L, arg))
			raw := transmute([size_of(f64)]u8)f
			buff := luaL_prepbuffsize(&b, size_of(f64))
			copywithendian(buff, raw[:], size, h.islittle)
			luaL_addsize(&b, size)
		case .Char:
			s := transmute([]u8)luaL_checklstring(L, arg)
			luaL_argcheck(L, uint(len(s)) <= size, arg, "string longer than given size")
			luaL_addlstring(&b, s)
			if uint(len(s)) < size {
				psize := size - uint(len(s))
				buff := luaL_prepbuffsize(&b, psize)
				for k in 0 ..< int(psize) {
					buff[k] = LUAL_PACKPADBYTE
				}
				luaL_addsize(&b, psize)
			}
		case .String:
			s := transmute([]u8)luaL_checklstring(L, arg)
			luaL_argcheck(
				L,
				size >= size_of(lua.Unsigned) || uint(len(s)) < (uint(1) << uint(size * NB)),
				arg,
				"string length does not fit in given size",
			)
			packint(&b, lua.Unsigned(len(s)), h.islittle, size, false)
			luaL_addlstring(&b, s)
			totalsize += uint(len(s))
		case .Zstr:
			s := transmute([]u8)luaL_checklstring(L, arg)
			luaL_argcheck(L, c_strlen(s) == len(s), arg, "string contains zeros")
			luaL_addlstring(&b, s)
			luaL_addchar(&b, 0)
			totalsize += uint(len(s)) + 1
		case .Padding:
			luaL_addchar(&b, LUAL_PACKPADBYTE)
			arg -= 1 // consumes no argument
		case .Paddalign, .Nop:
			arg -= 1 // consumes no argument
		}
	}
	luaL_pushresult(&b)
	return 1
}

@(private = "file")
str_packsize :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fmt := transmute([]u8)luaL_checkstring(L, 1)
	flen := c_strlen(fmt)
	h: Header
	initheader(L, &h)
	totalsize: uint = 0
	pos := 0
	for pos < flen {
		ntoalign: uint
		size: uint
		opt := getdetails(&h, totalsize, fmt[:flen], &pos, &size, &ntoalign)
		luaL_argcheck(L, opt != .String && opt != .Zstr, 1, "variable-length format")
		size += ntoalign
		luaL_argcheck(L, totalsize <= uint(lua.MAX_INTEGER) - size, 1, "format result too large")
		totalsize += size
	}
	lua.lua_pushinteger(L, lua.Integer(totalsize))
	return 1
}

// Unpack an integer of `size` bytes, doing sign extension (if signed and narrower
// than a Lua integer) or an overflow check (if wider).
@(private = "file")
unpackint :: proc(
	L: ^lua.Lua_State,
	str: []u8,
	islittle: bool,
	size: int,
	issigned: bool,
) -> lua.Integer {
	res: lua.Unsigned = 0
	limit := (size <= SZINT) ? size : SZINT
	for i := limit - 1; i >= 0; i -= 1 {
		res <<= NB
		res |= lua.Unsigned(str[islittle ? i : size - 1 - i])
	}
	if size < SZINT {
		if issigned {
			mask := lua.Unsigned(1) << uint(size * NB - 1)
			res = (res ~ mask) - mask // sign-extend
		}
	} else if size > SZINT {
		mask := (!issigned || lua.Integer(res) >= 0) ? 0 : MC
		for i := limit; i < size; i += 1 {
			if int(str[islittle ? i : size - 1 - i]) != mask {
				luaL_error(L, "%d-byte integer does not fit into Lua Integer", size)
			}
		}
	}
	return lua.Integer(res)
}

@(private = "file")
str_unpack :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fmt := transmute([]u8)luaL_checkstring(L, 1)
	flen := c_strlen(fmt)
	data := transmute([]u8)luaL_checklstring(L, 2)
	ld := uint(len(data))
	pos := uint(posrelatI(luaL_optinteger(L, 3, 1), len(data)) - 1)
	n := 0
	luaL_argcheck(L, pos <= ld, 3, "initial position out of string")
	h: Header
	initheader(L, &h)
	fpos := 0
	for fpos < flen {
		ntoalign: uint
		size: uint
		opt := getdetails(&h, pos, fmt[:flen], &fpos, &size, &ntoalign)
		// Ordered so the subtraction can't underflow: pos <= ld already holds.
		luaL_argcheck(L, ntoalign + size <= ld - pos, 2, "data string too short")
		pos += ntoalign
		luaL_checkstack(L, 2, "too many results")
		n += 1
		switch opt {
		case .Int, .Uint:
			res := unpackint(L, data[pos:], h.islittle, int(size), opt == .Int)
			lua.lua_pushinteger(L, res)
		case .Float:
			raw: [size_of(f32)]u8
			copywithendian(raw_data(raw[:]), data[pos:], size_of(f32), h.islittle)
			f := transmute(f32)raw
			lua.lua_pushnumber(L, lua.Number(f))
		case .Number:
			raw: [size_of(lua.Number)]u8
			copywithendian(raw_data(raw[:]), data[pos:], size_of(lua.Number), h.islittle)
			f := transmute(lua.Number)raw
			lua.lua_pushnumber(L, f)
		case .Double:
			raw: [size_of(f64)]u8
			copywithendian(raw_data(raw[:]), data[pos:], size_of(f64), h.islittle)
			f := transmute(f64)raw
			lua.lua_pushnumber(L, lua.Number(f))
		case .Char:
			lua.lua_pushlstring(L, data[pos:pos + size])
		case .String:
			length := lua.Unsigned(unpackint(L, data[pos:], h.islittle, int(size), false))
			luaL_argcheck(L, uint(length) <= ld - pos - size, 2, "data string too short")
			lua.lua_pushlstring(L, data[pos + size:pos + size + uint(length)])
			pos += uint(length)
		case .Zstr:
			length := uint(c_strlen(data[pos:]))
			luaL_argcheck(L, pos + length < ld, 2, "unfinished string for format 'z'")
			lua.lua_pushlstring(L, data[pos:pos + length])
			pos += length + 1
		case .Paddalign, .Padding, .Nop:
			n -= 1 // produced no value
		}
		pos += size
	}
	lua.lua_pushinteger(L, lua.Integer(pos) + 1) // next position
	return i32(n + 1)
}

// ===========================================================================
// Registration
// ===========================================================================

@(private = "file")
strlib := []Reg {
	{"byte", str_byte},
	{"char", str_char},
	{"dump", str_dump},
	{"find", str_find},
	{"format", str_format},
	{"gmatch", gmatch},
	{"gsub", str_gsub},
	{"len", str_len},
	{"lower", str_lower},
	{"match", str_match},
	{"rep", str_rep},
	{"reverse", str_reverse},
	{"sub", str_sub},
	{"upper", str_upper},
	{"pack", str_pack},
	{"packsize", str_packsize},
	{"unpack", str_unpack},
}

// Build the shared metatable for all strings so `("x"):upper()` works and the
// arithmetic metamethods are in place. `__index` points at the library table.
@(private = "file")
createmetatable :: proc(L: ^lua.Lua_State) {
	luaL_newlib(L, stringmetamethods) // table with the arithmetic metamethods
	lua.lua_pushstring(L, "") // a dummy string...
	lua.lua_pushvalue(L, -2) // ...and a copy of the metatable
	lua.lua_setmetatable(L, -2) // set it as the metatable for all strings
	lua.lua_pop(L, 1) // drop the dummy string
	lua.lua_pushvalue(L, -2) // the string library table
	lua.lua_setfield(L, -2, "__index") // metatable.__index = string
	lua.lua_pop(L, 1) // drop the metatable
}

luaopen_string :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_newlib(L, strlib)
	createmetatable(L)
	return 1
}
