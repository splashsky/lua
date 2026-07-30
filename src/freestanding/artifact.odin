#+build freestanding

package freestanding

// This tiny exported surface gives Odin's object-file backend real roots. With
// no executable entry point, an optimizing build would otherwise prove that the
// whole library is unreachable and emit an almost-empty object. These are also
// useful firmware-facing conveniences: construct a state from the embedder's
// allocator, open exactly the freestanding libraries, and close it again.

import "base:runtime"
import lua "luao:lua"
import stdlib "luao:stdlib"

@(export)
luao_freestanding_newstate :: proc "c" (
	alloc: lua.Alloc_Proc,
	ud: rawptr,
) -> ^lua.Lua_State {
	context = runtime.default_context()
	if alloc == nil {
		return nil
	}
	L := lua.new_state(lua.Allocator{alloc = alloc, ud = ud})
	if L != nil {
		stdlib.luaL_openlibs(L)
	}
	return L
}

@(export)
luao_freestanding_close :: proc "c" (L: ^lua.Lua_State) {
	context = runtime.default_context()
	if L != nil {
		lua.close_state(L)
	}
}
