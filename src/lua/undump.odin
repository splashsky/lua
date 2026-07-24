package lua

// undump.odin -- our analogue of reference Lua's `lundump.h` / `lundump.c`.
//
// The bytecode loader: the exact inverse of `dump`. It reads a precompiled chunk
// (via ZIO), validates the header against our ABI configuration -- rejecting
// incompatible chunks precisely as reference Lua does -- and reconstructs the
// `Proto` tree. Because loading untrusted bytecode is a real hazard, the
// validation here is a correctness *and* safety matter.
//
// TODO(phase-8): header verification, and recursive deserialization of Proto,
// constants, upvalues, and debug info, with strict format checks.

// luaU_undump reconstructs a `Proto` tree from a precompiled (binary) chunk read
// through `z`, returning the top-level closure -- reference Lua's `luaU_undump`.
// `fixed` marks strings that should be pinned (loaded from a read-only image).
//
// The full deserializer is Phase 8's deliverable. It already has a real call site
// though: `lua_load` (via `luaD_protectedparser`) dispatches here the moment a
// chunk begins with the `LUA_SIGNATURE` escape byte. Until Phase 8 lands the body,
// we raise a truthful syntax error rather than silently mis-loading bytes -- the
// control flow is faithful, only the implementation is deferred.
luaU_undump :: proc(L: ^Lua_State, z: ^Zio, name: string, fixed: bool) -> ^LClosure {
	luaG_runerror(L, "binary chunk loading is not implemented yet (phase 8)")
	return nil // unreachable: luaG_runerror never returns
}
