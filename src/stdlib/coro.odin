package stdlib

// coro.odin -- our analogue of reference Lua's `lcorolib.c`.
//
// The coroutine library: create/resume/yield/status/wrap/isyieldable/running/
// close. It's a thin surface over the kernel's coroutine machinery -- but that
// machinery is only faithful because the VM uses an explicit frame stack it can
// suspend and resume (see docs/ARCHITECTURE.md, Decision 2). Every function here
// is a direct port of its reference counterpart, so the observable semantics
// (result multiplicity, the true/false + error convention of resume, the raising
// wrapper produced by coroutine.wrap) match PUC-Rio exactly.

import "base:runtime"
import lua "luao:lua"

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.State {
	return (^lua.State)(Lp)
}

// Fetch the thread argument at slot 1, raising the standard "thread expected"
// argument error if it isn't one. Reference `getco`.
@(private = "file")
getco :: proc(L: ^lua.State) -> ^lua.State {
	co := lua.api_tothread(L, 1)
	aux_argexpected(L, co != nil, 1, "thread")
	return co
}

// Resume coroutine `co` with `narg` arguments already on `L`'s stack. Returns the
// number of results moved back onto `L`, or -1 to signal an error (with the error
// object / message left on top of `L`). Reference `auxresume`.
@(private = "file")
auxresume :: proc(L: ^lua.State, co: ^lua.State, narg: int) -> int {
	if !lua.api_checkstack(co, narg) {
		lua.api_pushstring(L, "too many arguments to resume")
		return -1 // error flag
	}
	lua.api_xmove(L, co, narg)
	status, nres := lua.api_resume(co, L, narg)
	if status == .Ok || status == .Yield {
		if !lua.api_checkstack(L, nres + 1) {
			lua.api_pop(co, nres) // remove results anyway
			lua.api_pushstring(L, "too many results to resume")
			return -1 // error flag
		}
		lua.api_xmove(co, L, nres) // move yielded values across
		return nres
	}
	lua.api_xmove(co, L, 1) // move the error message across
	return -1 // error flag
}

// coroutine.resume(co, ...) -> true, ... | false, errobj. Reference `luaB_coresume`.
@(private = "file")
co_resume :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	co := getco(L)
	r := auxresume(L, co, lua.api_gettop(L) - 1)
	if r < 0 {
		// Prepend `false` so the caller sees `false, <error>`.
		lua.api_pushboolean(L, false)
		lua.api_insert(L, -2)
		return 2
	}
	// Prepend `true` before the r yielded/returned values.
	lua.api_pushboolean(L, true)
	lua.api_insert(L, -(r + 1))
	return i32(r) + 1
}

// The closure body produced by coroutine.wrap: resume the captured coroutine and,
// on error, re-raise it in the caller (rather than returning false). Reference
// `luaB_auxwrap`.
@(private = "file")
co_auxwrap :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	co := lua.api_tothread(L, lua.upvalueindex(1))
	r := auxresume(L, co, lua.api_gettop(L))
	if r < 0 { // error?
		stat := lua.api_status(co)
		if stat != .Ok && stat != .Yield { // error inside the coroutine?
			stat = lua.api_closethread(co, L) // close its to-be-closed variables
			lua.api_xmove(co, L, 1) // move the error message to the caller
		}
		if stat != .Err_Mem && lua.api_type(L, -1) == lua.TSTRING {
			// Attach position information to a string error, like a normal error().
			aux_where(L, 1)
			lua.api_insert(L, -2)
			lua.api_concat(L, 2)
		}
		lua.api_error(L) // propagate (diverges)
	}
	return i32(r)
}

// The shared body of create/wrap: type-check the function argument, spawn a new
// thread, and move the function onto it. Reference `luaB_cocreate` factored out so
// `co_wrap` can reuse it without calling a `proc "c"` reentrantly.
@(private = "file")
do_cocreate :: proc(L: ^lua.State) {
	aux_checktype(L, 1, lua.TFUNCTION)
	NL := lua.api_newthread(L)
	lua.api_pushvalue(L, 1) // move the function to the top ...
	lua.api_xmove(L, NL, 1) // ... then onto the new thread
}

// coroutine.create(f) -> a new suspended coroutine. Reference `luaB_cocreate`.
@(private = "file")
co_create :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	do_cocreate(state(Lp))
	return 1
}

// coroutine.wrap(f) -> a function that resumes the coroutine and re-raises errors.
// Reference `luaB_cowrap`.
@(private = "file")
co_wrap :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	do_cocreate(L)
	lua.api_pushcclosure(L, co_auxwrap, 1) // capture the coroutine as upvalue #1
	return 1
}

// coroutine.yield(...) -> suspends the running coroutine. Reference `luaB_yield`.
@(private = "file")
co_yield :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return lua.api_yield(L, lua.api_gettop(L))
}

// The internal status codes, indexing `statname`. Reference COS_* macros.
@(private = "file")
COS_RUN :: 0
@(private = "file")
COS_DEAD :: 1
@(private = "file")
COS_YIELD :: 2
@(private = "file")
COS_NORM :: 3

@(private = "file")
statname := []string{"running", "dead", "suspended", "normal"}

// Classify a coroutine relative to the current thread. Reference `auxstatus`.
@(private = "file")
auxstatus :: proc(L: ^lua.State, co: ^lua.State) -> int {
	if L == co {
		return COS_RUN // the running coroutine is asking about itself
	}
	#partial switch lua.api_status(co) {
	case .Yield:
		return COS_YIELD
	case .Ok:
		// A status of OK is ambiguous: it may be actively running (has frames),
		// finished (no frames, empty stack), or freshly created but never resumed
		// (no frames, but its function still sits on the stack).
		ar: lua.Debug_Info
		if lua.api_getstack(co, 0, &ar) {
			return COS_NORM
		} else if lua.api_gettop(co) == 0 {
			return COS_DEAD
		} else {
			return COS_YIELD
		}
	case:
		return COS_DEAD // any error status leaves the coroutine unusable
	}
}

// coroutine.status(co) -> "running"|"suspended"|"normal"|"dead". Reference
// `luaB_costatus`.
@(private = "file")
co_status :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	co := getco(L)
	lua.api_pushstring(L, statname[auxstatus(L, co)])
	return 1
}

// Coroutine argument that defaults to the current thread when omitted. Reference
// `getoptco`.
@(private = "file")
getoptco :: proc(L: ^lua.State) -> ^lua.State {
	return lua.api_isnone(L, 1) ? L : getco(L)
}

// coroutine.isyieldable([co]) -> can this coroutine yield right now? Reference
// `luaB_yieldable`.
@(private = "file")
co_yieldable :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	co := getoptco(L)
	lua.api_pushboolean(L, lua.api_isyieldable(co))
	return 1
}

// coroutine.running() -> the running coroutine plus whether it is the main thread.
// Reference `luaB_corunning`.
@(private = "file")
co_running :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	ismain := lua.api_pushthread(L)
	lua.api_pushboolean(L, ismain)
	return 2
}

// coroutine.close([co]) -> close a dead or suspended coroutine, running its to-be-
// closed variables. Reference `luaB_close`.
@(private = "file")
co_close :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	co := getoptco(L)
	status := auxstatus(L, co)
	switch status {
	case COS_DEAD, COS_YIELD:
		st := lua.api_closethread(co, L)
		if st == .Ok {
			lua.api_pushboolean(L, true)
			return 1
		}
		lua.api_pushboolean(L, false)
		lua.api_xmove(co, L, 1) // move the error message across
		return 2
	case COS_NORM:
		aux_error(L, "cannot close a %s coroutine", statname[status])
	case COS_RUN:
		// A coroutine may only close itself; the main thread never can.
		lua.api_geti(L, lua.REGISTRYINDEX, lua.RIDX_MAINTHREAD)
		if lua.api_tothread(L, -1) == co {
			aux_error(L, "cannot close main thread")
		}
		lua.api_closethread(co, L) // close itself
	}
	return 0
}

@(private = "file")
co_funcs := []Reg {
	{"create", co_create},
	{"resume", co_resume},
	{"running", co_running},
	{"status", co_status},
	{"wrap", co_wrap},
	{"yield", co_yield},
	{"isyieldable", co_yieldable},
	{"close", co_close},
}

// `luaopen_coroutine` -- build and return the coroutine table.
open_coroutine :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, co_funcs)
	return 1
}
