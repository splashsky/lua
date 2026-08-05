#+build !freestanding

package stdlib

// base.odin -- the basic library (reference `lbaselib.c`): the global functions
// that are always available without a library prefix (`print`, `type`, `pairs`,
// `pcall`, `setmetatable`, `tonumber`, `load`, ...), plus the `_G` and `_VERSION`
// globals. Everything here is a faithful port; the C functions keep the native
// ABI (`proc "c" (L: rawptr) -> i32`) and lean on the auxiliary library above.

import "base:runtime"
import kernel "lang:kernel"
import stream "lang:stream"

// The name under which the global table is itself exposed (`_G`) -- reference
// `LUA_GNAME`.
G_NAME :: "_G"

// Every native library entry begins by restoring an Odin context and recovering
// the typed state pointer from the raw ABI pointer. Kept as a tiny helper so each
// function body reads like its C original.
@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
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
base_print :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := kernel.api_gettop(L)
	for i in 1 ..= n {
		s := aux_tolstring(L, i) // pushes the converted string
		if i > 1 {
			write_stdout("\t")
		}
		write_stdout(s)
		kernel.api_pop(L, 1) // pop the converted string
	}
	write_stdout("\n")
	stream.flush(stream.stdout())
	return 0
}

// `warn(...)`: compose a warning from string arguments -- reference `luaB_warn`.
// Arguments are validated up front so a bad one cannot leave a half-emitted
// warning.
base_warn :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := kernel.api_gettop(L)
	aux_checkstring(L, 1)
	for i in 2 ..= n {
		aux_checkstring(L, i)
	}
	for i in 1 ..< n {
		s, _ := kernel.api_tostring(L, i)
		kernel.api_warning(L, cstring(raw_data(s)), true) // fragment: continued
	}
	last, _ := kernel.api_tostring(L, n)
	kernel.api_warning(L, cstring(raw_data(last)), false) // final fragment
	return 0
}

// --------------------------------------------------------------------------------
// tonumber / type / tostring
// --------------------------------------------------------------------------------

// Parse a signed integer in an explicit base (2..36), matching reference
// `b_str2int`. Returns the parsed value and whether the *entire* string was a valid
// numeral (leading/trailing spaces allowed).
@(private = "file")
b_str2int :: proc(s: string, base: int) -> (n: kernel.Integer, ok: bool) {
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
	acc: kernel.Unsigned = 0
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
		acc = acc * kernel.Unsigned(base) + kernel.Unsigned(d)
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
	v := kernel.Integer(acc)
	if neg {
		v = -v
	}
	return v, true
}

// `tonumber(v [, base])` -- reference `luaB_tonumber`.
base_tonumber :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if kernel.api_isnoneornil(L, 2) {
		// Standard conversion (no explicit base).
		if kernel.api_type(L, 1) == kernel.TNUMBER {
			kernel.api_settop(L, 1) // already a number: return it unchanged
			return 1
		}
		s, ok := kernel.api_tolstring(L, 1)
		if ok && kernel.api_stringtonumber(L, s) == uint(len(s)) + 1 {
			return 1 // parsed a full numeral (pushed by api_stringtonumber)
		}
		aux_checkany(L, 1) // there must be *some* argument
	} else {
		base := aux_checkinteger(L, 2)
		aux_checktype(L, 1, kernel.TSTRING) // base form requires a string
		s := aux_checkstring(L, 1)
		aux_argcheck(L, 2 <= base && base <= 36, 2, "base out of range")
		if v, ok := b_str2int(s, int(base)); ok {
			kernel.api_pushinteger(L, v)
			return 1
		}
	}
	kernel.api_pushnil(L) // fail == nil
	return 1
}

// `type(v)` -- reference `luaB_type`.
base_type :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := kernel.api_type(L, 1)
	aux_argcheck(L, tt != kernel.TNONE, 1, "value expected")
	kernel.api_pushstring(L, kernel.api_typename(L, tt))
	return 1
}

// `tostring(v)` -- reference `luaB_tostring`.
base_tostring :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	aux_tolstring(L, 1)
	return 1
}

// --------------------------------------------------------------------------------
// error / assert
// --------------------------------------------------------------------------------

// `error(msg [, level])` -- reference `luaB_error`. A string message at a positive
// level gets a `source:line:` prefix.
base_error :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	level := aux_optinteger(L, 2, 1)
	kernel.api_settop(L, 1)
	if kernel.api_type(L, 1) == kernel.TSTRING && level > 0 {
		aux_where(L, int(level))
		kernel.api_pushvalue(L, 1)
		kernel.api_concat(L, 2)
	}
	kernel.api_error(L)
}

// `assert(v, ...)` -- reference `luaB_assert`. Returns all arguments on truth,
// otherwise raises with the supplied (or default) message.
base_assert :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if kernel.api_toboolean(L, 1) {
		return i32(kernel.api_gettop(L)) // pass through every argument
	}
	aux_checkany(L, 1) // there must be a condition
	kernel.api_remove(L, 1) // drop the (false) condition
	kernel.api_pushstring(L, "assertion failed!")
	kernel.api_settop(L, 1) // keep only the message (default unless one was given)
	return base_error(Lp) // delegate to error()
}

// --------------------------------------------------------------------------------
// select
// --------------------------------------------------------------------------------

// `select('#', ...)` -> count; `select(n, ...)` -> the arguments from n on --
// reference `luaB_select`.
base_select :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := kernel.api_gettop(L)
	if kernel.api_type(L, 1) == kernel.TSTRING {
		s, _ := kernel.api_tostring(L, 1)
		if len(s) > 0 && s[0] == '#' {
			kernel.api_pushinteger(L, kernel.Integer(n - 1))
			return 1
		}
	}
	i := aux_checkinteger(L, 1)
	if i < 0 {
		i = kernel.Integer(n) + i
	} else if i > kernel.Integer(n) {
		i = kernel.Integer(n)
	}
	aux_argcheck(L, 1 <= i, 1, "index out of range")
	return i32(kernel.Integer(n) - i)
}

// --------------------------------------------------------------------------------
// raw table access, metatables
// --------------------------------------------------------------------------------

base_rawequal :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	aux_checkany(L, 2)
	kernel.api_pushboolean(L, kernel.api_rawequal(L, 1, 2))
	return 1
}

base_rawlen :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := kernel.api_type(L, 1)
	aux_argexpected(L, tt == kernel.TTABLE || tt == kernel.TSTRING, 1, "table or string")
	kernel.api_pushinteger(L, kernel.Integer(kernel.api_rawlen(L, 1)))
	return 1
}

base_rawget :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checktype(L, 1, kernel.TTABLE)
	aux_checkany(L, 2)
	kernel.api_settop(L, 2)
	kernel.api_rawget(L, 1)
	return 1
}

base_rawset :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checktype(L, 1, kernel.TTABLE)
	aux_checkany(L, 2)
	aux_checkany(L, 3)
	kernel.api_settop(L, 3)
	kernel.api_rawset(L, 1)
	return 1
}

base_getmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	if !kernel.api_getmetatable(L, 1) {
		kernel.api_pushnil(L)
		return 1 // no metatable
	}
	aux_getmetafield(L, 1, "__metatable") // protected view if present
	return 1
}

base_setmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tt := kernel.api_type(L, 2)
	aux_checktype(L, 1, kernel.TTABLE)
	aux_argexpected(L, tt == kernel.TNIL || tt == kernel.TTABLE, 2, "nil or table")
	if aux_getmetafield(L, 1, "__metatable") != kernel.TNIL {
		aux_error(L, "cannot change a protected metatable")
	}
	kernel.api_settop(L, 2)
	kernel.api_setmetatable(L, 1)
	return 1
}

// --------------------------------------------------------------------------------
// collectgarbage
// --------------------------------------------------------------------------------

@(private = "file")
pushmode :: proc(L: ^kernel.State, oldmode: int) -> i32 {
	if oldmode == -1 {
		kernel.api_pushnil(L) // invalid call (inside a finalizer)
	} else {
		kernel.api_pushstring(L, oldmode == kernel.GCINC ? "incremental" : "generational")
	}
	return 1
}

// `collectgarbage([opt [, arg]])` -- reference `luaB_collectgarbage`.
base_collectgarbage :: proc "c" (Lp: rawptr) -> i32 {
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
		kernel.GCSTOP,
		kernel.GCRESTART,
		kernel.GCCOLLECT,
		kernel.GCCOUNT,
		kernel.GCSTEP,
		kernel.GCISRUNNING,
		kernel.GCGEN,
		kernel.GCINC,
		kernel.GCPARAM,
	}
	o := optsnum[aux_checkoption(L, 1, "collect", opts)]
	switch o {
	case kernel.GCCOUNT:
		k := kernel.api_gc(L, o)
		b := kernel.api_gc(L, kernel.GCCOUNTB)
		if k == -1 {
			break
		}
		kernel.api_pushnumber(L, kernel.Number(k) + kernel.Number(b) / 1024)
		return 1
	case kernel.GCSTEP:
		n := aux_optinteger(L, 2, 0)
		res := kernel.api_gc(L, o, int(n))
		if res == -1 {
			break
		}
		kernel.api_pushboolean(L, res != 0)
		return 1
	case kernel.GCISRUNNING:
		res := kernel.api_gc(L, o)
		if res == -1 {
			break
		}
		kernel.api_pushboolean(L, res != 0)
		return 1
	case kernel.GCGEN:
		return pushmode(L, kernel.api_gc(L, o))
	case kernel.GCINC:
		return pushmode(L, kernel.api_gc(L, o))
	case kernel.GCPARAM:
		params := []string{"minormul", "majorminor", "minormajor", "pause", "stepmul", "stepsize"}
		pnum := []int {
			kernel.GCPMINORMUL,
			kernel.GCPMAJORMINOR,
			kernel.GCPMINORMAJOR,
			kernel.GCPPAUSE,
			kernel.GCPSTEPMUL,
			kernel.GCPSTEPSIZE,
		}
		p := pnum[aux_checkoption(L, 2, "", params)]
		value := aux_optinteger(L, 3, -1)
		kernel.api_pushinteger(L, kernel.Integer(kernel.api_gc(L, o, p, int(value))))
		return 1
	case:
		res := kernel.api_gc(L, o)
		if res == -1 {
			break
		}
		kernel.api_pushinteger(L, kernel.Integer(res))
		return 1
	}
	kernel.api_pushnil(L) // invalid call (inside a finalizer)
	return 1
}

// --------------------------------------------------------------------------------
// next / pairs / ipairs
// --------------------------------------------------------------------------------

base_next :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checktype(L, 1, kernel.TTABLE)
	kernel.api_settop(L, 2) // ensure there is a (possibly nil) key argument
	if kernel.api_next(L, 1) {
		return 2
	}
	kernel.api_pushnil(L)
	return 1
}

// `__pairs` continuation: it already produced the four results -- reference
// `pairscont`.
pairscont :: proc "c" (Lp: rawptr, status: i32, ctx: kernel.K_Context) -> i32 {
	return 4
}

// `pairs(t)` -- reference `luaB_pairs`. In 5.5 this yields *four* values (the
// iterator, the state, the initial control, and a to-be-closed slot).
base_pairs :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	if aux_getmetafield(L, 1, "__pairs") == kernel.TNIL {
		kernel.api_pushcfunction(L, base_next) // iterator
		kernel.api_pushvalue(L, 1) // state
		kernel.api_pushnil(L) // initial control value
		kernel.api_pushnil(L) // to-be-closed slot
	} else {
		kernel.api_pushvalue(L, 1) // self
		kernel.api_callk(L, 1, 4, 0, pairscont) // __pairs returns four values
	}
	return 4
}

// The stateless iterator behind `ipairs` -- reference `ipairsaux`.
ipairsaux :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	i := aux_checkinteger(L, 2) + 1
	kernel.api_pushinteger(L, i)
	return kernel.api_geti(L, 1, i) == kernel.TNIL ? 1 : 2
}

// `ipairs(t)` -- reference `luaB_ipairs`. Returns (iterator, t, 0).
base_ipairs :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	kernel.api_pushcfunction(L, ipairsaux)
	kernel.api_pushvalue(L, 1)
	kernel.api_pushinteger(L, 0)
	return 3
}

// --------------------------------------------------------------------------------
// load / loadfile / dofile
// --------------------------------------------------------------------------------

// Shared tail for `load`/`loadfile`: on success optionally install the `env`
// upvalue; on error return `fail, message` -- reference `load_aux`.
@(private = "file")
load_aux :: proc(L: ^kernel.State, status: kernel.Thread_Status, envidx: int) -> i32 {
	if status == .Ok {
		if envidx != 0 {
			kernel.api_pushvalue(L, envidx)
			if _, ok := kernel.api_setupvalue(L, -2, 1); !ok {
				kernel.api_pop(L, 1) // env unused by the chunk: drop it
			}
		}
		return 1
	}
	kernel.api_pushnil(L) // fail
	kernel.api_insert(L, -2) // put it before the error message
	return 2
}

// Validate and return a load mode, rejecting the fixed-buffer 'B' flag from Lua --
// reference `getMode`.
@(private = "file")
getMode :: proc(L: ^kernel.State, idx: int) -> string {
	mode := aux_optstring(L, idx, "bt")
	for c in transmute([]u8)mode {
		if c == 'B' {
			aux_argerror(L, idx, "invalid mode")
		}
	}
	return mode
}

base_loadfile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fname := aux_optstring(L, 1, "")
	mode := getMode(L, 2)
	env := !kernel.api_isnone(L, 3) ? 3 : 0
	status := aux_loadfilex(L, fname, mode)
	return load_aux(L, status, env)
}

// Reader slot: a reserved stack index that holds the last chunk piece so the GC
// cannot collect it mid-parse -- reference `RESERVEDSLOT`.
@(private = "file")
RESERVEDSLOT :: 5

// Reader for `load(f)` where `f` is a function -- reference `generic_reader`.
generic_reader :: proc "c" (L: ^kernel.State, ud: rawptr, size: ^uint) -> [^]u8 {
	context = runtime.default_context()
	aux_checkstack(L, 2, "too many nested functions")
	kernel.api_pushvalue(L, 1) // the reader function
	kernel.api_call(L, 0, 1) // call it for the next piece
	if kernel.api_isnil(L, -1) {
		kernel.api_pop(L, 1)
		size^ = 0
		return nil // end of input
	}
	if !kernel.api_isstring(L, -1) {
		aux_error(L, "reader function must return a string")
	}
	kernel.api_replace(L, RESERVEDSLOT) // park it in the reserved slot
	s, _ := kernel.api_tolstring(L, RESERVEDSLOT)
	size^ = uint(len(s))
	return ([^]u8)(raw_data(s))
}

base_load :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	mode := getMode(L, 3)
	env := !kernel.api_isnone(L, 4) ? 4 : 0
	status: kernel.Thread_Status
	if s, ok := kernel.api_tolstring(L, 1); ok {
		// Loading from a string.
		chunkname := aux_optstring(L, 2, s)
		status = aux_loadbufferx(L, transmute([]u8)s, chunkname, mode)
	} else {
		// Loading from a reader function.
		chunkname := aux_optstring(L, 2, "=(load)")
		aux_checktype(L, 1, kernel.TFUNCTION)
		kernel.api_settop(L, RESERVEDSLOT) // create the reserved slot
		status = kernel.api_load(L, generic_reader, nil, chunkname, mode)
	}
	return load_aux(L, status, env)
}

// `dofile` continuation: return every result the chunk produced -- reference
// `dofilecont`.
dofilecont :: proc "c" (Lp: rawptr, status: i32, ctx: kernel.K_Context) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return i32(kernel.api_gettop(L) - 1)
}

base_dofile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fname := aux_optstring(L, 1, "")
	kernel.api_settop(L, 1)
	if aux_loadfilex(L, fname, "") != .Ok {
		kernel.api_error(L)
	}
	kernel.api_callk(L, 0, kernel.MULTRET, 0, dofilecont)
	return dofilecont(Lp, 0, 0)
}

// --------------------------------------------------------------------------------
// pcall / xpcall
// --------------------------------------------------------------------------------

// Shared continuation/tail for `pcall`/`xpcall` -- reference `finishpcall`. `extra`
// counts leading stack values to skip when returning results.
finishpcall :: proc "c" (Lp: rawptr, status: i32, extra: kernel.K_Context) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st := kernel.Thread_Status(status)
	if st != .Ok && st != .Yield {
		kernel.api_pushboolean(L, false) // first result: false
		kernel.api_pushvalue(L, -2) // the error message
		return 2
	}
	return i32(kernel.api_gettop(L) - int(extra))
}

base_pcall :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	kernel.api_pushboolean(L, true) // success sentinel, prepended
	kernel.api_insert(L, 1)
	status := kernel.api_pcallk(L, kernel.api_gettop(L) - 2, kernel.MULTRET, 0, 0, finishpcall)
	return finishpcall(Lp, i32(status), 0)
}

base_xpcall :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := kernel.api_gettop(L)
	aux_checktype(L, 2, kernel.TFUNCTION) // the message handler
	kernel.api_pushboolean(L, true)
	kernel.api_pushvalue(L, 1) // the function to call
	kernel.api_rotate(L, 3, 2) // move sentinel+function below the arguments
	status := kernel.api_pcallk(L, n - 2, kernel.MULTRET, 2, 2, finishpcall)
	return finishpcall(Lp, i32(status), 2)
}

// --------------------------------------------------------------------------------
// Registration
// --------------------------------------------------------------------------------

// The base-library registration table -- reference `base_funcs`. `_G`/`_VERSION`
// are placeholders (nil func) filled in by `luaopen_base`.
@(private = "file")
base_funcs := []Reg {
	{"assert", base_assert},
	{"collectgarbage", base_collectgarbage},
	{"dofile", base_dofile},
	{"error", base_error},
	{"getmetatable", base_getmetatable},
	{"ipairs", base_ipairs},
	{"loadfile", base_loadfile},
	{"load", base_load},
	{"next", base_next},
	{"pairs", base_pairs},
	{"pcall", base_pcall},
	{"print", base_print},
	{"warn", base_warn},
	{"rawequal", base_rawequal},
	{"rawlen", base_rawlen},
	{"rawget", base_rawget},
	{"rawset", base_rawset},
	{"select", base_select},
	{"setmetatable", base_setmetatable},
	{"tonumber", base_tonumber},
	{"tostring", base_tostring},
	{"type", base_type},
	{"xpcall", base_xpcall},
}

// Open the basic library into the global table, wiring `_G` and `_VERSION` --
// reference `luaopen_base`.
open_base :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	kernel.api_pushglobaltable(L)
	aux_setfuncs(L, base_funcs, 0)
	kernel.api_pushvalue(L, -1)
	kernel.api_setfield(L, -2, G_NAME) // _G._G = _G
	kernel.api_pushstring(L, kernel.VERSION)
	kernel.api_setfield(L, -2, "_VERSION")
	return 1
}
