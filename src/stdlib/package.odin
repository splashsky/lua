package stdlib

// package.odin -- our analogue of reference Lua's `loadlib.c`.
//
// The package/module system: `require`, the `package` table (loaded, preload,
// path/cpath, searchers, config), `package.searchpath`, `package.loadlib`, and
// the loader pipeline (searcher_preload / searcher_Lua / searcher_C /
// searcher_Croot). Lua-*source* modules load exactly as reference Lua does: the
// Lua searcher walks `package.path`, finds a readable `.lua` file, and loads it
// with `luaL_loadfile`.
//
// Documented deviation (see README / docs/ARCHITECTURE.md): reference Lua loads
// native **C** modules by dlopen/LoadLibrary + a `luaopen_*` C ABI. A
// standard-library-only Odin build has no such dynamic-linking facility, so we
// faithfully mirror reference Lua's *own* ISO-C fallback -- the configuration it
// compiles to on a platform without dlopen. In that configuration `lsys_load`
// simply reports "dynamic libraries not enabled; check your Lua installation",
// `package.loadlib` returns (fail, that-message, "absent"), and the C searchers
// still walk `package.cpath` but raise the same honest "dynamic libraries not
// enabled" error the moment they find a readable native file. This is a real,
// legitimate reference behavior -- not a shortcut -- so observable Lua semantics
// (including the PUC test suite's package handling) match a stock dlopen-less Lua.
// The searcher/loader *shape* is preserved exactly; only native-module loading is
// (as in that reference configuration) unavailable.

import "base:runtime"
import "core:c/libc"
import lua "luao:lua"
import stream "luao:stream"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// Convert a (NUL-terminated) Lua string to a C string for libc calls. Lua strings
// always carry a trailing NUL, so this is just a reinterpretation.
@(private = "file")
cstr :: #force_inline proc "contextless" (s: string) -> cstring {
	return cstring(raw_data(s))
}

// -----------------------------------------------------------------------------
// Configuration constants (reference luaconf.h). These are chosen at compile time
// per target platform, exactly like reference Lua's `#if defined(_WIN32)` split.
// -----------------------------------------------------------------------------

@(private = "file")
PATH_SEP :: ";" // separates templates within a path
@(private = "file")
PATH_MARK :: "?" // substitution mark within a template
@(private = "file")
EXEC_DIR :: "!" // executable-directory mark (left literal in the ISO-C fallback)
@(private = "file")
IGMARK :: "-" // "ignore all after this" mark in a module name
@(private = "file")
VERSUFFIX :: "_5_5" // "_" MAJOR "_" MINOR -- appended to versioned env-var names

when ODIN_OS == .Windows {
	@(private = "file")
	DIRSEP :: "\\"
	@(private = "file")
	PATH_DEFAULT ::
		"!\\lua\\?.lua;!\\lua\\?\\init.lua;" +
		"!\\?.lua;!\\?\\init.lua;" +
		"!\\..\\share\\lua\\5.5\\?.lua;!\\..\\share\\lua\\5.5\\?\\init.lua;" +
		".\\?.lua;.\\?\\init.lua"
	@(private = "file")
	CPATH_DEFAULT ::
		"!\\?.dll;" +
		"!\\..\\lib\\lua\\5.5\\?.dll;" +
		"!\\loadall.dll;.\\?.dll"
} else {
	@(private = "file")
	DIRSEP :: "/"
	@(private = "file")
	PATH_DEFAULT ::
		"/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;" +
		"/usr/local/lib/lua/5.5/?.lua;/usr/local/lib/lua/5.5/?/init.lua;" +
		"./?.lua;./?/init.lua"
	@(private = "file")
	CPATH_DEFAULT ::
		"/usr/local/lib/lua/5.5/?.so;/usr/local/lib/lua/5.5/loadall.so;./?.so"
}

// The five-line `package.config` string -- reference:
//   directory separator / template separator / substitution mark /
//   executable-directory mark / ignore mark, each on its own line, trailing '\n'.
@(private = "file")
CONFIG :: DIRSEP + "\n" + PATH_SEP + "\n" + PATH_MARK + "\n" + EXEC_DIR + "\n" + IGMARK + "\n"

// The registry key under which we keep handles for loaded C libraries -- reference
// CLIBS. In our dlopen-less build it stays empty, but we still create it so the
// structure exactly matches reference Lua.
@(private = "file")
CLIBS :: "_CLIBS"

// The message reference Lua's ISO-C fallback reports when asked to load a native
// dynamic library -- reference DLMSG.
@(private = "file")
DLMSG :: "dynamic libraries not enabled; check your Lua installation"

// Error codes from `lookforfunc` -- reference ERRLIB / ERRFUNC.
@(private = "file")
ERRLIB :: 1
@(private = "file")
ERRFUNC :: 2

// The "where" string returned by a failed `loadlib` -- reference's fallback
// redefines LIB_FAIL to "absent" (the library is simply not available at all).
@(private = "file")
LIB_FAIL :: "absent"

// -----------------------------------------------------------------------------
// Small string helpers (pure Odin; they do not touch the Lua stack)
// -----------------------------------------------------------------------------

// Does `s` contain the literal substring `sub`?
@(private = "file")
str_contains :: proc(s: string, sub: string) -> bool {
	if len(sub) == 0 {
		return false
	}
	if len(sub) > len(s) {
		return false
	}
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i + len(sub)] == sub {
			return true
		}
	}
	return false
}

// Index of the first occurrence of byte `c` in `s`, or -1.
@(private = "file")
str_index_byte :: proc(s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// -----------------------------------------------------------------------------
// Native-library loading -- the ISO-C fallback (no dlopen). Faithful to reference
// Lua compiled without LUA_USE_DLOPEN.
// -----------------------------------------------------------------------------

// Look for a C function `sym` in the dynamic library `path`. In our build no C
// libraries can ever be loaded, so -- exactly like reference's stub `lsys_load` --
// we push the DLMSG error and report ERRLIB. Reference's `checkclib` would find no
// cached handle (CLIBS is always empty), then `lsys_load` fails identically.
@(private = "file")
lookforfunc :: proc(L: ^lua.Lua_State, path: string, sym: string) -> int {
	lua.lua_pushstring(L, DLMSG)
	return ERRLIB
}

// package.loadlib(path, init) -- reference `ll_loadlib`.
@(private = "file")
ll_loadlib :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	path := luaL_checkstring(L, 1)
	init := luaL_checkstring(L, 2)
	stat := lookforfunc(L, path, init)
	if stat == 0 {
		return 1 // (never happens in this build, but faithful)
	}
	// Error: the message is on top. Return (fail, message, where).
	luaL_pushfail(L)
	lua.lua_insert(L, -2)
	lua.lua_pushstring(L, stat == ERRLIB ? LIB_FAIL : "init")
	return 3
}

// -----------------------------------------------------------------------------
// searchpath / findfile
// -----------------------------------------------------------------------------

// Can `filename` be opened for reading? -- reference `readable` (fopen "r").
// `filename` is frequently a slice of a larger expanded path list. core:os accepts
// an Odin string with an explicit length, so unlike the old fopen path this needs
// no temporary NUL-terminated copy.
@(private = "file")
readable :: proc(filename: string) -> bool {
	f := stream.open(filename, "r")
	if f == nil {
		return false
	}
	stream.close(f)
	return true
}

// Build the "no file 'a'\n\tno file 'b'..." message for a failed search from the
// already-expanded template list `path` -- reference `pusherrornotfound`. Leaves
// the message on top of the stack.
@(private = "file")
pusherrornotfound :: proc(L: ^lua.Lua_State, path: string) {
	b: Buffer
	luaL_buffinit(L, &b)
	luaL_addstring(&b, "no file '")
	luaL_addgsub(&b, path, PATH_SEP, "'\n\tno file '")
	luaL_addstring(&b, "'")
	luaL_pushresult(&b)
}

// Search `path` (a ';'-separated template list) for a readable file, substituting
// `name` for each '?' -- reference `searchpath`. `sep`, when non-empty and present
// in `name`, is first replaced by `dirsep` (so dotted submodule names map to
// directories). On success pushes and returns the found filename (ok=true). On
// failure pushes the "not found" message and returns ok=false.
@(private = "file")
searchpath_push :: proc(
	L: ^lua.Lua_State,
	name: string,
	path: string,
	sep: string,
	dirsep: string,
) -> (
	filename: string,
	ok: bool,
) {
	name := name
	// Replace the separator (e.g. ".") by the directory separator inside the name.
	// Like reference we use luaL_gsub, which pushes the rewritten name; the residue
	// sits harmlessly below our work and is truncated when the C function returns.
	if sep != "" && str_contains(name, sep) {
		name = luaL_gsub(L, name, sep, dirsep)
	}
	// Expand the whole template list, replacing every '?' with the name.
	b: Buffer
	luaL_buffinit(L, &b)
	luaL_addgsub(&b, path, PATH_MARK, name)
	luaL_pushresult(&b)
	expanded, _ := lua.lua_tolstring(L, -1)
	// Walk the ';'-separated candidates and return the first readable one.
	start := 0
	for i := 0; i <= len(expanded); i += 1 {
		if i == len(expanded) || expanded[i] == PATH_SEP[0] {
			cand := expanded[start:i]
			if readable(cand) {
				// Push a fresh copy of the found name (above the expanded list) and
				// return it. The expanded list below is left as harmless residue,
				// mirroring reference (which leaves its buffer box on the stack).
				lua.lua_pushstring(L, cand)
				res, _ := lua.lua_tolstring(L, -1)
				return res, true
			}
			start = i + 1
		}
	}
	// Nothing readable: build and push the "no file ..." message.
	pusherrornotfound(L, expanded)
	return "", false
}

// package.searchpath(name, path [, sep [, dirsep]]) -- reference `ll_searchpath`.
@(private = "file")
ll_searchpath :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	path := luaL_checkstring(L, 2)
	sep := luaL_optstring(L, 3, ".")
	dirsep := luaL_optstring(L, 4, DIRSEP)
	_, ok := searchpath_push(L, name, path, sep, dirsep)
	if ok {
		return 1
	}
	// Error message is on top: return (fail, message).
	luaL_pushfail(L)
	lua.lua_insert(L, -2)
	return 2
}

// Look up `package[pname]` (a path string) and search it for `name` -- reference
// `findfile`. Returns the found filename or ("", false) with the error message on
// the stack.
@(private = "file")
findfile :: proc(
	L: ^lua.Lua_State,
	name: string,
	pname: string,
	dirsep: string,
) -> (
	string,
	bool,
) {
	lua.lua_getfield(L, lua.lua_upvalueindex(1), pname)
	path, isstr := lua.lua_tolstring(L, -1)
	if !isstr {
		luaL_error(L, "'package.%s' must be a string", pname)
	}
	return searchpath_push(L, name, path, ".", dirsep)
}

// Turn a searcher's "did it load?" flag into its two return values -- reference
// `checkload`. On success pushes the filename (the loader's 2nd argument) and
// returns 2; on failure raises the standard "error loading module" error.
@(private = "file")
checkload :: proc(L: ^lua.Lua_State, stat: bool, filename: string) -> i32 {
	if stat {
		lua.lua_pushstring(L, filename) // 2nd argument to the module loader
		return 2
	}
	modname, _ := lua.lua_tolstring(L, 1)
	errmsg, _ := lua.lua_tolstring(L, -1)
	luaL_error(L, "error loading module '%s' from file '%s':\n\t%s", modname, filename, errmsg)
}

// -----------------------------------------------------------------------------
// The four searchers
// -----------------------------------------------------------------------------

// The Lua-source searcher -- reference `searcher_Lua`. Fully functional: finds a
// readable `.lua` file on `package.path` and loads it with `luaL_loadfile`.
@(private = "file")
searcher_Lua :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	filename, ok := findfile(L, name, "path", DIRSEP)
	if !ok {
		return 1 // not found on this path: the message is a searcher error
	}
	loaded := luaL_loadfilex(L, filename) == .Ok
	return checkload(L, loaded, filename)
}

// Try to find a native load function for `modname` in `filename` -- reference
// `loadfunc`. Faithfully performs the '.'->'_' rewrite and the ignore-mark
// handling; in our dlopen-less build every attempt bottoms out in `lookforfunc`
// returning ERRLIB, so the ignore-mark branch returns immediately.
@(private = "file")
loadfunc :: proc(L: ^lua.Lua_State, filename: string, modname: string) -> int {
	modname := luaL_gsub(L, modname, ".", "_")
	mark := str_index_byte(modname, IGMARK[0])
	if mark >= 0 {
		prefix := lua.lua_pushlstring(L, transmute([]u8)modname[:mark])
		openfunc := lua.lua_pushfstring(L, "luaopen_%s", prefix)
		stat := lookforfunc(L, filename, openfunc)
		if stat != ERRFUNC {
			return stat
		}
		modname = modname[mark + 1:] // else try the old-style name
	}
	openfunc := lua.lua_pushfstring(L, "luaopen_%s", modname)
	return lookforfunc(L, filename, openfunc)
}

// The C-library searcher -- reference `searcher_C`. Walks `package.cpath`. In our
// build a readable match still raises the honest "dynamic libraries not enabled"
// error via checkload (exactly reference-without-dlopen behavior).
@(private = "file")
searcher_C :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	filename, ok := findfile(L, name, "cpath", DIRSEP)
	if !ok {
		return 1
	}
	return checkload(L, loadfunc(L, filename, name) == 0, filename)
}

// The "C root" searcher (for submodules whose root ships as one library) --
// reference `searcher_Croot`.
@(private = "file")
searcher_Croot :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	p := str_index_byte(name, '.')
	if p < 0 {
		return 0 // `name` is a root -- nothing for this searcher to do
	}
	rootname := lua.lua_pushlstring(L, transmute([]u8)name[:p])
	filename, ok := findfile(L, rootname, "cpath", DIRSEP)
	if !ok {
		return 1 // root not found
	}
	stat := loadfunc(L, filename, name)
	if stat != 0 {
		if stat != ERRFUNC {
			return checkload(L, false, filename) // real error
		}
		// open function not found: not fatal, just report it as a searcher message
		lua.lua_pushfstring(L, "no module '%s' in file '%s'", name, filename)
		return 1
	}
	lua.lua_pushstring(L, filename)
	return 2
}

// The preload searcher -- reference `searcher_preload`. Fully functional: looks in
// the registry PRELOAD table for a preregistered loader function.
@(private = "file")
searcher_preload :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
	if lua.lua_getfield(L, -1, name) == lua.LUA_TNIL {
		lua.lua_pushfstring(L, "no field package.preload['%s']", name)
		return 1
	}
	lua.lua_pushstring(L, ":preload:")
	return 2
}

// -----------------------------------------------------------------------------
// require
// -----------------------------------------------------------------------------

// Walk `package.searchers` looking for a loader for `name` -- reference
// `findloader`. On success leaves (loader-function, loader-data) on top of the
// stack; on total failure raises "module '...' not found:" with each searcher's
// accumulated message. `package.searchers` is left at absolute stack index 3, and
// searchers are read with `rawgeti` (holes terminate; `__index` is ignored).
@(private = "file")
findloader :: proc(L: ^lua.Lua_State, name: string) {
	if lua.lua_getfield(L, lua.lua_upvalueindex(1), "searchers") != lua.LUA_TTABLE {
		luaL_error(L, "'package.searchers' must be a table")
	}
	msg: Buffer
	luaL_buffinit(L, &msg)
	luaL_addstring(&msg, "\n\t") // prefix for the first accumulated message
	for i := 1;; i += 1 {
		if lua.lua_rawgeti(L, 3, lua.Integer(i)) == lua.LUA_TNIL {
			lua.lua_pop(L, 1) // remove the nil
			luaL_buffsub(&msg, 2) // drop the last "\n\t"
			luaL_pushresult(&msg)
			errmsg, _ := lua.lua_tolstring(L, -1)
			luaL_error(L, "module '%s' not found:%s", name, errmsg)
		}
		lua.lua_pushstring(L, name)
		lua.lua_call(L, 1, 2) // call the searcher with the module name
		if lua.lua_isfunction(L, -2) {
			return // found a loader
		} else if lua.lua_isstring(L, -2) {
			lua.lua_pop(L, 1) // remove the extra return (loader data slot)
			luaL_addvalue(&msg) // concatenate the searcher's error message
			luaL_addstring(&msg, "\n\t")
		} else {
			lua.lua_pop(L, 2) // no message: discard both returns
		}
	}
}

// require(modname) -- reference `ll_require`. Returns the cached module if present,
// else finds a loader, runs it, caches the result in LOADED, and returns the module
// value plus the loader data (two results on a fresh load; one for a cache hit).
@(private = "file")
ll_require :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := luaL_checkstring(L, 1)
	lua.lua_settop(L, 1) // LOADED table will be at index 2
	lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
	lua.lua_getfield(L, 2, name) // LOADED[name]
	if lua.lua_toboolean(L, -1) {
		return 1 // already loaded (truthiness: a cached `false` reloads)
	}
	lua.lua_pop(L, 1) // remove the getfield result
	findloader(L, name)
	lua.lua_rotate(L, -2, 1) // function <-> loader data
	lua.lua_pushvalue(L, 1) // name is the loader's 1st argument
	lua.lua_pushvalue(L, -3) // loader data is the 2nd argument
	lua.lua_call(L, 2, 1) // run the loader to load the module
	if !lua.lua_isnil(L, -1) {
		lua.lua_setfield(L, 2, name) // LOADED[name] = returned value
	} else {
		lua.lua_pop(L, 1) // pop the nil
	}
	if lua.lua_getfield(L, 2, name) == lua.LUA_TNIL { // module set no value?
		lua.lua_pushboolean(L, true) // use `true` as the result
		lua.lua_copy(L, -1, -2) // replace the loader result
		lua.lua_setfield(L, 2, name) // LOADED[name] = true
	}
	lua.lua_rotate(L, -2, 1) // loader data <-> module result
	return 2 // module result and loader data
}

// -----------------------------------------------------------------------------
// Environment-driven path setup
// -----------------------------------------------------------------------------

// registry.LUA_NOENV as a boolean -- reference `noenv`.
@(private = "file")
noenv :: proc(L: ^lua.Lua_State) -> bool {
	lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "LUA_NOENV")
	b := lua.lua_toboolean(L, -1)
	lua.lua_pop(L, 1)
	return b
}

// Fetch an environment variable by name, or "" + false if unset. An *empty* value
// counts as set (reference distinguishes NULL from "").
@(private = "file")
getenv_str :: proc(name: string) -> (string, bool) {
	v := libc.getenv(cstr(name))
	if v == nil {
		return "", false
	}
	return string(v), true
}

// Set package[fieldname] from the environment (versioned name first, then the bare
// name), honoring LUA_NOENV and the ";;" default-insertion rule -- reference
// `setpath`. Assumes the package table is on top of the stack.
@(private = "file")
setpath :: proc(L: ^lua.Lua_State, fieldname: string, envname: string, dft: string) {
	nver := lua.lua_pushfstring(L, "%s%s", envname, VERSUFFIX) // e.g. "LUA_PATH_5_5"
	path, have := getenv_str(nver)
	if !have {
		path, have = getenv_str(envname) // fall back to the unversioned name
	}
	if !have || noenv(L) {
		lua.lua_pushstring(L, dft) // no environment override: use the default
	} else {
		mark := -1
		// find the first ";;" (a request to splice the default path in here)
		for i := 0; i + 1 < len(path); i += 1 {
			if path[i] == PATH_SEP[0] && path[i + 1] == PATH_SEP[0] {
				mark = i
				break
			}
		}
		if mark < 0 {
			lua.lua_pushstring(L, path) // nothing to change
		} else {
			prefix := path[:mark] // text before ";;"
			suffix := path[mark + 2:] // text after ";;"
			b: Buffer
			luaL_buffinit(L, &b)
			if len(prefix) > 0 {
				luaL_addlstring(&b, transmute([]u8)prefix)
				luaL_addchar(&b, PATH_SEP[0])
			}
			luaL_addstring(&b, dft)
			if len(suffix) > 0 {
				luaL_addchar(&b, PATH_SEP[0])
				luaL_addlstring(&b, transmute([]u8)suffix)
			}
			luaL_pushresult(&b)
		}
	}
	lua.lua_setfield(L, -3, fieldname) // package[fieldname] = value
	lua.lua_pop(L, 1) // pop the versioned variable name (nver)
}

// -----------------------------------------------------------------------------
// Library open
// -----------------------------------------------------------------------------

// The `package.*` functions (plus placeholders filled in by luaopen_package).
@(private = "file")
pk_funcs := []Reg {
	{"loadlib", ll_loadlib},
	{"searchpath", ll_searchpath},
	// placeholders (set below):
	{"preload", nil},
	{"cpath", nil},
	{"path", nil},
	{"searchers", nil},
	{"loaded", nil},
}

// The functions installed into the global table (just `require`).
@(private = "file")
ll_funcs := []Reg{{"require", ll_require}}

// Build `package.searchers` -- reference `createsearcherstable`. Each searcher is a
// C closure carrying the `package` table as upvalue 1. Assumes the package table is
// at stack top.
@(private = "file")
createsearcherstable :: proc(L: ^lua.Lua_State) {
	searchers := []lua.C_Function{searcher_preload, searcher_Lua, searcher_C, searcher_Croot}
	lua.lua_createtable(L, len(searchers), 0)
	for i in 0 ..< len(searchers) {
		lua.lua_pushvalue(L, -2) // package as the shared upvalue
		lua.lua_pushcclosure(L, searchers[i], 1)
		lua.lua_rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.lua_setfield(L, -2, "searchers")
}

// luaopen_package -- reference `luaopen_package`. Builds the `package` table, its
// searchers, path/cpath (from the environment or defaults), config string, and the
// loaded/preload registry links, then installs `require` into the global table.
luaopen_package :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_getsubtable(L, lua.LUA_REGISTRYINDEX, CLIBS) // create CLIBS table
	lua.lua_pop(L, 1) // (unused in this build, but created for structural parity)
	luaL_newlib(L, pk_funcs) // the `package` table
	createsearcherstable(L)
	setpath(L, "path", "LUA_PATH", PATH_DEFAULT)
	setpath(L, "cpath", "LUA_CPATH", CPATH_DEFAULT)
	lua.lua_pushstring(L, CONFIG) // store config information
	lua.lua_setfield(L, -2, "config")
	luaL_getsubtable(L, lua.LUA_REGISTRYINDEX, LUA_LOADED_TABLE) // package.loaded
	lua.lua_setfield(L, -2, "loaded")
	luaL_getsubtable(L, lua.LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE) // package.preload
	lua.lua_setfield(L, -2, "preload")
	lua.lua_pushglobaltable(L)
	lua.lua_pushvalue(L, -2) // set `package` as the upvalue for `require`
	luaL_setfuncs(L, ll_funcs, 1) // open `require` into the global table
	lua.lua_pop(L, 1) // pop the global table
	return 1 // return the `package` table
}
