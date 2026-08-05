#+build !freestanding

package stdlib

// base_hosted.odin -- the parts of the basic library that need an OS.
//
// `print`, `loadfile`, and `dofile` are the only three entries of reference
// `lbaselib.c` that cannot exist on bare metal: two need a filesystem and one
// needs standard output. They live here so the other twenty entries -- and all of
// the shared machinery behind `load` -- exist exactly once, in the untagged
// `base.odin`.
//
// The registration table itself is deliberately duplicated between this file and
// `base_freestanding.odin` rather than being assembled from a shared list plus
// per-target extras. Registration order determines the order keys are inserted
// into `_G`, which determines that table's internal node layout and hence
// `pairs(_G)` iteration order. Lua leaves that order unspecified, but it is
// observable, and keeping the hosted list in one literal keeps the hosted build --
// the one the PUC-Rio suite validates -- byte-for-byte unchanged.

import "base:runtime"
import kernel "lang:kernel"
import stream "lang:stream"

// Write bytes to the stdout object shared with io.*.
@(private = "file")
write_stdout :: proc(s: string) {
	if len(s) > 0 {
		stream.write(stream.stdout(), transmute([]u8)s)
	}
}

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

base_loadfile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	fname := aux_optstring(L, 1, "")
	mode := getMode(L, 2)
	env := !kernel.api_isnone(L, 3) ? 3 : 0
	status := aux_loadfilex(L, fname, mode)
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

// The base-library registration table -- reference `base_funcs`. `_G`/`_VERSION`
// are placeholders (nil func) filled in by `luaopen_base`.
@(private)
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
