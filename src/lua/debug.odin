package lua

// debug.odin -- our analogue of reference Lua's `ldebug.h` / `ldebug.c`.
//
// The reflection and diagnostics layer: mapping instructions back to source
// lines, producing the runtime error messages (with variable-name guessing),
// building tracebacks, and driving the debug hooks (call/return/line/count) that
// the debug library and profilers rely on.
//
// TODO(phase-5): line-info lookup, symbolic execution for names, traceback
// building, and hook dispatch. What exists now is the piece the lexer needs.

// luaG_addinfo prefixes a raw error message with its source position, producing the
// familiar `chunkname:line: message` string Lua shows for syntax and runtime
// errors. Reference Lua's `luaG_addinfo`. The lexer calls this to decorate its
// messages before raising. When there is no source (an unnamed chunk), Lua uses a
// bare "?" in place of the chunk id.
luaG_addinfo :: proc(L: ^Lua_State, msg: string, src: ^TString, line: int) -> ^TString {
	buff: [LUA_IDSIZE]u8
	idstr: string
	if src != nil {
		w := luaO_chunkid(buff[:], string(str_slice(src)))
		idstr = string(buff[:w])
	} else {
		idstr = "?"
	}
	return luaO_pushfstring(L, "%s:%d: %s", idstr, line, msg)
}
