#+build !freestanding

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
import kernel "lang:kernel"
import stream "lang:stream"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
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

// "_5_5" -- appended to versioned env-var names. Brand-derived; see brand.odin.
@(private = "file")
VERSUFFIX :: kernel.VERSUFFIX

// The brand-derived pieces of every default template: the lower-case brand used
// as a directory component ("lua"), the source extension (".lua"), and the
// MAJOR.MINOR directory ("5.5").
@(private = "file")
B :: kernel.BRAND_LOWER
@(private = "file")
EXT :: kernel.SOURCE_EXT
@(private = "file")
VD :: kernel.VERSION_DIR

when ODIN_OS == .Windows {
	@(private = "file")
	DIRSEP :: "\\"
	@(private = "file")
	PATH_DEFAULT ::
		"!\\" + B + "\\?" + EXT + ";!\\" + B + "\\?\\init" + EXT + ";" +
		"!\\?" + EXT + ";!\\?\\init" + EXT + ";" +
		"!\\..\\share\\" + B + "\\" + VD + "\\?" + EXT +
		";!\\..\\share\\" + B + "\\" + VD + "\\?\\init" + EXT + ";" +
		".\\?" + EXT + ";.\\?\\init" + EXT
	@(private = "file")
	CPATH_DEFAULT ::
		"!\\?.dll;" +
		"!\\..\\lib\\" + B + "\\" + VD + "\\?.dll;" +
		"!\\loadall.dll;.\\?.dll"
} else {
	@(private = "file")
	DIRSEP :: "/"
	@(private = "file")
	PATH_DEFAULT ::
		"/usr/local/share/" + B + "/" + VD + "/?" + EXT +
		";/usr/local/share/" + B + "/" + VD + "/?/init" + EXT + ";" +
		"/usr/local/lib/" + B + "/" + VD + "/?" + EXT +
		";/usr/local/lib/" + B + "/" + VD + "/?/init" + EXT + ";" +
		"./?" + EXT + ";./?/init" + EXT
	@(private = "file")
	CPATH_DEFAULT ::
		"/usr/local/lib/" + B + "/" + VD + "/?.so;/usr/local/lib/" + B + "/" + VD +
		"/loadall.so;./?.so"
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
DLMSG :: "dynamic libraries not enabled; check your " + kernel.BRAND + " installation"

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
lookforfunc :: proc(L: ^kernel.State, path: string, sym: string) -> int {
	kernel.api_pushstring(L, DLMSG)
	return ERRLIB
}

// package.loadlib(path, init) -- reference `ll_loadlib`.
@(private = "file")
ll_loadlib :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	path := aux_checkstring(L, 1)
	init := aux_checkstring(L, 2)
	stat := lookforfunc(L, path, init)
	if stat == 0 {
		return 1 // (never happens in this build, but faithful)
	}
	// Error: the message is on top. Return (fail, message, where).
	aux_pushfail(L)
	kernel.api_insert(L, -2)
	kernel.api_pushstring(L, stat == ERRLIB ? LIB_FAIL : "init")
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
pusherrornotfound :: proc(L: ^kernel.State, path: string) {
	b: Buffer
	aux_buffinit(L, &b)
	aux_addstring(&b, "no file '")
	aux_addgsub(&b, path, PATH_SEP, "'\n\tno file '")
	aux_addstring(&b, "'")
	aux_pushresult(&b)
}

// Search `path` (a ';'-separated template list) for a readable file, substituting
// `name` for each '?' -- reference `searchpath`. `sep`, when non-empty and present
// in `name`, is first replaced by `dirsep` (so dotted submodule names map to
// directories). On success pushes and returns the found filename (ok=true). On
// failure pushes the "not found" message and returns ok=false.
@(private = "file")
searchpath_push :: proc(
	L: ^kernel.State,
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
		name = aux_gsub(L, name, sep, dirsep)
	}
	// Expand the whole template list, replacing every '?' with the name.
	b: Buffer
	aux_buffinit(L, &b)
	aux_addgsub(&b, path, PATH_MARK, name)
	aux_pushresult(&b)
	expanded, _ := kernel.api_tolstring(L, -1)
	// Walk the ';'-separated candidates and return the first readable one.
	start := 0
	for i := 0; i <= len(expanded); i += 1 {
		if i == len(expanded) || expanded[i] == PATH_SEP[0] {
			cand := expanded[start:i]
			if readable(cand) {
				// Push a fresh copy of the found name (above the expanded list) and
				// return it. The expanded list below is left as harmless residue,
				// mirroring reference (which leaves its buffer box on the stack).
				kernel.api_pushstring(L, cand)
				res, _ := kernel.api_tolstring(L, -1)
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
	name := aux_checkstring(L, 1)
	path := aux_checkstring(L, 2)
	sep := aux_optstring(L, 3, ".")
	dirsep := aux_optstring(L, 4, DIRSEP)
	_, ok := searchpath_push(L, name, path, sep, dirsep)
	if ok {
		return 1
	}
	// Error message is on top: return (fail, message).
	aux_pushfail(L)
	kernel.api_insert(L, -2)
	return 2
}

// Look up `package[pname]` (a path string) and search it for `name` -- reference
// `findfile`. Returns the found filename or ("", false) with the error message on
// the stack.
@(private = "file")
findfile :: proc(
	L: ^kernel.State,
	name: string,
	pname: string,
	dirsep: string,
) -> (
	string,
	bool,
) {
	kernel.api_getfield(L, kernel.upvalueindex(1), pname)
	path, isstr := kernel.api_tolstring(L, -1)
	if !isstr {
		aux_error(L, "'package.%s' must be a string", pname)
	}
	return searchpath_push(L, name, path, ".", dirsep)
}

// Turn a searcher's "did it load?" flag into its two return values -- reference
// `checkload`. On success pushes the filename (the loader's 2nd argument) and
// returns 2; on failure raises the standard "error loading module" error.
@(private = "file")
checkload :: proc(L: ^kernel.State, stat: bool, filename: string) -> i32 {
	if stat {
		kernel.api_pushstring(L, filename) // 2nd argument to the module loader
		return 2
	}
	modname, _ := kernel.api_tolstring(L, 1)
	errmsg, _ := kernel.api_tolstring(L, -1)
	aux_error(L, "error loading module '%s' from file '%s':\n\t%s", modname, filename, errmsg)
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
	name := aux_checkstring(L, 1)
	filename, ok := findfile(L, name, "path", DIRSEP)
	if !ok {
		return 1 // not found on this path: the message is a searcher error
	}
	loaded := aux_loadfilex(L, filename) == .Ok
	return checkload(L, loaded, filename)
}

// Try to find a native load function for `modname` in `filename` -- reference
// `loadfunc`. Faithfully performs the '.'->'_' rewrite and the ignore-mark
// handling; in our dlopen-less build every attempt bottoms out in `lookforfunc`
// returning ERRLIB, so the ignore-mark branch returns immediately.
@(private = "file")
loadfunc :: proc(L: ^kernel.State, filename: string, modname: string) -> int {
	modname := aux_gsub(L, modname, ".", "_")
	mark := str_index_byte(modname, IGMARK[0])
	if mark >= 0 {
		prefix := kernel.api_pushlstring(L, transmute([]u8)modname[:mark])
		openfunc := kernel.api_pushfstring(L, kernel.NATIVE_OPEN_FMT, prefix)
		stat := lookforfunc(L, filename, openfunc)
		if stat != ERRFUNC {
			return stat
		}
		modname = modname[mark + 1:] // else try the old-style name
	}
	openfunc := kernel.api_pushfstring(L, kernel.NATIVE_OPEN_FMT, modname)
	return lookforfunc(L, filename, openfunc)
}

// The C-library searcher -- reference `searcher_C`. Walks `package.cpath`. In our
// build a readable match still raises the honest "dynamic libraries not enabled"
// error via checkload (exactly reference-without-dlopen behavior).
@(private = "file")
searcher_C :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := aux_checkstring(L, 1)
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
	name := aux_checkstring(L, 1)
	p := str_index_byte(name, '.')
	if p < 0 {
		return 0 // `name` is a root -- nothing for this searcher to do
	}
	rootname := kernel.api_pushlstring(L, transmute([]u8)name[:p])
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
		kernel.api_pushfstring(L, "no module '%s' in file '%s'", name, filename)
		return 1
	}
	kernel.api_pushstring(L, filename)
	return 2
}

// The preload searcher -- reference `searcher_preload`. Fully functional: looks in
// the registry PRELOAD table for a preregistered loader function.
@(private = "file")
searcher_preload :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := aux_checkstring(L, 1)
	kernel.api_getfield(L, kernel.REGISTRYINDEX, PRELOAD_TABLE)
	if kernel.api_getfield(L, -1, name) == kernel.TNIL {
		kernel.api_pushfstring(L, "no field package.preload['%s']", name)
		return 1
	}
	kernel.api_pushstring(L, ":preload:")
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
findloader :: proc(L: ^kernel.State, name: string) {
	if kernel.api_getfield(L, kernel.upvalueindex(1), "searchers") != kernel.TTABLE {
		aux_error(L, "'package.searchers' must be a table")
	}
	msg: Buffer
	aux_buffinit(L, &msg)
	aux_addstring(&msg, "\n\t") // prefix for the first accumulated message
	for i := 1;; i += 1 {
		if kernel.api_rawgeti(L, 3, kernel.Integer(i)) == kernel.TNIL {
			kernel.api_pop(L, 1) // remove the nil
			aux_buffsub(&msg, 2) // drop the last "\n\t"
			aux_pushresult(&msg)
			errmsg, _ := kernel.api_tolstring(L, -1)
			aux_error(L, "module '%s' not found:%s", name, errmsg)
		}
		kernel.api_pushstring(L, name)
		kernel.api_call(L, 1, 2) // call the searcher with the module name
		if kernel.api_isfunction(L, -2) {
			return // found a loader
		} else if kernel.api_isstring(L, -2) {
			kernel.api_pop(L, 1) // remove the extra return (loader data slot)
			aux_addvalue(&msg) // concatenate the searcher's error message
			aux_addstring(&msg, "\n\t")
		} else {
			kernel.api_pop(L, 2) // no message: discard both returns
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
	name := aux_checkstring(L, 1)
	kernel.api_settop(L, 1) // LOADED table will be at index 2
	kernel.api_getfield(L, kernel.REGISTRYINDEX, LOADED_TABLE)
	kernel.api_getfield(L, 2, name) // LOADED[name]
	if kernel.api_toboolean(L, -1) {
		return 1 // already loaded (truthiness: a cached `false` reloads)
	}
	kernel.api_pop(L, 1) // remove the getfield result
	findloader(L, name)
	kernel.api_rotate(L, -2, 1) // function <-> loader data
	kernel.api_pushvalue(L, 1) // name is the loader's 1st argument
	kernel.api_pushvalue(L, -3) // loader data is the 2nd argument
	kernel.api_call(L, 2, 1) // run the loader to load the module
	if !kernel.api_isnil(L, -1) {
		kernel.api_setfield(L, 2, name) // LOADED[name] = returned value
	} else {
		kernel.api_pop(L, 1) // pop the nil
	}
	if kernel.api_getfield(L, 2, name) == kernel.TNIL { // module set no value?
		kernel.api_pushboolean(L, true) // use `true` as the result
		kernel.api_copy(L, -1, -2) // replace the loader result
		kernel.api_setfield(L, 2, name) // LOADED[name] = true
	}
	kernel.api_rotate(L, -2, 1) // loader data <-> module result
	return 2 // module result and loader data
}

// -----------------------------------------------------------------------------
// Environment-driven path setup
// -----------------------------------------------------------------------------

// registry.LUA_NOENV as a boolean -- reference `noenv`.
@(private = "file")
noenv :: proc(L: ^kernel.State) -> bool {
	kernel.api_getfield(L, kernel.REGISTRYINDEX, kernel.ENV_NOENV)
	b := kernel.api_toboolean(L, -1)
	kernel.api_pop(L, 1)
	return b
}

// Set package[fieldname] from the environment (versioned name first, then the bare
// name), honoring LUA_NOENV and the ";;" default-insertion rule -- reference
// `setpath`. Assumes the package table is on top of the stack.
@(private = "file")
setpath :: proc(L: ^kernel.State, fieldname: string, envname: string, dft: string) {
	nver := kernel.api_pushfstring(L, "%s%s", envname, VERSUFFIX) // e.g. "LUA_PATH_5_5"
	have := aux_getenv_push(L, nver)
	if !have {
		have = aux_getenv_push(L, envname) // fall back to the unversioned name
	}
	path := ""
	if have do path, _ = kernel.api_tostring(L, -1)
	if !have || noenv(L) {
		kernel.api_pushstring(L, dft) // no environment override: use the default
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
			kernel.api_pushstring(L, path) // nothing to change
		} else {
			prefix := path[:mark] // text before ";;"
			suffix := path[mark + 2:] // text after ";;"
			b: Buffer
			aux_buffinit(L, &b)
			if len(prefix) > 0 {
				aux_addlstring(&b, transmute([]u8)prefix)
				aux_addchar(&b, PATH_SEP[0])
			}
			aux_addstring(&b, dft)
			if len(suffix) > 0 {
				aux_addchar(&b, PATH_SEP[0])
				aux_addlstring(&b, transmute([]u8)suffix)
			}
			aux_pushresult(&b)
		}
	}
	kernel.api_setfield(L, have ? -4 : -3, fieldname) // package[fieldname] = value
	if have do kernel.api_pop(L, 1) // environment value
	kernel.api_pop(L, 1) // pop the versioned variable name (nver)
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
createsearcherstable :: proc(L: ^kernel.State) {
	searchers := []kernel.C_Function{searcher_preload, searcher_Lua, searcher_C, searcher_Croot}
	kernel.api_createtable(L, len(searchers), 0)
	for i in 0 ..< len(searchers) {
		kernel.api_pushvalue(L, -2) // package as the shared upvalue
		kernel.api_pushcclosure(L, searchers[i], 1)
		kernel.api_rawseti(L, -2, kernel.Integer(i + 1))
	}
	kernel.api_setfield(L, -2, "searchers")
}

// luaopen_package -- reference `luaopen_package`. Builds the `package` table, its
// searchers, path/cpath (from the environment or defaults), config string, and the
// loaded/preload registry links, then installs `require` into the global table.
open_package :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_getsubtable(L, kernel.REGISTRYINDEX, CLIBS) // create CLIBS table
	kernel.api_pop(L, 1) // (unused in this build, but created for structural parity)
	aux_newlib(L, pk_funcs) // the `package` table
	createsearcherstable(L)
	setpath(L, "path", kernel.ENV_PATH, PATH_DEFAULT)
	setpath(L, "cpath", kernel.ENV_CPATH, CPATH_DEFAULT)
	kernel.api_pushstring(L, CONFIG) // store config information
	kernel.api_setfield(L, -2, "config")
	aux_getsubtable(L, kernel.REGISTRYINDEX, LOADED_TABLE) // package.loaded
	kernel.api_setfield(L, -2, "loaded")
	aux_getsubtable(L, kernel.REGISTRYINDEX, PRELOAD_TABLE) // package.preload
	kernel.api_setfield(L, -2, "preload")
	kernel.api_pushglobaltable(L)
	kernel.api_pushvalue(L, -2) // set `package` as the upvalue for `require`
	aux_setfuncs(L, ll_funcs, 1) // open `require` into the global table
	kernel.api_pop(L, 1) // pop the global table
	return 1 // return the `package` table
}
