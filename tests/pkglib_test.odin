package tests

// pkglib_test.odin -- honest end-to-end tests for the package/require library
// (src/stdlib/package.odin) and luaL_openlibs (src/stdlib/init.odin).
//
// These prove observable module-system semantics: that luaL_openlibs installs
// every standard library, that `require` consults the searchers, caches results,
// loads real Lua-source files from disk via package.path, honors package.preload,
// reports honest "not found" errors, and that package.searchpath / package.loadlib
// / package.config behave exactly as reference Lua's dlopen-less configuration.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

// A state with the ENTIRE standard library opened (base, package, coroutine,
// debug, io, math, os, string, table, utf8) -- i.e. luaL_openlibs, the real entry
// point host programs use.
pkg_state :: proc() -> ^lua.State {
	L := lua.new_state(lua.default_allocator())
	aux.aux_openlibs(L)
	return L
}

pkg_run :: proc(L: ^lua.State, src: string) -> lua.Thread_Status {
	if st := aux.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.api_pcall(L, 0, lua.MULTRET, 0)
}

pkg_eval :: proc(t: ^testing.T, L: ^lua.State, src: string) -> string {
	st := pkg_run(L, src)
	if st != .Ok {
		msg, _ := lua.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return ""
	}
	s, _ := lua.api_tolstring(L, -1)
	return s
}

@(test)
pkg_openlibs_installs_everything :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	src :=
		// every standard library is present as a global table / function
		"assert(type(_G) == 'table')\n" +
		"assert(type(string) == 'table' and type(string.format) == 'function')\n" +
		"assert(type(table) == 'table' and type(table.insert) == 'function')\n" +
		"assert(type(math) == 'table' and type(math.sqrt) == 'function')\n" +
		"assert(type(io) == 'table' and type(io.open) == 'function')\n" +
		"assert(type(os) == 'table' and type(os.time) == 'function')\n" +
		"assert(type(coroutine) == 'table' and type(coroutine.create) == 'function')\n" +
		"assert(type(utf8) == 'table' and type(utf8.char) == 'function')\n" +
		"assert(type(debug) == 'table' and type(debug.traceback) == 'function')\n" +
		"assert(type(package) == 'table')\n" +
		"assert(type(require) == 'function')\n" +
		// each is also registered in package.loaded under its name
		"for _, n in ipairs{'_G','package','coroutine','debug','io','math','os','string','table','utf8'} do\n" +
		"  assert(package.loaded[n] ~= nil, 'missing loaded['..n..']')\n" +
		"end\n" +
		"assert(package.loaded.string == string)\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "aux_openlibs installs all libraries")
}

@(test)
pkg_config_and_searchpath :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	src :=
		// package.config is five lines; line 1 is the directory separator,
		// line 2 ';', line 3 '?', line 4 '!', line 5 '-'
		"local c = package.config\n" +
		"assert(type(c) == 'string')\n" +
		"local sep = c:sub(1,1)\n" +
		"assert(sep == '/' or sep == '\\\\')\n" +
		"local lines = {}\n" +
		"for line in c:gmatch('[^\\n]+') do lines[#lines+1] = line end\n" +
		"assert(lines[2] == ';' and lines[3] == '?' and lines[4] == '!' and lines[5] == '-')\n" +
		// searchpath on a definitely-missing module returns fail + a 'no file' report
		"local f, msg = package.searchpath('no.such.module.zzz', '/nonexistent/?.lua')\n" +
		"assert(f == nil)\n" +
		"assert(type(msg) == 'string' and msg:find('no file', 1, true))\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "package.config and searchpath")
}

@(test)
pkg_preload :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	src :=
		// a preloaded module is found by searcher_preload; require runs it and
		// caches the result, and returns ':preload:' as the loader data
		"local ran = 0\n" +
		"package.preload['mymod'] = function(name, data)\n" +
		"  ran = ran + 1\n" +
		"  assert(name == 'mymod')\n" +
		"  assert(data == ':preload:')\n" +
		"  return { tag = 'M' }\n" +
		"end\n" +
		"local m, data = require('mymod')\n" +
		"assert(m.tag == 'M')\n" +
		"assert(data == ':preload:')\n" +
		"assert(ran == 1)\n" +
		"local m2 = require('mymod')\n" + // second require is a cache hit
		"assert(m2 == m and ran == 1)\n" +
		"assert(package.loaded.mymod == m)\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "package.preload + require caching")
}

@(test)
pkg_require_not_found :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	src :=
		// a module that no searcher can find raises a 'not found' error listing
		// the searchers' individual failures
		"package.path = '/nonexistent/?.lua'\n" +
		"package.cpath = '/nonexistent/?.dll'\n" +
		"local ok, err = pcall(require, 'totally.absent.module')\n" +
		"assert(not ok)\n" +
		"assert(type(err) == 'string')\n" +
		"assert(err:find('module', 1, true))\n" +
		"assert(err:find('not found', 1, true))\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "require reports not-found honestly")
}

@(test)
pkg_loadlib_unsupported :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	src :=
		// dlopen-less build: loadlib fails with the reference DLMSG and 'absent'
		"local ok, msg, where = package.loadlib('whatever.dll', 'open_x')\n" +
		"assert(ok == nil)\n" +
		"assert(type(msg) == 'string' and msg:find('dynamic libraries', 1, true))\n" +
		"assert(where == 'absent')\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "package.loadlib is honestly unsupported")
}

@(test)
pkg_require_lua_file :: proc(t: ^testing.T) {
	L := pkg_state()
	defer lua.close_state(L)
	// Write a real .lua module to the temp directory, then require it through
	// package.path. This exercises searcher_Lua + luaL_loadfile end to end and
	// proves the two-value (module, loader-data=filename) return.
	src :=
		"local tmp = os.getenv('TEMP') or os.getenv('TMP') or '.'\n" +
		"local sep = package.config:sub(1,1)\n" +
		"local modname = 'luaodin_pkg_probe'\n" +
		"local path = tmp .. sep .. modname .. '.lua'\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"f:write('return { answer = 42, who = ... }')\n" + // '...' captures the module name arg
		"f:close()\n" +
		"package.path = tmp .. sep .. '?.lua'\n" +
		"local m, data = require(modname)\n" +
		"assert(type(m) == 'table')\n" +
		"assert(m.answer == 42)\n" +
		"assert(m.who == modname)\n" + // require passes the module name as 1st arg
		"assert(type(data) == 'string' and data:find('%.lua$'))\n" + // loader data is the filename
		"assert(package.loaded[modname] == m)\n" +
		"local again = require(modname)\n" +
		"assert(again == m)\n" + // cached
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, pkg_eval(t, L, src) == "ok", "require loads a real .lua file from package.path")
}
