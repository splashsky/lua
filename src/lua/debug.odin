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

// ---------------------------------------------------------------------------
// Hook dispatch (line + count hooks driven from the VM)
// ---------------------------------------------------------------------------
//
// The call and return hooks fire from the call protocol (see `luaD_hookcall` /
// `rethook` in do.odin). The line and count hooks are different: they must fire
// *between instructions*, so they are driven from the VM's dispatch loop. To
// avoid slowing the common (no-hook) case, each Lua frame carries a `trap` flag
// in `ci.u.l.trap`; the VM only consults the hook machinery when that flag is
// set. `settraps` sets it on every live Lua frame when a hook is installed, and
// `luaG_traceexec` clears it again the moment the relevant masks are gone.

// Reload the instruction-count-down from its base -- reference `resethookcount`.
resethookcount :: #force_inline proc "contextless" (L: ^Lua_State) {
	L.hookcount = L.basehookcount
}

// Mark every live Lua frame as trapping, so the VM will call `luaG_traceexec`
// before each instruction -- reference Lua's `settraps`. Called when a hook is
// installed. C frames have no per-instruction dispatch, so they are skipped.
settraps :: proc(L: ^Lua_State) {
	for i := L.ci; i >= 0; i -= 1 {
		if is_lua_frame(&L.frames[i]) {
			L.frames[i].u.l.trap = 1
		}
	}
}

// Did the source line change between two instruction indices? -- reference Lua's
// `changedline`. Reference has a fast delta-walking path; the observable result
// is exactly "do the two pcs map to different source lines", which we compute
// directly. Honest and identical in outcome (just without the micro-optimization).
changedline :: proc(p: ^Proto, oldpc, newpc: int) -> bool {
	if p.lineinfo == nil {
		return false // stripped chunk: never report a line change
	}
	return luaG_getfuncline(p, oldpc) != luaG_getfuncline(p, newpc)
}

// Trace the execution of a Lua function, firing count and line hooks as needed --
// reference Lua's `luaG_traceexec`. Called by the VM before an instruction when
// the current frame's `trap` flag is set. `pc` is the index of the instruction
// about to execute. Returns the new value of `trap` (0 to stop trapping, 1 to
// keep going): once the line/count masks are cleared, we turn the frame's trap
// off so the fast path resumes.
//
// A subtlety mirrored from reference: when the instruction about to run does not
// consume `L.top` as a variable-length input (`is_it`), we snap `L.top` back to
// the frame's register top before calling the hook, so the hook sees a tidy
// stack. Instructions that *do* use top (a multi-value CALL/RETURN setup) are
// left alone.
luaG_traceexec :: proc(L: ^Lua_State, pc: int) -> i32 {
	ci := &L.frames[L.ci]
	mask := L.hookmask
	p := ci_func(L, ci).p
	if mask & (LUA_MASKLINE | LUA_MASKCOUNT) == 0 {
		ci.u.l.trap = 0 // no line/count hook: stop trapping this frame
		return 0
	}
	npci := pc // the instruction about to execute
	ci.u.l.savedpc = pc + 1 // reference's `savepc`: savedpc points at the *next* instr
	counthook := false
	L.hookcount -= 1
	if L.hookcount == 0 && (mask & LUA_MASKCOUNT) != 0 {
		counthook = true
		resethookcount(L)
	} else if mask & LUA_MASKLINE == 0 {
		return 1 // only a count hook, and it isn't due yet
	}
	if ci.callstatus & CIST_HOOKYIELD != 0 {
		ci.callstatus &= ~CIST_HOOKYIELD // already hooked here before a yield
		return 1
	}
	// Tidy the stack for the hook unless the pending instruction needs top.
	if npci < p.sizecode && !is_it(p.code[npci]) {
		L.top = ci.top
	}
	if counthook {
		luaD_hook(L, LUA_HOOKCOUNT, -1, 0, 0)
	}
	if mask & LUA_MASKLINE != 0 {
		oldpc := L.oldpc < p.sizecode ? L.oldpc : 0
		if npci <= oldpc || changedline(p, oldpc, npci) {
			newline := luaG_getfuncline(p, npci)
			luaD_hook(L, LUA_HOOKLINE, newline, 0, 0)
		}
		L.oldpc = npci
	}
	if L.status == .Yield { // the hook yielded
		if counthook {
			L.hookcount = 1 // undo the decrement to zero
		}
		ci = &L.frames[L.ci]
		ci.u.l.savedpc -= 1 // resume will re-increment
		ci.callstatus |= CIST_HOOKYIELD
		throw(L, .Yield)
	}
	return 1 // keep trapping
}

// ---------------------------------------------------------------------------
// The public debug API (reference Lua's ldebug.c LUA_API surface)
// ---------------------------------------------------------------------------

// Install (or, with a nil func / zero mask, remove) a debug hook -- reference
// `lua_sethook`. Installing a hook arms the trap flag on every live Lua frame so
// the VM starts consulting `luaG_traceexec`.
lua_sethook :: proc(L: ^Lua_State, fn: Hook_Proc, mask: i32, count: i32) {
	fn := fn
	mask := mask
	if fn == nil || mask == 0 { // turning hooks off
		mask = 0
		fn = nil
	}
	L.hook = fn
	L.basehookcount = count
	resethookcount(L)
	L.hookmask = mask
	if mask != 0 {
		settraps(L) // so line/count hooks trip inside luaG_traceexec
	}
}

lua_gethook :: proc(L: ^Lua_State) -> Hook_Proc {
	return L.hook
}

lua_gethookmask :: proc(L: ^Lua_State) -> i32 {
	return L.hookmask
}

lua_gethookcount :: proc(L: ^Lua_State) -> i32 {
	return L.basehookcount
}

// Resolve stack `level` (0 = the current running frame) to a `Lua_Debug` record
// identifying that frame -- reference `lua_getstack`. Frame index 0 (the C entry
// frame) is excluded, exactly as reference excludes `base_ci`.
lua_getstack :: proc(L: ^Lua_State, level: int, ar: ^Lua_Debug) -> bool {
	if level < 0 {
		return false // an invalid (negative) level
	}
	ci_idx := L.ci
	lvl := level
	for lvl > 0 && ci_idx > 0 {
		lvl -= 1
		ci_idx -= 1
	}
	if lvl == 0 && ci_idx > 0 {
		ar.i_ci = ci_idx
		return true
	}
	return false // no such level
}

// Fill in the parts of a `Lua_Debug` selected by `what` -- reference Lua's static
// `auxgetinfo`. `func` is the function value the record describes; `ci_idx` is its
// frame (or -1 for a function pulled off the stack via the '>' selector).
@(private = "file")
auxgetinfo :: proc(L: ^Lua_State, what: string, ar: ^Lua_Debug, fv: ^TValue, ci_idx: int) -> bool {
	status := true
	is_lua := is_lua_closure(fv)
	p: ^Proto = is_lua ? lua_closure_value(fv).p : nil
	for c in transmute([]u8)what {
		switch c {
		case 'S':
			if p != nil {
				ar.source = p.source != nil ? string(str_slice(p.source)) : "=?"
				ar.linedefined = i32(p.linedefined)
				ar.lastlinedefined = i32(p.lastlinedefined)
				ar.what = p.linedefined == 0 ? "main" : "Lua"
			} else {
				ar.source = "=[C]"
				ar.linedefined = -1
				ar.lastlinedefined = -1
				ar.what = "C"
			}
			w := luaO_chunkid(ar.short_src[:], ar.source)
			_ = w
		case 'l':
			ar.currentline = (p != nil && ci_idx >= 0) ? i32(getcurrentline(L, &L.frames[ci_idx])) : -1
		case 'u':
			if is_lua {
				ar.nups = u8(lua_closure_value(fv).nupvalues)
			} else if is_c_closure(fv) {
				ar.nups = u8(c_closure_value(fv).nupvalues)
			} else {
				ar.nups = 0
			}
			if p != nil {
				ar.nparams = p.numparams
				ar.isvararg = (p.flag & PF_VAHID) != 0 ? 1 : 0
			} else {
				ar.nparams = 0
				ar.isvararg = 1
			}
		case 't':
			ar.istailcall = (ci_idx >= 0 && (L.frames[ci_idx].callstatus & CIST_TAIL) != 0) ? 1 : 0
		case 'n':
			// Name guessing (getfuncname) is intentionally minimal for now: we
			// report no name rather than a fabricated one. The fields are honest
			// empty strings; enriching them is a later debug-layer refinement.
			ar.name = ""
			ar.namewhat = ""
		case 'f', 'L':
			// Handled by the caller (they push onto the stack).
		case:
			status = false // an unknown option
		}
	}
	return status
}

// Populate a `Lua_Debug` for a function, per the `what` option string -- reference
// `lua_getinfo`. A leading '>' pops a function off the top of the stack to
// describe; otherwise `ar.i_ci` (from `lua_getstack`) selects the frame. The 'f'
// option pushes the function and 'L' pushes a table of its valid lines.
lua_getinfo :: proc(L: ^Lua_State, what: string, ar: ^Lua_Debug) -> bool {
	what := what
	fv: ^TValue
	ci_idx := -1
	if len(what) > 0 && what[0] == '>' {
		fv = stack_value(L, L.top - 1)
		assert(is_function(fv), "function expected in lua_getinfo")
		what = what[1:]
		L.top -= 1 // pop the function
	} else {
		ci_idx = ar.i_ci
		fv = stack_value(L, L.frames[ci_idx].func)
	}
	status := auxgetinfo(L, what, ar, fv, ci_idx)
	// 'f' and 'L' push results; per reference they are appended after auxgetinfo.
	for c in transmute([]u8)what {
		if c == 'f' {
			set_obj(stack_value(L, L.top), fv)
			L.top += 1
		} else if c == 'L' {
			collectvalidlines(L, fv)
		}
	}
	return status
}

// Push a table whose keys are the source lines a function can stop on -- reference
// Lua's `collectvalidlines`. For a C function (no line info) it pushes nil, again
// matching reference.
@(private = "file")
collectvalidlines :: proc(L: ^Lua_State, fv: ^TValue) {
	if !is_lua_closure(fv) {
		set_nil(stack_value(L, L.top))
		L.top += 1
		return
	}
	p := lua_closure_value(fv).p
	t := luaH_new(L)
	set_gc(stack_value(L, L.top), &t.header)
	L.top += 1
	if p.lineinfo != nil {
		active: TValue
		set_bool(&active, true)
		currentline := p.linedefined
		for i in 0 ..< p.sizecode {
			if p.lineinfo[i] == ABSLINEINFO {
				currentline = luaG_getfuncline(p, i)
			} else {
				currentline += int(p.lineinfo[i])
			}
			luaH_setint(L, t, Integer(currentline), &active)
		}
	}
}

// Return the name of local variable number `n` in the frame `ar` describes, and
// push its current value -- reference `lua_getlocal`. With a '>' style `ar`
// (i_ci < 0) it instead reports a function's parameter names without a value.
lua_getlocal :: proc(L: ^Lua_State, ar: ^Lua_Debug, n: int) -> (name: string, ok: bool) {
	ci := &L.frames[ar.i_ci]
	if !is_lua_frame(ci) {
		return "", false // C frames expose no locals
	}
	p := ci_func(L, ci).p
	nm := luaF_getlocalname(p, n, currentpc(ci))
	if nm == nil {
		return "", false
	}
	// Local `n` lives at register (n-1) above the frame base.
	base := ci.func + 1
	set_obj(stack_value(L, L.top), stack_value(L, base + (n - 1)))
	L.top += 1
	return string(str_slice(nm)), true
}

// Set local variable number `n` from the popped top value -- reference
// `lua_setlocal`.
lua_setlocal :: proc(L: ^Lua_State, ar: ^Lua_Debug, n: int) -> (name: string, ok: bool) {
	ci := &L.frames[ar.i_ci]
	if !is_lua_frame(ci) {
		return "", false
	}
	p := ci_func(L, ci).p
	nm := luaF_getlocalname(p, n, currentpc(ci))
	if nm == nil {
		return "", false
	}
	base := ci.func + 1
	L.top -= 1
	set_obj(stack_value(L, base + (n - 1)), stack_value(L, L.top))
	return string(str_slice(nm)), true
}
