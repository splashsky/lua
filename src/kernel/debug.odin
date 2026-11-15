package kernel
import "base:intrinsics"

// debug.odin -- our analogue of reference Lua's `ldebug.h` / `ldebug.c`.
//
// The reflection and diagnostics layer: mapping instructions back to source
// lines, producing the runtime error messages (with variable-name guessing),
// building tracebacks, and driving the debug hooks (call/return/line/count) that
// the debug library and profilers rely on.
//
// All of that is implemented here: line-info lookup, the symbolic execution that
// recovers a name for a value ("local 'x'", "field 'insert'"), traceback building,
// and hook dispatch.

// luaG_addinfo prefixes a raw error message with its source position, producing the
// familiar `chunkname:line: message` string Lua shows for syntax and runtime
// errors. Reference Lua's `luaG_addinfo`. The lexer calls this to decorate its
// messages before raising. When there is no source (an unnamed chunk), Lua uses a
// bare "?" in place of the chunk id.
debug_addinfo :: proc(L: ^State, msg: string, src: ^TString, line: int) -> ^TString {
	// Reference `luaG_addinfo`: with no debug info the source pointer is nil, and
	// BOTH the chunk id and the line render as "?" (a stripped chunk carries no
	// line table, so there is no meaningful number to print -- not even -1).
	if src == nil {
		return object_pushfstring(L, "?:?: %s", msg)
	}
	buff: [IDSIZE]u8
	w := object_chunkid(buff[:], string(str_slice(src)))
	idstr := string(buff[:w])
	return object_pushfstring(L, "%s:%d: %s", idstr, line, msg)
}

// ---------------------------------------------------------------------------
// Debug hooks -- event codes, masks, and the activation record
// ---------------------------------------------------------------------------
// Reference Lua's lua.h hook constants. A hook is a callback fired on certain
// VM events; the debug library and profilers install one. Until the debug API
// lands (Phase 9) no hook is ever installed, so these drive dead branches -- but
// the call/return machinery references them, so we define them faithfully now.
HOOKCALL :: 0
HOOKRET :: 1
HOOKLINE :: 2
HOOKCOUNT :: 3
HOOKTAILCALL :: 4

MASKCALL :: i32(1) << HOOKCALL
MASKRET :: i32(1) << HOOKRET
MASKLINE :: i32(1) << HOOKLINE
MASKCOUNT :: i32(1) << HOOKCOUNT

// The activation record handed to a hook / queried by the debug API -- reference
// Lua's `lua_Debug`. We keep the observable fields; `i_ci` identifies the frame by
// index (our model) rather than by pointer. The remaining introspection fields are
// filled in by the debug API in a later phase.
Debug_Info :: struct {
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
	extraargs:       u8,
	istailcall:      u8,
	ftransfer:       u16,
	ntransfer:       u16,
	short_src:       [IDSIZE]u8,
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
debug_getfuncline :: proc(f: ^Proto, pc: int) -> int {
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
getcurrentline :: proc(L: ^State, ci: ^Call_Info) -> int {
	return debug_getfuncline(ci_func(L, ci).p, currentpc(ci))
}

// ---------------------------------------------------------------------------
// Variable-name guessing (symbolic execution over the bytecode)
// ---------------------------------------------------------------------------
// Lua enriches messages with the *source* of a value, e.g. "attempt to index a
// nil value (global 'x')", and `debug.getinfo(...).name` reports how a function
// was reached ("local 'f'", "method 'x'", "for iterator", ...). Both are best-
// effort: we replay a little of the calling function's bytecode to discover which
// local/upvalue/constant/field last wrote a register, then read the name out of
// the prototype's debug tables. This is a faithful port of reference Lua's
// `getobjname`/`funcnamefromcode` family (ldebug.c). Everything here is honest --
// when the code cannot prove a name we report none rather than guess.

// The name recorded for upvalue `uv` (or "?" when the prototype carries no debug
// name) -- reference Lua's `upvalname`.
@(private = "file")
dbg_upvalname :: proc(p: ^Proto, uv: int) -> string {
	s := p.upvalues[uv].name
	if s == nil {
		return "?"
	}
	return string(str_slice(s))
}

// A "name" for the constant at index `index`: a string constant names itself and
// is kind "constant"; anything else has no usable name -- reference Lua's `kname`.
// A "" kind means "no reasonable name" (reference's NULL return).
@(private = "file")
dbg_kname :: proc(p: ^Proto, index: int) -> (kind: string, name: string) {
	kv := &p.k[index]
	if base_type(kv) == TSTRING {
		return "constant", string(str_slice(str_value(kv)))
	}
	return "", "?"
}

// A conditional instruction (one reached only by jumping into it) cannot be
// trusted to have set a register on the straight-line path -- reference `filterpc`.
@(private = "file")
dbg_filterpc :: proc(pc: int, jmptarget: int) -> int {
	if pc < jmptarget {
		return -1 // inside a jump: we cannot know who set that register
	}
	return pc
}

// Find the last instruction before `lastpc` that wrote register `reg`, ignoring
// writes that are only reached conditionally -- reference Lua's `findsetreg`.
@(private = "file")
dbg_findsetreg :: proc(p: ^Proto, lastpc: int, reg: int) -> int {
	lastpc := lastpc
	setreg := -1 // last instruction that changed `reg`
	jmptarget := 0 // any code before this address is conditional
	if test_mm_mode(get_opcode(p.code[lastpc])) {
		lastpc -= 1 // the MMBIN pseudo-instruction did not really run
	}
	for pc := 0; pc < lastpc; pc += 1 {
		i := p.code[pc]
		op := get_opcode(i)
		a := getarg_A(i)
		change := false // did this instruction change `reg`?
		#partial switch op {
		case .LOADNIL: // sets registers a .. a+b
			b := getarg_B(i)
			change = a <= reg && reg <= a + b
		case .TFORCALL: // clobbers all registers above base+2
			change = reg >= a + 2
		case .CALL, .TAILCALL: // clobber all registers from base up
			change = reg >= a
		case .JMP: // no register change, but it advances `jmptarget`
			b := getarg_sJ(i)
			dest := pc + 1 + b
			if dest <= lastpc && dest > jmptarget {
				jmptarget = dest
			}
		case: // any ordinary instruction that writes A
			change = test_a_mode(op) && reg == a
		}
		if change {
			setreg = dbg_filterpc(pc, jmptarget)
		}
	}
	return setreg
}

// The core name search for register `reg` as of `ppc^`: locals, then a symbolic
// trace through MOVE / GETUPVAL / LOADK -- reference Lua's `basicgetobjname`. On
// success returns a non-empty kind and updates `ppc^` to the defining pc; a ""
// kind means "no reasonable name" (reference's NULL).
@(private = "file")
dbg_basicgetobjname :: proc(p: ^Proto, ppc: ^int, reg: int) -> (kind: string, name: string) {
	pc := ppc^
	local := func_getlocalname(p, reg + 1, pc)
	if local != nil { // is it a live local?
		return "local", string(str_slice(local))
	}
	// Otherwise replay the bytecode to find who last wrote the register.
	pc = dbg_findsetreg(p, pc, reg)
	ppc^ = pc
	if pc != -1 {
		i := p.code[pc]
		op := get_opcode(i)
		#partial switch op {
		case .MOVE:
			b := getarg_B(i) // moved from register b into a
			if b < getarg_A(i) {
				return dbg_basicgetobjname(p, ppc, b) // chase the source
			}
		case .GETUPVAL:
			return "upvalue", dbg_upvalname(p, getarg_B(i))
		case .LOADK:
			return dbg_kname(p, getarg_Bx(i))
		case .LOADKX:
			return dbg_kname(p, getarg_Ax(p.code[pc + 1]))
		}
	}
	return "", "" // could not find a reasonable name
}

// A name for the register used as a key `c` -- reference Lua's `rname`. Only a
// constant name is meaningful here; anything else is reported as "?".
@(private = "file")
dbg_rname :: proc(p: ^Proto, pc: int, c: int) -> string {
	pc := pc
	kind, name := dbg_basicgetobjname(p, &pc, c)
	if kind != "constant" {
		return "?"
	}
	return name
}

// Decide whether the table indexed by instruction `i` is the `_ENV` upvalue (making
// the access a global) or an ordinary field -- reference Lua's `isEnv`.
@(private = "file")
dbg_isEnv :: proc(p: ^Proto, pc: int, i: Instruction, isup: bool) -> string {
	t := getarg_B(i) // the table operand
	valid := false
	name := ""
	if isup {
		name = dbg_upvalname(p, t)
		valid = true
	} else {
		pc2 := pc
		kind, nm := dbg_basicgetobjname(p, &pc2, t)
		// The name only counts if the table is itself a local or an upvalue.
		if kind == "local" || kind == "upvalue" {
			name = nm
			valid = true
		}
	}
	if valid && name == ENV_NAME {
		return "global"
	}
	return "field"
}

// Extend `basicgetobjname` to also name values produced by table reads -- reference
// Lua's `getobjname`. Returns ("", "") when no name can be proven.
@(private = "file")
dbg_getobjname :: proc(p: ^Proto, lastpc: int, reg: int) -> (kind: string, name: string) {
	lastpc := lastpc
	kind, name = dbg_basicgetobjname(p, &lastpc, reg)
	if kind != "" {
		return kind, name
	}
	if lastpc != -1 {
		i := p.code[lastpc]
		op := get_opcode(i)
		#partial switch op {
		case .GETTABUP:
			_, nm := dbg_kname(p, getarg_C(i))
			return dbg_isEnv(p, lastpc, i, true), nm
		case .GETTABLE, .GETVARG:
			nm := dbg_rname(p, lastpc, getarg_C(i))
			return dbg_isEnv(p, lastpc, i, false), nm
		case .GETI:
			return "field", "integer index"
		case .GETFIELD:
			_, nm := dbg_kname(p, getarg_C(i))
			return dbg_isEnv(p, lastpc, i, false), nm
		case .SELF:
			_, nm := dbg_kname(p, getarg_C(i))
			return "method", nm
		}
	}
	return "", ""
}

// Name a function from the instruction that called it -- reference Lua's
// `funcnamefromcode`. Direct calls resolve the callee register; instructions that
// dispatch through a metamethod report that metamethod's name. "" kind = none.
@(private = "file")
dbg_funcnamefromcode :: proc(L: ^State, p: ^Proto, pc: int) -> (kind: string, name: string) {
	i := p.code[pc]
	tm := -1
	#partial switch get_opcode(i) {
	case .CALL, .TAILCALL:
		return dbg_getobjname(p, pc, getarg_A(i)) // the function's own name
	case .TFORCALL:
		return "for iterator", "for iterator"
	// The remaining instructions can only "call" through a metamethod.
	case .SELF, .GETTABUP, .GETTABLE, .GETI, .GETFIELD:
		tm = TM_INDEX
	case .SETTABUP, .SETTABLE, .SETI, .SETFIELD:
		tm = TM_NEWINDEX
	case .MMBIN, .MMBINI, .MMBINK:
		tm = getarg_C(i) // the event id is encoded in C
	case .UNM:
		tm = TM_UNM
	case .BNOT:
		tm = TM_BNOT
	case .LEN:
		tm = TM_LEN
	case .CONCAT:
		tm = TM_CONCAT
	case .EQ:
		tm = TM_EQ
	// (no OP_EQI/OP_EQK: those never invoke a metamethod)
	case .LT, .LTI, .GTI:
		tm = TM_LT
	case .LE, .LEI, .GEI:
		tm = TM_LE
	case .CLOSE, .RETURN:
		tm = TM_CLOSE
	case:
		return "", "" // no reasonable name
	}
	// Metamethod names are stored as "__event"; reference skips the "__" prefix.
	return "metamethod", string(str_slice(L.g.tmname[tm]))[2:]
}

// Name a function from how the *calling* frame reached it -- reference Lua's
// `funcnamefromcall`. `ci_idx` is the caller frame. Hooks and finalizers report a
// synthetic name; ordinary Lua callers defer to `funcnamefromcode`.
@(private = "file")
dbg_funcnamefromcall :: proc(L: ^State, ci_idx: int) -> (kind: string, name: string) {
	ci := &L.frames[ci_idx]
	if (ci.callstatus & CIST_HOOKED) != 0 {
		return "hook", "?"
	}
	if (ci.callstatus & CIST_FIN) != 0 {
		return "metamethod", "__gc"
	}
	if is_lua_frame(ci) {
		return dbg_funcnamefromcode(L, ci_func(L, ci).p, currentpc(ci))
	}
	return "", ""
}

// The public name lookup for a described frame -- reference Lua's `getfuncname`.
// A tail-called frame has no caller to inspect, and a function pulled off the stack
// (`ci_idx < 0`) has no frame at all; both yield no name.
@(private = "file")
dbg_getfuncname :: proc(L: ^State, ci_idx: int) -> (kind: string, name: string) {
	if ci_idx <= 0 { // no described frame, or no caller below it
		return "", ""
	}
	if (L.frames[ci_idx].callstatus & CIST_TAIL) != 0 {
		return "", "" // a tail call overwrote its caller: nothing to read
	}
	return dbg_funcnamefromcall(L, ci_idx - 1)
}

// Is `o` one of the current Lua frame's upvalues? If so, name it -- reference
// Lua's `getupvalname`. "" kind means "not an upvalue".
@(private = "file")
dbg_getupvalname :: proc(L: ^State, ci_idx: int, o: ^TValue) -> (kind: string, name: string) {
	c := ci_func(L, &L.frames[ci_idx])
	for k in 0 ..< int(c.nupvalues) {
		if upval_value(closure_upvals(c)[k]) == o {
			return "upvalue", dbg_upvalname(c.p, k)
		}
	}
	return "", ""
}

// Where in the current frame's register window does `o` live, if anywhere? Returns
// the register number, or -1 -- reference Lua's `instack`.
@(private = "file")
dbg_instack :: proc(L: ^State, ci_idx: int, o: ^TValue) -> int {
	ci := &L.frames[ci_idx]
	base := ci.func + 1
	for pos := 0; base + pos < ci.top; pos += 1 {
		if stack_value(L, base + pos) == o {
			return pos
		}
	}
	return -1
}

// Format a "( kind 'name')" hint, or "" when there is no information -- reference
// Lua's `formatvarinfo`.
@(private = "file")
dbg_formatvarinfo :: proc(L: ^State, kind: string, name: string) -> string {
	if kind == "" {
		return ""
	}
	return string(str_slice(object_pushfstring(L, " (%s '%s')", kind, name)))
}

// Build a human description of where value `o` came from ("global 'x'", etc.) to
// append to a type error -- reference Lua's `varinfo`. Best-effort: an upvalue, a
// register traced back to a name, or nothing.
varinfo :: proc(L: ^State, o: ^TValue) -> string {
	ci_idx := L.ci
	kind := ""
	name := ""
	if is_lua_frame(&L.frames[ci_idx]) {
		kind, name = dbg_getupvalname(L, ci_idx, o) // an upvalue?
		if kind == "" { // no: try a register
			reg := dbg_instack(L, ci_idx, o)
			if reg >= 0 {
				kind, name = dbg_getobjname_frame(L, ci_idx, reg)
			}
		}
	}
	return dbg_formatvarinfo(L, kind, name)
}

// A thin wrapper so `varinfo` can call `getobjname` with a frame index (it needs
// the frame's proto and current pc).
@(private = "file")
dbg_getobjname_frame :: proc(L: ^State, ci_idx: int, reg: int) -> (kind: string, name: string) {
	ci := &L.frames[ci_idx]
	return dbg_getobjname(ci_func(L, ci).p, currentpc(ci), reg)
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
typeerror :: proc(L: ^State, o: ^TValue, op: string, extra: string) {
	t := tm_objtypename(L, o)
	debug_runerror(L, "attempt to %s a %s value%s", op, t, extra)
}

// A type error with standard variable info about the faulty object -- reference
// Lua's `luaG_typeerror`.
debug_typeerror :: proc(L: ^State, o: ^TValue, op: string) {
	typeerror(L, o, op, varinfo(L, o))
}

// Calling a non-callable object -- reference Lua's `luaG_callerror`. We first try
// to name the object from *how it was called* (`funcnamefromcall` on the current
// frame): that is what turns a failed `__close`/`__index`/... dispatch into the
// "(metamethod 'close')" hint. Only if that yields nothing do we fall back to the
// generic variable-info recovery.
debug_callerror :: proc(L: ^State, o: ^TValue) {
	kind, name := dbg_funcnamefromcall(L, L.ci)
	extra := kind != "" ? dbg_formatvarinfo(L, kind, name) : varinfo(L, o)
	typeerror(L, o, "call", extra)
}

// A `for` loop given a non-number control value -- reference Lua's `luaG_forerror`.
debug_forerror :: proc(L: ^State, o: ^TValue, what: string) {
	debug_runerror(L, "bad 'for' %s (number expected, got %s)", what, tm_objtypename(L, o))
}

// Concatenation of a non-concatenable value -- reference Lua's `luaG_concaterror`.
// Whichever operand is *not* a string/number is the offender. (`cvt2str` in the
// reference is simply "is a number".)
debug_concaterror :: proc(L: ^State, p1: ^TValue, p2: ^TValue) {
	bad := p1
	if base_type(p1) == TSTRING || is_number(p1) {
		bad = p2
	}
	debug_typeerror(L, bad, "concatenate")
}

// Arithmetic/bitwise on a non-number -- reference Lua's `luaG_opinterror`. The
// first non-number operand is the one to blame.
debug_opinterror :: proc(L: ^State, p1: ^TValue, p2: ^TValue, msg: string) {
	bad := p2
	if !is_number(p1) {
		bad = p1
	}
	debug_typeerror(L, bad, msg)
}

// Both operands are numbers but at least one has no integer representation --
// reference Lua's `luaG_tointerror`.
debug_tointerror :: proc(L: ^State, p1: ^TValue, p2: ^TValue) {
	bad := p2
	// Bitwise operators accept an integral float, but they do not silently floor
	// a fractional one. Re-test with the same exact-conversion rule used by the
	// operation itself; using floor here would make -0.5 look valid and wrongly
	// blame the second operand even though the first conversion actually failed.
	if _, ok := to_integer_no_string(p1, .Eq); !ok {
		bad = p1
	}
	debug_runerror(L, "number%s has no integer representation", varinfo(L, bad))
}

// Comparison between incompatible types -- reference Lua's `luaG_ordererror`.
debug_ordererror :: proc(L: ^State, p1: ^TValue, p2: ^TValue) {
	t1 := tm_objtypename(L, p1)
	t2 := tm_objtypename(L, p2)
	if t1 == t2 {
		debug_runerror(L, "attempt to compare two %s values", t1)
	} else {
		debug_runerror(L, "attempt to compare %s with %s", t1, t2)
	}
}

// Deliver the error object at the top of the stack to the active boundary --
// reference Lua's `luaG_errormsg`. If a message handler (`errfunc`) is installed
// it is called first, with the error object as its single argument, and its result
// replaces the object. A nil error object becomes the literal "<no error object>".
// Finally we longjmp with LUA_ERRRUN (our `.Err_Run`).
debug_errormsg :: proc(L: ^State) {
	if L.errfunc != 0 {
		// Push the handler below the argument and call it: [handler][errobj].
		errfunc := L.errfunc
		set_obj(stack_value(L, L.top), stack_value(L, L.top - 1)) // duplicate arg up
		set_obj(stack_value(L, L.top - 1), stack_value(L, errfunc)) // handler underneath
		L.top += 1 // EXTRA_STACK guarantees room
		do_callnoyield(L, L.top - 2, 1)
	}
	if is_nil(stack_value(L, L.top - 1)) {
		set_string(stack_value(L, L.top - 1), string_new(L, "<no error object>"))
	}
	throw(L, .Err_Run)
}

// Raise a runtime error with a printf-style formatted message -- reference Lua's
// `luaG_runerror`. When the erroring frame is Lua code we prepend `source:line`
// and drop the raw message, mirroring the reference exactly. We also pace the GC
// via `luaC_checkGC` before building the message, as reference does.
debug_runerror :: proc(L: ^State, fmt: string, args: ..any) {
	ci := &L.frames[L.ci]
	gc_checkGC(L) // the error message about to be built uses memory
	msg := object_pushfstring(L, fmt, ..args)
	if is_lua_frame(ci) {
		// Decorate with position, then collapse the two top slots into one.
		debug_addinfo(L, string(str_slice(msg)), ci_func(L, ci).p.source, getcurrentline(L, ci))
		set_obj(stack_value(L, L.top - 2), stack_value(L, L.top - 1))
		L.top -= 1
	}
	debug_errormsg(L)
}

// Raise the "global already defined" error for a repeated `<const>`/global
// definition -- reference Lua's `luaG_errnnil`. The offending name is the string
// constant at `K[k-1]` (reference reads it via `kname`); when `k == 0` the name is
// unknown and reported as "?".
debug_errnnil :: proc(L: ^State, cl: ^LClosure, k: int) {
	globalname := "?"
	if k > 0 {
		o := &cl.p.k[k - 1]
		if base_type(o) == TSTRING {
			globalname = string(str_slice(str_value(o)))
		}
	}
	debug_runerror(L, "global '%s' already defined", globalname)
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
resethookcount :: #force_inline proc "contextless" (L: ^State) {
	L.hookcount = L.basehookcount
}

// Mark every live Lua frame as trapping, so the VM will call `luaG_traceexec`
// before each instruction -- reference Lua's `settraps`. Called when a hook is
// installed or a stack/frame array is relocated. C frames have no per-instruction
// dispatch, so they are skipped.
settraps :: proc(L: ^State) {
	if L.frames == nil { // a thread may be observed while its stack is being built
		return
	}
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
	return debug_getfuncline(p, oldpc) != debug_getfuncline(p, newpc)
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
// Keep this cold path out of the dispatch loop to reduce register pressure.
debug_traceexec :: #force_no_inline proc(L: ^State, pc: int) -> i32 {
	ci := &L.frames[L.ci]
	mask := L.hookmask
	p := ci_func(L, ci).p
	if mask & (MASKLINE | MASKCOUNT) == 0 {
		ci.u.l.trap = 0 // no line/count hook: stop trapping this frame
		return 0
	}
	npci := pc // the instruction about to execute
	ci.u.l.savedpc = pc + 1 // reference's `savepc`: savedpc points at the *next* instr
	// A malformed chunk can reach a reserved encoding while tracing. Reject it
	// before `is_it` indexes the opcode property table, just as dispatch does.
	if npci < p.sizecode && int(get_opcode(p.code[npci])) >= NUM_OPCODES {
		debug_runerror(L, "invalid opcode")
	}
	counthook := false
	L.hookcount -= 1
	if L.hookcount == 0 && (mask & MASKCOUNT) != 0 {
		counthook = true
		resethookcount(L)
	} else if mask & MASKLINE == 0 {
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
		do_hook(L, HOOKCOUNT, -1, 0, 0)
	}
	if mask & MASKLINE != 0 {
		oldpc := L.oldpc < p.sizecode ? L.oldpc : 0
		if npci <= oldpc || changedline(p, oldpc, npci) {
			newline := debug_getfuncline(p, npci)
			do_hook(L, HOOKLINE, newline, 0, 0)
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

// A tiny, cross-thread-safe mailbox for hosted interrupt handlers. In
// particular, a Windows console-control callback runs on a new OS thread: it
// must not call lua_sethook, walk frames, allocate, or otherwise race the VM.
// The owner fills the immutable hook description before arming it; the handler
// publishes `pending` and a global poll hint, and the interpreter thread performs
// the real lua_sethook at the next call, return, or loop back-edge.
Async_Hook_Request :: struct {
	pending: i32,
	hook:    Hook_Proc,
	mask:    i32,
	count:   i32,
}

// The standalone interpreter has one executing main state. Keeping the mailbox
// pointer here avoids changing Lua_State's public/internal ABI merely for hosted
// driver policy. As before, whichever State reaches a poll first consumes the
// currently armed request; the request is not owned by a particular State.
async_hook_request: ^Async_Hook_Request

// A hint, not a replacement for the per-request pending bit: requests for an
// unarmed mailbox must not install the currently armed mailbox's hook. The
// handler stores the mailbox bit first and then publishes this flag. Pollers
// exchange the flag *before* examining the mailbox, so a concurrent publisher
// cannot have its notification erased after the mailbox has been inspected.
async_hook_pending: i32

api_prepare_async_hook :: proc(
	L: ^State,
	request: ^Async_Hook_Request,
	hook: Hook_Proc,
	mask, count: i32,
) {
	request.hook = hook
	request.mask = mask
	request.count = count
	intrinsics.atomic_store(&request.pending, i32(0))
	async_hook_request = request
}

// This is intentionally the only operation an OS handler performs. It is not a
// general Lua API call: both stores are lock-free and signal-handler-safe.
api_request_async_hook :: proc "contextless" (request: ^Async_Hook_Request) {
	intrinsics.atomic_store(&request.pending, i32(1))
	intrinsics.atomic_store(&async_hook_pending, i32(1))
}

api_disarm_async_hook :: proc(L: ^State, request: ^Async_Hook_Request) {
	if async_hook_request == request {
		async_hook_request = nil
	}
	intrinsics.atomic_store(&request.pending, i32(0))
}

// The VM checks the hint before calling this cold path. Clearing it before
// inspecting pending preserves concurrent publications; an extra poll is harmless.
// As in the original mailbox design, hook descriptions and the armed pointer are
// prepared/disarmed by the owning interpreter, not modified by the OS handler.
api_apply_async_hook :: proc(L: ^State) -> bool {
	if intrinsics.atomic_exchange(&async_hook_pending, i32(0)) == 0 {
		return false
	}
	request := async_hook_request
	if request == nil || intrinsics.atomic_load(&request.pending) == 0 {
		return false
	}
	if intrinsics.atomic_exchange(&request.pending, i32(0)) == 0 {
		return false
	}
	api_sethook(L, request.hook, request.mask, request.count)
	return true
}

// Install (or, with a nil func / zero mask, remove) a debug hook -- reference
// `lua_sethook`. Installing a hook arms the trap flag on every live Lua frame so
// the VM starts consulting `luaG_traceexec`.
api_sethook :: proc(L: ^State, fn: Hook_Proc, mask: i32, count: i32) {
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
		settraps(L) // so line/count hooks trip inside debug_traceexec
	}
}

api_gethook :: proc(L: ^State) -> Hook_Proc {
	return L.hook
}

api_gethookmask :: proc(L: ^State) -> i32 {
	return L.hookmask
}

api_gethookcount :: proc(L: ^State) -> i32 {
	return L.basehookcount
}

// Resolve stack `level` (0 = the current running frame) to a `Lua_Debug` record
// identifying that frame -- reference `lua_getstack`. Frame index 0 (the C entry
// frame) is excluded, exactly as reference excludes `base_ci`.
api_getstack :: proc(L: ^State, level: int, ar: ^Debug_Info) -> bool {
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
auxgetinfo :: proc(L: ^State, what: string, ar: ^Debug_Info, fv: ^TValue, ci_idx: int) -> bool {
	status := true
	is_lua := is_lua_closure(fv)
	p: ^Proto = is_lua ? api_closure_value(fv).p : nil
	for c in transmute([]u8)what {
		switch c {
		case 'S':
			if p != nil {
				ar.source = p.source != nil ? string(str_slice(p.source)) : "=?"
				ar.linedefined = i32(p.linedefined)
				ar.lastlinedefined = i32(p.lastlinedefined)
				ar.what = p.linedefined == 0 ? "main" : SOURCE_KIND
			} else {
				ar.source = "=[C]"
				ar.linedefined = -1
				ar.lastlinedefined = -1
				ar.what = "C"
			}
			// `luaO_chunkid` writes `w` bytes but leaves no terminator (its other
			// callers slice by the return value). `short_src`, however, is a fixed
			// array consumed elsewhere as a NUL-terminated C string, and the same
			// `Lua_Debug` record is reused across frames (e.g. in `luaL_traceback`).
			// Without a terminator a short label like "[C]" would show stale bytes
			// from a previous, longer source. `w` is always < LUA_IDSIZE, so there
			// is room to place the NUL.
			w := object_chunkid(ar.short_src[:], ar.source)
			ar.short_src[w] = 0
		case 'l':
			ar.currentline = (p != nil && ci_idx >= 0) ? i32(getcurrentline(L, &L.frames[ci_idx])) : -1
		case 'u':
			if is_lua {
				ar.nups = u8(api_closure_value(fv).nupvalues)
			} else if is_c_closure(fv) {
				ar.nups = u8(c_closure_value(fv).nupvalues)
			} else {
				ar.nups = 0
			}
			if p != nil {
				ar.nparams = p.numparams
				// "isvararg" must cover BOTH vararg models: the hidden-args model
				// (PF_VAHID) and the vararg-table model (PF_VATAB). code.odin clears
				// PF_VAHID when PF_VATAB is set, so testing only PF_VAHID would wrongly
				// report a `(a,b,...t)` function as non-vararg. Reference's `isvararg`
				// checks the union of both flags.
				ar.isvararg = (p.flag & u8(PF_VAHID | PF_VATAB)) != 0 ? 1 : 0
			} else {
				ar.nparams = 0
				ar.isvararg = 1
			}
		case 't':
			ar.istailcall = (ci_idx >= 0 && (L.frames[ci_idx].callstatus & CIST_TAIL) != 0) ? 1 : 0
			// "extraargs" is how many extra arguments a chain of `__call`
			// metamethods injected before this call -- reference stores that count
			// in the CIST_CCMT bits of callstatus (each tryfuncTM bumps it), so we
			// simply decode it back out here.
			if ci_idx >= 0 {
				ar.extraargs = u8((L.frames[ci_idx].callstatus & MAX_CCMT) >> CIST_CCMT)
			} else {
				ar.extraargs = 0
			}
		case 'r':
			// The 'r' option reports the value-transfer window of the call being
			// hooked (which arguments a call received, or which results a return
			// produced). Reference fills it from L->transferinfo, but only when the
			// described frame is actually running a hook (CIST_HOOKED); otherwise
			// there is no meaningful transfer to report.
			if ci_idx >= 0 && (L.frames[ci_idx].callstatus & CIST_HOOKED) != 0 {
				ar.ftransfer = u16(L.transfer_first)
				ar.ntransfer = u16(L.transfer_n)
			} else {
				ar.ftransfer = 0
				ar.ntransfer = 0
			}
		case 'n':
			// Recover how this function was reached: its name and the kind of
			// reference (local/global/field/method/upvalue/metamethod/...),
			// exactly as reference Lua's `getfuncname`. When nothing can be
			// proven we honestly report an empty name.
			kind, nm := dbg_getfuncname(L, ci_idx)
			ar.namewhat = kind
			ar.name = nm
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
api_getinfo :: proc(L: ^State, what: string, ar: ^Debug_Info) -> bool {
	what := what
	fv: ^TValue
	ci_idx := -1
	if len(what) > 0 && what[0] == '>' {
		fv = stack_value(L, L.top - 1)
		when API_CHECKS {assert(is_function(fv), "function expected in api_getinfo")}
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
collectvalidlines :: proc(L: ^State, fv: ^TValue) {
	if !is_lua_closure(fv) {
		set_nil(stack_value(L, L.top))
		L.top += 1
		return
	}
	p := api_closure_value(fv).p
	t := table_new(L)
	set_gc(stack_value(L, L.top), obj2gco(t))
	L.top += 1
	if p.lineinfo != nil {
		active: TValue
		set_bool(&active, true)
		currentline := p.linedefined
		i := 0
		// A vararg function begins with OP_VARARGPREP, whose line is the function
		// header. Reference skips it: advance the running line past instruction 0
		// but do not mark it, so an all-empty vararg body reports only its real
		// lines (e.g. just {linedefined} for `function(...) end`).
		if (p.flag & u8(PF_VAHID | PF_VATAB)) != 0 {
			currentline = nextline(p, currentline, 0)
			i = 1
		}
		for ; i < p.sizecode; i += 1 {
			currentline = nextline(p, currentline, i)
			table_setint(L, t, Integer(currentline), &active)
		}
	}
}

// The source line of instruction `pc`, given the running line of `pc-1` -- reference
// Lua's `nextline`. Relative deltas accumulate; an absolute checkpoint resets.
@(private = "file")
nextline :: proc(p: ^Proto, currentline: int, pc: int) -> int {
	if p.lineinfo[pc] == ABSLINEINFO {
		return debug_getfuncline(p, pc)
	}
	return currentline + int(p.lineinfo[pc])
}

// Return the name of local variable number `n` in the frame `ar` describes, and
// push its current value -- reference `lua_getlocal`. With a '>' style `ar`
// (i_ci < 0) it instead reports a function's parameter names without a value.
api_getlocal :: proc(L: ^State, ar: ^Debug_Info, n: int) -> (name: string, ok: bool) {
	if ar == nil {
		// "Non-active function" form: the function sits on top of the stack and we
		// report its parameter *names* only (no live value to push). Reference Lua
		// inspects local variables live at pc 0 -- i.e. the declared parameters.
		fv := stack_value(L, L.top - 1)
		if !is_lua_closure(fv) {
			return "", false // only Lua functions carry local-variable names
		}
		p := api_closure_value(fv).p
		nm := func_getlocalname(p, n, 0)
		if nm == nil {
			return "", false
		}
		return string(str_slice(nm)), true
	}
	nm, pos, found := findlocal(L, ar.i_ci, n)
	if !found {
		return "", false
	}
	set_obj(stack_value(L, L.top), stack_value(L, pos))
	L.top += 1
	return nm, true
}

// Set local variable number `n` from the popped top value -- reference
// `lua_setlocal`.
api_setlocal :: proc(L: ^State, ar: ^Debug_Info, n: int) -> (name: string, ok: bool) {
	nm, pos, found := findlocal(L, ar.i_ci, n)
	if !found {
		return "", false
	}
	L.top -= 1
	set_obj(stack_value(L, pos), stack_value(L, L.top))
	return nm, true
}

// Locate local variable number `n` in the frame at index `ci_idx` -- reference
// `luaG_findlocal` (plus its `findvararg` helper). Positive `n` counts declared
// locals from the frame base; a negative `n` reaches the frame's hidden vararg
// values (only in the PF_VAHID model, where extras sit just below `func`). A
// positive slot with no source-level name but still inside the frame's live stack
// window gets a generic "(temporary)"/"(C temporary)" name, exactly like reference.
findlocal :: proc(L: ^State, ci_idx: int, n: int) -> (name: string, pos: int, ok: bool) {
	ci := &L.frames[ci_idx]
	base := ci.func + 1
	found := false
	if is_lua_frame(ci) {
		if n < 0 {
			// Access to vararg values. The extras were hidden just below `func`
			// when the frame was set up (see luaT_adjustvarargs, PF_VAHID model).
			p := api_closure_value(stack_value(L, ci.func)).p
			if (p.flag & PF_VAHID) != 0 {
				nextra := ci.u.l.nextraargs
				if n >= -nextra {
					return "(vararg)", ci.func - nextra - (n + 1), true
				}
			}
			return "", 0, false // no such vararg
		}
		nm := func_getlocalname(ci_func(L, ci).p, n, currentpc(ci))

		if nm != nil {
			name = string(str_slice(nm))
			found = true
		}
	}
	if !found {
		// No "standard" name: is `n` still a valid live slot inside this frame?
		limit := ci_idx == L.ci ? L.top : L.frames[ci_idx + 1].func
		if n > 0 && (limit - base) >= n {
			name = is_lua_frame(ci) ? "(temporary)" : "(C temporary)"
		} else {
			return "", 0, false // no name
		}
	}
	return name, base + (n - 1), true
}
