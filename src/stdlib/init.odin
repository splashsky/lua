package stdlib

// init.odin -- our analogue of reference Lua's `linit.c`.
//
// The single entry point that opens the standard libraries appropriate to the
// target. Hosted builds retain reference Lua's complete canonical list. A
// freestanding machine has no files, environment, process, or terminal, so its
// list contains only the kernel-backed, pure libraries.

import kernel "lang:kernel"

// The standard libraries, in the exact ORDER reference Lua's `linit.c` lists them
// (matching the LUA_<lib>K constants). `require`-ing them in this order means the
// global table and any preload arrangement come out identical to reference Lua.
when ODIN_OS == .Freestanding {
	// package, io, and os fundamentally describe hosted services. The debug
	// library is mostly introspection, but its interactive debug() entry point
	// also requires stdin/stderr, so the deliberately small freestanding set is
	// exactly base, coroutine, math, string, table, and utf8.
	@(private = "file")
	stdlibs := []Reg {
		{"_G", open_base},
		{"coroutine", open_coroutine},
		{"math", open_math},
		{"string", open_string},
		{"table", open_table},
		{"utf8", open_utf8},
	}
} else {
	@(private = "file")
	stdlibs := []Reg {
		{"_G", open_base},
		{"package", open_package},
		{"coroutine", open_coroutine},
		{"debug", open_debug},
		{"io", open_io},
		{"math", open_math},
		{"os", open_os},
		{"string", open_string},
		{"table", open_table},
		{"utf8", open_utf8},
	}
}

// Open every standard library into `L` -- reference `luaL_openlibs` (which in 5.5
// is `luaL_openselectedlibs(L, ~0, 0)`: require them all, preload none). The
// registry's loaded-module table is part of auxlib and does not require the
// package library itself, so this same mechanism works on bare metal.
aux_openlibs :: proc(L: ^kernel.State) {
	for lib in stdlibs {
		aux_requiref(L, lib.name, lib.func, true) // require + set as global
		kernel.api_pop(L, 1) // remove the library table left on the stack
	}
}
