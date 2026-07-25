package stdlib

// init.odin -- our analogue of reference Lua's `linit.c`.
//
// The single entry point that opens the whole standard library into a state:
// the equivalent of `luaL_openlibs`. It registers each library (base, package,
// coroutine, debug, io, math, os, string, table, utf8) in the canonical order
// reference Lua uses, so that globals and preloaded modules end up arranged
// identically.

import lua "luao:lua"

// The standard libraries, in the exact ORDER reference Lua's `linit.c` lists them
// (matching the LUA_<lib>K constants). `require`-ing them in this order means the
// global table and any preload arrangement come out identical to reference Lua.
@(private = "file")
stdlibs := []Reg {
	{"_G", luaopen_base},
	{"package", luaopen_package},
	{"coroutine", luaopen_coroutine},
	{"debug", luaopen_debug},
	{"io", luaopen_io},
	{"math", luaopen_math},
	{"os", luaopen_os},
	{"string", luaopen_string},
	{"table", luaopen_table},
	{"utf8", luaopen_utf8},
}

// Open every standard library into `L` -- reference `luaL_openlibs` (which in 5.5
// is `luaL_openselectedlibs(L, ~0, 0)`: require them all, preload none). Each is
// `require`d so it is registered in `package.loaded` under its name and (for those
// that ask for it) exposed as a global, exactly as reference does.
luaL_openlibs :: proc(L: ^lua.Lua_State) {
	for lib in stdlibs {
		luaL_requiref(L, lib.name, lib.func, true) // require + set as global
		lua.lua_pop(L, 1) // remove the library table left on the stack
	}
}

