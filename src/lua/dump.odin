package lua

// dump.odin -- our analogue of reference Lua's `ldump.c`.
//
// The bytecode serializer: turns a compiled `Proto` (and its nested protos,
// constants, upvalues, and debug info) into the precompiled-chunk byte stream
// that `luac` writes and that `undump` reads back.
//
// Byte-exactness is a project goal, so this targets one fixed ABI configuration
// (little-endian, 32-bit Instruction/int, 64-bit integer, IEEE-754 binary64) and
// serializes the C-defined layout *explicitly*, preserving floating-point bit
// patterns rather than re-encoding numerically (see docs/ARCHITECTURE.md,
// Decision 5).
//
// TODO(phase-8): the header writer, and recursive serialization of Proto,
// constants, upvalues, and (optionally stripped) debug info.

// The sink a `lua_dump` caller supplies -- reference Lua's `lua_Writer`. It is
// handed each chunk of serialized bytes and returns 0 on success or a non-zero
// status to abort the dump. `context = runtime.default_context()` is the caller's
// responsibility inside the callback (it is a "c" proc so it works from host code).
Lua_Writer :: #type proc "c" (L: rawptr, p: rawptr, sz: uint, ud: rawptr) -> i32

// luaU_dump serializes prototype `f` (and everything it references) through the
// `writer` sink -- reference Lua's `luaU_dump`. `strip` drops debug info. Returns
// the writer's last status (0 == success).
//
// Like `luaU_undump`, the real serializer is Phase 8's deliverable; the call site
// (`lua_dump`) is already wired. Until then we raise a truthful error rather than
// emit a bogus stream.
luaU_dump :: proc(L: ^Lua_State, f: ^Proto, writer: Lua_Writer, data: rawptr, strip: bool) -> i32 {
	luaG_runerror(L, "bytecode dumping is not implemented yet (phase 8)")
	return 0 // unreachable: luaG_runerror never returns
}
