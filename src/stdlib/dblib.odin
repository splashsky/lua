#+build !freestanding

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
import kernel "lang:kernel"
import stream "lang:stream"

// The registry key under which per-thread hook functions are stored -- reference
// HOOKKEY. It maps each thread to the Lua hook function set for it.
@(private = "file")
HOOKKEY :: "_HOOKKEY"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
}

// Render a Lua_Debug's short_src (a fixed NUL-terminated byte array) as a string.
@(private = "file")
short_src :: proc(ar: ^kernel.Debug_Info) -> string {
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
checkstack :: proc(L: ^kernel.State, L1: ^kernel.State, n: int) {
	if L != L1 && !kernel.api_checkstack(L1, n) {
		aux_error(L, "stack overflow")
	}
}

// Optional leading thread argument. Returns the thread to operate on and the arg
// offset (1 if a thread was consumed, else 0) -- reference `getthread`.
@(private = "file")
getthread :: proc(L: ^kernel.State) -> (^kernel.State, int) {
	if kernel.api_type(L, 1) == kernel.TTHREAD {
		return kernel.api_tothread(L, 1), 1
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
	kernel.api_pushvalue(L, kernel.REGISTRYINDEX)
	return 1
}

@(private = "file")
db_getmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	if !kernel.api_getmetatable(L, 1) {
		kernel.api_pushnil(L) // no metatable
	}
	return 1
}

@(private = "file")
db_setmetatable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	t := kernel.api_type(L, 2)
	aux_argexpected(L, t == kernel.TNIL || t == kernel.TTABLE, 2, "nil or table")
	kernel.api_settop(L, 2)
	kernel.api_setmetatable(L, 1)
	return 1 // return the first argument
}

@(private = "file")
db_getuservalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := int(aux_optinteger(L, 2, 1))
	if kernel.api_type(L, 1) != kernel.TUSERDATA {
		aux_pushfail(L)
	} else if kernel.api_getiuservalue(L, 1, n) != kernel.TNONE {
		kernel.api_pushboolean(L, true)
		return 2
	}
	return 1
}

@(private = "file")
db_setuservalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := int(aux_optinteger(L, 3, 1))
	aux_checktype(L, 1, kernel.TUSERDATA)
	aux_checkany(L, 2)
	kernel.api_settop(L, 2)
	if !kernel.api_setiuservalue(L, 1, n) {
		aux_pushfail(L)
	}
	return 1
}

// --------------------------------------------------------------------------------
// getinfo
// --------------------------------------------------------------------------------

// Small table-population helpers used by db_getinfo -- reference settabss/i/b.
@(private = "file")
settabss :: proc(L: ^kernel.State, k: string, v: string) {
	kernel.api_pushstring(L, v)
	kernel.api_setfield(L, -2, k)
}

@(private = "file")
settabsi :: proc(L: ^kernel.State, k: string, v: int) {
	kernel.api_pushinteger(L, kernel.Integer(v))
	kernel.api_setfield(L, -2, k)
}

@(private = "file")
settabsb :: proc(L: ^kernel.State, k: string, v: bool) {
	kernel.api_pushboolean(L, v)
	kernel.api_setfield(L, -2, k)
}

// Move a stack result produced by lua_getinfo (on L1) onto the result table (on L)
// under key `fname` -- reference `treatstackoption`.
@(private = "file")
treatstackoption :: proc(L: ^kernel.State, L1: ^kernel.State, fname: string) {
	if L == L1 {
		kernel.api_rotate(L, -2, 1) // swap object and table
	} else {
		kernel.api_xmove(L1, L, 1) // move object to the main stack
	}
	kernel.api_setfield(L, -2, fname)
}

@(private = "file")
db_getinfo :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	ar: kernel.Debug_Info
	L1, arg := getthread(L)
	options := aux_optstring(L, arg + 2, "flnSrtu")
	checkstack(L, L1, 3)
	aux_argcheck(L, len(options) == 0 || options[0] != '>', arg + 2, "invalid option '>'")
	if kernel.api_isfunction(L, arg + 1) { // info about a function value?
		options = kernel.api_pushfstring(L, ">%s", options) // prefix '>'
		kernel.api_pushvalue(L, arg + 1)
		kernel.api_xmove(L, L1, 1) // move the function to L1's stack
	} else { // info about a stack level
		if !kernel.api_getstack(L1, int(aux_checkinteger(L, arg + 1)), &ar) {
			aux_pushfail(L) // level out of range
			return 1
		}
	}
	if !kernel.api_getinfo(L1, options, &ar) {
		aux_argerror(L, arg + 2, "invalid option")
	}
	kernel.api_newtable(L) // result table
	if has_opt(options, 'S') {
		kernel.api_pushlstring(L, transmute([]u8)ar.source)
		kernel.api_setfield(L, -2, "source")
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
		// Reference stores a NULL `ar.name` (pushed as nil) exactly when no name
		// was found, which is precisely when `namewhat` is empty. A found name
		// may itself be the empty string (e.g. a `t[""]` field), so we key off
		// `namewhat`, not off `name` being empty.
		if ar.namewhat == "" {
			kernel.api_pushnil(L)
			kernel.api_setfield(L, -2, "name")
		} else {
			settabss(L, "name", ar.name)
		}
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
	nvar := int(aux_checkinteger(L, arg + 2)) // local-variable index
	if kernel.api_isfunction(L, arg + 1) { // function argument: names only
		kernel.api_pushvalue(L, arg + 1)
		name, ok := kernel.api_getlocal(L, nil, nvar)
		if ok {
			kernel.api_pushstring(L, name)
		} else {
			kernel.api_pushnil(L)
		}
		return 1 // just the name (there is no value)
	}
	// stack-level argument
	ar: kernel.Debug_Info
	level := int(aux_checkinteger(L, arg + 1))
	if !kernel.api_getstack(L1, level, &ar) {
		aux_argerror(L, arg + 1, "level out of range")
	}
	checkstack(L, L1, 1)
	name, ok := kernel.api_getlocal(L1, &ar, nvar)
	if ok {
		kernel.api_xmove(L1, L, 1) // move the local's value across
		kernel.api_pushstring(L, name)
		kernel.api_rotate(L, -2, 1) // re-order to (name, value)
		return 2
	}
	aux_pushfail(L) // no such local
	return 1
}

@(private = "file")
db_setlocal :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	ar: kernel.Debug_Info
	level := int(aux_checkinteger(L, arg + 1))
	nvar := int(aux_checkinteger(L, arg + 2))
	if !kernel.api_getstack(L1, level, &ar) {
		aux_argerror(L, arg + 1, "level out of range")
	}
	aux_checkany(L, arg + 3)
	kernel.api_settop(L, arg + 3)
	checkstack(L, L1, 1)
	kernel.api_xmove(L, L1, 1)
	name, ok := kernel.api_setlocal(L1, &ar, nvar)
	if !ok {
		kernel.api_pop(L1, 1) // pop the value api_setlocal didn't consume
	}
	if ok {
		kernel.api_pushstring(L, name)
	} else {
		kernel.api_pushnil(L)
	}
	return 1
}

// Shared get/set of an upvalue -- reference `auxupvalue`. `get` selects reading or
// writing; on a read it returns (name, value), on a write just (name).
@(private = "file")
auxupvalue :: proc(L: ^kernel.State, get: bool) -> i32 {
	n := int(aux_checkinteger(L, 2)) // upvalue index
	aux_checktype(L, 1, kernel.TFUNCTION)
	name: string
	ok: bool
	if get {
		name, ok = kernel.api_getupvalue(L, 1, n)
	} else {
		name, ok = kernel.api_setupvalue(L, 1, n)
	}
	if !ok {
		return 0
	}
	kernel.api_pushstring(L, name)
	// For a read the stack holds (value, name); move the name below the value. For
	// a write there is no value, so this insert is a no-op position.
	kernel.api_insert(L, get ? -2 : -1)
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
	aux_checkany(L, 3)
	return auxupvalue(L, false)
}

// Validate that closure `argf` has upvalue `argnup` and return its identity --
// reference `checkupval`. When `pnup` is provided the index is also validated and
// written back.
@(private = "file")
checkupval :: proc(L: ^kernel.State, argf: int, argnup: int, pnup: ^int) -> rawptr {
	nup := int(aux_checkinteger(L, argnup)) // upvalue index
	aux_checktype(L, argf, kernel.TFUNCTION)
	id := kernel.api_upvalueid(L, argf, nup)
	if pnup != nil {
		aux_argcheck(L, id != nil, argnup, "invalid upvalue index")
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
		kernel.api_pushlightuserdata(L, id)
	} else {
		aux_pushfail(L)
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
	aux_argcheck(L, !kernel.api_iscfunction(L, 1), 1, kernel.BRAND + " function expected")
	aux_argcheck(L, !kernel.api_iscfunction(L, 3), 3, kernel.BRAND + " function expected")
	kernel.api_upvaluejoin(L, 1, n1, 3, n2)
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
	ar := (^kernel.Debug_Info)(arp)
	kernel.api_getfield(L, kernel.REGISTRYINDEX, HOOKKEY)
	kernel.api_pushthread(L)
	if kernel.api_rawget(L, -2) == kernel.TFUNCTION { // is there a hook function?
		kernel.api_pushstring(L, hooknames[int(ar.event)]) // event name
		if ar.currentline >= 0 {
			kernel.api_pushinteger(L, kernel.Integer(ar.currentline))
		} else {
			kernel.api_pushnil(L)
		}
		kernel.api_getinfo(L, "lS", ar)
		kernel.api_call(L, 2, 0) // call the hook function
	}
}

// Turn a string mask ("crl") plus a count into a bit mask -- reference `makemask`.
@(private = "file")
makemask :: proc(smask: string, count: int) -> i32 {
	mask: i32 = 0
	if has_opt(smask, 'c') {
		mask |= kernel.MASKCALL
	}
	if has_opt(smask, 'r') {
		mask |= kernel.MASKRET
	}
	if has_opt(smask, 'l') {
		mask |= kernel.MASKLINE
	}
	if count > 0 {
		mask |= kernel.MASKCOUNT
	}
	return mask
}

// Turn a bit mask back into its string form, written into `buff` -- reference
// `unmakemask`. Returns the populated slice as a string.
@(private = "file")
unmakemask :: proc(mask: i32, buff: []u8) -> string {
	i := 0
	if mask & kernel.MASKCALL != 0 {
		buff[i] = 'c';i += 1
	}
	if mask & kernel.MASKRET != 0 {
		buff[i] = 'r';i += 1
	}
	if mask & kernel.MASKLINE != 0 {
		buff[i] = 'l';i += 1
	}
	return string(buff[:i])
}

@(private = "file")
db_sethook :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	func: kernel.Hook_Proc
	mask: i32
	count: int
	if kernel.api_isnoneornil(L, arg + 1) { // no hook: turn hooks off
		kernel.api_settop(L, arg + 1)
		func = nil
		mask = 0
		count = 0
	} else {
		smask := aux_checkstring(L, arg + 2)
		aux_checktype(L, arg + 1, kernel.TFUNCTION)
		count = int(aux_optinteger(L, arg + 3, 0))
		func = hookf
		mask = makemask(smask, count)
	}
	if !aux_getsubtable(L, kernel.REGISTRYINDEX, HOOKKEY) {
		// Table freshly created: make it weak-keyed and self-metatabled so dead
		// threads don't keep their hook functions alive.
		kernel.api_pushstring(L, "k")
		kernel.api_setfield(L, -2, "__mode") // hooktable.__mode = "k"
		kernel.api_pushvalue(L, -1)
		kernel.api_setmetatable(L, -2) // metatable(hooktable) = hooktable
	}
	checkstack(L, L1, 1)
	kernel.api_pushthread(L1)
	kernel.api_xmove(L1, L, 1) // key: the thread
	kernel.api_pushvalue(L, arg + 1) // value: the hook function
	kernel.api_rawset(L, -3) // hooktable[L1] = hook
	kernel.api_sethook(L1, func, mask, i32(count))
	return 0
}

@(private = "file")
db_gethook :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, _ := getthread(L)
	buff: [5]u8
	mask := kernel.api_gethookmask(L1)
	hook := kernel.api_gethook(L1)
	if hook == nil {
		aux_pushfail(L) // no hook
		return 1
	} else if hook != kernel.Hook_Proc(hookf) { // an external (non-Lua) hook
		kernel.api_pushstring(L, "external hook")
	} else { // the hook table must exist
		kernel.api_getfield(L, kernel.REGISTRYINDEX, HOOKKEY)
		checkstack(L, L1, 1)
		kernel.api_pushthread(L1)
		kernel.api_xmove(L1, L, 1)
		kernel.api_rawget(L, -2) // 1st result: hooktable[L1]
		kernel.api_remove(L, -2) // drop the hook table
	}
	kernel.api_pushstring(L, unmakemask(mask, buff[:])) // 2nd result: the mask
	kernel.api_pushinteger(L, kernel.Integer(kernel.api_gethookcount(L1))) // 3rd: the count
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
		write_stderr(kernel.DEBUG_PROMPT)
		n := 0
		for n < len(buffer) - 1 {
			c := stream.getc(stream.stdin())
			if c == stream.EOF {
				break
			}
			buffer[n] = u8(c)
			n += 1
			if c == '\n' {
				break
			}
		}
		if n == 0 {
			return 0
		}
		line := string(buffer[:n])
		if line == "cont\n" {
			return 0
		}
		bytes := transmute([]u8)line
		if aux_loadbufferx(L, bytes, "=(debug command)", "") != .Ok ||
		   kernel.api_pcall(L, 0, 0, 0) != .Ok {
			write_stderr(aux_tolstring(L, -1))
			write_stderr("\n")
		}
		kernel.api_settop(L, 0) // discard any results/errors
	}
}

@(private = "file")
db_traceback :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	L1, arg := getthread(L)
	msg, is_str := kernel.api_tostring(L, arg + 1)
	if !is_str && !kernel.api_isnoneornil(L, arg + 1) { // non-string, non-nil message
		kernel.api_pushvalue(L, arg + 1) // return it untouched
	} else {
		level := int(aux_optinteger(L, arg + 2, kernel.Integer(L == L1 ? 1 : 0)))
		aux_traceback(L, L1, msg, is_str, level)
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
open_debug :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, dblib)
	return 1
}
