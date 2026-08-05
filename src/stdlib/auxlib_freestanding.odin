#+build freestanding

package stdlib

// auxlib_freestanding.odin -- the bare-metal half of the auxiliary library.
//
// Freestanding keeps the auxiliary API that is meaningful without an OS; the
// target-independent bulk of it lives in `auxlib.odin`, which carries no build
// tag and is shared with hosted builds. File loading, `luaL_newstate`, the
// process/file result reporters, and the stderr warning system are hosted-only
// and live in `auxlib_hosted.odin`; an embedder creates a state with
// `kernel.new_state` and its own allocator instead.
//
// Only `aux_makeseed` appears here, because it is the one routine that is not
// simply absent on bare metal -- it needs a genuinely different implementation.

import kernel "lang:kernel"

// `luaL_makeseed` -- reference Lua's seed generator, which mixes a stack address
// with the wall clock and folds the result to an unsigned 32-bit value. There is
// no required clock source on bare metal, so we mix address entropy only. That
// preserves the reference routine's actual contract ("some unpredictable unsigned
// int", not "these exact bytes") without inventing a platform hook. On fixed-
// address firmware the result is deterministic, which is still fully correct.
aux_makeseed :: proc(L: ^kernel.State) -> u32 {
	local: int
	mixed := u64(uintptr(L)) ~ u64(uintptr(&local))
	mixed *= 0x9E3779B97F4A7C15 // golden-ratio odd multiplier
	return u32(mixed) ~ u32(mixed >> 32)
}
