#+build freestanding

package stdlib

// base_freestanding.odin -- the bare-metal registration table for the basic library.
//
// The library itself lives in the untagged `base.odin`; only the table of entries
// differs per target. `print`, `loadfile`, and `dofile` are intentionally absent
// here: bare metal has no standard output and no filesystem. In-memory `load`
// remains available, so chunks can still be compiled from a buffer.
//
// This literal is deliberately spelled out in full rather than derived from a
// shared list plus hosted extras. Registration order determines the order keys are
// inserted into `_G`, and therefore that table's internal node layout and
// `pairs(_G)` iteration order. Lua leaves that unspecified but it is observable,
// so each target owns one explicit, ordered list.

@(private)
base_funcs := []Reg {
	{"assert", base_assert},
	{"collectgarbage", base_collectgarbage},
	{"error", base_error},
	{"getmetatable", base_getmetatable},
	{"ipairs", base_ipairs},
	{"load", base_load},
	{"next", base_next},
	{"pairs", base_pairs},
	{"pcall", base_pcall},
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
