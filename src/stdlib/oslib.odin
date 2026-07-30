package stdlib

// oslib.odin -- our analogue of reference Lua's `loslib.c`.
//
// The operating-system library: clock/date/time/difftime, environment access,
// file remove/rename, execute/exit, tmpname, and setlocale. It is a thin wrapper
// over the C standard library exactly as reference Lua is -- we call the same
// libc entry points (time/clock/strftime/mktime/gmtime/localtime/getenv/system/
// remove/rename/setlocale/exit) through `core:c/libc`, so the observable results
// match the host platform's C runtime byte for byte, which is the whole point of
// this library. We model time as a lua_Integer (reference's default LUA_NUMTIME
// off), so the "cannot be represented" overflow guards collapse to the mktime
// sentinel check, just as they do in a 64-bit reference build.

import "base:runtime"
import "core:c/libc"
import lua "luao:lua"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// Turn a Lua-owned string into a C string. Lua strings always carry a trailing
// NUL in their backing storage (see string.odin's createstrobj), and Odin string
// literals are NUL-terminated too, so this is a safe zero-copy view for any string
// that came from luaL_check*/opt* or a literal default.
@(private = "file")
cstr :: #force_inline proc "contextless" (s: string) -> cstring {
	return cstring(raw_data(s))
}

// The set of strftime conversion specifiers we accept, grouped by length with a
// "||" marker before the two-character group -- reference LUA_STRFTIMEOPTIONS.
// Picking the right set per platform keeps us faithful to the host's strftime.
@(private = "file")
STRFTIME_OPTIONS :: (
	"aAbBcdHIjmMpSUwWxXyYzZ%||#c#x#d#H#I#j#m#M#S#U#w#W#y#Y" when ODIN_OS == .Windows else "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%||EcECExEXEyEYOdOeOHOIOmOMOSOuOUOVOwOWOy" \
)

// Largest string a single strftime specifier may expand to -- reference SIZETIMEFMT.
@(private = "file")
SIZETIMEFMT :: 250

// os.execute([cmd]) -> run a shell command, or report whether a shell exists.
@(private = "file")
os_execute :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	has_cmd := !lua.lua_isnoneornil(L, 1)
	libc.errno()^ = 0
	if has_cmd {
		cmd := luaL_checkstring(L, 1)
		return luaL_execresult(L, i32(libc.system(cstr(cmd))))
	}
	// No command: system(NULL) is nonzero iff a command processor is available.
	lua.lua_pushboolean(L, libc.system(nil) != 0)
	return 1
}

// os.remove(filename) -> delete a file, reporting success or an errno message.
@(private = "file")
os_remove :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	filename := luaL_checkstring(L, 1)
	libc.errno()^ = 0
	return luaL_fileresult(L, libc.remove(cstr(filename)) == 0, filename, true)
}

// os.rename(from, to) -> rename a file, reporting success or an errno message.
@(private = "file")
os_rename :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fromname := luaL_checkstring(L, 1)
	toname := luaL_checkstring(L, 2)
	libc.errno()^ = 0
	return luaL_fileresult(L, libc.rename(cstr(fromname), cstr(toname)) == 0, "", false)
}

// os.tmpname() -> a name safe to use for a temporary file.
@(private = "file")
os_tmpname :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	buff: [128]u8 // comfortably larger than L_tmpnam on every target
	r := libc.tmpnam(([^]libc.char)(&buff[0]))
	if r == nil {
		luaL_error(L, "unable to generate a unique filename")
	}
	lua.lua_pushstring(L, string(cstring(&buff[0])))
	return 1
}

// os.getenv(name) -> the environment variable's value, or nil if unset.
@(private = "file")
os_getenv :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	v := libc.getenv(cstr(name))
	if v == nil {
		lua.lua_pushnil(L) // reference pushes nil when getenv returns NULL
	} else {
		lua.lua_pushstring(L, string(v))
	}
	return 1
}

// os.clock() -> CPU time used by the program, in seconds.
@(private = "file")
os_clock :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(f64(libc.clock()) / f64(libc.CLOCKS_PER_SEC)))
	return 1
}

// --------------------------------------------------------------------------------
// Time/date helpers
// --------------------------------------------------------------------------------

// Push `value + delta` under `key` into the table on top of the stack. With an
// integer time representation and a 64-bit lua_Integer no field can overflow, so
// the reference's guarded add reduces to a plain add. Reference `setfield`.
@(private = "file")
setfield :: proc(L: ^lua.Lua_State, key: string, value: int, delta: int) {
	lua.lua_pushinteger(L, lua.Integer(value) + lua.Integer(delta))
	lua.lua_setfield(L, -2, key)
}

// Push a boolean field, but skip it entirely for the "undefined" (-1) case, which
// is how a struct tm signals it doesn't know about DST. Reference `setboolfield`.
@(private = "file")
setboolfield :: proc(L: ^lua.Lua_State, key: string, value: int) {
	if value < 0 {
		return
	}
	lua.lua_pushboolean(L, value != 0)
	lua.lua_setfield(L, -2, key)
}

// Populate every date field of the table on top of the stack from a struct tm.
// The +1900/+1/+1 deltas convert C's tm conventions to Lua's. Reference
// `setallfields`.
@(private = "file")
setallfields :: proc(L: ^lua.Lua_State, stm: ^libc.tm) {
	setfield(L, "year", int(stm.tm_year), 1900)
	setfield(L, "month", int(stm.tm_mon), 1)
	setfield(L, "day", int(stm.tm_mday), 0)
	setfield(L, "hour", int(stm.tm_hour), 0)
	setfield(L, "min", int(stm.tm_min), 0)
	setfield(L, "sec", int(stm.tm_sec), 0)
	setfield(L, "yday", int(stm.tm_yday), 1)
	setfield(L, "wday", int(stm.tm_wday), 1)
	setboolfield(L, "isdst", int(stm.tm_isdst))
}

// Read a boolean field from the table at the top of the stack, returning -1 when
// it is absent. Reference `getboolfield`.
@(private = "file")
getboolfield :: proc(L: ^lua.Lua_State, key: string) -> int {
	res: int
	if lua.lua_getfield(L, -1, key) == lua.LUA_TNIL {
		res = -1
	} else {
		res = lua.lua_toboolean(L, -1) ? 1 : 0
	}
	lua.lua_pop(L, 1)
	return res
}

// Read an integer field, applying the `delta` (tm-vs-Lua convention offset) and
// bounds-checking against the C `int` range. `d < 0` marks a mandatory field.
// Reference `getfield`.
@(private = "file")
getfield :: proc(L: ^lua.Lua_State, key: string, d: int, delta: int) -> int {
	tp := lua.lua_getfield(L, -1, key)
	res, isnum := lua.lua_tointegerx(L, -1)
	if !isnum {
		if tp != lua.LUA_TNIL {
			luaL_error(L, "field '%s' is not an integer", key)
		} else if d < 0 {
			luaL_error(L, "field '%s' missing in date table", key)
		}
		res = lua.Integer(d)
	} else {
		// A struct tm field is a C int; reject values that won't fit after delta.
		ok := res >= 0 ? (res - lua.Integer(delta) <= lua.Integer(max(i32))) : (lua.Integer(min(i32)) + lua.Integer(delta) <= res)
		if !ok {
			luaL_error(L, "field '%s' is out-of-bound", key)
		}
		res -= lua.Integer(delta)
	}
	lua.lua_pop(L, 1)
	return int(res)
}

// Match the strftime specifier at the front of `conv` against the option list,
// copy it (with its leading '%') into `buff`, and return how many source bytes it
// consumed. Raises an argument error on an unknown specifier. Reference
// `checkoption`. The "||" marker in the option list bumps the compared length to
// two, so single- and two-character specifiers share one scan.
@(private = "file")
checkoption :: proc(L: ^lua.Lua_State, conv: []u8, buff: []u8) -> int {
	option := STRFTIME_OPTIONS
	oplen := 1 // length of the options currently being compared
	oi := 0
	for oi < len(option) && oplen <= len(conv) {
		if option[oi] == '|' {
			oplen += 1 // next block holds longer options
		} else if oi + oplen <= len(option) && string(conv[:oplen]) == option[oi:oi + oplen] {
			copy(buff[1:], conv[:oplen]) // buff[0] is already '%'
			buff[1 + oplen] = 0 // terminate for strftime
			return oplen
		}
		oi += oplen
	}
	luaL_argerror(
		L,
		1,
		lua.lua_pushfstring(L, "invalid conversion specifier '%%%s'", string(conv)),
	)
}

// Fetch and range-check a time argument. Reference `l_checktime` (integer time:
// the (time_t)t == t identity always holds for a 64-bit lua_Integer).
@(private = "file")
l_checktime :: proc(L: ^lua.Lua_State, arg: int) -> libc.time_t {
	return libc.time_t(luaL_checkinteger(L, arg))
}

// os.date([format [, time]]) -> a formatted date string, or a "*t" table.
@(private = "file")
os_date :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)luaL_optlstring(L, 1, "%c")
	t: libc.time_t
	if lua.lua_isnoneornil(L, 2) {
		t = libc.time(nil)
	} else {
		t = l_checktime(L, 2)
	}
	si := 0
	utc := false
	if len(s) > 0 && s[0] == '!' { // leading '!' means UTC
		utc = true
		si = 1
	}
	stm := utc ? libc.gmtime(&t) : libc.localtime(&t)
	if stm == nil {
		luaL_error(L, "date result cannot be represented in this installation")
	}
	rest := s[si:]
	if string(rest) == "*t" {
		lua.lua_createtable(L, 0, 9) // 9 date fields
		setallfields(L, stm)
	} else {
		b: Buffer
		luaL_buffinit(L, &b)
		i := 0
		for i < len(rest) {
			if rest[i] != '%' {
				luaL_addchar(&b, rest[i])
				i += 1
			} else {
				i += 1 // skip '%'
				cc: [4]u8
				cc[0] = '%'
				oplen := checkoption(L, rest[i:], cc[:])
				i += oplen
				buff := luaL_prepbuffsize(&b, SIZETIMEFMT)
				reslen := libc.strftime(([^]libc.char)(buff), SIZETIMEFMT, cstring(&cc[0]), stm)
				luaL_addsize(&b, uint(reslen))
			}
		}
		luaL_pushresult(&b)
	}
	return 1
}

// os.time([table]) -> the current time, or the time described by a date table.
@(private = "file")
os_time :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	t: libc.time_t
	if lua.lua_isnoneornil(L, 1) {
		t = libc.time(nil)
	} else {
		luaL_checktype(L, 1, lua.LUA_TTABLE)
		lua.lua_settop(L, 1) // keep the table at the top for the getfield helpers
		ts: libc.tm
		ts.tm_year = type_of(ts.tm_year)(getfield(L, "year", -1, 1900))
		ts.tm_mon = type_of(ts.tm_mon)(getfield(L, "month", -1, 1))
		ts.tm_mday = type_of(ts.tm_mday)(getfield(L, "day", -1, 0))
		ts.tm_hour = type_of(ts.tm_hour)(getfield(L, "hour", 12, 0))
		ts.tm_min = type_of(ts.tm_min)(getfield(L, "min", 0, 0))
		ts.tm_sec = type_of(ts.tm_sec)(getfield(L, "sec", 0, 0))
		ts.tm_isdst = type_of(ts.tm_isdst)(getboolfield(L, "isdst"))
		t = libc.mktime(&ts)
		setallfields(L, &ts) // write back the normalized fields
	}
	// With integer time the "cannot be represented" test reduces to the mktime
	// failure sentinel.
	if t == libc.time_t(-1) {
		luaL_error(L, "time result cannot be represented in this installation")
	}
	lua.lua_pushinteger(L, lua.Integer(t))
	return 1
}

// os.difftime(t2, t1) -> the difference, in seconds, between two times.
@(private = "file")
os_difftime :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	t1 := l_checktime(L, 1)
	t2 := l_checktime(L, 2)
	lua.lua_pushnumber(L, lua.Number(libc.difftime(t1, t2)))
	return 1
}

@(private = "file")
locale_cats := [6]libc.Locale_Category {
	.ALL,
	.COLLATE,
	.CTYPE,
	.MONETARY,
	.NUMERIC,
	.TIME,
}

@(private = "file")
locale_names := []string{"all", "collate", "ctype", "monetary", "numeric", "time"}

// os.setlocale([locale [, category]]) -> configure/query the C locale.
@(private = "file")
os_setlocale :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	op := luaL_checkoption(L, 2, "all", locale_names)
	if !lua.lua_isnoneornil(L, 1) && (op == 0 || op == 4) {
		requested := luaL_checkstring(L, 1)
		// Numeric conversion is freestanding and deliberately fixed to the C
		// locale. Do not claim that a different LC_NUMERIC took effect while
		// tonumber and numeric rendering continue to use '.', as that would
		// expose an internally inconsistent locale to Lua code.
		if requested != "C" && requested != "POSIX" {
			lua.lua_pushnil(L)
			return 1
		}
	}
	// A missing/nil locale means "query", which maps to a NULL argument.
	loc: cstring = nil
	if !lua.lua_isnoneornil(L, 1) {
		loc = cstr(luaL_checkstring(L, 1))
	}
	r := libc.setlocale(locale_cats[op], loc)
	if r == nil {
		lua.lua_pushnil(L)
	} else {
		lua.lua_pushstring(L, string(r))
	}
	return 1
}

// os.exit([code [, close]]) -> terminate the process (optionally closing the state
// first so finalizers run).
@(private = "file")
os_exit :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	status: int
	if lua.lua_isboolean(L, 1) {
		status = lua.lua_toboolean(L, 1) ? libc.EXIT_SUCCESS : libc.EXIT_FAILURE
	} else {
		status = int(luaL_optinteger(L, 1, lua.Integer(libc.EXIT_SUCCESS)))
	}
	if lua.lua_toboolean(L, 2) {
		lua.close_state(L) // run __gc finalizers and release the state
	}
	libc.exit(i32(status))
}

@(private = "file")
syslib := []Reg {
	{"clock", os_clock},
	{"date", os_date},
	{"difftime", os_difftime},
	{"execute", os_execute},
	{"exit", os_exit},
	{"getenv", os_getenv},
	{"remove", os_remove},
	{"rename", os_rename},
	{"setlocale", os_setlocale},
	{"time", os_time},
	{"tmpname", os_tmpname},
}

// `luaopen_os` -- build and return the os table.
luaopen_os :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_newlib(L, syslib)
	return 1
}
