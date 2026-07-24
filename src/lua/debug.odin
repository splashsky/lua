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

// ---------------------------------------------------------------------------
// Debug hooks -- event codes, masks, and the activation record
// ---------------------------------------------------------------------------
// Reference Lua's lua.h hook constants. A hook is a callback fired on certain
// VM events; the debug library and profilers install one. Until the debug API
// lands (Phase 9) no hook is ever installed, so these drive dead branches -- but
// the call/return machinery references them, so we define them faithfully now.
LUA_HOOKCALL :: 0
LUA_HOOKRET :: 1
LUA_HOOKLINE :: 2
LUA_HOOKCOUNT :: 3
LUA_HOOKTAILCALL :: 4

LUA_MASKCALL :: i32(1) << LUA_HOOKCALL
LUA_MASKRET :: i32(1) << LUA_HOOKRET
LUA_MASKLINE :: i32(1) << LUA_HOOKLINE
LUA_MASKCOUNT :: i32(1) << LUA_HOOKCOUNT

// The activation record handed to a hook / queried by the debug API -- reference
// Lua's `lua_Debug`. We keep the observable fields; `i_ci` identifies the frame by
// index (our model) rather than by pointer. The remaining introspection fields are
// filled in by the debug API in a later phase.
Lua_Debug :: struct {
	event:           i32,
	name:            string,
	namewhat:        string,
	what:            string,
	source:          string,
	currentline:     i32,
	linedefined:     i32,
	lastlinedefined: i32,
	nups:            u8,
	nparams:         u8,
	isvararg:        u8,
	istailcall:      u8,
	ftransfer:       u16,
	ntransfer:       u16,
	short_src:       [LUA_IDSIZE]u8,
	i_ci:            int, // index of the frame this record describes
}

// ---------------------------------------------------------------------------
// Source-line lookup
// ---------------------------------------------------------------------------
// Every Lua error carries a `source:line` prefix, so before we can raise runtime
// errors we need to map a program counter back to a source line. The bytecode
// stores line numbers compactly: `lineinfo` holds a signed per-instruction delta
// from the previous instruction's line, and whenever a delta won't fit in a byte
// (the `ABSLINEINFO` sentinel) the true line is recorded absolutely in the
// `abslineinfo` checkpoint array. To find a line we pick the nearest absolute
// checkpoint at or before the target pc and then walk the deltas forward.

// The index of the instruction currently executing in a Lua frame. Our `savedpc`
// always points at the *next* instruction to run (reference Lua advances it before
// dispatch), so the one being executed is one back -- reference Lua's `currentpc`.
currentpc :: #force_inline proc "contextless" (ci: ^Call_Info) -> int {
	return ci.u.l.savedpc - 1
}

// Find the absolute-line checkpoint to start walking from for instruction `pc`,
// returning that base line and (through `basepc`) the pc it applies to -- reference
// Lua's `getbaseline`. With no absolute info, or a pc before the first checkpoint,
// we start from the function's first line and a `basepc` of -1 (meaning "the line
// of instruction 0 has no preceding delta"). Otherwise we use `pc / MAXIWTHABS - 1`
// as a guaranteed-low estimate of the checkpoint index and nudge it forward.
getbaseline :: proc(f: ^Proto, pc: int) -> (baseline: int, basepc: int) {
	if f.sizeabslineinfo == 0 || pc < f.abslineinfo[0].pc {
		return f.linedefined, -1
	}
	i := pc / MAXIWTHABS - 1 // an estimate that is always a lower bound
	if i < 0 {
		i = 0
	}
	for i + 1 < f.sizeabslineinfo && pc >= f.abslineinfo[i + 1].pc {
		i += 1 // the estimate was low; advance to the real checkpoint
	}
	return f.abslineinfo[i].line, f.abslineinfo[i].pc
}

// The source line for instruction `pc` in prototype `f` -- reference Lua's
// `luaG_getfuncline`. Returns -1 when the prototype carries no line info (a
// stripped chunk). Otherwise walk the per-instruction deltas from the base
// checkpoint up to the target pc.
luaG_getfuncline :: proc(f: ^Proto, pc: int) -> int {
	if f.lineinfo == nil {
		return -1 // debug info was stripped
	}
	baseline, basepc := getbaseline(f, pc)
	bp := basepc
	for bp + 1 <= pc {
		bp += 1
		baseline += int(f.lineinfo[bp]) // each byte is a delta from the prior line
	}
	return baseline
}

// The current source line of a Lua call frame -- reference Lua's `getcurrentline`.
getcurrentline :: proc(L: ^Lua_State, ci: ^Call_Info) -> int {
	return luaG_getfuncline(ci_func(L, ci).p, currentpc(ci))
}

// ---------------------------------------------------------------------------
// Variable-name guessing (minimal placeholder)
// ---------------------------------------------------------------------------
// Reference Lua enriches type errors with the source of the faulty value, e.g.
// "attempt to index a nil value (global 'x')". Recovering that name requires a
// small symbolic execution over the bytecode (`getobjname`/`getupvalname`), which
// lands with the full debug layer later in this phase. Until then `varinfo`
// returns the empty string, so messages are still *truthful* -- just without the
// parenthetical hint. Nothing depends on the hint being present.
varinfo :: proc(L: ^Lua_State, o: ^TValue) -> string {
	return ""
}

// ---------------------------------------------------------------------------
// Error raisers
// ---------------------------------------------------------------------------
// These build a message, prepend `source:line` when the erroring frame is Lua
// code, and then longjmp out through the active protected boundary. They never
// return (they are our `l_noret` analogues), so callers can treat them as
// diverging. `throw` is our setjmp/longjmp `luaD_throw`.

// The shared type-error core -- reference Lua's static `typeerror`. `op` is the
// verb ("index", "call", "perform arithmetic on", ...) and `extra` is the trailing
// variable-info hint (possibly empty).
typeerror :: proc(L: ^Lua_State, o: ^TValue, op: string, extra: string) {
	t := luaT_objtypename(L, o)
	luaG_runerror(L, "attempt to %s a %s value%s", op, t, extra)
}

// A type error with standard variable info about the faulty object -- reference
// Lua's `luaG_typeerror`.
luaG_typeerror :: proc(L: ^Lua_State, o: ^TValue, op: string) {
	typeerror(L, o, op, varinfo(L, o))
}

// Calling a non-callable object -- reference Lua's `luaG_callerror`. (Name-from-
// call recovery is deferred with the rest of name guessing; we fall back to
// `varinfo`, which is currently empty.)
luaG_callerror :: proc(L: ^Lua_State, o: ^TValue) {
	typeerror(L, o, "call", varinfo(L, o))
}

// A `for` loop given a non-number control value -- reference Lua's `luaG_forerror`.
luaG_forerror :: proc(L: ^Lua_State, o: ^TValue, what: string) {
	luaG_runerror(L, "bad 'for' %s (number expected, got %s)", what, luaT_objtypename(L, o))
}

// Concatenation of a non-concatenable value -- reference Lua's `luaG_concaterror`.
// Whichever operand is *not* a string/number is the offender. (`cvt2str` in the
// reference is simply "is a number".)
luaG_concaterror :: proc(L: ^Lua_State, p1: ^TValue, p2: ^TValue) {
	bad := p1
	if base_type(p1) == TSTRING || is_number(p1) {
		bad = p2
	}
	luaG_typeerror(L, bad, "concatenate")
}

// Arithmetic/bitwise on a non-number -- reference Lua's `luaG_opinterror`. The
// first non-number operand is the one to blame.
luaG_opinterror :: proc(L: ^Lua_State, p1: ^TValue, p2: ^TValue, msg: string) {
	bad := p2
	if !is_number(p1) {
		bad = p1
	}
	luaG_typeerror(L, bad, msg)
}

// Both operands are numbers but at least one has no integer representation --
// reference Lua's `luaG_tointerror`.
luaG_tointerror :: proc(L: ^Lua_State, p1: ^TValue, p2: ^TValue) {
	bad := p2
	if _, ok := to_integer_no_string(p1, .Floor); !ok {
		bad = p1
	}
	luaG_runerror(L, "number%s has no integer representation", varinfo(L, bad))
}

// Comparison between incompatible types -- reference Lua's `luaG_ordererror`.
luaG_ordererror :: proc(L: ^Lua_State, p1: ^TValue, p2: ^TValue) {
	t1 := luaT_objtypename(L, p1)
	t2 := luaT_objtypename(L, p2)
	if t1 == t2 {
		luaG_runerror(L, "attempt to compare two %s values", t1)
	} else {
		luaG_runerror(L, "attempt to compare %s with %s", t1, t2)
	}
}

// Deliver the error object at the top of the stack to the active boundary --
// reference Lua's `luaG_errormsg`. If a message handler (`errfunc`) is installed
// it is called first, with the error object as its single argument, and its result
// replaces the object. A nil error object becomes the literal "<no error object>".
// Finally we longjmp with LUA_ERRRUN (our `.Err_Run`).
luaG_errormsg :: proc(L: ^Lua_State) {
	if L.errfunc != 0 {
		// Push the handler below the argument and call it: [handler][errobj].
		errfunc := L.errfunc
		set_obj(stack_value(L, L.top), stack_value(L, L.top - 1)) // duplicate arg up
		set_obj(stack_value(L, L.top - 1), stack_value(L, errfunc)) // handler underneath
		L.top += 1 // EXTRA_STACK guarantees room
		luaD_callnoyield(L, L.top - 2, 1)
	}
	if is_nil(stack_value(L, L.top - 1)) {
		set_string(stack_value(L, L.top - 1), luaS_new(L, "<no error object>"))
	}
	throw(L, .Err_Run)
}

// Raise a runtime error with a printf-style formatted message -- reference Lua's
// `luaG_runerror`. When the erroring frame is Lua code we prepend `source:line`
// and drop the raw message, mirroring the reference exactly. (Reference also paces
// the GC here via `luaC_checkGC`; that stepping arrives with the full collector in
// Phase 7, so we omit it for now -- it has no bearing on the error's observable
// behavior.)
luaG_runerror :: proc(L: ^Lua_State, fmt: string, args: ..any) {
	ci := &L.frames[L.ci]
	msg := luaO_pushfstring(L, fmt, ..args)
	if is_lua_frame(ci) {
		// Decorate with position, then collapse the two top slots into one.
		luaG_addinfo(L, string(str_slice(msg)), ci_func(L, ci).p.source, getcurrentline(L, ci))
		set_obj(stack_value(L, L.top - 2), stack_value(L, L.top - 1))
		L.top -= 1
	}
	luaG_errormsg(L)
}

// Raise the "global already defined" error for a repeated `<const>`/global
// definition -- reference Lua's `luaG_errnnil`. The offending name is the string
// constant at `K[k-1]` (reference reads it via `kname`); when `k == 0` the name is
// unknown and reported as "?".
luaG_errnnil :: proc(L: ^Lua_State, cl: ^LClosure, k: int) {
	globalname := "?"
	if k > 0 {
		o := &cl.p.k[k - 1]
		if base_type(o) == TSTRING {
			globalname = string(str_slice(str_value(o)))
		}
	}
	luaG_runerror(L, "global '%s' already defined", globalname)
}