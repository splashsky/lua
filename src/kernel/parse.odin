package kernel
// parse.odin -- our analogue of reference Lua's `lparser.h` / `lparser.c`.
//
// The parser, which in Lua is also the front half of the code generator: it's a
// single-pass recursive-descent parser that emits bytecode as it goes rather
// than building a separate AST. It tracks local variables, scopes, upvalue
// capture, and control-flow structure, handing the low-level instruction
// emission off to `code`.
//
// Because it's single-pass, the interplay between parsing and `code`'s
// backpatching/register allocation is intricate -- and it's where the shape of
// our `Proto` output must line up with reference Lua for bytecode compatibility.
//
// This file holds the recursive-descent grammar, scope, local and upvalue
// management, and the `Proto` construction that drives `code`.

// ---------------------------------------------------------------------------
// Expression descriptors (reference `lparser.h`'s `expkind` / `expdesc`)
// ---------------------------------------------------------------------------
//
// Code generation for variables and expressions is delayed so the compiler can
// pick better instructions once it sees the surrounding context. An `Expdesc`
// captures that pending value: its "main" representation (a register, a constant,
// a literal, an indexed access, a pending jump, ...) plus two patch lists `t`/`f`
// that the short-circuit operators `and`/`or` use to also produce the value via
// conditional jumps.
//
// The ORDER of `Expkind` is load-bearing: several range tests below (and in the
// code generator) rely on it, e.g. `vkisvar` = VLOCAL..VINDEXSTR and
// `vkisindexed` = VINDEXED..VINDEXSTR, and `discharge2reg` asserts VNIL..VKSTR.
// Do not reorder; this mirrors reference Lua's `expkind` verbatim.
Expkind :: enum u32 {
	VVOID, // no value: empty expression / empty expression-list tail
	VNIL, // constant nil
	VTRUE, // constant true
	VFALSE, // constant false
	VK, // constant in 'k'; info = index of constant
	VKFLT, // float constant; nval = value
	VKINT, // integer constant; ival = value
	VKSTR, // string constant; strval = TString (fixed by the scanner)
	VNONRELOC, // value sits in a fixed register; info = that register
	VLOCAL, // local variable; var.ridx = register, var.vidx = actvar index
	VVARGVAR, // vararg parameter; var.* as in VLOCAL
	VGLOBAL, // global variable; info = actvar index (or -1 implicit)
	VUPVAL, // upvalue; info = index into 'upvalues'
	VCONST, // compile-time <const>; info = absolute actvar index
	VINDEXED, // t[k] with register key; ind.*
	VVARGIND, // vararg-parameter index; ind.*
	VINDEXUP, // _ENV-style upvalue index; ind.idx = K index of key
	VINDEXI, // t[k] with constant integer key; ind.idx = the integer
	VINDEXSTR, // t[k] with short-string key; ind.idx = K index of key
	VJMP, // test/comparison; info = pc of the jump instruction
	VRELOC, // result can go in any register; info = instruction pc
	VCALL, // function call; info = instruction pc
	VVARARG, // vararg '...'; info = instruction pc
}

// `vkisvar` -- kinds that denote an assignable variable (used to reject bad
// assignment targets). `vkisindexed` -- kinds that are an indexed access.
vkisvar :: #force_inline proc "contextless" (k: Expkind) -> bool {
	return Expkind.VLOCAL <= k && k <= Expkind.VINDEXSTR
}
vkisindexed :: #force_inline proc "contextless" (k: Expkind) -> bool {
	return Expkind.VINDEXED <= k && k <= Expkind.VINDEXSTR
}

// The payload for indexed expressions (VINDEXED/VVARGIND/VINDEXUP/VINDEXI/
// VINDEXSTR). Mirrors reference's anonymous `ind` struct field-for-field.
Expdesc_Ind :: struct {
	idx:    i16, // key: an R index, or a "long" K index, or a literal integer
	t:      u8, // table: a register or (for VINDEXUP) an upvalue index
	ro:     u8, // true if this represents a read-only global
	keystr: int, // if the key is a string, its index in 'k'; else -1
}

// The payload for register-resident locals (VLOCAL/VVARGVAR).
Expdesc_Var :: struct {
	ridx: u8, // register currently holding the variable
	vidx: u16, // index of the variable in 'actvar.arr'
}

// The overlapping payload union. Faithful to reference's `union { ... } u`: every
// member shares storage at offset zero. Because members overlap (like the C
// union), some code paths must copy a field into a temporary before overwriting
// `info`, since writing e.g. `var.ridx` (1 byte) does not clear the bytes that
// reading `info` (4 bytes) would see -- we mirror those copies literally.
Expdesc_U :: struct #raw_union {
	ival:   Integer, // VKINT
	nval:   Number, // VKFLT
	strval: ^TString, // VKSTR
	info:   int, // generic (register or pc, depending on kind)
	ind:    Expdesc_Ind, // indexed variables
	var:    Expdesc_Var, // register-resident locals
}

Expdesc :: struct {
	k: Expkind,
	u: Expdesc_U,
	t: int, // patch list of "exit when true"
	f: int, // patch list of "exit when false"
}

// ---------------------------------------------------------------------------
// Variable kinds (reference `lparser.h`'s VDKREG.. and the varinreg/varglobal tests)
// ---------------------------------------------------------------------------

VDKREG :: 0 // regular local
RDKCONST :: 1 // local constant (<const>)
RDKVAVAR :: 2 // vararg parameter
RDKTOCLOSE :: 3 // to-be-closed (<close>)
RDKCTC :: 4 // local compile-time constant (value folds into 'k')
GDKREG :: 5 // regular global
GDKCONST :: 6 // global constant

// Variables that occupy a register (kinds up to and including to-be-closed).
varinreg :: #force_inline proc "contextless" (kind: u8) -> bool {return kind <= RDKTOCLOSE}
// Variables that name a global (the two GDK* kinds).
varglobal :: #force_inline proc "contextless" (kind: u8) -> bool {return kind >= GDKREG}

// ---------------------------------------------------------------------------
// Active variables, labels, gotos (reference `Vardesc`/`Labeldesc`/`Dyndata`)
// ---------------------------------------------------------------------------
//
// `Vardesc` describes one active variable while a function is being compiled.
// Reference Lua declares it as a `union { struct{TValuefields; ...} vd; TValue k }`
// so that a compile-time constant can stash its value in the same bytes the
// metadata's `TValuefields` would occupy. We model it as a plain struct whose
// first member is a full `TValue k`: the metadata fields (`kind`/`ridx`/`pidx`/
// `name`) sit strictly *after* the value and never overlap it, which reproduces
// the reference semantics faithfully -- reading `.k` sees the const value, and
// writing metadata cannot corrupt it. (No binary layout compatibility is needed;
// `Vardesc` never leaves the compiler.)
Vardesc :: struct {
	k:    TValue, // constant value (for RDKCTC compile-time constants)
	kind: u8, // one of VDKREG/RDKCONST/RDKVAVAR/RDKTOCLOSE/RDKCTC/GDKREG/GDKCONST
	ridx: u8, // register holding the variable (when it lives in a register)
	pidx: i16, // index of the variable in the Proto's 'locvars' (debug)
	name: ^TString, // variable name
}

// A pending goto or an active label. Reference Lua's `Labeldesc`.
Labeldesc :: struct {
	name:    ^TString, // label identifier
	pc:      int, // position in code
	line:    int, // line where it appeared
	nactvar: i16, // number of active variables at that position
	close:   u8, // true for a goto that must close upvalues
}

// A growable list of labels or gotos. Reference Lua's `Labellist`.
Labellist :: struct {
	arr:  [^]Labeldesc, // array
	n:    int, // number of entries in use
	size: int, // allocated size
}

// The parser's dynamic scratch structures, shared across all nested functions of
// a single compilation. Reference Lua's `Dyndata`.
Dyndata :: struct {
	actvar: struct {
		// all active local variables (across the whole function nesting)
		arr:  [^]Vardesc,
		n:    int,
		size: int,
	},
	gt:     Labellist, // pending gotos
	label:  Labellist, // active labels
}

// ---------------------------------------------------------------------------
// Per-function code-generation state (reference `FuncState` / `BlockCnt`)
// ---------------------------------------------------------------------------
//
// `BlockCnt` tracks one lexical block on a stack rooted at `FuncState.bl`; it
// snapshots the label/goto/variable counts at block entry so scope exit can
// restore them and resolve gotos. Defined in reference Lua's `lparser.c`.
BlockCnt :: struct {
	previous:  ^BlockCnt, // enclosing block
	firstlabel: int, // index of first label in this block
	firstgoto: int, // index of first pending goto in this block
	nactvar:   i16, // active variables outside the block
	upval:     u8, // true if some variable in the block is an upvalue
	isloop:    u8, // 1 = loop; 2 = loop with a pending 'break'
	insidetbc: u8, // true if inside the scope of a to-be-closed variable
}

// Everything needed to generate code for one function. Reference `FuncState`.
FuncState :: struct {
	f:            ^Proto, // current function header
	prev:         ^FuncState, // enclosing function
	ls:           ^LexState, // lexical/scanner state (shared)
	bl:           ^BlockCnt, // chain of current blocks
	kcache:       ^Table, // constant cache (reuse identical constants)
	pc:           int, // next position to code (== number of instructions)
	lasttarget:   int, // 'label' of last jump target
	previousline: int, // last line saved in 'lineinfo'
	nk:           int, // number of elements in 'k'
	np:           int, // number of elements in 'p'
	nabslineinfo: int, // number of elements in 'abslineinfo'
	firstlocal:   int, // index of first local (in Dyndata's actvar array)
	firstlabel:   int, // index of first label (in dyd.label)
	ndebugvars:   i16, // number of elements in 'f.locvars'
	nactvar:      i16, // number of active local variables
	// The following four are `lu_byte` in reference Lua; we widen them to `int`
	// because they're purely transient compiler counters/flags (never serialized)
	// and the arithmetic on them (`freereg + n`, `iwthabs++`, ...) reads far more
	// cleanly without a cast at every step. The byte-range invariants are still
	// enforced where they matter -- e.g. `luaK_checkstack` clamps `freereg`
	// against `MAX_FSTACK` before it ever reaches the byte-wide `maxstacksize`.
	nups:         int, // number of upvalues
	freereg:      int, // first free register
	iwthabs:      int, // instructions since last absolute line info
	needclose:    int, // function needs to close upvalues on return
}

// ---------------------------------------------------------------------------
// Small shared helpers the code generator (`code.odin`) leans on
// ---------------------------------------------------------------------------
//
// These live here (rather than in `code.odin`) because they're conceptually the
// parser's bookkeeping over its active-variable table -- `code.odin` only *reads*
// the answers. They're transcribed verbatim from reference Lua's `lparser.c`.

// Get the descriptor for active variable 'vidx' (an index relative to this
// function's first local). Reference `getlocalvardesc`.
getlocalvardesc :: #force_inline proc "contextless" (fs: ^FuncState, vidx: int) -> ^Vardesc {
	return &fs.ls.dyd.actvar.arr[fs.firstlocal + vidx]
}

// Convert a compiler variable-index level to its corresponding register count:
// walk backwards from 'nvar' and return the register-index-plus-one of the
// highest variable that actually occupies a register. Reference `reglevel`.
reglevel :: proc "contextless" (fs: ^FuncState, nvar: int) -> int {
	nvar := nvar
	for nvar > 0 {
		nvar -= 1
		vd := getlocalvardesc(fs, nvar)
		if varinreg(vd.kind) {
			return int(vd.ridx) + 1
		}
	}
	return 0
}

// Number of variables currently living on the register stack. Reference
// `luaY_nvarstack`.
parse_nvarstack :: proc "contextless" (fs: ^FuncState) -> int {
	return reglevel(fs, int(fs.nactvar))
}

// Raise a "too many X" limit error, blaming the function being compiled.
// Reference `errorlimit`. There is never a live Lua frame during parsing, so we
// route the formatted message straight through the scanner's syntax-error path.
@(private = "file")
errorlimit :: proc(fs: ^FuncState, limit: int, what: string) {
	L := fs.ls.L
	line := fs.f.linedefined
	loc: string
	if line == 0 {
		loc = "main function"
	} else {
		loc = string(str_slice(object_pushfstring(L, "function at line %d", line)))
	}
	msg := string(
		str_slice(
			object_pushfstring(L, "too many %s (limit is %d) in %s", what, limit, loc),
		),
	)
	lex_syntaxerror(fs.ls, msg)
}

// Assert that value 'v' does not exceed limit 'l'; raise otherwise. Reference
// `luaY_checklimit`.
parse_checklimit :: proc(fs: ^FuncState, v: int, l: int, what: string) {
	if v > l {
		errorlimit(fs, l, what)
	}
}

// ===========================================================================
// The recursive-descent grammar (reference `lparser.c`, the bulk of the file)
// ===========================================================================
//
// Everything below is transcribed function-for-function from reference Lua's
// `lparser.c`. It is a single-pass parser: it never builds an AST, it drives the
// code generator (`code.odin`, the `luaK_*` procedures) as it recognizes each
// construct. The interplay between what we parse and what registers/constants
// `code` allocates is precisely what makes our `Proto` output byte-compatible
// with reference Lua.

// Maximum number of variable declarations per function. Must stay under 250
// because a register index is a byte in the bytecode. Reference `MAXVARS`.
MAXVARS :: 200

// A pending goto or label list is capped at SHRT_MAX entries, matching the C
// `luaM_growvector(..., SHRT_MAX, ...)` limit the reference uses for the actvar,
// locvar, and label/goto arrays. (`short` is the natural width of the counts
// those arrays index.)
@(private = "file")
SHRT_MAX :: 32767

// The parser bounds its own recursion so a pathologically nested chunk cannot
// blow the native call stack. Reference Lua funnels this through
// `luaE_incCstack`/`nCcalls` (the shared C-stack guard). We reuse the same
// `n_ccalls` counter here; Phase 5 will unify this with the call machinery once
// the trampoline exists. 200 mirrors reference `LUAI_MAXCCALLS`.
@(private = "file")
MAXCCALLS :: 200

// Whether an expression kind can yield *multiple* results (a call or a vararg).
// Reference macro `hasmultret`.
@(private = "file")
hasmultret :: #force_inline proc "contextless" (k: Expkind) -> bool {
	return k == .VCALL || k == .VVARARG
}

// String equality is pointer equality because every string the scanner produces
// is interned. Reference macro `eqstr`.
@(private = "file")
eqstr :: #force_inline proc "contextless" (a, b: ^TString) -> bool {
	return a == b
}

// The text bytes of an interned string, as an Odin `string` view -- our stand-in
// for reference Lua's `getstr`. Only ever used to format error messages, so a
// borrowed view (not a copy) is exactly right.
@(private = "file")
getstr :: #force_inline proc "contextless" (ts: ^TString) -> string {
	return string(str_slice(ts))
}

// Whether this prototype takes variable arguments at all. Reference macro
// `isvararg` -- either it uses hidden `...` slots or it materializes a vararg
// table.
@(private = "file")
isvararg :: #force_inline proc "contextless" (p: ^Proto) -> bool {
	return (p.flag & u8(PF_VAHID | PF_VATAB)) != 0
}

// ---------------------------------------------------------------------------
// Token-stream conveniences
// ---------------------------------------------------------------------------

// Raise "<token> expected" for a token we required but did not see. Reference
// `error_expected`.
@(private = "file")
error_expected :: proc(ls: ^LexState, token: int) {
	lex_syntaxerror(
		ls,
		string(str_slice(object_pushfstring(ls.L, "%s expected", lex_token2str(ls, token)))),
	)
}

// If the current token is `c`, consume it and report success. Reference
// `testnext`.
@(private = "file")
testnext :: proc(ls: ^LexState, c: int) -> bool {
	if ls.t.token == c {
		lex_next(ls)
		return true
	}
	return false
}

// Require the current token to be `c` (without consuming it). Reference `check`.
@(private = "file")
check :: proc(ls: ^LexState, c: int) {
	if ls.t.token != c {
		error_expected(ls, c)
	}
}

// Require token `c` and consume it. Reference `checknext`.
@(private = "file")
checknext :: proc(ls: ^LexState, c: int) {
	check(ls, c)
	lex_next(ls)
}

// Require token `what` and consume it; on failure, if the opener `who` was on a
// different line `where`, produce a "expected (to close ... at line N)" message
// that points at the unbalanced opener. Reference `check_match`.
@(private = "file")
check_match :: proc(ls: ^LexState, what, who, where_line: int) {
	if !testnext(ls, what) {
		if where_line == ls.linenumber {
			error_expected(ls, what) // same line: the short message is enough
		} else {
			lex_syntaxerror(
				ls,
				string(
					str_slice(
						object_pushfstring(
							ls.L,
							"%s expected (to close %s at line %d)",
							lex_token2str(ls, what),
							lex_token2str(ls, who),
							where_line,
						),
					),
				),
			)
		}
	}
}

// Require a NAME token and return its interned text, consuming it. Reference
// `str_checkname`.
@(private = "file")
str_checkname :: proc(ls: ^LexState) -> ^TString {
	check(ls, TK_NAME)
	ts := ls.t.seminfo.ts
	lex_next(ls)
	return ts
}

// ---------------------------------------------------------------------------
// Expression-descriptor initializers
// ---------------------------------------------------------------------------

// Seed an `Expdesc` of kind `k` whose generic payload is `i` (a register or a pc,
// depending on the kind), with empty true/false patch lists. Reference
// `init_exp`.
@(private = "file")
init_exp :: proc "contextless" (e: ^Expdesc, k: Expkind, i: int) {
	e.f = NO_JUMP
	e.t = NO_JUMP
	e.k = k
	e.u.info = i
}

// Seed an `Expdesc` describing the string constant `s` (a scanner-fixed
// TString). Reference `codestring`.
@(private = "file")
codestring :: proc "contextless" (e: ^Expdesc, s: ^TString) {
	e.f = NO_JUMP
	e.t = NO_JUMP
	e.k = .VKSTR
	e.u.strval = s
}

// Parse a NAME and describe it as a string constant (used for `.field` keys and
// the like). Reference `codename`.
@(private = "file")
codename :: proc(ls: ^LexState, e: ^Expdesc) {
	codestring(e, str_checkname(ls))
}

// ---------------------------------------------------------------------------
// Local variables, upvalues, and the active-variable table
// ---------------------------------------------------------------------------

// Record a local's name in the prototype's debug `locvars` array and return the
// index of that debug entry. Reference `registerlocalvar`.
@(private = "file")
registerlocalvar :: proc(ls: ^LexState, fs: ^FuncState, varname: ^TString) -> i16 {
	f := fs.f
	oldsize := f.sizelocvars
	grow_vector(ls.L, &f.locvars, int(fs.ndebugvars), &f.sizelocvars, SHRT_MAX, "local variables")
	// Freshly grown slots are raw memory; the GC may scan `locvars`, so nil out
	// the names of any slots we just added before anyone can observe them.
	for oldsize < f.sizelocvars {
		f.locvars[oldsize].varname = nil
		oldsize += 1
	}
	idx := fs.ndebugvars
	f.locvars[idx].varname = varname
	f.locvars[idx].startpc = fs.pc
	gc_barrier(ls.L, obj2gco(f), obj2gco(varname)) // f now points at varname
	fs.ndebugvars += 1
	return idx
}

// Declare a new active variable of the given `kind`, returning its compiler index
// (relative to this function's first local). The name may be nil to represent a
// collective `global *` declaration. Reference `new_varkind`.
@(private = "file")
new_varkind :: proc(ls: ^LexState, name: ^TString, kind: u8) -> int {
	L := ls.L
	fs := ls.fs
	dyd := ls.dyd
	grow_vector(
		L,
		&dyd.actvar.arr,
		dyd.actvar.n + 1,
		&dyd.actvar.size,
		SHRT_MAX,
		"variable declarations",
	)
	var := &dyd.actvar.arr[dyd.actvar.n]
	dyd.actvar.n += 1
	var.kind = kind
	var.name = name
	return dyd.actvar.n - 1 - fs.firstlocal
}

// Declare a plain (regular-kind) local variable. Reference `new_localvar`.
@(private = "file")
new_localvar :: proc(ls: ^LexState, name: ^TString) -> int {
	return new_varkind(ls, name, VDKREG)
}

// Declare an internal (compiler-generated) local with a literal name such as
// "(for state)". Reference's `new_localvarliteral` macro; here a small proc that
// interns the literal through the scanner's string table.
@(private = "file")
new_localvarliteral :: proc(ls: ^LexState, s: string) -> int {
	return new_localvar(ls, lex_newstring(ls, raw_data(transmute([]u8)s), uint(len(s))))
}

// Debug-info entry for active variable `vidx`, or nil if the variable is a
// compile-time constant (which occupies no register and has no debug row).
// Reference `localdebuginfo`.
@(private = "file")
localdebuginfo :: proc "contextless" (fs: ^FuncState, vidx: int) -> ^LocVar {
	vd := getlocalvardesc(fs, vidx)
	if !varinreg(vd.kind) {
		return nil // constants carry no debug information
	}
	return &fs.f.locvars[int(vd.pidx)]
}

// Describe active local variable `vidx` as an expression sitting in its register.
// Reference `init_var`.
@(private = "file")
init_var :: proc "contextless" (fs: ^FuncState, e: ^Expdesc, vidx: int) {
	e.f = NO_JUMP
	e.t = NO_JUMP
	e.k = .VLOCAL
	e.u.var.vidx = u16(vidx)
	e.u.var.ridx = getlocalvardesc(fs, vidx).ridx
}

// Reject assignment to a read-only variable (`<const>`/`<close>` locals, const
// upvalues, const globals). Also, if the target is `varargparam[exp]`, promote
// the virtual vararg to a real vararg table first (virtual tables can't be
// mutated). Reference `check_readonly`.
@(private = "file")
check_readonly :: proc(ls: ^LexState, e: ^Expdesc) {
	fs := ls.fs
	varname: ^TString = nil // set iff the target turns out to be read-only
	#partial switch e.k {
	case .VCONST:
		varname = ls.dyd.actvar.arr[e.u.info].name
	case .VLOCAL, .VVARGVAR:
		vardesc := getlocalvardesc(fs, int(e.u.var.vidx))
		if vardesc.kind != VDKREG {
			varname = vardesc.name
		}
	case .VUPVAL:
		up := &fs.f.upvalues[e.u.info]
		if up.kind != VDKREG {
			varname = up.name
		}
	case .VVARGIND:
		needvatab(fs.f) // this function will need a real vararg table
		e.k = .VINDEXED
		fallthrough
	case .VINDEXUP, .VINDEXSTR, .VINDEXED:
		if e.u.ind.ro != 0 { // read-only global?
			varname = str_value(&fs.f.k[e.u.ind.keystr])
		}
	case:
		// The only remaining indexed kind is VINDEXI (a literal integer key),
		// which can never be read-only, so there is nothing to check.
		return
	}
	if varname != nil {
		code_semerror(ls, "attempt to assign to const variable '%s'", getstr(varname))
	}
}

// Bring the last `nvars` just-declared variables into scope: assign each a
// register and a debug row. Reference `adjustlocalvars`.
@(private = "file")
adjustlocalvars :: proc(ls: ^LexState, nvars: int) {
	fs := ls.fs
	reglvl := parse_nvarstack(fs)
	for _ in 0 ..< nvars {
		vidx := int(fs.nactvar)
		fs.nactvar += 1
		var := getlocalvardesc(fs, vidx)
		var.ridx = u8(reglvl)
		reglvl += 1
		var.pidx = registerlocalvar(ls, fs, var.name)
		parse_checklimit(fs, reglvl, MAXVARS, "local variables")
	}
}

// Close the scope of every variable above level `tolevel`, stamping each debug
// row's `endpc`. Reference `removevars`.
@(private = "file")
removevars :: proc(fs: ^FuncState, tolevel: int) {
	fs.ls.dyd.actvar.n -= (int(fs.nactvar) - tolevel)
	for int(fs.nactvar) > tolevel {
		fs.nactvar -= 1
		var := localdebuginfo(fs, int(fs.nactvar))
		if var != nil { // constants have no debug row
			var.endpc = fs.pc
		}
	}
}

// Find an existing upvalue of `fs` named `name`; return its index or -1.
// Reference `searchupvalue`.
@(private = "file")
searchupvalue :: proc(fs: ^FuncState, name: ^TString) -> int {
	up := fs.f.upvalues
	for i in 0 ..< fs.nups {
		if eqstr(up[i].name, name) {
			return i
		}
	}
	return -1
}

// Grow the prototype's upvalue array by one and return the fresh descriptor.
// Reference `allocupvalue`.
@(private = "file")
allocupvalue :: proc(fs: ^FuncState) -> ^Upvaldesc {
	f := fs.f
	oldsize := f.sizeupvalues
	parse_checklimit(fs, fs.nups + 1, MAXUPVAL, "upvalues")
	grow_vector(fs.ls.L, &f.upvalues, fs.nups, &f.sizeupvalues, MAXUPVAL, "upvalues")
	for oldsize < f.sizeupvalues {
		f.upvalues[oldsize].name = nil // nil-out freshly grown slots for the GC
		oldsize += 1
	}
	r := &f.upvalues[fs.nups]
	fs.nups += 1
	return r
}

// Create a new upvalue in `fs` capturing the variable described by `v` (which was
// resolved in the *enclosing* function `fs.prev`). Reference `newupvalue`.
@(private = "file")
newupvalue :: proc(fs: ^FuncState, name: ^TString, v: ^Expdesc) -> int {
	up := allocupvalue(fs)
	prev := fs.prev
	if v.k == .VLOCAL {
		up.instack = 1 // captured from the enclosing function's registers
		up.idx = v.u.var.ridx
		up.kind = getlocalvardesc(prev, int(v.u.var.vidx)).kind
	} else {
		up.instack = 0 // captured from an upvalue of the enclosing function
		up.idx = u8(v.u.info)
		up.kind = prev.f.upvalues[v.u.info].kind
	}
	up.name = name
	gc_barrier(fs.ls.L, obj2gco(fs.f), obj2gco(name))
	return fs.nups - 1
}

// Look for an active variable named `n` in function `fs`. On success fills `var`
// and returns its expression kind (>= 0); returns -1 if not found here. The
// `var.u.info` sentinels (-1/-2) track the state of `global` declarations while
// scanning -- see the block comment mirrored from reference `searchvar`.
@(private = "file")
searchvar :: proc(fs: ^FuncState, n: ^TString, var: ^Expdesc) -> int {
	for i := int(fs.nactvar) - 1; i >= 0; i -= 1 {
		vd := getlocalvardesc(fs, i)
		if varglobal(vd.kind) { // a `global` declaration?
			if vd.name == nil { // collective `global *`?
				if var.u.info < 0 { // no previous collective declaration yet
					var.u.info = fs.firstlocal + i // remember the first one
				}
			} else { // a named global
				if eqstr(n, vd.name) {
					init_exp(var, .VGLOBAL, fs.firstlocal + i)
					return int(Expkind.VGLOBAL)
				} else if var.u.info == -1 { // preambular declaration still active?
					var.u.info = -2 // invalidate it: an explicit global exists
				}
			}
		} else if eqstr(n, vd.name) {
			if vd.kind == RDKCTC { // compile-time constant?
				init_exp(var, .VCONST, fs.firstlocal + i)
			} else {
				init_var(fs, var, i)
				if vd.kind == RDKVAVAR { // vararg parameter?
					var.k = .VVARGVAR
				}
			}
			return int(var.k)
		}
	}
	return -1 // not found at this level
}

// Mark the block where the variable at `level` was declared as owning an
// upvalue, so a matching CLOSE is emitted on the way out. Reference `markupval`.
@(private = "file")
markupval :: proc(fs: ^FuncState, level: int) {
	bl := fs.bl
	for int(bl.nactvar) > level {
		bl = bl.previous
	}
	bl.upval = 1
	fs.needclose = 1
}

// Mark the current block as containing a to-be-closed variable. Reference
// `marktobeclosed`.
@(private = "file")
marktobeclosed :: proc(fs: ^FuncState) {
	bl := fs.bl
	bl.upval = 1
	bl.insidetbc = 1
	fs.needclose = 1
}

// Resolve name `n` starting at function `fs`, threading an upvalue through every
// intermediate function if the name is captured from an outer scope. `base` is
// nonzero only at the innermost call (the function actually using the name).
// Reference `singlevaraux`.
@(private = "file")
singlevaraux :: proc(fs: ^FuncState, n: ^TString, var: ^Expdesc, base: int) {
	v := searchvar(fs, n, var) // look at this function's own variables
	if v >= 0 { // found here
		if base == 0 {
			if var.k == .VVARGVAR { // capturing a vararg parameter?
				code_vapar2local(fs, var) // demote it to a regular local first
			}
			if var.k == .VLOCAL {
				markupval(fs, int(var.u.var.vidx)) // it will be used as an upvalue
			}
		}
	} else { // not a local here; try upvalues
		idx := searchupvalue(fs, n)
		if idx < 0 { // no existing upvalue either
			if fs.prev != nil { // more enclosing functions to try?
				singlevaraux(fs.prev, n, var, 0)
			}
			if var.k == .VLOCAL || var.k == .VUPVAL { // resolved up there?
				idx = newupvalue(fs, n, var) // create a new upvalue for it here
			} else { // it is a global or a constant: nothing to do at this level
				return
			}
		}
		init_exp(var, .VUPVAL, idx)
	}
}

// Build `var` as `_ENV[varname]` (a global access). Reference `buildglobal`.
@(private = "file")
buildglobal :: proc(ls: ^LexState, varname: ^TString, var: ^Expdesc) {
	fs := ls.fs
	key: Expdesc
	init_exp(var, .VGLOBAL, -1) // global by default
	singlevaraux(fs, ls.envn, var, 1) // resolve _ENV
	if var.k == .VGLOBAL { // _ENV itself resolved as a global?!
		code_semerror(ls, "%s is global when accessing variable '%s'", ENV_NAME, getstr(varname))
	}
	code_exp2anyregup(fs, var) // _ENV could be a constant
	codestring(&key, varname) // key is the variable's name
	code_indexed(fs, var, &key) // 'var' now represents _ENV[varname]
}

// Resolve name `varname`, handling locals, upvalues, and globals. Reference
// `buildvar`.
@(private = "file")
buildvar :: proc(ls: ^LexState, varname: ^TString, var: ^Expdesc) {
	fs := ls.fs
	init_exp(var, .VGLOBAL, -1) // global by default
	singlevaraux(fs, varname, var, 1)
	if var.k == .VGLOBAL { // came out as a global name?
		info := var.u.info
		if info == -2 { // inside a `global` declaration with no matching entry?
			code_semerror(ls, "variable '%s' not declared", getstr(varname))
		}
		buildglobal(ls, varname, var)
		if info != -1 && ls.dyd.actvar.arr[info].kind == GDKCONST {
			var.u.ind.ro = 1 // it is a read-only (const) global
		}
	}
}

// Parse a NAME and resolve it to a variable expression. Reference `singlevar`.
@(private = "file")
singlevar :: proc(ls: ^LexState, var: ^Expdesc) {
	buildvar(ls, str_checkname(ls), var)
}

// Adjust an expression list producing `nexps` values to yield exactly `nvars`
// values: either spread the last multi-return, or pad/trim with nils. Reference
// `adjust_assign`.
@(private = "file")
adjust_assign :: proc(ls: ^LexState, nvars, nexps: int, e: ^Expdesc) {
	fs := ls.fs
	needed := nvars - nexps // extra values still needed
	code_checkstack(fs, needed)
	if hasmultret(e.k) { // last expression returns multiple values?
		extra := needed + 1 // it also has to cover itself
		if extra < 0 {
			extra = 0
		}
		code_setreturns(fs, e, extra) // let it provide the difference
	} else {
		if e.k != .VVOID { // at least one expression?
			code_exp2nextreg(fs, e) // close the last one
		}
		if needed > 0 { // still short?
			code_nil(fs, fs.freereg, needed) // pad with nils
		}
	}
	if needed > 0 {
		code_reserveregs(fs, needed) // reserve registers for the extra values
	} else {
		fs.freereg = fs.freereg + needed // negative: drop the surplus values
	}
}

// Bound parser recursion against the native stack. Reference `enterlevel`
// (`luaE_incCstack`) / `leavelevel`. See LUAI_MAXCCALLS above.
@(private = "file")
enterlevel :: proc(ls: ^LexState) {
	ls.L.n_ccalls += 1
	if (ls.L.n_ccalls & 0xffff) >= MAXCCALLS {
		lex_syntaxerror(ls, "too many syntax levels")
	}
}
@(private = "file")
leavelevel :: proc(ls: ^LexState) {
	ls.L.n_ccalls -= 1
}

// ---------------------------------------------------------------------------
// Labels and gotos
// ---------------------------------------------------------------------------

// Error: a goto jumps *into* the scope of a variable. Reference `jumpscopeerror`.
@(private = "file")
jumpscopeerror :: proc(ls: ^LexState, gt: ^Labeldesc) {
	tsname := getlocalvardesc(ls.fs, int(gt.nactvar)).name
	varname := tsname != nil ? getstr(tsname) : "*"
	code_semerror(
		ls,
		"<goto %s> at line %d jumps into the scope of '%s'",
		getstr(gt.name),
		gt.line,
		varname,
	)
}

// Resolve pending goto `g` against `label`, emitting a CLOSE if the jump leaves a
// block/scope that owns upvalues, then remove it from the pending list.
// Reference `closegoto`.
@(private = "file")
closegoto :: proc(ls: ^LexState, g: int, label: ^Labeldesc, bup: u8) {
	fs := ls.fs
	gl := &ls.dyd.gt
	gt := &gl.arr[g]
	if gt.nactvar < label.nactvar { // would enter some variable's scope?
		jumpscopeerror(ls, gt)
	}
	if gt.close != 0 || (label.nactvar < gt.nactvar && bup != 0) { // needs a CLOSE?
		stklevel := reglevel(fs, int(label.nactvar))
		// Swap the dead CLOSE placeholder in front of the jump (see newgotoentry).
		fs.f.code[gt.pc + 1] = fs.f.code[gt.pc]
		fs.f.code[gt.pc] = create_ABCk(.CLOSE, stklevel, 0, 0, 0)
		gt.pc += 1 // gt.pc now points at the jump proper
	}
	code_patchlist(ls.fs, gt.pc, label.pc) // goto jumps to the label
	// Remove the goto from the pending list, shifting the tail down.
	for i := g; i < gl.n - 1; i += 1 {
		gl.arr[i] = gl.arr[i + 1]
	}
	gl.n -= 1
}

// Search active labels for `name`, starting at `ilb`. Reference `findlabel`.
@(private = "file")
findlabel :: proc(ls: ^LexState, name: ^TString, ilb: int) -> ^Labeldesc {
	dyd := ls.dyd
	for i := ilb; i < dyd.label.n; i += 1 {
		lb := &dyd.label.arr[i]
		if eqstr(lb.name, name) {
			return lb
		}
	}
	return nil
}

// Append a label/goto entry to list `l` and return its index. Reference
// `newlabelentry`.
@(private = "file")
newlabelentry :: proc(ls: ^LexState, l: ^Labellist, name: ^TString, line, pc: int) -> int {
	n := l.n
	grow_vector(ls.L, &l.arr, n, &l.size, SHRT_MAX, "labels/gotos")
	l.arr[n].name = name
	l.arr[n].line = line
	l.arr[n].nactvar = ls.fs.nactvar
	l.arr[n].close = 0
	l.arr[n].pc = pc
	l.n = n + 1
	return n
}

// Emit a goto: a jump followed by a dead CLOSE placeholder (so a CLOSE can be
// swapped in front later without shifting code). Reference `newgotoentry`.
@(private = "file")
newgotoentry :: proc(ls: ^LexState, name: ^TString, line: int) -> int {
	fs := ls.fs
	pc := code_jump(fs)
	code_codeABC(fs, .CLOSE, 0, 1, 0) // dead placeholder (comes after the jump)
	return newlabelentry(ls, &ls.dyd.gt, name, line, pc)
}

// Create a label at the current pc, resolving all matching pending gotos. `last`
// says the label is the block's final no-op statement (so locals are already out
// of scope). Reference `createlabel`.
@(private = "file")
createlabel :: proc(ls: ^LexState, name: ^TString, line: int, last: bool) {
	fs := ls.fs
	ll := &ls.dyd.label
	l := newlabelentry(ls, ll, name, line, code_getlabel(fs))
	if last {
		ll.arr[l].nactvar = fs.bl.nactvar
	}
}

// When a block finishes, match its pending gotos against its labels; export the
// unmatched ones to the enclosing block (adjusting their level). Reference
// `solvegotos`.
@(private = "file")
solvegotos :: proc(fs: ^FuncState, bl: ^BlockCnt) {
	ls := fs.ls
	gl := &ls.dyd.gt
	outlevel := reglevel(fs, int(bl.nactvar)) // register level outside the block
	igt := bl.firstgoto
	for igt < gl.n {
		gt := &gl.arr[igt]
		lb := findlabel(ls, gt.name, bl.firstlabel)
		if lb != nil { // matched a label in this block?
			closegoto(ls, igt, lb, bl.upval)
		} else { // export to the outer block
			if bl.upval != 0 && reglevel(fs, int(gt.nactvar)) > outlevel {
				gt.close = 1 // the jump may need to close variables
			}
			gt.nactvar = bl.nactvar // correct the level for the outer block
			igt += 1
		}
	}
	ls.dyd.label.n = bl.firstlabel // drop this block's local labels
}

// ---------------------------------------------------------------------------
// Blocks and functions
// ---------------------------------------------------------------------------

// Push a new lexical block onto `fs.bl`, snapshotting scope/label/goto state.
// Reference `enterblock`.
@(private = "file")
enterblock :: proc(fs: ^FuncState, bl: ^BlockCnt, isloop: u8) {
	bl.isloop = isloop
	bl.nactvar = fs.nactvar
	bl.firstlabel = fs.ls.dyd.label.n
	bl.firstgoto = fs.ls.dyd.gt.n
	bl.upval = 0
	bl.insidetbc = fs.bl != nil && fs.bl.insidetbc != 0 ? 1 : 0 // inherit
	bl.previous = fs.bl
	fs.bl = bl
}

// Error: a goto never found its label. Reference `undefgoto`.
@(private = "file")
undefgoto :: proc(ls: ^LexState, gt: ^Labeldesc) {
	code_semerror(
		ls,
		"no visible label '%s' for <goto> at line %d",
		getstr(gt.name),
		gt.line,
	)
}

// Pop the current lexical block: emit a CLOSE if it owns upvalues, free its
// registers, drop its locals, fix pending breaks, and resolve gotos. Reference
// `leaveblock`.
@(private = "file")
leaveblock :: proc(fs: ^FuncState) {
	bl := fs.bl
	ls := fs.ls
	stklevel := reglevel(fs, int(bl.nactvar)) // register level outside the block
	if bl.previous != nil && bl.upval != 0 { // need a CLOSE?
		code_codeABC(fs, .CLOSE, stklevel, 0, 0)
	}
	fs.freereg = stklevel // free the block's registers
	removevars(fs, int(bl.nactvar)) // drop the block's locals
	if bl.isloop == 2 { // pending breaks to fix?
		createlabel(ls, ls.brkn, 0, false)
	}
	solvegotos(fs, bl)
	if bl.previous == nil { // outermost block?
		if bl.firstgoto < ls.dyd.gt.n { // still-pending gotos are undefined
			undefgoto(ls, &ls.dyd.gt.arr[bl.firstgoto])
		}
	}
	fs.bl = bl.previous
}

// Append a fresh nested prototype to the current function and return it.
// Reference `addprototype`.
@(private = "file")
addprototype :: proc(ls: ^LexState) -> ^Proto {
	L := ls.L
	fs := ls.fs
	f := fs.f // prototype of the current (enclosing) function
	if fs.np >= f.sizep {
		oldsize := f.sizep
		grow_vector(L, &f.p, fs.np, &f.sizep, MAXARG_Bx, "functions")
		for oldsize < f.sizep {
			f.p[oldsize] = nil // nil-out freshly grown slots for the GC
			oldsize += 1
		}
	}
	clp := func_newproto(L)
	f.p[fs.np] = clp
	fs.np += 1
	gc_barrier(L, obj2gco(f), obj2gco(clp))
	return clp
}

// Emit the OP_CLOSURE that builds the nested function `fs.np-1` in the parent.
// Reference `codeclosure`.
@(private = "file")
codeclosure :: proc(ls: ^LexState, v: ^Expdesc) {
	fs := ls.fs.prev // code goes into the *enclosing* function
	init_exp(v, .VRELOC, code_codeABx(fs, .CLOSURE, 0, fs.np - 1))
	code_exp2nextreg(fs, v) // fix it at the last register
}

// Begin compiling a new function `fs` (whose `.f` prototype the caller has set),
// nesting it under the current one. Also anchors the constant-cache table on the
// Lua stack so an allocation during compilation can't collect it. Reference
// `open_func`.
@(private = "file")
open_func :: proc(ls: ^LexState, fs: ^FuncState, bl: ^BlockCnt) {
	L := ls.L
	f := fs.f
	fs.prev = ls.fs // linked list of funcstates
	fs.ls = ls
	ls.fs = fs
	fs.pc = 0
	fs.previousline = f.linedefined
	fs.iwthabs = 0
	fs.lasttarget = 0
	fs.freereg = 0
	fs.nk = 0
	fs.nabslineinfo = 0
	fs.np = 0
	fs.nups = 0
	fs.ndebugvars = 0
	fs.nactvar = 0
	fs.needclose = 0
	fs.firstlocal = ls.dyd.actvar.n
	fs.firstlabel = ls.dyd.label.n
	fs.bl = nil
	f.source = ls.source
	gc_barrier(L, obj2gco(f), obj2gco(f.source))
	f.maxstacksize = 2 // registers 0/1 are always valid
	fs.kcache = table_new(L) // per-function constant cache
	set_gc(stack_value(L, L.top), obj2gco(fs.kcache)) // anchor it on the stack
	inc_top(L)
	enterblock(fs, bl, 0)
}

// Finish compiling the current function: emit its final return, close the outer
// block, run the code generator's finalization, then shrink every Proto array to
// its exact used length. Pops the anchored constant cache. Reference
// `close_func`.
@(private = "file")
close_func :: proc(ls: ^LexState) {
	L := ls.L
	fs := ls.fs
	f := fs.f
	code_ret(fs, parse_nvarstack(fs), 0) // final (default) return
	leaveblock(fs)
	code_finish(fs)
	// Trim each growable array from its allocated capacity down to what was
	// actually used, so the prototype occupies no more memory than necessary
	// (and so the size fields describe exactly the live contents).
	shrink_vector(L, &f.code, &f.sizecode, fs.pc)
	shrink_vector(L, &f.lineinfo, &f.sizelineinfo, fs.pc)
	shrink_vector(L, &f.abslineinfo, &f.sizeabslineinfo, fs.nabslineinfo)
	shrink_vector(L, &f.k, &f.sizek, fs.nk)
	shrink_vector(L, &f.p, &f.sizep, fs.np)
	shrink_vector(L, &f.locvars, &f.sizelocvars, int(fs.ndebugvars))
	shrink_vector(L, &f.upvalues, &f.sizeupvalues, fs.nups)
	ls.fs = fs.prev
	L.top -= 1 // pop the constant-cache table
	gc_checkGC(L) // a completed prototype is a good pacing point
}

// ===========================================================================
// GRAMMAR RULES
// ===========================================================================

// Is the current token in the follow set of a block? `withuntil` decides whether
// UNTIL counts (it closes a syntactic block but not a scope). Reference
// `block_follow`.
@(private = "file")
block_follow :: proc(ls: ^LexState, withuntil: bool) -> bool {
	switch ls.t.token {
	case TK_ELSE, TK_ELSEIF, TK_END, TK_EOS:
		return true
	case TK_UNTIL:
		return withuntil
	case:
		return false
	}
}

// Parse a sequence of statements until the block ends. A `return` must be last.
// Reference `statlist`.
@(private = "file")
statlist :: proc(ls: ^LexState) {
	for !block_follow(ls, true) {
		if ls.t.token == TK_RETURN {
			statement(ls)
			return // 'return' must be the final statement
		}
		statement(ls)
	}
}

// Parse `.NAME` or `:NAME` and turn `v` into an indexed access. Reference
// `fieldsel`.
@(private = "file")
fieldsel :: proc(ls: ^LexState, v: ^Expdesc) {
	fs := ls.fs
	key: Expdesc
	code_exp2anyregup(fs, v)
	lex_next(ls) // skip the '.' or ':'
	codename(ls, &key)
	code_indexed(fs, v, &key)
}

// Parse `[ expr ]` as a table index. Reference `yindex`.
@(private = "file")
yindex :: proc(ls: ^LexState, v: ^Expdesc) {
	lex_next(ls) // skip '['
	expr(ls, v)
	code_exp2val(ls.fs, v)
	checknext(ls, ']')
}

// ---------------------------------------------------------------------------
// Table constructors
// ---------------------------------------------------------------------------

// The running state of a table constructor. Reference `ConsControl`.
@(private = "file")
ConsControl :: struct {
	v:          Expdesc, // last list item read
	t:          ^Expdesc, // table descriptor
	nh:         int, // number of 'record' (key=value) elements
	na:         int, // number of array elements already stored
	tostore:    int, // number of array elements pending a flush
	maxtostore: int, // flush threshold (see maxtostore)
}

// Cap on total constructor elements, guarding counter and SETLIST/NEWTABLE
// encoding overflow. Reference computes MAX_CNST as min(INT_MAX/2, the largest
// count SETLIST's Ax "extra arg" can encode).
@(private = "file")
MAX_CNST :: min(MAX_INT / 2, MAXARG_Ax * (MAXARG_vC + 1))

// Parse a `[exp]=exp` or `NAME=exp` record field. Reference `recfield`.
@(private = "file")
recfield :: proc(ls: ^LexState, cc: ^ConsControl) {
	fs := ls.fs
	reg := ls.fs.freereg
	key, val: Expdesc
	if ls.t.token == TK_NAME {
		codename(ls, &key)
	} else { // '['
		yindex(ls, &key)
	}
	cc.nh += 1
	checknext(ls, '=')
	tab := cc.t^
	code_indexed(fs, &tab, &key)
	expr(ls, &val)
	code_storevar(fs, &tab, &val)
	fs.freereg = reg // free the registers used for the field
}

// Flush the current list item into the pending SETLIST batch, flushing the batch
// itself once it reaches the threshold. Reference `closelistfield`.
@(private = "file")
closelistfield :: proc(fs: ^FuncState, cc: ^ConsControl) {
	code_exp2nextreg(fs, &cc.v)
	cc.v.k = .VVOID
	if cc.tostore >= cc.maxtostore {
		code_setlist(fs, cc.t.u.info, cc.na, cc.tostore) // flush
		cc.na += cc.tostore
		cc.tostore = 0
	}
}

// Store the final list field(s), spreading a trailing multi-return if present.
// Reference `lastlistfield`.
@(private = "file")
lastlistfield :: proc(fs: ^FuncState, cc: ^ConsControl) {
	if cc.tostore == 0 {
		return
	}
	if hasmultret(cc.v.k) {
		code_setreturns(fs, &cc.v, MULTRET)
		code_setlist(fs, cc.t.u.info, cc.na, MULTRET)
		cc.na -= 1 // do not count the last (unknown-count) expression
	} else {
		if cc.v.k != .VVOID {
			code_exp2nextreg(fs, &cc.v)
		}
		code_setlist(fs, cc.t.u.info, cc.na, cc.tostore)
	}
	cc.na += cc.tostore
}

// Parse a bare array (list) field. Reference `listfield`.
@(private = "file")
listfield :: proc(ls: ^LexState, cc: ^ConsControl) {
	expr(ls, &cc.v)
	cc.tostore += 1
}

// Parse one constructor field, deciding between list and record forms.
// Reference `field`.
@(private = "file")
field :: proc(ls: ^LexState, cc: ^ConsControl) {
	switch ls.t.token {
	case TK_NAME: // could be a list item or a `NAME = value` record field
		if lex_lookahead(ls) != '=' {
			listfield(ls, cc)
		} else {
			recfield(ls, cc)
		}
	case '[':
		recfield(ls, cc)
	case:
		listfield(ls, cc)
	}
}

// Choose how many array elements to accumulate before emitting a SETLIST, based
// on register pressure. Reference `maxtostore`.
@(private = "file")
maxtostore :: proc(fs: ^FuncState) -> int {
	numfreeregs := MAX_FSTACK - fs.freereg
	if numfreeregs >= 160 { // lots of registers?
		return numfreeregs / 5
	} else if numfreeregs >= 80 { // still plenty?
		return 10
	}
	return 1 // save registers for deeper nesting
}

// Parse a `{ ... }` table constructor. Reference `constructor`.
@(private = "file")
constructor :: proc(ls: ^LexState, t: ^Expdesc) {
	fs := ls.fs
	line := ls.linenumber
	pc := code_codevABCk(fs, .NEWTABLE, 0, 0, 0, 0)
	cc: ConsControl
	code_code(fs, 0) // room for the extra-argument instruction
	cc.na = 0
	cc.nh = 0
	cc.tostore = 0
	cc.t = t
	init_exp(t, .VNONRELOC, fs.freereg) // table will live at the stack top
	code_reserveregs(fs, 1)
	init_exp(&cc.v, .VVOID, 0) // no value yet
	checknext(ls, '{')
	cc.maxtostore = maxtostore(fs)
	for {
		if ls.t.token == '}' {
			break
		}
		if cc.v.k != .VVOID { // a previous list item pending?
			closelistfield(fs, &cc)
		}
		field(ls, &cc)
		parse_checklimit(fs, cc.tostore + cc.na + cc.nh, MAX_CNST, "items in a constructor")
		if !(testnext(ls, ',') || testnext(ls, ';')) {
			break
		}
	}
	check_match(ls, '}', '{', line)
	lastlistfield(fs, &cc)
	code_settablesize(fs, pc, t.u.info, cc.na, cc.nh)
}

// ---------------------------------------------------------------------------
// Function bodies and argument lists
// ---------------------------------------------------------------------------

// Mark the current function as vararg and emit VARARGPREP. Reference
// `setvararg`.
@(private = "file")
setvararg :: proc(fs: ^FuncState) {
	fs.f.flag |= u8(PF_VAHID) // default: use hidden vararg arguments
	code_codeABC(fs, .VARARGPREP, 0, 0, 0)
}

// Parse a function parameter list. Reference `parlist`.
@(private = "file")
parlist :: proc(ls: ^LexState) {
	fs := ls.fs
	f := fs.f
	nparams := 0
	varargk := false
	if ls.t.token != ')' { // not an empty list?
		for {
			switch ls.t.token {
			case TK_NAME:
				new_localvar(ls, str_checkname(ls))
				nparams += 1
			case TK_DOTS:
				varargk = true
				lex_next(ls) // skip '...'
				if ls.t.token == TK_NAME { // named vararg parameter?
					new_varkind(ls, str_checkname(ls), RDKVAVAR)
				} else {
					new_localvarliteral(ls, "(vararg table)")
				}
			case:
				lex_syntaxerror(ls, "<name> or '...' expected")
			}
			if varargk || !testnext(ls, ',') {
				break
			}
		}
	}
	adjustlocalvars(ls, nparams)
	f.numparams = u8(fs.nactvar)
	if varargk {
		setvararg(fs) // declared vararg
		adjustlocalvars(ls, 1) // the vararg parameter itself
	}
	code_reserveregs(fs, int(fs.nactvar)) // registers for the parameters
}

// Parse a function body `( parlist ) block END` into a fresh nested function and
// leave the resulting closure in `e`. Reference `body`.
@(private = "file")
body :: proc(ls: ^LexState, e: ^Expdesc, ismethod: bool, line: int) {
	new_fs: FuncState
	bl: BlockCnt
	new_fs.f = addprototype(ls)
	new_fs.f.linedefined = line
	open_func(ls, &new_fs, &bl)
	checknext(ls, '(')
	if ismethod {
		new_localvarliteral(ls, "self") // implicit 'self' parameter
		adjustlocalvars(ls, 1)
	}
	parlist(ls)
	checknext(ls, ')')
	statlist(ls)
	new_fs.f.lastlinedefined = ls.linenumber
	check_match(ls, TK_END, TK_FUNCTION, line)
	codeclosure(ls, e)
	close_func(ls)
}

// Parse a comma-separated expression list, returning the count. Reference
// `explist`.
@(private = "file")
explist :: proc(ls: ^LexState, v: ^Expdesc) -> int {
	n := 1
	expr(ls, v)
	for testnext(ls, ',') {
		code_exp2nextreg(ls.fs, v)
		expr(ls, v)
		n += 1
	}
	return n
}

// Parse the arguments of a call (`( ... )`, a constructor, or a string literal)
// and emit the CALL. Reference `funcargs`.
@(private = "file")
funcargs :: proc(ls: ^LexState, f: ^Expdesc) {
	fs := ls.fs
	args: Expdesc
	line := ls.linenumber
	switch ls.t.token {
	case '(': // '(' [ explist ] ')'
		lex_next(ls)
		if ls.t.token == ')' { // empty argument list?
			args.k = .VVOID
		} else {
			explist(ls, &args)
			if hasmultret(args.k) {
				code_setreturns(fs, &args, MULTRET)
			}
		}
		check_match(ls, ')', '(', line)
	case '{': // a single table-constructor argument
		constructor(ls, &args)
	case TK_STRING: // a single string-literal argument
		codestring(&args, ls.t.seminfo.ts)
		lex_next(ls) // must consume seminfo before advancing
	case:
		lex_syntaxerror(ls, "function arguments expected")
	}
	base := f.u.info // base register holding the function
	nparams: int
	if hasmultret(args.k) {
		nparams = MULTRET // open call (all available arguments)
	} else {
		if args.k != .VVOID {
			code_exp2nextreg(fs, &args) // close the last argument
		}
		nparams = fs.freereg - (base + 1)
	}
	init_exp(f, .VCALL, code_codeABC(fs, .CALL, base, nparams + 1, 2))
	code_fixline(fs, line)
	fs.freereg = base + 1 // call leaves one result at 'base'
}

// ---------------------------------------------------------------------------
// Expression parsing
// ---------------------------------------------------------------------------

// Parse a primary expression: `( expr )` or a NAME. Reference `primaryexp`.
@(private = "file")
primaryexp :: proc(ls: ^LexState, v: ^Expdesc) {
	switch ls.t.token {
	case '(':
		line := ls.linenumber
		lex_next(ls)
		expr(ls, v)
		check_match(ls, ')', '(', line)
		code_dischargevars(ls.fs, v)
	case TK_NAME:
		singlevar(ls, v)
	case:
		lex_syntaxerror(ls, "unexpected symbol")
	}
}

// Parse a suffixed expression: a primary followed by any run of field selectors,
// indexings, method calls, or calls. Reference `suffixedexp`.
@(private = "file")
suffixedexp :: proc(ls: ^LexState, v: ^Expdesc) {
	fs := ls.fs
	primaryexp(ls, v)
	for {
		switch ls.t.token {
		case '.': // field selector
			fieldsel(ls, v)
		case '[': // '[' exp ']'
			key: Expdesc
			code_exp2anyregup(fs, v)
			yindex(ls, &key)
			code_indexed(fs, v, &key)
		case ':': // method call ':' NAME funcargs
			key: Expdesc
			lex_next(ls)
			codename(ls, &key)
			code_self(fs, v, &key)
			funcargs(ls, v)
		case '(', TK_STRING, '{': // a call
			code_exp2nextreg(fs, v)
			funcargs(ls, v)
		case:
			return
		}
	}
}

// Parse a simple expression (a literal, constructor, function, vararg, or a
// suffixed expression). Reference `simpleexp`.
@(private = "file")
simpleexp :: proc(ls: ^LexState, v: ^Expdesc) {
	switch ls.t.token {
	case TK_FLT:
		init_exp(v, .VKFLT, 0)
		v.u.nval = ls.t.seminfo.r
	case TK_INT:
		init_exp(v, .VKINT, 0)
		v.u.ival = ls.t.seminfo.i
	case TK_STRING:
		codestring(v, ls.t.seminfo.ts)
	case TK_NIL:
		init_exp(v, .VNIL, 0)
	case TK_TRUE:
		init_exp(v, .VTRUE, 0)
	case TK_FALSE:
		init_exp(v, .VFALSE, 0)
	case TK_DOTS: // vararg '...'
		fs := ls.fs
		if !isvararg(fs.f) {
			lex_syntaxerror(ls, "cannot use '...' outside a vararg function")
		}
		init_exp(v, .VVARARG, code_codeABC(fs, .VARARG, 0, int(fs.f.numparams), 1))
	case '{': // table constructor
		constructor(ls, v)
		return
	case TK_FUNCTION:
		lex_next(ls)
		body(ls, v, false, ls.linenumber)
		return
	case:
		suffixedexp(ls, v)
		return
	}
	lex_next(ls)
}

// Map a token to a unary operator (or "none"). Reference `getunopr`.
@(private = "file")
getunopr :: proc(op: int) -> UnOpr {
	switch op {
	case TK_NOT:
		return .OPR_NOT
	case '-':
		return .OPR_MINUS
	case '~':
		return .OPR_BNOT
	case '#':
		return .OPR_LEN
	case:
		return .OPR_NOUNOPR
	}
}

// Map a token to a binary operator (or "none"). Reference `getbinopr`.
@(private = "file")
getbinopr :: proc(op: int) -> BinOpr {
	switch op {
	case '+':
		return .OPR_ADD
	case '-':
		return .OPR_SUB
	case '*':
		return .OPR_MUL
	case '%':
		return .OPR_MOD
	case '^':
		return .OPR_POW
	case '/':
		return .OPR_DIV
	case TK_IDIV:
		return .OPR_IDIV
	case '&':
		return .OPR_BAND
	case '|':
		return .OPR_BOR
	case '~':
		return .OPR_BXOR
	case TK_SHL:
		return .OPR_SHL
	case TK_SHR:
		return .OPR_SHR
	case TK_CONCAT:
		return .OPR_CONCAT
	case TK_NE:
		return .OPR_NE
	case TK_EQ:
		return .OPR_EQ
	case '<':
		return .OPR_LT
	case TK_LE:
		return .OPR_LE
	case '>':
		return .OPR_GT
	case TK_GE:
		return .OPR_GE
	case TK_AND:
		return .OPR_AND
	case TK_OR:
		return .OPR_OR
	case:
		return .OPR_NOBINOPR
	}
}

// Left/right binding priorities for each binary operator. ORDER OPR: this table
// is indexed by `BinOpr` and must stay lock-step with that enum. Reference
// `priority`.
@(private = "file")
binop_priority := [?]struct {
	left:  u8,
	right: u8,
} {
	{10, 10}, {10, 10}, // '+'  '-'
	{11, 11}, {11, 11}, // '*'  '%'
	{14, 13}, // '^' (right associative)
	{11, 11}, {11, 11}, // '/'  '//'
	{6, 6}, {4, 4}, {5, 5}, // '&'  '|'  '~'
	{7, 7}, {7, 7}, // '<<'  '>>'
	{9, 8}, // '..' (right associative)
	{3, 3}, {3, 3}, {3, 3}, // '=='  '<'  '<='
	{3, 3}, {3, 3}, {3, 3}, // '~='  '>'  '>='
	{2, 2}, {1, 1}, // and  or
}

// Priority of the unary operators. Reference `UNARY_PRIORITY`.
@(private = "file")
UNARY_PRIORITY :: 12

// Parse a sub-expression with operator-precedence climbing: an optional prefix
// unary operator, a simple expression, then any binary operators binding tighter
// than `limit`. Returns the first operator it did not consume. Reference
// `subexpr`.
@(private = "file")
subexpr :: proc(ls: ^LexState, v: ^Expdesc, limit: int) -> BinOpr {
	enterlevel(ls)
	uop := getunopr(ls.t.token)
	if uop != .OPR_NOUNOPR { // prefix unary operator?
		line := ls.linenumber
		lex_next(ls) // skip the operator
		subexpr(ls, v, UNARY_PRIORITY)
		code_prefix(ls.fs, uop, v, line)
	} else {
		simpleexp(ls, v)
	}
	// While the next operator binds tighter than 'limit', fold it in.
	op := getbinopr(ls.t.token)
	for op != .OPR_NOBINOPR && int(binop_priority[int(op)].left) > limit {
		v2: Expdesc
		line := ls.linenumber
		lex_next(ls) // skip the operator
		code_infix(ls.fs, op, v)
		nextop := subexpr(ls, &v2, int(binop_priority[int(op)].right))
		code_posfix(ls.fs, op, v, &v2, line)
		op = nextop
	}
	leavelevel(ls)
	return op // the first untreated operator
}

// Parse a full expression. Reference `expr`.
@(private = "file")
expr :: proc(ls: ^LexState, v: ^Expdesc) {
	subexpr(ls, v, 0)
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

// Parse a `{ statlist }`-style block inside its own scope. Reference `block`.
@(private = "file")
block :: proc(ls: ^LexState) {
	fs := ls.fs
	bl: BlockCnt
	enterblock(fs, &bl, 0)
	statlist(ls)
	leaveblock(fs)
}

// A node in the chain of variables on the left of a multiple assignment.
// Reference `struct LHS_assign`.
@(private = "file")
LHS_assign :: struct {
	prev: ^LHS_assign,
	v:    Expdesc,
}

// Guard against a table assignment clobbering a local/upvalue that a *previous*
// assignment in the same statement still needs, by copying the value to a safe
// temporary register. Reference `check_conflict`.
@(private = "file")
check_conflict :: proc(ls: ^LexState, lh: ^LHS_assign, v: ^Expdesc) {
	fs := ls.fs
	extra := fs.freereg // where a safe copy would go
	conflict := false
	for l := lh; l != nil; l = l.prev {
		if vkisindexed(l.v.k) { // assignment to a table field?
			if l.v.k == .VINDEXUP { // table is an upvalue?
				if v.k == .VUPVAL && l.v.u.ind.t == u8(v.u.info) {
					conflict = true
					l.v.k = .VINDEXSTR
					l.v.u.ind.t = u8(extra) // use the safe copy
				}
			} else { // table is a register
				if v.k == .VLOCAL && l.v.u.ind.t == v.u.var.ridx {
					conflict = true
					l.v.u.ind.t = u8(extra) // use the safe copy
				}
				if l.v.k == .VINDEXED && v.k == .VLOCAL && l.v.u.ind.idx == i16(v.u.var.ridx) {
					conflict = true
					l.v.u.ind.idx = i16(extra) // use the safe copy
				}
			}
		}
	}
	if conflict {
		// Copy the local/upvalue into the temporary at 'extra'.
		if v.k == .VLOCAL {
			code_codeABC(fs, .MOVE, extra, int(v.u.var.ridx), 0)
		} else {
			code_codeABC(fs, .GETUPVAL, extra, v.u.info, 0)
		}
		code_reserveregs(fs, 1)
	}
}

// Store the top register into variable `var` (the default assignment path).
// Reference `storevartop`.
@(private = "file")
storevartop :: proc(fs: ^FuncState, var: ^Expdesc) {
	e: Expdesc
	init_exp(&e, .VNONRELOC, fs.freereg - 1)
	code_storevar(fs, var, &e) // also frees the top register
}

// Parse and compile the tail of a (possibly multiple) assignment; the first
// target was already read by the caller. Reference `restassign`.
@(private = "file")
restassign :: proc(ls: ^LexState, lh: ^LHS_assign, nvars: int) {
	e: Expdesc
	if !vkisvar(lh.v.k) {
		lex_syntaxerror(ls, "syntax error")
	}
	check_readonly(ls, &lh.v)
	if testnext(ls, ',') { // more targets: ',' suffixedexp restassign
		nv: LHS_assign
		nv.prev = lh
		suffixedexp(ls, &nv.v)
		if !vkisindexed(nv.v.k) {
			check_conflict(ls, lh, &nv.v)
		}
		enterlevel(ls) // control recursion depth
		restassign(ls, &nv, nvars + 1)
		leavelevel(ls)
	} else { // '=' explist
		nexps := 0
		checknext(ls, '=')
		nexps = explist(ls, &e)
		if nexps != nvars {
			adjust_assign(ls, nvars, nexps, &e)
		} else {
			code_setoneret(ls.fs, &e) // close the last expression
			code_storevar(ls.fs, &lh.v, &e)
			return // avoid the default path below
		}
	}
	storevartop(ls.fs, &lh.v) // default assignment
}

// Parse a condition, compile a "jump if false", and return the false-list.
// Reference `cond`.
@(private = "file")
cond :: proc(ls: ^LexState) -> int {
	v: Expdesc
	expr(ls, &v)
	if v.k == .VNIL { // 'nil' and 'false' behave identically here
		v.k = .VFALSE
	}
	code_goiftrue(ls.fs, &v)
	return v.f
}

// Parse `goto NAME`. Reference `gotostat`.
@(private = "file")
gotostat :: proc(ls: ^LexState, line: int) {
	name := str_checkname(ls)
	newgotoentry(ls, name, line)
}

// Parse `break` (semantically `goto break` to the nearest loop). Reference
// `breakstat`.
@(private = "file")
breakstat :: proc(ls: ^LexState, line: int) {
	found: ^BlockCnt = nil
	for bl := ls.fs.bl; bl != nil; bl = bl.previous {
		if bl.isloop != 0 { // an enclosing loop?
			found = bl
			break
		}
	}
	if found == nil {
		lex_syntaxerror(ls, "break outside loop")
	}
	found.isloop = 2 // signal that the block has pending breaks
	lex_next(ls) // skip 'break'
	newgotoentry(ls, ls.brkn, line)
}

// Error if a label with this name already exists in the current function.
// Reference `checkrepeated`.
@(private = "file")
checkrepeated :: proc(ls: ^LexState, name: ^TString) {
	lb := findlabel(ls, name, ls.fs.firstlabel)
	if lb != nil {
		code_semerror(ls, "label '%s' already defined on line %d", getstr(name), lb.line)
	}
}

// Parse `:: NAME ::` (a label). Reference `labelstat`.
@(private = "file")
labelstat :: proc(ls: ^LexState, name: ^TString, line: int) {
	checknext(ls, TK_DBCOLON) // skip '::'
	for ls.t.token == ';' || ls.t.token == TK_DBCOLON {
		statement(ls) // skip other no-op statements
	}
	checkrepeated(ls, name)
	createlabel(ls, name, line, block_follow(ls, false))
}

// Parse `while cond do block end`. Reference `whilestat`.
@(private = "file")
whilestat :: proc(ls: ^LexState, line: int) {
	fs := ls.fs
	bl: BlockCnt
	lex_next(ls) // skip WHILE
	whileinit := code_getlabel(fs)
	condexit := cond(ls)
	enterblock(fs, &bl, 1)
	checknext(ls, TK_DO)
	block(ls)
	code_patchlist(fs, code_jump(fs), whileinit) // loop back (luaK_jumpto)
	check_match(ls, TK_END, TK_WHILE, line)
	leaveblock(fs)
	code_patchtohere(fs, condexit) // false conditions exit the loop
}

// Parse `repeat block until cond`. Reference `repeatstat`.
@(private = "file")
repeatstat :: proc(ls: ^LexState, line: int) {
	fs := ls.fs
	repeat_init := code_getlabel(fs)
	bl1, bl2: BlockCnt
	enterblock(fs, &bl1, 1) // loop block
	enterblock(fs, &bl2, 0) // scope block
	lex_next(ls) // skip REPEAT
	statlist(ls)
	check_match(ls, TK_UNTIL, TK_REPEAT, line)
	condexit := cond(ls) // read the condition (inside the scope block)
	leaveblock(fs) // finish the scope
	if bl2.upval != 0 { // upvalues to close?
		exit := code_jump(fs) // the normal exit must jump over the fix
		code_patchtohere(fs, condexit) // repetition closes upvalues
		code_codeABC(fs, .CLOSE, reglevel(fs, int(bl2.nactvar)), 0, 0)
		condexit = code_jump(fs) // repeat after closing
		code_patchtohere(fs, exit)
	}
	code_patchlist(fs, condexit, repeat_init) // close the loop
	leaveblock(fs) // finish the loop
}

// Parse an expression and emit its value into the next stack slot. Reference
// `exp1`.
@(private = "file")
exp1 :: proc(ls: ^LexState) {
	e: Expdesc
	expr(ls, &e)
	code_exp2nextreg(ls.fs, &e)
}

// Fix the jump instruction at `pc` to target `dest` (relative; `back` for a
// backward jump). Reference `fixforjump`.
@(private = "file")
fixforjump :: proc(fs: ^FuncState, pc, dest: int, back: bool) {
	jmp := &fs.f.code[pc]
	offset := dest - (pc + 1)
	if back {
		offset = -offset
	}
	if offset > MAXARG_Bx {
		lex_syntaxerror(fs.ls, "control structure too long")
	}
	setarg_Bx(jmp, offset)
}

// Emit the body of a numeric or generic `for` loop. `isgen` selects the
// generic-for opcodes. Reference `forbody`.
@(private = "file")
forbody :: proc(ls: ^LexState, base, line, nvars: int, isgen: bool) {
	forprep := [2]Op_Code{.FORPREP, .TFORPREP}
	forloop := [2]Op_Code{.FORLOOP, .TFORLOOP}
	sel := isgen ? 1 : 0
	fs := ls.fs
	bl: BlockCnt
	checknext(ls, TK_DO)
	prep := code_codeABx(fs, forprep[sel], base, 0)
	fs.freereg -= 1 // both 'forprep' opcodes pop one register
	enterblock(fs, &bl, 0) // scope for the declared control variables
	adjustlocalvars(ls, nvars)
	code_reserveregs(fs, nvars)
	block(ls)
	leaveblock(fs)
	fixforjump(fs, prep, code_getlabel(fs), false)
	if isgen { // generic for needs a TFORCALL before the loop test
		code_codeABC(fs, .TFORCALL, base, 0, nvars)
		code_fixline(fs, line)
	}
	endfor := code_codeABx(fs, forloop[sel], base, 0)
	fixforjump(fs, endfor, prep + 1, true)
	code_fixline(fs, line)
}

// Parse a numeric `for NAME = e1, e2 [, e3] do ... end`. Reference `fornum`.
@(private = "file")
fornum :: proc(ls: ^LexState, varname: ^TString, line: int) {
	fs := ls.fs
	base := fs.freereg
	new_localvarliteral(ls, "(for state)")
	new_localvarliteral(ls, "(for state)")
	new_varkind(ls, varname, RDKCONST) // the control variable
	checknext(ls, '=')
	exp1(ls) // initial value
	checknext(ls, ',')
	exp1(ls) // limit
	if testnext(ls, ',') {
		exp1(ls) // optional step
	} else { // default step of 1
		code_int(fs, fs.freereg, 1)
		code_reserveregs(fs, 1)
	}
	adjustlocalvars(ls, 2) // the two internal state variables
	forbody(ls, base, line, 1, false)
}

// Parse a generic `for NAME {, NAME} in explist do ... end`. Reference
// `forlist`.
@(private = "file")
forlist :: proc(ls: ^LexState, indexname: ^TString) {
	fs := ls.fs
	e: Expdesc
	nvars := 4 // function, state, closing, control
	base := fs.freereg
	new_localvarliteral(ls, "(for state)") // iterator function
	new_localvarliteral(ls, "(for state)") // state
	new_localvarliteral(ls, "(for state)") // closing variable (after swap)
	new_varkind(ls, indexname, RDKCONST) // the control variable
	for testnext(ls, ',') { // any further declared variables
		new_localvar(ls, str_checkname(ls))
		nvars += 1
	}
	checknext(ls, TK_IN)
	line := ls.linenumber
	adjust_assign(ls, 4, explist(ls, &e), &e)
	adjustlocalvars(ls, 3) // the three internal state variables
	marktobeclosed(fs) // the last internal variable must be closed
	code_checkstack(fs, 2) // extra space to call the iterator
	forbody(ls, base, line, nvars - 3, true)
}

// Parse a `for` statement, dispatching to numeric or generic form. Reference
// `forstat`.
@(private = "file")
forstat :: proc(ls: ^LexState, line: int) {
	fs := ls.fs
	bl: BlockCnt
	enterblock(fs, &bl, 1) // scope for the loop and control variables
	lex_next(ls) // skip 'for'
	varname := str_checkname(ls) // first variable name
	switch ls.t.token {
	case '=':
		fornum(ls, varname, line)
	case ',', TK_IN:
		forlist(ls, varname)
	case:
		lex_syntaxerror(ls, "'=' or 'in' expected")
	}
	check_match(ls, TK_END, TK_FOR, line)
	leaveblock(fs) // 'break' jumps here
}

// Parse one `[IF|ELSEIF] cond THEN block`, chaining its exit onto `escapelist`.
// Reference `test_then_block`.
@(private = "file")
test_then_block :: proc(ls: ^LexState, escapelist: ^int) {
	fs := ls.fs
	lex_next(ls) // skip IF or ELSEIF
	condtrue := cond(ls)
	checknext(ls, TK_THEN)
	block(ls) // the 'then' part
	if ls.t.token == TK_ELSE || ls.t.token == TK_ELSEIF { // more parts follow?
		code_concat(fs, escapelist, code_jump(fs)) // jump over them
	}
	code_patchtohere(fs, condtrue)
}

// Parse a full `if ... [elseif ...] [else ...] end`. Reference `ifstat`.
@(private = "file")
ifstat :: proc(ls: ^LexState, line: int) {
	fs := ls.fs
	escapelist := NO_JUMP
	test_then_block(ls, &escapelist) // IF cond THEN block
	for ls.t.token == TK_ELSEIF {
		test_then_block(ls, &escapelist) // ELSEIF cond THEN block
	}
	if testnext(ls, TK_ELSE) {
		block(ls) // ELSE block
	}
	check_match(ls, TK_END, TK_IF, line)
	code_patchtohere(fs, escapelist)
}

// Parse `local function NAME body`. Reference `localfunc`.
@(private = "file")
localfunc :: proc(ls: ^LexState) {
	b: Expdesc
	fs := ls.fs
	fvar := int(fs.nactvar) // the function's own variable index
	new_localvar(ls, str_checkname(ls))
	adjustlocalvars(ls, 1) // enter its scope (visible to itself: recursion)
	body(ls, &b, false, ls.linenumber)
	// The debug info only "sees" the variable from here on.
	localdebuginfo(fs, fvar).startpc = fs.pc
}

// Parse an optional `< NAME >` attribute, returning its kind (or `df` if absent).
// Reference `getvarattribute`.
@(private = "file")
getvarattribute :: proc(ls: ^LexState, df: u8) -> u8 {
	if testnext(ls, '<') {
		ts := str_checkname(ls)
		attr := getstr(ts)
		checknext(ls, '>')
		if attr == "const" {
			return RDKCONST
		} else if attr == "close" {
			return RDKTOCLOSE
		} else {
			code_semerror(ls, "unknown attribute '%s'", attr)
		}
	}
	return df
}

// Emit the TBC instruction for a to-be-closed local (if there is one). Reference
// `checktoclose`.
@(private = "file")
checktoclose :: proc(fs: ^FuncState, level: int) {
	if level != -1 {
		marktobeclosed(fs)
		code_codeABC(fs, .TBC, reglevel(fs, level), 0, 0)
	}
}

// Parse `local NAME attrib {, NAME attrib} [= explist]`. Reference `localstat`.
@(private = "file")
localstat :: proc(ls: ^LexState) {
	fs := ls.fs
	toclose := -1 // register level of a to-be-closed variable, if any
	vidx := 0 // index of the last declared variable
	nvars := 0
	nexps := 0
	e: Expdesc
	defkind := getvarattribute(ls, VDKREG) // prefixed attribute (default kind)
	for { // for each declared variable
		vname := str_checkname(ls)
		kind := getvarattribute(ls, defkind) // postfixed attribute
		vidx = new_varkind(ls, vname, kind)
		if kind == RDKTOCLOSE {
			if toclose != -1 {
				code_semerror(ls, "multiple to-be-closed variables in local list")
			}
			toclose = int(fs.nactvar) + nvars
		}
		nvars += 1
		if !testnext(ls, ',') {
			break
		}
	}
	if testnext(ls, '=') {
		nexps = explist(ls, &e)
	} else {
		e.k = .VVOID
		nexps = 0
	}
	var := getlocalvardesc(fs, vidx) // the last variable
	if nvars == nexps && var.kind == RDKCONST && code_exp2const(fs, &e, &var.k) {
		// A single `<const>` initialized by a compile-time constant folds away.
		var.kind = RDKCTC // compile-time constant
		adjustlocalvars(ls, nvars - 1) // all but the last
		fs.nactvar += 1 // but still count the last one
	} else {
		adjust_assign(ls, nvars, nexps, &e)
		adjustlocalvars(ls, nvars)
	}
	checktoclose(fs, toclose)
}

// Parse a global attribute, mapping const→GDKCONST and rejecting `<close>`.
// Reference `getglobalattribute`.
@(private = "file")
getglobalattribute :: proc(ls: ^LexState, df: u8) -> u8 {
	kind := getvarattribute(ls, df)
	switch kind {
	case RDKTOCLOSE:
		code_semerror(ls, "global variables cannot be to-be-closed")
		return kind
	case RDKCONST:
		return GDKCONST
	case:
		return kind
	}
}

// Emit the run-time check that a global being defined does not already exist.
// Reference `checkglobal`.
@(private = "file")
checkglobal :: proc(ls: ^LexState, varname: ^TString, line: int) {
	fs := ls.fs
	var: Expdesc
	buildglobal(ls, varname, &var)
	k := var.u.ind.keystr // index of the global's name constant
	code_codecheckglobal(fs, &var, k, line)
}

// Recursively build the target descriptors for a `global a, b = ...` list, then
// (at the deepest level) read the initializer list and, unwinding, store each
// value. Reference `initglobal`.
@(private = "file")
initglobal :: proc(ls: ^LexState, nvars, firstidx, n, line: int) {
	if n == nvars { // traversed every variable?
		e: Expdesc
		nexps := explist(ls, &e)
		adjust_assign(ls, nvars, nexps, &e)
	} else {
		fs := ls.fs
		var: Expdesc
		varname := getlocalvardesc(fs, firstidx + n).name
		buildglobal(ls, varname, &var)
		enterlevel(ls) // control recursion depth
		initglobal(ls, nvars, firstidx, n + 1, line)
		leavelevel(ls)
		checkglobal(ls, varname, line)
		storevartop(fs, &var)
	}
}

// Parse a `global NAME attrib {, NAME attrib} [= explist]` declaration list.
// Reference `globalnames`.
@(private = "file")
globalnames :: proc(ls: ^LexState, defkind: u8) {
	fs := ls.fs
	nvars := 0
	lastidx := 0
	for {
		vname := str_checkname(ls)
		kind := getglobalattribute(ls, defkind)
		lastidx = new_varkind(ls, vname, kind)
		nvars += 1
		if !testnext(ls, ',') {
			break
		}
	}
	if testnext(ls, '=') {
		initglobal(ls, nvars, lastidx - nvars + 1, 0, ls.linenumber)
	}
	fs.nactvar = i16(int(fs.nactvar) + nvars) // activate the declarations
}

// Parse a `global` declaration, handling the collective `global *` form.
// Reference `globalstat`.
@(private = "file")
globalstat :: proc(ls: ^LexState) {
	fs := ls.fs
	defkind := getglobalattribute(ls, GDKREG)
	if !testnext(ls, '*') {
		globalnames(ls, defkind)
	} else {
		new_varkind(ls, nil, defkind) // a nil name represents '*'
		fs.nactvar += 1 // activate the declaration
	}
}

// Parse `global function NAME body`. Reference `globalfunc`.
@(private = "file")
globalfunc :: proc(ls: ^LexState, line: int) {
	var, b: Expdesc
	fs := ls.fs
	fname := str_checkname(ls)
	new_varkind(ls, fname, GDKREG) // declare the global
	fs.nactvar += 1 // enter its scope
	buildglobal(ls, fname, &var)
	body(ls, &b, false, ls.linenumber)
	checkglobal(ls, fname, line)
	code_storevar(fs, &var, &b)
	code_fixline(fs, line) // definition "happens" on the first line
}

// Dispatch `global function ...` vs `global ...` declarations. Reference
// `globalstatfunc`.
@(private = "file")
globalstatfunc :: proc(ls: ^LexState, line: int) {
	lex_next(ls) // skip 'global'
	if testnext(ls, TK_FUNCTION) {
		globalfunc(ls, line)
	} else {
		globalstat(ls)
	}
}

// Parse a function name `NAME {.NAME} [:NAME]`, returning whether it is a method
// (has a `:` component). Reference `funcname`.
@(private = "file")
funcname :: proc(ls: ^LexState, v: ^Expdesc) -> bool {
	ismethod := false
	singlevar(ls, v)
	for ls.t.token == '.' {
		fieldsel(ls, v)
	}
	if ls.t.token == ':' {
		ismethod = true
		fieldsel(ls, v)
	}
	return ismethod
}

// Parse a `function funcname body` statement. Reference `funcstat`.
@(private = "file")
funcstat :: proc(ls: ^LexState, line: int) {
	v, b: Expdesc
	lex_next(ls) // skip FUNCTION
	ismethod := funcname(ls, &v)
	check_readonly(ls, &v)
	body(ls, &b, ismethod, line)
	code_storevar(ls.fs, &v, &b)
	code_fixline(ls.fs, line) // definition "happens" on the first line
}

// Parse an expression statement: either a function call or an assignment.
// Reference `exprstat`.
@(private = "file")
exprstat :: proc(ls: ^LexState) {
	fs := ls.fs
	v: LHS_assign
	suffixedexp(ls, &v.v)
	if ls.t.token == '=' || ls.t.token == ',' { // an assignment?
		v.prev = nil
		restassign(ls, &v, 1)
	} else { // a call used as a statement
		if v.v.k != .VCALL {
			lex_syntaxerror(ls, "syntax error")
		}
		inst := getinstruction(fs, &v.v)
		setarg_C(inst, 1) // a statement call keeps no results
	}
}

// Parse `return [explist] [';']`. Reference `retstat`.
@(private = "file")
retstat :: proc(ls: ^LexState) {
	fs := ls.fs
	e: Expdesc
	first := parse_nvarstack(fs) // first slot that will be returned
	nret: int
	if block_follow(ls, true) || ls.t.token == ';' {
		nret = 0 // return no values
	} else {
		nret = explist(ls, &e) // the return values
		if hasmultret(e.k) {
			code_setreturns(fs, &e, MULTRET)
			if e.k == .VCALL && nret == 1 && fs.bl.insidetbc == 0 { // tail call?
				set_opcode(getinstruction(fs, &e), .TAILCALL)
			}
			nret = MULTRET // return all values
		} else {
			if nret == 1 { // a single value can stay in its own slot
				first = code_exp2anyreg(fs, &e)
			} else { // several values must sit at the top of the stack
				code_exp2nextreg(fs, &e)
			}
		}
	}
	code_ret(fs, first, nret)
	testnext(ls, ';') // skip the optional semicolon
}

// Parse a single statement, dispatching on the leading token. Reference
// `statement`.
@(private = "file")
statement :: proc(ls: ^LexState) {
	line := ls.linenumber // may be needed for error messages
	enterlevel(ls)
	switch ls.t.token {
	case ';': // empty statement
		lex_next(ls)
	case TK_IF:
		ifstat(ls, line)
	case TK_WHILE:
		whilestat(ls, line)
	case TK_DO: // DO block END
		lex_next(ls)
		block(ls)
		check_match(ls, TK_END, TK_DO, line)
	case TK_FOR:
		forstat(ls, line)
	case TK_REPEAT:
		repeatstat(ls, line)
	case TK_FUNCTION:
		funcstat(ls, line)
	case TK_LOCAL: // LOCAL function or LOCAL variable list
		lex_next(ls)
		if testnext(ls, TK_FUNCTION) {
			localfunc(ls)
		} else {
			localstat(ls)
		}
	case TK_GLOBAL:
		globalstatfunc(ls, line)
	case TK_DBCOLON: // label
		lex_next(ls)
		labelstat(ls, str_checkname(ls), line)
	case TK_RETURN:
		lex_next(ls)
		retstat(ls)
	case TK_BREAK:
		breakstat(ls, line)
	case TK_GOTO:
		lex_next(ls)
		gotostat(ls, line)
	case:
		// A function call or assignment. In compatibility mode, "global" is not
		// a reserved word, so recognize it as a keyword here when it is followed
		// by something that begins a global declaration.
		when COMPAT_GLOBAL {
			if ls.t.token == TK_NAME && ls.t.seminfo.ts == ls.glbn {
				lk := lex_lookahead(ls)
				if lk == '<' || lk == TK_NAME || lk == '*' || lk == TK_FUNCTION {
					globalstatfunc(ls, line)
					break
				}
			}
		}
		exprstat(ls)
	}
	// Every statement must leave the register machine tidy: free the scratch
	// registers, keeping only those holding live locals.
	ls.fs.freereg = parse_nvarstack(ls.fs)
	leavelevel(ls)
}

// ---------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------

// Compile the main chunk: a vararg function with a single upvalue named `_ENV`.
// Reference `mainfunc`.
@(private = "file")
mainfunc :: proc(ls: ^LexState, fs: ^FuncState) {
	bl: BlockCnt
	open_func(ls, fs, &bl)
	setvararg(fs) // the main function is always vararg
	env := allocupvalue(fs) // ...and its sole upvalue is _ENV
	env.instack = 1
	env.idx = 0
	env.kind = VDKREG
	env.name = ls.envn
	gc_barrier(ls.L, obj2gco(fs.f), obj2gco(env.name))
	lex_next(ls) // read the first token
	statlist(ls) // parse the body
	check(ls, TK_EOS)
	close_func(ls)
}

// Compile the chunk read from `z` into a main closure, byte-compatible with
// reference Lua's `Proto` shape. Anchors the closure, scanner table, prototype,
// and source string on the Lua stack across allocations. Reference
// `luaY_parser`.
parse_parser :: proc(
	L: ^State,
	z: ^Zio,
	buff: ^Mbuffer,
	dyd: ^Dyndata,
	name: string,
	firstchar: int,
) -> ^LClosure {
	lexstate: LexState
	funcstate: FuncState
	cl := func_newLclosure(L, 1) // the main closure (one upvalue: _ENV)
	set_lua_closure(stack_value(L, L.top), cl) // anchor it against collection
	inc_top(L)
	lexstate.h = table_new(L) // scanner's string-anchoring table
	set_gc(stack_value(L, L.top), obj2gco(lexstate.h)) // anchor it
	inc_top(L)
	funcstate.f = func_newproto(L)
	cl.p = funcstate.f
	gc_barrier(L, obj2gco(cl), obj2gco(cl.p))
	funcstate.f.source = string_new(L, name) // create and anchor the source name
	gc_barrier(L, obj2gco(funcstate.f), obj2gco(funcstate.f.source))
	lexstate.buff = buff
	lexstate.dyd = dyd
	dyd.actvar.n = 0
	dyd.gt.n = 0
	dyd.label.n = 0
	lex_setinput(L, &lexstate, z, funcstate.f.source, firstchar)
	mainfunc(&lexstate, &funcstate)
	L.top -= 1 // pop the scanner's table (closure stays on the stack)
	return cl
}
