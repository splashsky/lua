package stdlib

// base.odin -- the basic library (reference `lbaselib.c`): the global functions
// that are always available without a library prefix (`print`, `type`, `pairs`,
// `pcall`, `setmetatable`, `tonumber`, `load`, ...), plus the `_G` and `_VERSION`
// globals. Everything here is a faithful port; the C functions keep the native
// ABI (`proc "c" (L: rawptr) -> i32`) and lean on the auxiliary library above.

import "base:runtime"
import lua "luao:lua"
import stream "luao:stream"

// The name under which the global table is itself exposed (`_G`) -- reference
// `LUA_GNAME`.
G_NAME :: "_G"

// Every native library entry begins by restoring an Odin context and recovering
// the typed state pointer from the raw ABI pointer. Kept as a tiny helper so each
// function body reads like its C original.
@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// Write bytes to the stdout object shared with io.*.
@(private = "file")
write_stdout :: proc(s: string) {
	if len(s) > 0 {
		stream.write(stream.stdout(), transmute([]u8)s)
	}
}

// --------------------------------------------------------------------------------
// print / warn
// --------------------------------------------------------------------------------

// `print(...)`: convert each argument with `luaL_tolstring` (honoring `__tostring`),
// separated by tabs, then a newline -- reference `luaB_print`.
luaB_print :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	for i in 1 ..= n {
		s := luaL_tolstring(L, i) // pushes the converted string
		if i > 1 {
			write_stdout("\t")
		}
		write_stdout(s)
		lua.lua_pop(L, 1) // pop the converted string
	}
	write_stdout("\n")
	stream.flush(stream.stdout())
	return 0
}

// `warn(...)`: compose a warning from string arguments -- reference `luaB_warn`.
// Arguments are validated up front so a bad one cannot leave a half-emitted
// warning.
luaB_warn :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	luaL_checkstring(L, 1)
	for i in 2 ..= n {
		luaL_checkstring(L, i)
	}
	for i in 1 ..< n {
		s, _ := lua.lua_tostring(L, i)
		lua.lua_warning(L, cstring(raw_data(s)), true) // fragment: continued
	}
	last, _ := lua.lua_tostring(L, n)
	lua.lua_warning(L, cstring(raw_data(last)), false) // final fragment
	return 0
}

// --------------------------------------------------------------------------------
// tonumber / type / tostring
// --------------------------------------------------------------------------------

// Parse a signed integer in an explicit base (2..36), matching reference
// `b_str2int`. Returns the parsed value and whether the *entire* string was a valid
// numeral (leading/trailing spaces allowed).
@(private = "file")
b_str2int :: proc(s: string, base: int) -> (n: lua.Integer, ok: bool) {
	i := 0
	m := len(s)
	is_space :: proc(c: u8) -> bool {
		return c == ' ' || c == '\f' || c == '\n' || c == '\r' || c == '\t' || c == '\v'
	}
	for i < m && is_space(s[i]) {
		i += 1
	}
	neg := false
	if i < m && (s[i] == '-' || s[i] == '+') {
		neg = s[i] == '-'
		i += 1
	}
	acc: lua.Unsigned = 0
	digits := 0
	for i < m {
		c := s[i]
		d := -1
		switch {
		case c >= '0' && c <= '9':
			d = int(c - '0')
		case c >= 'a' && c <= 'z':
			d = int(c - 'a') + 10
		case c >= 'A' && c <= 'Z':
			d = int(c - 'A') + 10
		}
		if d < 0 {
			break // not alphanumeric: the numeral ends here
		}
		if d >= base {
			return 0, false
		}
		acc = acc * lua.Unsigned(base) + lua.Unsigned(d)
		digits += 1
		i += 1
	}
	if digits == 0 {
		return 0, false
	}
	for i < m && is_space(s[i]) {
		i += 1
	}
	if i != m {
		return 0, false // trailing garbage
	}
	v := lua.Integer(acc)
	if neg {
		v = -v
	}
	return v, true
}

// `tonumber(v [, base])` -- reference `luaB_tonumber`.
luaB_tonumber :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isnoneornil(L, 2) {
		// Standard conversion (no explicit base).
		if lua.lua_type(L, 1) == lua.LUA_TNUMBER {
			lua.lua_settop(L, 1) // already a number: return it unchanged
			return 1
		}
		s, ok := lua.lua_tolstring(L, 1)
		if ok && lua.lua_stringtonumber(L, s) == uint(len(s)) + 1 {
			return 1 // parsed a full numeral (pushed by lua_stringtonumber)
		}
		luaL_checkany(L, 1) // there must be *some* argument
	} else {
		base := luaL_checkinteger(L, 2)
		luaL_checktype(L, 1, lua.LUA_TSTRING) // base form requires a string
		s := luaL_checkstring(L, 1)
		luaL_argcheck(L, 2 <= base && base <= 36, 2, "base out of range")
		if v, ok := b_str2int(s, int(base)); ok {
			lua.lua_pushinteger(L, v)
			return 1
		}
	}
	lua.lua_pushnil(L) // fail == nil
	return 1
}

// `type(v)` -- reference `luaB_type`.
luaB_type :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := lua.lua_type(L, 1)
	luaL_argcheck(L, tt != lua.LUA_TNONE, 1, "value expected")
	lua.lua_pushstring(L, lua.lua_typename(L, tt))
	return 1
}

// `tostring(v)` -- reference `luaB_tostring`.
luaB_tostring :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	luaL_tolstring(L, 1)
	return 1
}

// --------------------------------------------------------------------------------
// error / assert
// --------------------------------------------------------------------------------

// `error(msg [, level])` -- reference `luaB_error`. A string message at a positive
// level gets a `source:line:` prefix.
luaB_error :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	level := luaL_optinteger(L, 2, 1)
	lua.lua_settop(L, 1)
	if lua.lua_type(L, 1) == lua.LUA_TSTRING && level > 0 {
		luaL_where(L, int(level))
		lua.lua_pushvalue(L, 1)
		lua.lua_concat(L, 2)
	}
	lua.lua_error(L)
}

// `assert(v, ...)` -- reference `luaB_assert`. Returns all arguments on truth,
// otherwise raises with the supplied (or default) message.
luaB_assert :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_toboolean(L, 1) {
		return i32(lua.lua_gettop(L)) // pass through every argument
	}
	luaL_checkany(L, 1) // there must be a condition
	lua.lua_remove(L, 1) // drop the (false) condition
	lua.lua_pushstring(L, "assertion failed!")
	lua.lua_settop(L, 1) // keep only the message (default unless one was given)
	return luaB_error(Lp) // delegate to error()
}

// --------------------------------------------------------------------------------
// select
// --------------------------------------------------------------------------------

// `select('#', ...)` -> count; `select(n, ...)` -> the arguments from n on --
// reference `luaB_select`.
luaB_select :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	if lua.lua_type(L, 1) == lua.LUA_TSTRING {
		s, _ := lua.lua_tostring(L, 1)
		if len(s) > 0 && s[0] == '#' {
			lua.lua_pushinteger(L, lua.Integer(n - 1))
			return 1
		}
	}
	i := luaL_checkinteger(L, 1)
	if i < 0 {
		i = lua.Integer(n) + i
	} else if i > lua.Integer(n) {
		i = lua.Integer(n)
	}
	luaL_argcheck(L, 1 <= i, 1, "index out of range")
	return i32(lua.Integer(n) - i)
}

// --------------------------------------------------------------------------------
// raw table access, metatables
// --------------------------------------------------------------------------------

luaB_rawequal :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	luaL_checkany(L, 2)
	lua.lua_pushboolean(L, lua.lua_rawequal(L, 1, 2))
	return 1
}

luaB_rawlen :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := lua.lua_type(L, 1)
	luaL_argexpected(L, tt == lua.LUA_TTABLE || tt == lua.LUA_TSTRING, 1, "table or string")
	lua.lua_pushinteger(L, lua.Integer(lua.lua_rawlen(L, 1)))
	return 1
}

luaB_rawget :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checktype(L, 1, lua.LUA_TTABLE)
	luaL_checkany(L, 2)
	lua.lua_settop(L, 2)
	lua.lua_rawget(L, 1)
	return 1
}

luaB_rawset :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checktype(L, 1, lua.LUA_TTABLE)
	luaL_checkany(L, 2)
	luaL_checkany(L, 3)
	lua.lua_settop(L, 3)
	lua.lua_rawset(L, 1)
	return 1
}

luaB_getmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	if !lua.lua_getmetatable(L, 1) {
		lua.lua_pushnil(L)
		return 1 // no metatable
	}
	luaL_getmetafield(L, 1, "__metatable") // protected view if present
	return 1
}

luaB_setmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := lua.lua_type(L, 2)
	luaL_checktype(L, 1, lua.LUA_TTABLE)
	luaL_argexpected(L, tt == lua.LUA_TNIL || tt == lua.LUA_TTABLE, 2, "nil or table")
	if luaL_getmetafield(L, 1, "__metatable") != lua.LUA_TNIL {
		luaL_error(L, "cannot change a protected metatable")
	}
	lua.lua_settop(L, 2)
	lua.lua_setmetatable(L, 1)
	return 1
}

// --------------------------------------------------------------------------------
// collectgarbage
// --------------------------------------------------------------------------------

@(private = "file")
pushmode :: proc(L: ^lua.Lua_State, oldmode: int) -> i32 {
	if oldmode == -1 {
		lua.lua_pushnil(L) // invalid call (inside a finalizer)
	} else {
		lua.lua_pushstring(L, oldmode == lua.LUA_GCINC ? "incremental" : "generational")
	}
	return 1
}

// `collectgarbage([opt [, arg]])` -- reference `luaB_collectgarbage`.
luaB_collectgarbage :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	opts := []string {
		"stop",
		"restart",
		"collect",
		"count",
		"step",
		"isrunning",
		"generational",
		"incremental",
		"param",
	}
	optsnum := []int {
		lua.LUA_GCSTOP,
		lua.LUA_GCRESTART,
		lua.LUA_GCCOLLECT,
		lua.LUA_GCCOUNT,
		lua.LUA_GCSTEP,
		lua.LUA_GCISRUNNING,
		lua.LUA_GCGEN,
		lua.LUA_GCINC,
		lua.LUA_GCPARAM,
	}
	o := optsnum[luaL_checkoption(L, 1, "collect", opts)]
	switch o {
	case lua.LUA_GCCOUNT:
		k := lua.lua_gc(L, o)
		b := lua.lua_gc(L, lua.LUA_GCCOUNTB)
		if k == -1 {
			break
		}
		lua.lua_pushnumber(L, lua.Number(k) + lua.Number(b) / 1024)
		return 1
	case lua.LUA_GCSTEP:
		n := luaL_optinteger(L, 2, 0)
		res := lua.lua_gc(L, o, int(n))
		if res == -1 {
			break
		}
		lua.lua_pushboolean(L, res != 0)
		return 1
	case lua.LUA_GCISRUNNING:
		res := lua.lua_gc(L, o)
		if res == -1 {
			break
		}
		lua.lua_pushboolean(L, res != 0)
		return 1
	case lua.LUA_GCGEN:
		return pushmode(L, lua.lua_gc(L, o))
	case lua.LUA_GCINC:
		return pushmode(L, lua.lua_gc(L, o))
	case lua.LUA_GCPARAM:
		params := []string{"minormul", "majorminor", "minormajor", "pause", "stepmul", "stepsize"}
		pnum := []int {
			lua.LUA_GCPMINORMUL,
			lua.LUA_GCPMAJORMINOR,
			lua.LUA_GCPMINORMAJOR,
			lua.LUA_GCPPAUSE,
			lua.LUA_GCPSTEPMUL,
			lua.LUA_GCPSTEPSIZE,
		}
		p := pnum[luaL_checkoption(L, 2, "", params)]
		value := luaL_optinteger(L, 3, -1)
		lua.lua_pushinteger(L, lua.Integer(lua.lua_gc(L, o, p, int(value))))
		return 1
	case:
		res := lua.lua_gc(L, o)
		if res == -1 {
			break
		}
		lua.lua_pushinteger(L, lua.Integer(res))
		return 1
	}
	lua.lua_pushnil(L) // invalid call (inside a finalizer)
	return 1
}

// --------------------------------------------------------------------------------
// next / pairs / ipairs
// --------------------------------------------------------------------------------

luaB_next :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checktype(L, 1, lua.LUA_TTABLE)
	lua.lua_settop(L, 2) // ensure there is a (possibly nil) key argument
	if lua.lua_next(L, 1) {
		return 2
	}
	lua.lua_pushnil(L)
	return 1
}

// `__pairs` continuation: it already produced the four results -- reference
// `pairscont`.
pairscont :: proc "c" (Lp: rawptr, status: i32, ctx: lua.K_Context) -> i32 {
	return 4
}

// `pairs(t)` -- reference `luaB_pairs`. In 5.5 this yields *four* values (the
// iterator, the state, the initial control, and a to-be-closed slot).
luaB_pairs :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	if luaL_getmetafield(L, 1, "__pairs") == lua.LUA_TNIL {
		lua.lua_pushcfunction(L, luaB_next) // iterator
		lua.lua_pushvalue(L, 1) // state
		lua.lua_pushnil(L) // initial control value
		lua.lua_pushnil(L) // to-be-closed slot
	} else {
		lua.lua_pushvalue(L, 1) // self
		lua.lua_callk(L, 1, 4, 0, pairscont) // __pairs returns four values
	}
	return 4
}

// The stateless iterator behind `ipairs` -- reference `ipairsaux`.
ipairsaux :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	i := luaL_checkinteger(L, 2) + 1
	lua.lua_pushinteger(L, i)
	return lua.lua_geti(L, 1, i) == lua.LUA_TNIL ? 1 : 2
}

// `ipairs(t)` -- reference `luaB_ipairs`. Returns (iterator, t, 0).
luaB_ipairs :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	lua.lua_pushcfunction(L, ipairsaux)
	lua.lua_pushvalue(L, 1)
	lua.lua_pushinteger(L, 0)
	return 3
}

// --------------------------------------------------------------------------------
// load / loadfile / dofile
// --------------------------------------------------------------------------------

// Shared tail for `load`/`loadfile`: on success optionally install the `env`
// upvalue; on error return `fail, message` -- reference `load_aux`.
@(private = "file")
load_aux :: proc(L: ^lua.Lua_State, status: lua.Thread_Status, envidx: int) -> i32 {
	if status == .Ok {
		if envidx != 0 {
			lua.lua_pushvalue(L, envidx)
			if _, ok := lua.lua_setupvalue(L, -2, 1); !ok {
				lua.lua_pop(L, 1) // env unused by the chunk: drop it
			}
		}
		return 1
	}
	lua.lua_pushnil(L) // fail
	lua.lua_insert(L, -2) // put it before the error message
	return 2
}

// Validate and return a load mode, rejecting the fixed-buffer 'B' flag from Lua --
// reference `getMode`.
@(private = "file")
getMode :: proc(L: ^lua.Lua_State, idx: int) -> string {
	mode := luaL_optstring(L, idx, "bt")
	for c in transmute([]u8)mode {
		if c == 'B' {
			luaL_argerror(L, idx, "invalid mode")
		}
	}
	return mode
}

luaB_loadfile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fname := luaL_optstring(L, 1, "")
	mode := getMode(L, 2)
	env := !lua.lua_isnone(L, 3) ? 3 : 0
	status := luaL_loadfilex(L, fname, mode)
	return load_aux(L, status, env)
}

// Reader slot: a reserved stack index that holds the last chunk piece so the GC
// cannot collect it mid-parse -- reference `RESERVEDSLOT`.
@(private = "file")
RESERVEDSLOT :: 5

// Reader for `load(f)` where `f` is a function -- reference `generic_reader`.
generic_reader :: proc "c" (L: ^lua.Lua_State, ud: rawptr, size: ^uint) -> [^]u8 {
	context = runtime.default_context()
	luaL_checkstack(L, 2, "too many nested functions")
	lua.lua_pushvalue(L, 1) // the reader function
	lua.lua_call(L, 0, 1) // call it for the next piece
	if lua.lua_isnil(L, -1) {
		lua.lua_pop(L, 1)
		size^ = 0
		return nil // end of input
	}
	if !lua.lua_isstring(L, -1) {
		luaL_error(L, "reader function must return a string")
	}
	lua.lua_replace(L, RESERVEDSLOT) // park it in the reserved slot
	s, _ := lua.lua_tolstring(L, RESERVEDSLOT)
	size^ = uint(len(s))
	return ([^]u8)(raw_data(s))
}

luaB_load :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	mode := getMode(L, 3)
	env := !lua.lua_isnone(L, 4) ? 4 : 0
	status: lua.Thread_Status
	if s, ok := lua.lua_tolstring(L, 1); ok {
		// Loading from a string.
		chunkname := luaL_optstring(L, 2, s)
		status = luaL_loadbufferx(L, transmute([]u8)s, chunkname, mode)
	} else {
		// Loading from a reader function.
		chunkname := luaL_optstring(L, 2, "=(load)")
		luaL_checktype(L, 1, lua.LUA_TFUNCTION)
		lua.lua_settop(L, RESERVEDSLOT) // create the reserved slot
		status = lua.lua_load(L, generic_reader, nil, chunkname, mode)
	}
	return load_aux(L, status, env)
}

// `dofile` continuation: return every result the chunk produced -- reference
// `dofilecont`.
dofilecont :: proc "c" (Lp: rawptr, status: i32, ctx: lua.K_Context) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return i32(lua.lua_gettop(L) - 1)
}

luaB_dofile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fname := luaL_optstring(L, 1, "")
	lua.lua_settop(L, 1)
	if luaL_loadfilex(L, fname, "") != .Ok {
		lua.lua_error(L)
	}
	lua.lua_callk(L, 0, lua.LUA_MULTRET, 0, dofilecont)
	return dofilecont(Lp, 0, 0)
}

// --------------------------------------------------------------------------------
// pcall / xpcall
// --------------------------------------------------------------------------------

// Shared continuation/tail for `pcall`/`xpcall` -- reference `finishpcall`. `extra`
// counts leading stack values to skip when returning results.
finishpcall :: proc "c" (Lp: rawptr, status: i32, extra: lua.K_Context) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st := lua.Thread_Status(status)
	if st != .Ok && st != .Yield {
		lua.lua_pushboolean(L, false) // first result: false
		lua.lua_pushvalue(L, -2) // the error message
		return 2
	}
	return i32(lua.lua_gettop(L) - int(extra))
}

luaB_pcall :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	lua.lua_pushboolean(L, true) // success sentinel, prepended
	lua.lua_insert(L, 1)
	status := lua.lua_pcallk(L, lua.lua_gettop(L) - 2, lua.LUA_MULTRET, 0, 0, finishpcall)
	return finishpcall(Lp, i32(status), 0)
}

luaB_xpcall :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	luaL_checktype(L, 2, lua.LUA_TFUNCTION) // the message handler
	lua.lua_pushboolean(L, true)
	lua.lua_pushvalue(L, 1) // the function to call
	lua.lua_rotate(L, 3, 2) // move sentinel+function below the arguments
	status := lua.lua_pcallk(L, n - 2, lua.LUA_MULTRET, 2, 2, finishpcall)
	return finishpcall(Lp, i32(status), 2)
}

// --------------------------------------------------------------------------------
// Registration
// --------------------------------------------------------------------------------

// The base-library registration table -- reference `base_funcs`. `_G`/`_VERSION`
// are placeholders (nil func) filled in by `luaopen_base`.
@(private = "file")
base_funcs := []Reg {
	{"assert", luaB_assert},
	{"collectgarbage", luaB_collectgarbage},
	{"dofile", luaB_dofile},
	{"error", luaB_error},
	{"getmetatable", luaB_getmetatable},
	{"ipairs", luaB_ipairs},
	{"loadfile", luaB_loadfile},
	{"load", luaB_load},
	{"next", luaB_next},
	{"pairs", luaB_pairs},
	{"pcall", luaB_pcall},
	{"print", luaB_print},
	{"warn", luaB_warn},
	{"rawequal", luaB_rawequal},
	{"rawlen", luaB_rawlen},
	{"rawget", luaB_rawget},
	{"rawset", luaB_rawset},
	{"select", luaB_select},
	{"setmetatable", luaB_setmetatable},
	{"tonumber", luaB_tonumber},
	{"tostring", luaB_tostring},
	{"type", luaB_type},
	{"xpcall", luaB_xpcall},
}

// Open the basic library into the global table, wiring `_G` and `_VERSION` --
// reference `luaopen_base`.
luaopen_base :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushglobaltable(L)
	luaL_setfuncs(L, base_funcs, 0)
	lua.lua_pushvalue(L, -1)
	lua.lua_setfield(L, -2, G_NAME) // _G._G = _G
	lua.lua_pushstring(L, lua.VERSION)
	lua.lua_setfield(L, -2, "_VERSION")
	return 1
}
