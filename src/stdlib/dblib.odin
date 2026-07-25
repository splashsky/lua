package stdlib

// dblib.odin -- our analogue of reference Lua's `ldblib.c`.
//
// The debug library: getinfo/getlocal/setlocal/getupvalue/setupvalue/upvalueid/
// upvaluejoin, get/set metatable and uservalue and registry access, an interactive
// debug prompt, traceback, and the hook controls (sethook/gethook). This library
// is the toughest test of our public API boundary -- it is written purely against
// the debug-API surface the kernel exposes (lua_getstack/getinfo/getlocal/...),
// never reaching into kernel internals.

import "base:runtime"
import "core:c/libc"
import lua "luao:lua"

// The registry key under which per-thread hook functions are stored -- reference
// HOOKKEY. It maps each thread to the Lua hook function set for it.
@(private = "file")
HOOKKEY :: "_HOOKKEY"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// Render a Lua_Debug's short_src (a fixed NUL-terminated byte array) as a string.
@(private = "file")
short_src :: proc(ar: ^lua.Lua_Debug) -> string {
	return string(cstring(&ar.short_src[0]))
}

// True if option character `c` appears in the option string `s`.
@(private = "file")
has_opt :: proc(s: string, c: u8) -> bool {
	for b in transmute([]u8)s {
		if b == c {
			return true
		}
	}
	return false
}

// If L1 differs from L we cannot assume it has stack space; guard any push into it
// -- reference `checkstack`.
@(private = "file")
checkstack :: proc(L: ^lua.Lua_State, L1: ^lua.Lua_State, n: int) {
	if L != L1 && !lua.lua_checkstack(L1, n) {
		luaL_error(L, "stack overflow")
	}
}

// Optional leading thread argument. Returns the thread to operate on and the arg
// offset (1 if a thread was consumed, else 0) -- reference `getthread`.
@(private = "file")
getthread :: proc(L: ^lua.Lua_State) -> (^lua.Lua_State, int) {
	if lua.lua_type(L, 1) == lua.LUA_TTHREAD {
		return lua.lua_tothread(L, 1), 1
	}
	return L, 0
}

// --------------------------------------------------------------------------------
// registry / metatable / uservalue accessors
// --------------------------------------------------------------------------------

@(private = "file")
db_getregistry :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushvalue(L, lua.LUA_REGISTRYINDEX)
	return 1
}

@(private = "file")
db_getmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 1)
	if !lua.lua_getmetatable(L, 1) {
		lua.lua_pushnil(L) // no metatable
	}
	return 1
}

@(private = "file")
db_setmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	t := lua.lua_type(L, 2)
	luaL_argexpected(L, t == lua.LUA_TNIL || t == lua.LUA_TTABLE, 2, "nil or table")
	lua.lua_settop(L, 2)
	lua.lua_setmetatable(L, 1)
	return 1 // return the first argument
}

@(private = "file")
db_getuservalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := int(luaL_optinteger(L, 2, 1))
	if lua.lua_type(L, 1) != lua.LUA_TUSERDATA {
		luaL_pushfail(L)
	} else if lua.lua_getiuservalue(L, 1, n) != lua.LUA_TNONE {
		lua.lua_pushboolean(L, true)
		return 2
	}
	return 1
}

@(private = "file")
db_setuservalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := int(luaL_optinteger(L, 3, 1))
	luaL_checktype(L, 1, lua.LUA_TUSERDATA)
	luaL_checkany(L, 2)
	lua.lua_settop(L, 2)
	if !lua.lua_setiuservalue(L, 1, n) {
		luaL_pushfail(L)
	}
	return 1
}

// --------------------------------------------------------------------------------
// getinfo
// --------------------------------------------------------------------------------

// Small table-population helpers used by db_getinfo -- reference settabss/i/b.
@(private = "file")
settabss :: proc(L: ^lua.Lua_State, k: string, v: string) {
	lua.lua_pushstring(L, v)
	lua.lua_setfield(L, -2, k)
}

@(private = "file")
settabsi :: proc(L: ^lua.Lua_State, k: string, v: int) {
	lua.lua_pushinteger(L, lua.Integer(v))
	lua.lua_setfield(L, -2, k)
}

@(private = "file")
settabsb :: proc(L: ^lua.Lua_State, k: string, v: bool) {
	lua.lua_pushboolean(L, v)
	lua.lua_setfield(L, -2, k)
}

// Move a stack result produced by lua_getinfo (on L1) onto the result table (on L)
// under key `fname` -- reference `treatstackoption`.
@(private = "file")
treatstackoption :: proc(L: ^lua.Lua_State, L1: ^lua.Lua_State, fname: string) {
	if L == L1 {
		lua.lua_rotate(L, -2, 1) // swap object and table
	} else {
		lua.lua_xmove(L1, L, 1) // move object to the main stack
	}
	lua.lua_setfield(L, -2, fname)
}

@(private = "file")
db_getinfo :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	ar: lua.Lua_Debug
	L1, arg := getthread(L)
	options := luaL_optstring(L, arg + 2, "flnSrtu")
	checkstack(L, L1, 3)
	luaL_argcheck(L, len(options) == 0 || options[0] != '>', arg + 2, "invalid option '>'")
	if lua.lua_isfunction(L, arg + 1) { // info about a function value?
		options = lua.lua_pushfstring(L, ">%s", options) // prefix '>'
		lua.lua_pushvalue(L, arg + 1)
		lua.lua_xmove(L, L1, 1) // move the function to L1's stack
	} else { // info about a stack level
		if !lua.lua_getstack(L1, int(luaL_checkinteger(L, arg + 1)), &ar) {
			luaL_pushfail(L) // level out of range
			return 1
		}
	}
	if !lua.lua_getinfo(L1, options, &ar) {
		luaL_argerror(L, arg + 2, "invalid option")
	}
	lua.lua_newtable(L) // result table
	if has_opt(options, 'S') {
		lua.lua_pushlstring(L, transmute([]u8)ar.source)
		lua.lua_setfield(L, -2, "source")
		settabss(L, "short_src", short_src(&ar))
		settabsi(L, "linedefined", int(ar.linedefined))
		settabsi(L, "lastlinedefined", int(ar.lastlinedefined))
		settabss(L, "what", ar.what)
	}
	if has_opt(options, 'l') {
		settabsi(L, "currentline", int(ar.currentline))
	}
	if has_opt(options, 'u') {
		settabsi(L, "nups", int(ar.nups))
		settabsi(L, "nparams", int(ar.nparams))
		settabsb(L, "isvararg", ar.isvararg != 0)
	}
	if has_opt(options, 'n') {
		settabss(L, "name", ar.name)
		settabss(L, "namewhat", ar.namewhat)
	}
	if has_opt(options, 'r') {
		settabsi(L, "ftransfer", int(ar.ftransfer))
		settabsi(L, "ntransfer", int(ar.ntransfer))
	}
	if has_opt(options, 't') {
		settabsb(L, "istailcall", ar.istailcall != 0)
		settabsi(L, "extraargs", int(ar.extraargs))
	}
	if has_opt(options, 'L') {
		treatstackoption(L, L1, "activelines")
	}
	if has_opt(options, 'f') {
		treatstackoption(L, L1, "func")
	}
	return 1 // return the table
}

// --------------------------------------------------------------------------------
// locals and upvalues
// --------------------------------------------------------------------------------

@(private = "file")
db_getlocal :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	nvar := int(luaL_checkinteger(L, arg + 2)) // local-variable index
	if lua.lua_isfunction(L, arg + 1) { // function argument: names only
		lua.lua_pushvalue(L, arg + 1)
		name, ok := lua.lua_getlocal(L, nil, nvar)
		if ok {
			lua.lua_pushstring(L, name)
		} else {
			lua.lua_pushnil(L)
		}
		return 1 // just the name (there is no value)
	}
	// stack-level argument
	ar: lua.Lua_Debug
	level := int(luaL_checkinteger(L, arg + 1))
	if !lua.lua_getstack(L1, level, &ar) {
		luaL_argerror(L, arg + 1, "level out of range")
	}
	checkstack(L, L1, 1)
	name, ok := lua.lua_getlocal(L1, &ar, nvar)
	if ok {
		lua.lua_xmove(L1, L, 1) // move the local's value across
		lua.lua_pushstring(L, name)
		lua.lua_rotate(L, -2, 1) // re-order to (name, value)
		return 2
	}
	luaL_pushfail(L) // no such local
	return 1
}

@(private = "file")
db_setlocal :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	ar: lua.Lua_Debug
	level := int(luaL_checkinteger(L, arg + 1))
	nvar := int(luaL_checkinteger(L, arg + 2))
	if !lua.lua_getstack(L1, level, &ar) {
		luaL_argerror(L, arg + 1, "level out of range")
	}
	luaL_checkany(L, arg + 3)
	lua.lua_settop(L, arg + 3)
	checkstack(L, L1, 1)
	lua.lua_xmove(L, L1, 1)
	name, ok := lua.lua_setlocal(L1, &ar, nvar)
	if !ok {
		lua.lua_pop(L1, 1) // pop the value lua_setlocal didn't consume
	}
	if ok {
		lua.lua_pushstring(L, name)
	} else {
		lua.lua_pushnil(L)
	}
	return 1
}

// Shared get/set of an upvalue -- reference `auxupvalue`. `get` selects reading or
// writing; on a read it returns (name, value), on a write just (name).
@(private = "file")
auxupvalue :: proc(L: ^lua.Lua_State, get: bool) -> i32 {
	n := int(luaL_checkinteger(L, 2)) // upvalue index
	luaL_checktype(L, 1, lua.LUA_TFUNCTION)
	name: string
	ok: bool
	if get {
		name, ok = lua.lua_getupvalue(L, 1, n)
	} else {
		name, ok = lua.lua_setupvalue(L, 1, n)
	}
	if !ok {
		return 0
	}
	lua.lua_pushstring(L, name)
	// For a read the stack holds (value, name); move the name below the value. For
	// a write there is no value, so this insert is a no-op position.
	lua.lua_insert(L, get ? -2 : -1)
	return get ? 2 : 1
}

@(private = "file")
db_getupvalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return auxupvalue(L, true)
}

@(private = "file")
db_setupvalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_checkany(L, 3)
	return auxupvalue(L, false)
}

// Validate that closure `argf` has upvalue `argnup` and return its identity --
// reference `checkupval`. When `pnup` is provided the index is also validated and
// written back.
@(private = "file")
checkupval :: proc(L: ^lua.Lua_State, argf: int, argnup: int, pnup: ^int) -> rawptr {
	nup := int(luaL_checkinteger(L, argnup)) // upvalue index
	luaL_checktype(L, argf, lua.LUA_TFUNCTION)
	id := lua.lua_upvalueid(L, argf, nup)
	if pnup != nil {
		luaL_argcheck(L, id != nil, argnup, "invalid upvalue index")
		pnup^ = nup
	}
	return id
}

@(private = "file")
db_upvalueid :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	id := checkupval(L, 1, 2, nil)
	if id != nil {
		lua.lua_pushlightuserdata(L, id)
	} else {
		luaL_pushfail(L)
	}
	return 1
}

@(private = "file")
db_upvaluejoin :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n1: int
	n2: int
	checkupval(L, 1, 2, &n1)
	checkupval(L, 3, 4, &n2)
	luaL_argcheck(L, !lua.lua_iscfunction(L, 1), 1, "Lua function expected")
	luaL_argcheck(L, !lua.lua_iscfunction(L, 3), 3, "Lua function expected")
	lua.lua_upvaluejoin(L, 1, n1, 3, n2)
	return 0
}

// --------------------------------------------------------------------------------
// hooks
// --------------------------------------------------------------------------------

@(private = "file")
hooknames := [5]string{"call", "return", "line", "count", "tail call"}

// The C hook that dispatches to the Lua hook registered for the current thread --
// reference `hookf`. Its signature matches lua.Hook_Proc.
@(private = "file")
hookf :: proc "c" (Lp: rawptr, arp: rawptr) {
	context = runtime.default_context()
	L := state(Lp)
	ar := (^lua.Lua_Debug)(arp)
	lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, HOOKKEY)
	lua.lua_pushthread(L)
	if lua.lua_rawget(L, -2) == lua.LUA_TFUNCTION { // is there a hook function?
		lua.lua_pushstring(L, hooknames[int(ar.event)]) // event name
		if ar.currentline >= 0 {
			lua.lua_pushinteger(L, lua.Integer(ar.currentline))
		} else {
			lua.lua_pushnil(L)
		}
		lua.lua_getinfo(L, "lS", ar)
		lua.lua_call(L, 2, 0) // call the hook function
	}
}

// Turn a string mask ("crl") plus a count into a bit mask -- reference `makemask`.
@(private = "file")
makemask :: proc(smask: string, count: int) -> i32 {
	mask: i32 = 0
	if has_opt(smask, 'c') {
		mask |= lua.LUA_MASKCALL
	}
	if has_opt(smask, 'r') {
		mask |= lua.LUA_MASKRET
	}
	if has_opt(smask, 'l') {
		mask |= lua.LUA_MASKLINE
	}
	if count > 0 {
		mask |= lua.LUA_MASKCOUNT
	}
	return mask
}

// Turn a bit mask back into its string form, written into `buff` -- reference
// `unmakemask`. Returns the populated slice as a string.
@(private = "file")
unmakemask :: proc(mask: i32, buff: []u8) -> string {
	i := 0
	if mask & lua.LUA_MASKCALL != 0 {
		buff[i] = 'c';i += 1
	}
	if mask & lua.LUA_MASKRET != 0 {
		buff[i] = 'r';i += 1
	}
	if mask & lua.LUA_MASKLINE != 0 {
		buff[i] = 'l';i += 1
	}
	return string(buff[:i])
}

@(private = "file")
db_sethook :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	func: lua.Hook_Proc
	mask: i32
	count: int
	if lua.lua_isnoneornil(L, arg + 1) { // no hook: turn hooks off
		lua.lua_settop(L, arg + 1)
		func = nil
		mask = 0
		count = 0
	} else {
		smask := luaL_checkstring(L, arg + 2)
		luaL_checktype(L, arg + 1, lua.LUA_TFUNCTION)
		count = int(luaL_optinteger(L, arg + 3, 0))
		func = hookf
		mask = makemask(smask, count)
	}
	if !luaL_getsubtable(L, lua.LUA_REGISTRYINDEX, HOOKKEY) {
		// Table freshly created: make it weak-keyed and self-metatabled so dead
		// threads don't keep their hook functions alive.
		lua.lua_pushstring(L, "k")
		lua.lua_setfield(L, -2, "__mode") // hooktable.__mode = "k"
		lua.lua_pushvalue(L, -1)
		lua.lua_setmetatable(L, -2) // metatable(hooktable) = hooktable
	}
	checkstack(L, L1, 1)
	lua.lua_pushthread(L1)
	lua.lua_xmove(L1, L, 1) // key: the thread
	lua.lua_pushvalue(L, arg + 1) // value: the hook function
	lua.lua_rawset(L, -3) // hooktable[L1] = hook
	lua.lua_sethook(L1, func, mask, i32(count))
	return 0
}

@(private = "file")
db_gethook :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, _ := getthread(L)
	buff: [5]u8
	mask := lua.lua_gethookmask(L1)
	hook := lua.lua_gethook(L1)
	if hook == nil {
		luaL_pushfail(L) // no hook
		return 1
	} else if hook != lua.Hook_Proc(hookf) { // an external (non-Lua) hook
		lua.lua_pushstring(L, "external hook")
	} else { // the hook table must exist
		lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, HOOKKEY)
		checkstack(L, L1, 1)
		lua.lua_pushthread(L1)
		lua.lua_xmove(L1, L, 1)
		lua.lua_rawget(L, -2) // 1st result: hooktable[L1]
		lua.lua_remove(L, -2) // drop the hook table
	}
	lua.lua_pushstring(L, unmakemask(mask, buff[:])) // 2nd result: the mask
	lua.lua_pushinteger(L, lua.Integer(lua.lua_gethookcount(L1))) // 3rd: the count
	return 3
}

// --------------------------------------------------------------------------------
// interactive debugger and traceback
// --------------------------------------------------------------------------------

@(private = "file")
db_debug :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	for {
		buffer: [250]u8
		write_stderr("lua_debug> ")
		if libc.fgets(([^]libc.char)(&buffer[0]), len(buffer), libc.stdin) == nil {
			return 0
		}
		line := string(cstring(&buffer[0]))
		if line == "cont\n" {
			return 0
		}
		bytes := transmute([]u8)line
		if luaL_loadbufferx(L, bytes, "=(debug command)", "") != .Ok ||
		   lua.lua_pcall(L, 0, 0, 0) != .Ok {
			write_stderr(luaL_tolstring(L, -1))
			write_stderr("\n")
		}
		lua.lua_settop(L, 0) // discard any results/errors
	}
}

@(private = "file")
db_traceback :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	msg, is_str := lua.lua_tostring(L, arg + 1)
	if !is_str && !lua.lua_isnoneornil(L, arg + 1) { // non-string, non-nil message
		lua.lua_pushvalue(L, arg + 1) // return it untouched
	} else {
		level := int(luaL_optinteger(L, arg + 2, lua.Integer(L == L1 ? 1 : 0)))
		luaL_traceback(L, L1, msg, is_str, level)
	}
	return 1
}

// --------------------------------------------------------------------------------
// registration
// --------------------------------------------------------------------------------

@(private = "file")
dblib := []Reg {
	{"debug", db_debug},
	{"getuservalue", db_getuservalue},
	{"gethook", db_gethook},
	{"getinfo", db_getinfo},
	{"getlocal", db_getlocal},
	{"getregistry", db_getregistry},
	{"getmetatable", db_getmetatable},
	{"getupvalue", db_getupvalue},
	{"upvaluejoin", db_upvaluejoin},
	{"upvalueid", db_upvalueid},
	{"setuservalue", db_setuservalue},
	{"sethook", db_sethook},
	{"setlocal", db_setlocal},
	{"setmetatable", db_setmetatable},
	{"setupvalue", db_setupvalue},
	{"traceback", db_traceback},
}

// `luaopen_debug` -- build and return the debug table.
luaopen_debug :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_newlib(L, dblib)
	return 1
}
