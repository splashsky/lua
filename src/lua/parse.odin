package lua

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
// TODO(phase-4): the recursive-descent grammar, scope/local/upvalue management,
// and Proto construction driving `code`.

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
luaY_nvarstack :: proc "contextless" (fs: ^FuncState) -> int {
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
		loc = string(str_slice(luaO_pushfstring(L, "function at line %d", line)))
	}
	msg := string(
		str_slice(
			luaO_pushfstring(L, "too many %s (limit is %d) in %s", what, limit, loc),
		),
	)
	luaX_syntaxerror(fs.ls, msg)
}

// Assert that value 'v' does not exceed limit 'l'; raise otherwise. Reference
// `luaY_checklimit`.
luaY_checklimit :: proc(fs: ^FuncState, v: int, l: int, what: string) {
	if v > l {
		errorlimit(fs, l, what)
	}
}
