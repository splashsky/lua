package lua

import "core:math"

// code.odin -- our analogue of reference Lua's `lcode.h` / `lcode.c`.
//
// The low-level code generator the parser drives. It handles the fiddly parts of
// emitting bytecode: allocating and freeing VM registers, managing the constant
// table, folding constant arithmetic, discharging expressions into registers,
// and backpatching jump lists for control flow. It's where an expression's
// abstract description becomes concrete instructions.
//
// ---------------------------------------------------------------------------
// Constants, operator enums, and tiny helpers
// ---------------------------------------------------------------------------

// Marks the end of a patch list -- reference `NO_JUMP`. It is invalid both as an
// absolute code address and as a list link (it would link an element to itself).
NO_JUMP :: -1

// A 32-bit INT_MAX, matching reference Lua's `INT_MAX` used as the "no real
// limit" cap when growing the code/line-info arrays. We spell it explicitly (not
// Odin's `max(int)`, which is 64-bit here) so the overflow behavior of the growth
// math matches reference Lua's 32-bit `int` exactly.
MAX_INT :: 0x7FFFFFFF

// The largest constant index that still fits in an instruction's `argC` field, so
// it can be referenced directly as a "K" operand. Reference `MAXINDEXRK`.
MAXINDEXRK :: MAXARG_B

// Line-info encoding constants (reference `ldebug.h`/`lcode.c`).
//
//   ABSLINEINFO -- the sentinel stored in a relative `lineinfo` byte to say "the
//                  real line for this instruction lives in `abslineinfo`".
//   MAXIWTHABS  -- after this many instructions we force a fresh absolute entry
//                  so line lookups never scan too far.
//   LIMLINEDIFF -- if the line delta doesn't fit in a signed byte below this, we
//                  also fall back to an absolute entry.
ABSLINEINFO :: -0x80
MAXIWTHABS :: 128
LIMLINEDIFF :: 0x80

// Binary operator priorities live in the parser; here we only need the operator
// *enums* to translate parsed operators into opcodes/metamethods. The ORDER is
// load-bearing ("grep ORDER OPR") -- several conversions below are pure index
// arithmetic against these, so they must mirror reference Lua's `BinOpr`/`UnOpr`
// verbatim.
BinOpr :: enum u32 {
	// arithmetic
	OPR_ADD, OPR_SUB, OPR_MUL, OPR_MOD, OPR_POW,
	OPR_DIV, OPR_IDIV,
	// bitwise
	OPR_BAND, OPR_BOR, OPR_BXOR,
	OPR_SHL, OPR_SHR,
	// string
	OPR_CONCAT,
	// comparison
	OPR_EQ, OPR_LT, OPR_LE,
	OPR_NE, OPR_GT, OPR_GE,
	// logical
	OPR_AND, OPR_OR,
	OPR_NOBINOPR,
}

UnOpr :: enum u32 {
	OPR_MINUS,
	OPR_BNOT,
	OPR_NOT,
	OPR_LEN,
	OPR_NOUNOPR,
}

// True iff the operation is foldable (arithmetic or bitwise). Reference
// `foldbinop`.
foldbinop :: #force_inline proc "contextless" (op: BinOpr) -> bool {
	return op <= BinOpr.OPR_SHR
}

// Does expression 'e' carry pending jumps (from `and`/`or`/comparisons)?
// Reference `hasjumps`.
hasjumps :: #force_inline proc "contextless" (e: ^Expdesc) -> bool {
	return e.t != e.f
}

// The (pointer to the) instruction an expression refers to by pc. Reference macro
// `getinstruction`; we hand back a pointer so callers can both read and patch.
getinstruction :: #force_inline proc "contextless" (fs: ^FuncState, e: ^Expdesc) -> ^Instruction {
	return &fs.f.code[e.u.info]
}

// The number-as-Number view of a numeric TValue -- reference `nvalue`. Used only
// by folding/validity checks where the value is already known to be numeric.
@(private = "file")
nvalue :: #force_inline proc "contextless" (o: ^TValue) -> Number {
	return is_integer(o) ? Number(int_value(o)) : flt_value(o)
}

// Mark that a function will need a runtime vararg *table* (rather than the hidden
// register-based vararg convention). Reference `needvatab`.
@(private = "file")
needvatab :: #force_inline proc "contextless" (p: ^Proto) {
	p.flag |= PF_VATAB
}

// A short-string test on a raw TString -- reference `strisshr`.
@(private = "file")
strisshr :: #force_inline proc "contextless" (ts: ^TString) -> bool {
	return ts.tt == VSHRSTR
}

// ---------------------------------------------------------------------------
// Semantic errors, numerals, constants-as-expressions
// ---------------------------------------------------------------------------

// Raise a *semantic* error (a well-formed token that means something illegal,
// e.g. assigning to a <const>). Reference `luaK_semerror`: it drops the "near
// <token>" suffix (the token itself is fine) and reports at the last used line.
luaK_semerror :: proc(ls: ^LexState, fmt: string, args: ..any) {
	msg := string(str_slice(luaO_pushfstring(ls.L, fmt, ..args)))
	ls.t.token = 0 // remove "near <token>" from final message
	ls.linenumber = ls.lastline // back to line of last used token
	luaX_syntaxerror(ls, msg)
}

// If 'e' is a numeric constant, copy it into 'v' and return true. Reference
// `tonumeral`. 'v' may be nil when the caller only wants the yes/no answer.
@(private = "file")
tonumeral :: proc "contextless" (e: ^Expdesc, v: ^TValue) -> bool {
	if hasjumps(e) {
		return false // an expression with jumps is not a plain numeral
	}
	#partial switch e.k {
	case .VKINT:
		if v != nil {set_int(v, e.u.ival)}
		return true
	case .VKFLT:
		if v != nil {set_float(v, e.u.nval)}
		return true
	case:
		return false
	}
}

// Fetch the value behind a <const> expression. Reference `const2val`: the value
// was stashed in the active-variable table when the constant was declared.
@(private = "file")
const2val :: #force_inline proc "contextless" (fs: ^FuncState, e: ^Expdesc) -> ^TValue {
	return &fs.ls.dyd.actvar.arr[e.u.info].k
}

// If 'e' is a compile-time constant, materialize it into 'v' and return true.
// Reference `luaK_exp2const`. Unlike `tonumeral` this also handles nil, booleans,
// strings, and named <const>s.
luaK_exp2const :: proc "contextless" (fs: ^FuncState, e: ^Expdesc, v: ^TValue) -> bool {
	if hasjumps(e) {
		return false
	}
	#partial switch e.k {
	case .VFALSE:
		set_false(v)
		return true
	case .VTRUE:
		set_true(v)
		return true
	case .VNIL:
		set_nil(v)
		return true
	case .VKSTR:
		set_string(v, e.u.strval)
		return true
	case .VCONST:
		set_obj(v, const2val(fs, e))
		return true
	case:
		return tonumeral(e, v)
	}
}

// ---------------------------------------------------------------------------
// Line information and the raw instruction emitters
// ---------------------------------------------------------------------------

// A read-only "impossible" instruction, returned by `previousinstruction` when a
// jump target may sit between us and the real previous instruction. All ones is
// invalid as an opcode, so no peephole optimization will match it.
@(private = "file")
invalid_instruction: Instruction = ~Instruction(0)

// The previous instruction, or an invalid stand-in if a jump could land between
// it and the current pc (which would make peephole merging unsound). Reference
// `previousinstruction`.
@(private = "file")
previousinstruction :: proc "contextless" (fs: ^FuncState) -> ^Instruction {
	if fs.pc > fs.lasttarget {
		return &fs.f.code[fs.pc - 1]
	}
	return &invalid_instruction
}

// Emit `OP_LOADNIL` for `R[from] .. R[from+n-1]`, merging with an immediately
// preceding LOADNIL when their ranges touch (so `local a; local b` is one op).
// Reference `luaK_nil`.
luaK_nil :: proc(fs: ^FuncState, from: int, n: int) {
	from := from
	l := from + n - 1 // last register to set nil
	previous := previousinstruction(fs)
	if get_opcode(previous^) == .LOADNIL { 	// previous is LOADNIL?
		pfrom := getarg_A(previous^) // start of previous range
		pl := pfrom + getarg_B(previous^) // end of previous range
		if (pfrom <= from && from <= pl + 1) || (from <= pfrom && pfrom <= l + 1) {
			// ranges connect: widen the previous instruction to cover both
			if pfrom < from {from = pfrom} // from = min(from, pfrom)
			if pl > l {l = pl} // l = max(l, pl)
			setarg_A(previous, from)
			setarg_B(previous, l - from)
			return
		}
		// else fall through and emit a fresh instruction
	}
	luaK_codeABC(fs, .LOADNIL, from, n - 1, 0)
}

// Destination of the jump at 'pc', or NO_JUMP if it ends a list. Reference
// `getjump`. A jump that "points to itself" (offset NO_JUMP) marks the list end.
@(private = "file")
getjump :: proc "contextless" (fs: ^FuncState, pc: int) -> int {
	offset := getarg_sJ(fs.f.code[pc])
	if offset == NO_JUMP {
		return NO_JUMP
	}
	return (pc + 1) + offset // relative offset -> absolute position
}

// Point the jump at 'pc' to absolute address 'dest'. Reference `fixjump`.
@(private = "file")
fixjump :: proc(fs: ^FuncState, pc: int, dest: int) {
	jmp := &fs.f.code[pc]
	offset := dest - (pc + 1)
	if !(-OFFSET_sJ <= offset && offset <= MAXARG_sJ - OFFSET_sJ) {
		luaX_syntaxerror(fs.ls, "control structure too long")
	}
	setarg_sJ(jmp, offset)
}

// Concatenate jump list 'l2' onto the end of the list rooted at 'l1'. Reference
// `luaK_concat`.
luaK_concat :: proc(fs: ^FuncState, l1: ^int, l2: int) {
	if l2 == NO_JUMP {
		return // nothing to concatenate
	}
	if l1^ == NO_JUMP { 	// no original list?
		l1^ = l2
		return
	}
	list := l1^
	for { 	// walk to the last element and link it to 'l2'
		next := getjump(fs, list)
		if next == NO_JUMP {
			break
		}
		list = next
	}
	fixjump(fs, list, l2)
}

// Emit an unconditional jump and return its position (to be fixed later).
// Reference `luaK_jump`.
luaK_jump :: proc(fs: ^FuncState) -> int {
	return codesJ(fs, .JMP, NO_JUMP, 0)
}

// Emit a `return` of 'nret' values starting at register 'first'. Reference
// `luaK_ret`.
luaK_ret :: proc(fs: ^FuncState, first: int, nret: int) {
	op: Op_Code
	switch nret {
	case 0:
		op = .RETURN0
	case 1:
		op = .RETURN1
	case:
		op = .RETURN
	}
	luaY_checklimit(fs, nret + 1, MAXARG_B, "returns")
	luaK_codeABC(fs, op, first, nret + 1, 0)
}

// Emit a test/comparison opcode followed by a jump; return the jump position.
// Reference `condjump`.
@(private = "file")
condjump :: proc(fs: ^FuncState, op: Op_Code, A, B, C, k: int) -> int {
	luaK_codeABCk(fs, op, A, B, C, k)
	return luaK_jump(fs)
}

// Return the current pc and mark it as a jump target so the previous instruction
// won't be peephole-merged across this boundary. Reference `luaK_getlabel`.
luaK_getlabel :: proc(fs: ^FuncState) -> int {
	fs.lasttarget = fs.pc
	return fs.pc
}

// The instruction that *controls* the jump at 'pc' (its preceding test), or the
// jump itself when unconditional. Reference `getjumpcontrol`.
@(private = "file")
getjumpcontrol :: proc "contextless" (fs: ^FuncState, pc: int) -> ^Instruction {
	pi := &fs.f.code[pc]
	if pc >= 1 && test_t_mode(get_opcode((mem_ptr_prev(pi))^)) {
		return mem_ptr_prev(pi)
	}
	return pi
}

// Tiny helper: the instruction one slot before 'pi'. (Odin has no pointer
// arithmetic operator; this keeps `getjumpcontrol` readable.)
@(private = "file")
mem_ptr_prev :: #force_inline proc "contextless" (pi: ^Instruction) -> ^Instruction {
	return ([^]Instruction)(pi)[-1:]
}

// Patch the destination *register* of a TESTSET at 'node'. Returns false if the
// controlling instruction isn't a TESTSET. Reference `patchtestreg`.
@(private = "file")
patchtestreg :: proc(fs: ^FuncState, node: int, reg: int) -> bool {
	i := getjumpcontrol(fs, node)
	if get_opcode(i^) != .TESTSET {
		return false // cannot patch other instructions
	}
	if reg != NO_REG && reg != getarg_B(i^) {
		setarg_A(i, reg)
	} else {
		// no register to receive the value (or it's already there): downgrade to
		// a plain TEST that produces nothing.
		i^ = create_ABCk(.TEST, getarg_B(i^), 0, 0, getarg_k(i^))
	}
	return true
}

// Turn every value-producing test in 'list' into a plain test. Reference
// `removevalues`.
@(private = "file")
removevalues :: proc(fs: ^FuncState, list: int) {
	list := list
	for list != NO_JUMP {
		patchtestreg(fs, list, NO_REG)
		list = getjump(fs, list)
	}
}

// Patch a whole jump list: value-producing tests jump to 'vtarget' (leaving their
// value in 'reg'); the rest jump to 'dtarget'. Reference `patchlistaux`.
@(private = "file")
patchlistaux :: proc(fs: ^FuncState, list: int, vtarget: int, reg: int, dtarget: int) {
	list := list
	for list != NO_JUMP {
		next := getjump(fs, list)
		if patchtestreg(fs, list, reg) {
			fixjump(fs, list, vtarget)
		} else {
			fixjump(fs, list, dtarget)
		}
		list = next
	}
}

// Point every jump in 'list' at already-generated address 'target'. Reference
// `luaK_patchlist`.
luaK_patchlist :: proc(fs: ^FuncState, list: int, target: int) {
	patchlistaux(fs, list, target, NO_REG, target)
}

// Point every jump in 'list' at the current pc. Reference `luaK_patchtohere`.
luaK_patchtohere :: proc(fs: ^FuncState, list: int) {
	hr := luaK_getlabel(fs) // mark "here" as a jump target
	luaK_patchlist(fs, list, hr)
}

// Save the line for the just-emitted instruction, using a relative delta when it
// fits in a byte and falling back to an absolute checkpoint otherwise. Reference
// `savelineinfo`.
@(private = "file")
savelineinfo :: proc(fs: ^FuncState, f: ^Proto, line: int) {
	linedif := line - fs.previousline
	pc := fs.pc - 1 // last instruction coded
	absdif := linedif < 0 ? -linedif : linedif
	// Reference writes `abs(linedif) >= LIMLINEDIFF || fs->iwthabs++ >= MAXIWTHABS`.
	// The `++` is short-circuited: it only runs (and only increments) when the
	// first test is false. We reproduce that exactly so `iwthabs` tracks reference.
	need_abs: bool
	if absdif >= LIMLINEDIFF {
		need_abs = true
	} else {
		need_abs = fs.iwthabs >= MAXIWTHABS
		fs.iwthabs += 1
	}
	if need_abs {
		grow_vector(fs.ls.L, &f.abslineinfo, fs.nabslineinfo, &f.sizeabslineinfo, MAX_INT, "lines")
		f.abslineinfo[fs.nabslineinfo] = AbsLineInfo{pc = pc, line = line}
		fs.nabslineinfo += 1
		linedif = ABSLINEINFO // signal that absolute info exists
		fs.iwthabs = 1 // restart counter
	}
	grow_vector(fs.ls.L, &f.lineinfo, pc, &f.sizelineinfo, MAX_INT, "opcodes")
	f.lineinfo[pc] = i8(linedif)
	fs.previousline = line
}

// Undo the line info attached to the last instruction. Reference
// `removelastlineinfo`.
@(private = "file")
removelastlineinfo :: proc(fs: ^FuncState) {
	f := fs.f
	pc := fs.pc - 1
	if int(f.lineinfo[pc]) != ABSLINEINFO { 	// relative line info?
		fs.previousline -= int(f.lineinfo[pc]) // correct last line saved
		fs.iwthabs -= 1 // undo previous increment
	} else { 	// absolute line info
		fs.nabslineinfo -= 1 // remove it
		fs.iwthabs = MAXIWTHABS + 1 // force next line info to be absolute
	}
}

// Remove the last instruction entirely, fixing up line info. Reference
// `removelastinstruction`.
@(private = "file")
removelastinstruction :: proc(fs: ^FuncState) {
	removelastlineinfo(fs)
	fs.pc -= 1
}

// Append instruction 'i', growing the code array and recording line info. Returns
// the new instruction's index. Reference `luaK_code`.
luaK_code :: proc(fs: ^FuncState, i: Instruction) -> int {
	f := fs.f
	grow_vector(fs.ls.L, &f.code, fs.pc, &f.sizecode, MAX_INT, "opcodes")
	f.code[fs.pc] = i
	fs.pc += 1
	savelineinfo(fs, f, fs.ls.lastline)
	return fs.pc - 1
}

// Emit an iABC-format instruction (with explicit 'k' bit). Reference
// `luaK_codeABCk`.
luaK_codeABCk :: proc(fs: ^FuncState, o: Op_Code, A, B, C, k: int) -> int {
	return luaK_code(fs, create_ABCk(o, A, B, C, k))
}

// The `luaK_codeABC` convenience wrapper (k = 0). Reference macro.
luaK_codeABC :: #force_inline proc(fs: ^FuncState, o: Op_Code, A, B, C: int) -> int {
	return luaK_codeABCk(fs, o, A, B, C, 0)
}

// Emit an ivABC-format instruction (wide B/C, for table ops). Reference
// `luaK_codevABCk`.
luaK_codevABCk :: proc(fs: ^FuncState, o: Op_Code, A, B, C, k: int) -> int {
	return luaK_code(fs, create_vABCk(o, A, B, C, k))
}

// Emit an iABx-format instruction. Reference `luaK_codeABx`.
luaK_codeABx :: proc(fs: ^FuncState, o: Op_Code, A, Bc: int) -> int {
	return luaK_code(fs, create_ABx(o, A, Bc))
}

// Emit an iAsBx-format instruction (signed Bx, biased on the wire). Reference
// `codeAsBx`.
@(private = "file")
codeAsBx :: proc(fs: ^FuncState, o: Op_Code, A, Bc: int) -> int {
	b := Bc + OFFSET_sBx
	return luaK_code(fs, create_ABx(o, A, b))
}

// Emit an isJ-format instruction (signed jump). Reference `codesJ`.
@(private = "file")
codesJ :: proc(fs: ^FuncState, o: Op_Code, sj, k: int) -> int {
	j := sj + OFFSET_sJ
	return luaK_code(fs, create_sJ(o, j, k))
}

// Emit an `OP_EXTRAARG` carrying the wide argument 'A'. Reference `codeextraarg`.
@(private = "file")
codeextraarg :: proc(fs: ^FuncState, A: int) -> int {
	return luaK_code(fs, create_Ax(.EXTRAARG, A))
}

// Load constant 'k' into 'reg', using LOADK when the index fits in Bx or
// LOADKX + EXTRAARG otherwise. Reference `luaK_codek`.
@(private = "file")
luaK_codek :: proc(fs: ^FuncState, reg: int, k: int) -> int {
	if k <= MAXARG_Bx {
		return luaK_codeABx(fs, .LOADK, reg, k)
	}
	p := luaK_codeABx(fs, .LOADKX, reg, 0)
	codeextraarg(fs, k)
	return p
}

// ---------------------------------------------------------------------------
// Register allocation and the constant pool
// ---------------------------------------------------------------------------

// Ensure 'n' more registers are within the function's stack limit, tracking the
// high-water mark in `maxstacksize`. Reference `luaK_checkstack`.
luaK_checkstack :: proc(fs: ^FuncState, n: int) {
	newstack := fs.freereg + n
	if newstack > int(fs.f.maxstacksize) {
		luaY_checklimit(fs, newstack, MAX_FSTACK, "registers")
		fs.f.maxstacksize = u8(newstack)
	}
}

// Reserve 'n' registers on the register stack. Reference `luaK_reserveregs`.
luaK_reserveregs :: proc(fs: ^FuncState, n: int) {
	luaK_checkstack(fs, n)
	fs.freereg += n
}

// Free register 'reg' if it is a temporary (neither a constant index nor a local
// variable's register). Reference `freereg`.
@(private = "file")
freereg :: proc(fs: ^FuncState, reg: int) {
	if reg >= luaY_nvarstack(fs) {
		fs.freereg -= 1
	}
}

// Free two registers, highest first, so the stack stays contiguous. Reference
// `freeregs`.
@(private = "file")
freeregs :: proc(fs: ^FuncState, r1, r2: int) {
	if r1 > r2 {
		freereg(fs, r1)
		freereg(fs, r2)
	} else {
		freereg(fs, r2)
		freereg(fs, r1)
	}
}

// Free the register an expression occupies, if any. Reference `freeexp`.
@(private = "file")
freeexp :: proc(fs: ^FuncState, e: ^Expdesc) {
	if e.k == .VNONRELOC {
		freereg(fs, e.u.info)
	}
}

// Free the registers of two expressions in the proper order. Reference
// `freeexps`.
@(private = "file")
freeexps :: proc(fs: ^FuncState, e1, e2: ^Expdesc) {
	r1 := (e1.k == .VNONRELOC) ? e1.u.info : -1
	r2 := (e2.k == .VNONRELOC) ? e2.u.info : -1
	freeregs(fs, r1, r2)
}

// Append constant 'v' to the prototype's constant pool 'k', returning its index.
// New slots are nil-filled so the GC never scans garbage. Reference `addk`.
@(private = "file")
addk :: proc(fs: ^FuncState, f: ^Proto, v: ^TValue) -> int {
	L := fs.ls.L
	oldsize := f.sizek
	k := fs.nk
	grow_vector(L, &f.k, k, &f.sizek, MAXARG_Ax, "constants")
	for oldsize < f.sizek { 	// nil-fill freshly grown slots
		set_nil(&f.k[oldsize])
		oldsize += 1
	}
	set_obj(&f.k[k], v)
	fs.nk += 1
	if is_collectable(v) { 	// keep the GC's black/white invariant across the store
		luaC_barrier(L, obj2gco(f), v.value_.gc)
	}
	return k
}

// Reuse-or-add a constant, using the scanner's cache table keyed by 'key' (which
// the caller crafts to avoid nil keys and int/float collisions). Reference
// `k2proto`.
@(private = "file")
k2proto :: proc(fs: ^FuncState, key: ^TValue, v: ^TValue) -> int {
	val: TValue
	f := fs.f
	luaH_get(fs.kcache, key, &val) // query scanner table
	if !is_nil(&val) { 	// cache hit: an integer index is stored there
		return int(int_value(&val))
	}
	// miss: create the constant and remember its index for reuse.
	k := addk(fs, f, v)
	set_int(&val, Integer(k))
	luaH_set(fs.ls.L, fs.kcache, key, &val)
	return k
}

// Add a string constant, keyed by the string itself. Reference `stringK`.
@(private = "file")
stringK :: proc(fs: ^FuncState, s: ^TString) -> int {
	o: TValue
	set_string(&o, s)
	return k2proto(fs, &o, &o)
}

// Add an integer constant, keyed by the integer itself. Reference `luaK_intK`.
@(private = "file")
luaK_intK :: proc(fs: ^FuncState, n: Integer) -> int {
	o: TValue
	set_int(&o, n)
	return k2proto(fs, &o, &o)
}

// Add a float constant. Integral-valued floats need a perturbed key so they don't
// collide with the equal integer in the cache. Reference `luaK_numberK`.
@(private = "file")
luaK_numberK :: proc(fs: ^FuncState, r: Number) -> int {
	o, kv: TValue
	set_float(&o, r)
	if r == 0 { 	// zero is special (and -0.0): key on the FuncState, never collides
		set_light_userdata(&kv, rawptr(fs))
		return k2proto(fs, &kv, &o)
	}
	// Perturb by the smallest still-significant power-of-two fraction (2^-52 for
	// doubles). If the perturbed key is non-integral we can safely dedup on it;
	// otherwise just make a fresh entry.
	nbm := 53 // DBL_MANT_DIG for IEEE-754 binary64
	q := Number(math.ldexp(f64(1), -nbm + 1))
	k := r * (1 + q) // key
	set_float(&kv, k)
	_, isint := float_to_integer(k, .Eq)
	if !isint { 	// key is not an integer value: safe to dedup
		n := k2proto(fs, &kv, &o)
		if raw_equal(&fs.f.k[n], &o) { 	// same value we wanted?
			return n
		}
	}
	// integral key or a collision: don't reuse, just add a new constant.
	return addk(fs, fs.f, &o)
}

// Add `false` as a constant, keyed by itself. Reference `boolF`.
@(private = "file")
boolF :: proc(fs: ^FuncState) -> int {
	o: TValue
	set_false(&o)
	return k2proto(fs, &o, &o)
}

// Add `true` as a constant, keyed by itself. Reference `boolT`.
@(private = "file")
boolT :: proc(fs: ^FuncState) -> int {
	o: TValue
	set_true(&o)
	return k2proto(fs, &o, &o)
}

// Add `nil` as a constant. Nil can't be a table key, so we key on the cache table
// itself. Reference `nilK`.
@(private = "file")
nilK :: proc(fs: ^FuncState) -> int {
	k, v: TValue
	set_nil(&v)
	set_gc(&k, obj2gco(fs.kcache)) // use the table itself as the key
	return k2proto(fs, &k, &v)
}

// Does integer 'i' fit in a signed-C (`sC`) operand? Reference `fitsC` -- the
// unsigned add avoids overflow in the hidden `int2sC` bias.
@(private = "file")
fitsC :: proc "contextless" (i: Integer) -> bool {
	return u64(i) + u64(OFFSET_sC) <= u64(MAXARG_C)
}

// Does integer 'i' fit in a signed-Bx (`sBx`) operand? Reference `fitsBx`.
@(private = "file")
fitsBx :: proc "contextless" (i: Integer) -> bool {
	return Integer(-OFFSET_sBx) <= i && i <= Integer(MAXARG_Bx - OFFSET_sBx)
}

// Load integer 'i' into 'reg', as an immediate LOADI when it fits or via the
// constant pool otherwise. Reference `luaK_int`.
luaK_int :: proc(fs: ^FuncState, reg: int, i: Integer) {
	if fitsBx(i) {
		codeAsBx(fs, .LOADI, reg, int(i))
	} else {
		luaK_codek(fs, reg, luaK_intK(fs, i))
	}
}

// Load float 'f' into 'reg', as an immediate LOADF when it is an integral value
// in range or via the constant pool otherwise. Reference `luaK_float`.
@(private = "file")
luaK_float :: proc(fs: ^FuncState, reg: int, f: Number) {
	fi, isint := float_to_integer(f, .Eq)
	if isint && fitsBx(fi) {
		codeAsBx(fs, .LOADF, reg, int(fi))
	} else {
		luaK_codek(fs, reg, luaK_numberK(fs, f))
	}
}

// Emit the "check global not nil" guard after loading a global into a register.
// Reference `luaK_codecheckglobal`.
luaK_codecheckglobal :: proc(fs: ^FuncState, var: ^Expdesc, k: int, line: int) {
	k := k
	luaK_exp2anyreg(fs, var)
	luaK_fixline(fs, line)
	k = (k >= MAXARG_Bx) ? 0 : k + 1
	luaK_codeABx(fs, .ERRNNIL, var.u.info, k)
	luaK_fixline(fs, line)
	freeexp(fs, var)
}

// ---------------------------------------------------------------------------
// Discharging variables and expressions into registers
// ---------------------------------------------------------------------------

// Turn a constant TValue into its expression-descriptor form. Reference
// `const2exp`.
@(private = "file")
const2exp :: proc "contextless" (v: ^TValue, e: ^Expdesc) {
	switch int(type_tag(v)) {
	case VNUMINT:
		e.k = .VKINT
		e.u.ival = int_value(v)
	case VNUMFLT:
		e.k = .VKFLT
		e.u.nval = flt_value(v)
	case VFALSE:
		e.k = .VFALSE
	case VTRUE:
		e.k = .VTRUE
	case VNIL:
		e.k = .VNIL
	case VSHRSTR, VLNGSTR:
		e.k = .VKSTR
		e.u.strval = str_value(v)
	}
}

// Fix a multi-result expression (call or vararg) to yield exactly 'nresults'.
// Reference `luaK_setreturns`.
luaK_setreturns :: proc(fs: ^FuncState, e: ^Expdesc, nresults: int) {
	pc := getinstruction(fs, e)
	luaY_checklimit(fs, nresults + 1, MAXARG_C, "multiple results")
	if e.k == .VCALL {
		setarg_C(pc, nresults + 1)
	} else { 	// VVARARG
		setarg_C(pc, nresults + 1)
		setarg_A(pc, fs.freereg)
		luaK_reserveregs(fs, 1)
	}
}

// Convert a VKSTR to a VK by interning the string into the constant pool.
// Reference `str2K`.
@(private = "file")
str2K :: proc(fs: ^FuncState, e: ^Expdesc) -> int {
	e.u.info = stringK(fs, e.u.strval)
	e.k = .VK
	return e.u.info
}

// Fix a multi-result expression to a single result. Calls become VNONRELOC (their
// result is fixed in the call's base register); varargs become VRELOC. Reference
// `luaK_setoneret`.
luaK_setoneret :: proc(fs: ^FuncState, e: ^Expdesc) {
	if e.k == .VCALL { 	// open function call -> already returns 1 value
		e.k = .VNONRELOC
		e.u.info = getarg_A(getinstruction(fs, e)^)
	} else if e.k == .VVARARG {
		setarg_C(getinstruction(fs, e), 2)
		e.k = .VRELOC // OP_VARARG puts its one result where it wants
	}
}

// Reinterpret a vararg *parameter* as a regular local variable (forcing the
// function to keep a real vararg table). Reference `luaK_vapar2local`.
luaK_vapar2local :: proc(fs: ^FuncState, var: ^Expdesc) {
	needvatab(fs.f)
	var.k = .VLOCAL
}

// Ensure 'e' is not a variable (nor a <const>): resolve locals/upvalues/indexed
// accesses into concrete register loads. Reference `luaK_dischargevars`.
luaK_dischargevars :: proc(fs: ^FuncState, e: ^Expdesc) {
	#partial switch e.k {
	case .VCONST:
		const2exp(const2val(fs, e), e)
	case .VVARGVAR:
		luaK_vapar2local(fs, e) // becomes VLOCAL, then fall through
		fallthrough
	case .VLOCAL: // already in a register
		temp := e.u.var.ridx
		e.u.info = int(temp) // (copy first; the union members overlap)
		e.k = .VNONRELOC
	case .VUPVAL:
		e.u.info = luaK_codeABC(fs, .GETUPVAL, 0, e.u.info, 0)
		e.k = .VRELOC
	case .VINDEXUP:
		e.u.info = luaK_codeABC(fs, .GETTABUP, 0, int(e.u.ind.t), int(e.u.ind.idx))
		e.k = .VRELOC
	case .VINDEXI:
		freereg(fs, int(e.u.ind.t))
		e.u.info = luaK_codeABC(fs, .GETI, 0, int(e.u.ind.t), int(e.u.ind.idx))
		e.k = .VRELOC
	case .VINDEXSTR:
		freereg(fs, int(e.u.ind.t))
		e.u.info = luaK_codeABC(fs, .GETFIELD, 0, int(e.u.ind.t), int(e.u.ind.idx))
		e.k = .VRELOC
	case .VINDEXED:
		freeregs(fs, int(e.u.ind.t), int(e.u.ind.idx))
		e.u.info = luaK_codeABC(fs, .GETTABLE, 0, int(e.u.ind.t), int(e.u.ind.idx))
		e.k = .VRELOC
	case .VVARGIND:
		freeregs(fs, int(e.u.ind.t), int(e.u.ind.idx))
		e.u.info = luaK_codeABC(fs, .GETVARG, 0, int(e.u.ind.t), int(e.u.ind.idx))
		e.k = .VRELOC
	case .VVARARG, .VCALL:
		luaK_setoneret(fs, e)
	case:
		// one value already available somewhere; nothing to do
	}
}

// Put the value of 'e' into register 'reg', making it VNONRELOC. Reference
// `discharge2reg`.
@(private = "file")
discharge2reg :: proc(fs: ^FuncState, e: ^Expdesc, reg: int) {
	luaK_dischargevars(fs, e)
	#partial switch e.k {
	case .VNIL:
		luaK_nil(fs, reg, 1)
	case .VFALSE:
		luaK_codeABC(fs, .LOADFALSE, reg, 0, 0)
	case .VTRUE:
		luaK_codeABC(fs, .LOADTRUE, reg, 0, 0)
	case .VKSTR:
		str2K(fs, e)
		fallthrough
	case .VK:
		luaK_codek(fs, reg, e.u.info)
	case .VKFLT:
		luaK_float(fs, reg, e.u.nval)
	case .VKINT:
		luaK_int(fs, reg, e.u.ival)
	case .VRELOC:
		pc := getinstruction(fs, e)
		setarg_A(pc, reg) // instruction will put its result in 'reg'
	case .VNONRELOC:
		if reg != e.u.info {
			luaK_codeABC(fs, .MOVE, reg, e.u.info, 0)
		}
	case:
		// VJMP: nothing to place here
		return
	}
	e.u.info = reg
	e.k = .VNONRELOC
}

// Put 'e' into some register (reserving one if needed). Reference
// `discharge2anyreg`.
@(private = "file")
discharge2anyreg :: proc(fs: ^FuncState, e: ^Expdesc) {
	if e.k != .VNONRELOC {
		luaK_reserveregs(fs, 1)
		discharge2reg(fs, e, fs.freereg - 1)
	}
}

// Emit a boolean-load that may be a jump target. Reference `code_loadbool`.
@(private = "file")
code_loadbool :: proc(fs: ^FuncState, A: int, op: Op_Code) -> int {
	luaK_getlabel(fs) // these may be jump targets
	return luaK_codeABC(fs, op, A, 0, 0)
}

// Does 'list' contain a test that does not produce a (correct) value? Reference
// `need_value`.
@(private = "file")
need_value :: proc(fs: ^FuncState, list: int) -> bool {
	list := list
	for list != NO_JUMP {
		i := getjumpcontrol(fs, list)^
		if get_opcode(i) != .TESTSET {
			return true
		}
		list = getjump(fs, list)
	}
	return false
}

// Land the full result of 'e' (including its jump lists) in register 'reg',
// synthesizing boolean loads for tests that don't produce values. Reference
// `exp2reg`.
@(private = "file")
exp2reg :: proc(fs: ^FuncState, e: ^Expdesc, reg: int) {
	discharge2reg(fs, e, reg)
	if e.k == .VJMP { 	// expression itself is a test?
		luaK_concat(fs, &e.t, e.u.info) // add this jump to the "true" list
	}
	if hasjumps(e) {
		p_f := NO_JUMP // position of an eventual LOAD false
		p_t := NO_JUMP // position of an eventual LOAD true
		if need_value(fs, e.t) || need_value(fs, e.f) {
			fj := (e.k == .VJMP) ? NO_JUMP : luaK_jump(fs)
			p_f = code_loadbool(fs, reg, .LFALSESKIP) // load false, skip next
			p_t = code_loadbool(fs, reg, .LOADTRUE)
			luaK_patchtohere(fs, fj) // jump around the booleans
		}
		final := luaK_getlabel(fs) // position after the whole expression
		patchlistaux(fs, e.f, final, reg, p_f)
		patchlistaux(fs, e.t, final, reg, p_t)
	}
	e.f = NO_JUMP
	e.t = NO_JUMP
	e.u.info = reg
	e.k = .VNONRELOC
}

// Land 'e' in the next available register. Reference `luaK_exp2nextreg`.
luaK_exp2nextreg :: proc(fs: ^FuncState, e: ^Expdesc) {
	luaK_dischargevars(fs, e)
	freeexp(fs, e)
	luaK_reserveregs(fs, 1)
	exp2reg(fs, e, fs.freereg - 1)
}

// Land 'e' in some register and return it. Reuses an existing register when it can
// (and it isn't a jump-carrying local). Reference `luaK_exp2anyreg`.
luaK_exp2anyreg :: proc(fs: ^FuncState, e: ^Expdesc) -> int {
	luaK_dischargevars(fs, e)
	if e.k == .VNONRELOC {
		if !hasjumps(e) {
			return e.u.info // already in a register
		}
		if e.u.info >= luaY_nvarstack(fs) { 	// register is a temporary, not a local
			exp2reg(fs, e, e.u.info)
			return e.u.info
		}
		// else: has jumps and lives in a local's register -> use a fresh one
	}
	luaK_exp2nextreg(fs, e)
	return e.u.info
}

// Ensure 'e' is in a register, an upvalue, or is the vararg parameter. Reference
// `luaK_exp2anyregup`.
luaK_exp2anyregup :: proc(fs: ^FuncState, e: ^Expdesc) {
	if (e.k != .VUPVAL && e.k != .VVARGVAR) || hasjumps(e) {
		luaK_exp2anyreg(fs, e)
	}
}

// Ensure 'e' is either in a register or is a constant value. Reference
// `luaK_exp2val`.
luaK_exp2val :: proc(fs: ^FuncState, e: ^Expdesc) {
	if e.k == .VJMP || hasjumps(e) {
		luaK_exp2anyreg(fs, e)
	} else {
		luaK_dischargevars(fs, e)
	}
}

// Try to make 'e' a K expression whose index fits an R/K operand. Reference
// `luaK_exp2K`.
@(private = "file")
luaK_exp2K :: proc(fs: ^FuncState, e: ^Expdesc) -> bool {
	if !hasjumps(e) {
		info: int
		#partial switch e.k {
		case .VTRUE:
			info = boolT(fs)
		case .VFALSE:
			info = boolF(fs)
		case .VNIL:
			info = nilK(fs)
		case .VKINT:
			info = luaK_intK(fs, e.u.ival)
		case .VKFLT:
			info = luaK_numberK(fs, e.u.nval)
		case .VKSTR:
			info = stringK(fs, e.u.strval)
		case .VK:
			info = e.u.info
		case:
			return false // not a constant
		}
		if info <= MAXINDEXRK { 	// fits in argC?
			e.k = .VK
			e.u.info = info
			return true
		}
	}
	return false
}

// Ensure 'e' is a valid R/K operand; return true iff it ended up as a K. Reference
// `exp2RK`.
@(private = "file")
exp2RK :: proc(fs: ^FuncState, e: ^Expdesc) -> bool {
	if luaK_exp2K(fs, e) {
		return true
	}
	luaK_exp2anyreg(fs, e)
	return false
}

// Emit an A,B,RK(ec) instruction, discharging 'ec' to an R/K operand first.
// Reference `codeABRK`.
@(private = "file")
codeABRK :: proc(fs: ^FuncState, o: Op_Code, A, B: int, ec: ^Expdesc) {
	k := exp2RK(fs, ec)
	luaK_codeABCk(fs, o, A, B, ec.u.info, k ? 1 : 0)
}

// Store the value of expression 'ex' into variable 'var'. Reference
// `luaK_storevar`.
luaK_storevar :: proc(fs: ^FuncState, var: ^Expdesc, ex: ^Expdesc) {
	#partial switch var.k {
	case .VLOCAL:
		freeexp(fs, ex)
		exp2reg(fs, ex, int(var.u.var.ridx)) // compute 'ex' into its home register
		return
	case .VUPVAL:
		e := luaK_exp2anyreg(fs, ex)
		luaK_codeABC(fs, .SETUPVAL, e, var.u.info, 0)
	case .VINDEXUP:
		codeABRK(fs, .SETTABUP, int(var.u.ind.t), int(var.u.ind.idx), ex)
	case .VINDEXI:
		codeABRK(fs, .SETI, int(var.u.ind.t), int(var.u.ind.idx), ex)
	case .VINDEXSTR:
		codeABRK(fs, .SETFIELD, int(var.u.ind.t), int(var.u.ind.idx), ex)
	case .VVARGIND:
		needvatab(fs.f) // now a regular table assignment
		fallthrough
	case .VINDEXED:
		codeABRK(fs, .SETTABLE, int(var.u.ind.t), int(var.u.ind.idx), ex)
	case:
		// invalid var kind to store into; parser guarantees this can't happen
	}
	freeexp(fs, ex)
}

// ---------------------------------------------------------------------------
// Conditional-jump machinery (comparisons, `and`/`or`, `not`)
// ---------------------------------------------------------------------------

// Flip the sense of a comparison jump. Reference `negatecondition`.
@(private = "file")
negatecondition :: proc(fs: ^FuncState, e: ^Expdesc) {
	pc := getjumpcontrol(fs, e.u.info)
	setarg_k(pc, getarg_k(pc^) ~ 1)
}

// Emit a test that jumps when 'e' equals 'cond' (optimizing away a leading `not`).
// Reference `jumponcond`.
@(private = "file")
jumponcond :: proc(fs: ^FuncState, e: ^Expdesc, cond: bool) -> int {
	if e.k == .VRELOC {
		ie := getinstruction(fs, e)^
		if get_opcode(ie) == .NOT {
			removelastinstruction(fs) // remove the OP_NOT
			return condjump(fs, .TEST, getarg_B(ie), 0, 0, (!cond) ? 1 : 0)
		}
		// else fall through
	}
	discharge2anyreg(fs, e)
	freeexp(fs, e)
	return condjump(fs, .TESTSET, NO_REG, e.u.info, 0, cond ? 1 : 0)
}

// Emit code that continues when 'e' is true and jumps otherwise. Reference
// `luaK_goiftrue`.
luaK_goiftrue :: proc(fs: ^FuncState, e: ^Expdesc) {
	pc: int
	luaK_dischargevars(fs, e)
	#partial switch e.k {
	case .VJMP:
		negatecondition(fs, e) // jump when it is false
		pc = e.u.info
	case .VK, .VKFLT, .VKINT, .VKSTR, .VTRUE:
		pc = NO_JUMP // always true; nothing to do
	case:
		pc = jumponcond(fs, e, false) // jump when false
	}
	luaK_concat(fs, &e.f, pc) // add new jump to the "false" list
	luaK_patchtohere(fs, e.t) // "true" list falls through to here
	e.t = NO_JUMP
}

// Emit code that continues when 'e' is false and jumps otherwise. Reference
// `luaK_goiffalse`.
@(private = "file")
luaK_goiffalse :: proc(fs: ^FuncState, e: ^Expdesc) {
	pc: int
	luaK_dischargevars(fs, e)
	#partial switch e.k {
	case .VJMP:
		pc = e.u.info // already jumps if true
	case .VNIL, .VFALSE:
		pc = NO_JUMP // always false; nothing to do
	case:
		pc = jumponcond(fs, e, true) // jump if true
	}
	luaK_concat(fs, &e.t, pc) // add new jump to the "true" list
	luaK_patchtohere(fs, e.f) // "false" list falls through to here
	e.f = NO_JUMP
}

// Code `not e`, constant-folding when possible. Reference `codenot`.
@(private = "file")
codenot :: proc(fs: ^FuncState, e: ^Expdesc) {
	#partial switch e.k {
	case .VNIL, .VFALSE:
		e.k = .VTRUE // not nil == not false == true
	case .VK, .VKFLT, .VKINT, .VKSTR, .VTRUE:
		e.k = .VFALSE // not <constant truthy> == false
	case .VJMP:
		negatecondition(fs, e)
	case .VRELOC, .VNONRELOC:
		discharge2anyreg(fs, e)
		freeexp(fs, e)
		e.u.info = luaK_codeABC(fs, .NOT, 0, e.u.info, 0)
		e.k = .VRELOC
	case:
		// cannot happen
	}
	// swap true/false lists; the values they carried are useless once negated
	temp := e.f
	e.f = e.t
	e.t = temp
	removevalues(fs, e.f)
	removevalues(fs, e.t)
}

// ---------------------------------------------------------------------------
// Indexing, immediates, and the SELF opcode
// ---------------------------------------------------------------------------

// Is 'e' a short-string literal already in a valid K index? Reference `isKstr`.
@(private = "file")
isKstr :: proc(fs: ^FuncState, e: ^Expdesc) -> bool {
	return(
		e.k == .VK &&
		!hasjumps(e) &&
		e.u.info <= MAXINDEXRK &&
		int(type_tag(&fs.f.k[e.u.info])) == VSHRSTR \
	)
}

// Is 'e' a literal integer? Reference `isKint`.
@(private = "file")
isKint :: proc(e: ^Expdesc) -> bool {
	return e.k == .VKINT && !hasjumps(e)
}

// Is 'e' a literal integer that fits register C? Reference `isCint`.
@(private = "file")
isCint :: proc(e: ^Expdesc) -> bool {
	return isKint(e) && u64(e.u.ival) <= u64(MAXARG_C)
}

// Is 'e' a literal integer that fits a signed-C operand? Reference `isSCint`.
@(private = "file")
isSCint :: proc(e: ^Expdesc) -> bool {
	return isKint(e) && fitsC(e.u.ival)
}

// Is 'e' an int/float literal that fits a signed register operand? Fills *pi with
// the biased operand and flags floats. Reference `isSCnumber`.
@(private = "file")
isSCnumber :: proc(e: ^Expdesc, pi: ^int, isfloat: ^int) -> bool {
	i: Integer
	if e.k == .VKINT {
		i = e.u.ival
	} else if e.k == .VKFLT {
		fi, ok := float_to_integer(e.u.nval, .Eq)
		if !ok {
			return false
		}
		i = fi
		isfloat^ = 1
	} else {
		return false
	}
	if !hasjumps(e) && fitsC(i) {
		pi^ = int2sC(int(i))
		return true
	}
	return false
}

// Emit SELF (or a MOVE+GETTABLE equivalent) turning 'e' into `e.key(e, ...)`.
// Reference `luaK_self`.
luaK_self :: proc(fs: ^FuncState, e: ^Expdesc, key: ^Expdesc) {
	luaK_exp2anyreg(fs, e)
	ereg := e.u.info // register holding the receiver
	freeexp(fs, e)
	base := fs.freereg
	e.u.info = base
	e.k = .VNONRELOC // self expression has a fixed register
	luaK_reserveregs(fs, 2) // method + self produced by OP_SELF
	if strisshr(key.u.strval) && luaK_exp2K(fs, key) {
		luaK_codeABCk(fs, .SELF, base, ereg, key.u.info, 0)
	} else { 	// method name not a short K string: fall back to move+gettable
		luaK_exp2anyreg(fs, key)
		luaK_codeABC(fs, .MOVE, base + 1, ereg, 0)
		luaK_codeABC(fs, .GETTABLE, base, ereg, key.u.info)
	}
	freeexp(fs, key)
}

// Set the key + kind of an indexed expression. Reference `fillidxk`.
@(private = "file")
fillidxk :: proc "contextless" (t: ^Expdesc, idx: int, k: Expkind) {
	t.u.ind.idx = i16(idx)
	t.k = k
}

// Build expression `t[k]`. 't' must already be in a register or upvalue.
// Reference `luaK_indexed`.
luaK_indexed :: proc(fs: ^FuncState, t: ^Expdesc, k: ^Expdesc) {
	keystr := -1
	if k.k == .VKSTR {
		keystr = str2K(fs, k)
	}
	if t.k == .VUPVAL && !isKstr(fs, k) { 	// upvalue indexed by non-Kstr?
		luaK_exp2anyreg(fs, t) // must put it in a register first
	}
	if t.k == .VUPVAL {
		temp := u8(t.u.info) // upvalue index (copy first; union overlaps)
		t.u.ind.t = temp
		fillidxk(t, k.u.info, .VINDEXUP)
	} else if t.k == .VVARGVAR { 	// indexing the vararg parameter?
		kreg := luaK_exp2anyreg(fs, k)
		vreg := u8(t.u.var.ridx) // register holding the vararg parameter
		t.u.ind.t = vreg
		fillidxk(t, kreg, .VVARGIND)
	} else {
		t.u.ind.t = u8((t.k == .VLOCAL) ? int(t.u.var.ridx) : t.u.info)
		if isKstr(fs, k) {
			fillidxk(t, k.u.info, .VINDEXSTR)
		} else if isCint(k) {
			fillidxk(t, int(k.u.ival), .VINDEXI)
		} else {
			fillidxk(t, luaK_exp2anyreg(fs, k), .VINDEXED)
		}
	}
	t.u.ind.keystr = keystr
	t.u.ind.ro = 0 // not read-only by default
}

// ---------------------------------------------------------------------------
// Constant folding and operator dispatch
// ---------------------------------------------------------------------------

// Would folding operation 'op' over 'v1','v2' be safe (no runtime error)? Bitwise
// ops need integer-convertible operands; division-family ops forbid a zero
// divisor. Reference `validop`.
@(private = "file")
validop :: proc "contextless" (op: int, v1, v2: ^TValue) -> bool {
	switch op {
	case int(Arith_Op.Band), int(Arith_Op.Bor), int(Arith_Op.Bxor),
	     int(Arith_Op.Shl), int(Arith_Op.Shr), int(Arith_Op.Bnot):
		// Runtime bitwise conversion is exact: 4.0 is an integer, 4.5 is not.
		// Folding must ask the same question rather than treating floorability as
		// convertibility, or it can approve an expression the raw operation must
		// reject and send the compiler down an inconsistent path.
		_, ok1 := to_integer_no_string(v1, .Eq)
		_, ok2 := to_integer_no_string(v2, .Eq)
		return ok1 && ok2
	case int(Arith_Op.Div), int(Arith_Op.IDiv), int(Arith_Op.Mod):
		return nvalue(v2) != 0
	case:
		return true
	}
}

// Try to fold a constant operation into 'e1'. Reference `constfolding`. We keep
// reference Lua's refusal to fold a NaN or (signed) zero float result.
@(private = "file")
constfolding :: proc(fs: ^FuncState, op: int, e1: ^Expdesc, e2: ^Expdesc) -> bool {
	v1, v2: TValue
	if !tonumeral(e1, &v1) || !tonumeral(e2, &v2) || !validop(op, &v1, &v2) {
		return false // non-numeric operands, or unsafe to fold
	}
	res, _ := raw_arith(Arith_Op(op), &v1, &v2) // validop already vetted safety
	if is_integer(&res) {
		e1.k = .VKINT
		e1.u.ival = int_value(&res)
	} else {
		n := flt_value(&res)
		if n != n || n == 0 { 	// refuse NaN and 0.0/-0.0
			return false
		}
		e1.k = .VKFLT
		e1.u.nval = n
	}
	return true
}

// Convert a BinOpr to an OpCode by index arithmetic against a (base op, base opr)
// pair. Reference `binopr2op`.
@(private = "file")
binopr2op :: #force_inline proc "contextless" (opr, baser: BinOpr, base: Op_Code) -> Op_Code {
	return Op_Code(int(base) + (int(opr) - int(baser)))
}

// Convert a UnOpr to its OpCode. Reference `unopr2op`.
@(private = "file")
unopr2op :: #force_inline proc "contextless" (opr: UnOpr) -> Op_Code {
	return Op_Code(int(Op_Code.UNM) + (int(opr) - int(UnOpr.OPR_MINUS)))
}

// Convert a BinOpr to its tag-method event number. Reference `binopr2TM`.
@(private = "file")
binopr2TM :: #force_inline proc "contextless" (opr: BinOpr) -> int {
	return (int(opr) - int(BinOpr.OPR_ADD)) + TM_ADD
}

// Emit a value-producing unary op (everything but `not`). Reference
// `codeunexpval`.
@(private = "file")
codeunexpval :: proc(fs: ^FuncState, op: Op_Code, e: ^Expdesc, line: int) {
	r := luaK_exp2anyreg(fs, e) // operates only on registers
	freeexp(fs, e)
	e.u.info = luaK_codeABC(fs, op, 0, r, 0)
	e.k = .VRELOC
	luaK_fixline(fs, line)
}

// Emit the instruction pair (op + metamethod trailer) for a value-producing
// binary op. Reference `finishbinexpval`.
@(private = "file")
finishbinexpval :: proc(
	fs: ^FuncState,
	e1, e2: ^Expdesc,
	op: Op_Code,
	v2: int,
	flip: int,
	line: int,
	mmop: Op_Code,
	event: int,
) {
	v1 := luaK_exp2anyreg(fs, e1)
	pc := luaK_codeABCk(fs, op, 0, v1, v2, 0)
	freeexps(fs, e1, e2)
	e1.u.info = pc
	e1.k = .VRELOC
	luaK_fixline(fs, line)
	luaK_codeABCk(fs, mmop, v1, v2, event, flip) // metamethod fallback
	luaK_fixline(fs, line)
}

// Binary op over two registers. Reference `codebinexpval`.
@(private = "file")
codebinexpval :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, line: int) {
	op := binopr2op(opr, .OPR_ADD, .ADD)
	v2 := luaK_exp2anyreg(fs, e2) // ensure 'e2' is in a register
	finishbinexpval(fs, e1, e2, op, v2, 0, line, .MMBIN, binopr2TM(opr))
}

// Binary op with an immediate (`sC`) 2nd operand. Reference `codebini`.
@(private = "file")
codebini :: proc(fs: ^FuncState, op: Op_Code, e1, e2: ^Expdesc, flip: int, line: int, event: int) {
	v2 := int2sC(int(e2.u.ival)) // immediate operand
	finishbinexpval(fs, e1, e2, op, v2, flip, line, .MMBINI, event)
}

// Binary op with a K 2nd operand. Reference `codebinK`.
@(private = "file")
codebinK :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, flip: int, line: int) {
	event := binopr2TM(opr)
	v2 := e2.u.info // K index
	op := binopr2op(opr, .OPR_ADD, .ADDK)
	finishbinexpval(fs, e1, e2, op, v2, flip, line, .MMBINK, event)
}

// Try to code a binary op by negating a small integer 2nd operand (e.g. `a - 3`
// as `a + (-3)`). Reference `finishbinexpneg`.
@(private = "file")
finishbinexpneg :: proc(fs: ^FuncState, e1, e2: ^Expdesc, op: Op_Code, line: int, event: int) -> bool {
	if !isKint(e2) {
		return false // not an integer constant
	}
	i2 := e2.u.ival
	if !(fitsC(i2) && fitsC(-i2)) {
		return false // not in range (need both +/- to fit)
	}
	v2 := int(i2)
	finishbinexpval(fs, e1, e2, op, int2sC(-v2), 0, line, .MMBINI, event)
	// the metamethod trailer must keep the *original* (un-negated) argument
	setarg_B(&fs.f.code[fs.pc - 1], int2sC(v2))
	return true
}

// Swap two expression descriptors. Reference `swapexps`.
@(private = "file")
swapexps :: proc "contextless" (e1, e2: ^Expdesc) {
	temp := e1^
	e1^ = e2^
	e2^ = temp
}

// Binary op with no constant operand. Reference `codebinNoK`.
@(private = "file")
codebinNoK :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, flip: int, line: int) {
	if flip != 0 {
		swapexps(e1, e2) // back to original order
	}
	codebinexpval(fs, opr, e1, e2, line)
}

// Arithmetic op; prefer a K 2nd operand when it fits. Reference `codearith`.
@(private = "file")
codearith :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, flip: int, line: int) {
	if tonumeral(e2, nil) && luaK_exp2K(fs, e2) { 	// K operand?
		codebinK(fs, opr, e1, e2, flip, line)
	} else {
		codebinNoK(fs, opr, e1, e2, flip, line)
	}
}

// Commutative arithmetic op; reorder to expose an immediate/K operand. Reference
// `codecommutative`.
@(private = "file")
codecommutative :: proc(fs: ^FuncState, op: BinOpr, e1, e2: ^Expdesc, line: int) {
	flip := 0
	if tonumeral(e1, nil) { 	// first operand a numeric constant?
		swapexps(e1, e2)
		flip = 1
	}
	if op == .OPR_ADD && isSCint(e2) { 	// immediate operand?
		codebini(fs, .ADDI, e1, e2, flip, line, TM_ADD)
	} else {
		codearith(fs, op, e1, e2, flip, line)
	}
}

// Bitwise op; commutative, so try to make the 2nd operand an integer K. Reference
// `codebitwise`.
@(private = "file")
codebitwise :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, line: int) {
	flip := 0
	if e1.k == .VKINT {
		swapexps(e1, e2) // 'e2' becomes the constant operand
		flip = 1
	}
	if e2.k == .VKINT && luaK_exp2K(fs, e2) {
		codebinK(fs, opr, e1, e2, flip, line)
	} else {
		codebinNoK(fs, opr, e1, e2, flip, line)
	}
}

// Order comparison (`<`,`<=`), possibly using an immediate operand. Reference
// `codeorder`.
@(private = "file")
codeorder :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc) {
	r1, r2, im: int
	isfloat := 0
	op: Op_Code
	if isSCnumber(e2, &im, &isfloat) {
		r1 = luaK_exp2anyreg(fs, e1)
		r2 = im
		op = binopr2op(opr, .OPR_LT, .LTI)
	} else if isSCnumber(e1, &im, &isfloat) {
		// (A < B) becomes (B > A); (A <= B) becomes (B >= A)
		r1 = luaK_exp2anyreg(fs, e2)
		r2 = im
		op = binopr2op(opr, .OPR_LT, .GTI)
	} else { 	// two registers
		r1 = luaK_exp2anyreg(fs, e1)
		r2 = luaK_exp2anyreg(fs, e2)
		op = binopr2op(opr, .OPR_LT, .LT)
	}
	freeexps(fs, e1, e2)
	e1.u.info = condjump(fs, op, r1, r2, isfloat, 1)
	e1.k = .VJMP
}

// Equality comparison (`==`,`~=`). 'e1' was already put as RK by `luaK_infix`.
// Reference `codeeq`.
@(private = "file")
codeeq :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc) {
	r1, r2, im: int
	isfloat := 0
	op: Op_Code
	if e1.k != .VNONRELOC {
		swapexps(e1, e2)
	}
	r1 = luaK_exp2anyreg(fs, e1) // 1st expression must be in a register
	if isSCnumber(e2, &im, &isfloat) {
		op = .EQI
		r2 = im
	} else if exp2RK(fs, e2) { 	// 2nd expression is constant?
		op = .EQK
		r2 = e2.u.info
	} else {
		op = .EQ
		r2 = luaK_exp2anyreg(fs, e2)
	}
	freeexps(fs, e1, e2)
	e1.u.info = condjump(fs, op, r1, r2, isfloat, (opr == .OPR_EQ) ? 1 : 0)
	e1.k = .VJMP
}

// Apply prefix operator 'opr' to 'e'. Reference `luaK_prefix`.
luaK_prefix :: proc(fs: ^FuncState, opr: UnOpr, e: ^Expdesc, line: int) {
	// A fake 2nd operand (integer 0) so unary folding can reuse `constfolding`.
	ef := Expdesc {
		k = .VKINT,
		t = NO_JUMP,
		f = NO_JUMP,
	}
	luaK_dischargevars(fs, e)
	#partial switch opr {
	case .OPR_MINUS, .OPR_BNOT:
		if constfolding(fs, int(opr) + int(Arith_Op.Unm), e, &ef) {
			break
		}
		fallthrough
	case .OPR_LEN:
		codeunexpval(fs, unopr2op(opr), e, line)
	case .OPR_NOT:
		codenot(fs, e)
	case:
		// cannot happen
	}
}

// Process the 1st operand of binary operator 'op' before the 2nd is read.
// Reference `luaK_infix`.
luaK_infix :: proc(fs: ^FuncState, op: BinOpr, v: ^Expdesc) {
	luaK_dischargevars(fs, v)
	#partial switch op {
	case .OPR_AND:
		luaK_goiftrue(fs, v) // go ahead only if 'v' is true
	case .OPR_OR:
		luaK_goiffalse(fs, v) // go ahead only if 'v' is false
	case .OPR_CONCAT:
		luaK_exp2nextreg(fs, v) // operand must be on the stack
	case .OPR_ADD, .OPR_SUB, .OPR_MUL, .OPR_DIV, .OPR_IDIV,
	     .OPR_MOD, .OPR_POW, .OPR_BAND, .OPR_BOR, .OPR_BXOR,
	     .OPR_SHL, .OPR_SHR:
		if !tonumeral(v, nil) {
			luaK_exp2anyreg(fs, v)
		}
		// else keep the numeral: it may fold or become an immediate/K operand
	case .OPR_EQ, .OPR_NE:
		if !tonumeral(v, nil) {
			exp2RK(fs, v)
		}
	case .OPR_LT, .OPR_LE, .OPR_GT, .OPR_GE:
		dummy, dummy2: int
		if !isSCnumber(v, &dummy, &dummy2) {
			luaK_exp2anyreg(fs, v)
		}
	case:
		// cannot happen
	}
}

// Emit `(e1 .. e2)`, merging with a following CONCAT (concatenation is right
// associative) when possible. Reference `codeconcat`.
@(private = "file")
codeconcat :: proc(fs: ^FuncState, e1, e2: ^Expdesc, line: int) {
	ie2 := previousinstruction(fs)
	if get_opcode(ie2^) == .CONCAT { 	// is 'e2' itself a concatenation?
		n := getarg_B(ie2^) // number of elements 'e2' concatenates
		freeexp(fs, e2)
		setarg_A(ie2, e1.u.info) // correct the first element ('e1')
		setarg_B(ie2, n + 1) // one more element to concatenate
	} else { 	// 'e2' is not a concatenation: emit a fresh CONCAT of two
		luaK_codeABC(fs, .CONCAT, e1.u.info, 2, 0)
		freeexp(fs, e2)
		luaK_fixline(fs, line)
	}
}

// Finalize a binary operation after its 2nd operand is parsed. Reference
// `luaK_posfix`.
luaK_posfix :: proc(fs: ^FuncState, opr: BinOpr, e1, e2: ^Expdesc, line: int) {
	opr := opr
	luaK_dischargevars(fs, e2)
	if foldbinop(opr) && constfolding(fs, int(opr) + int(Arith_Op.Add), e1, e2) {
		return // handled by folding
	}
	#partial switch opr {
	case .OPR_AND:
		luaK_concat(fs, &e2.f, e1.f) // list closed by luaK_infix
		e1^ = e2^
	case .OPR_OR:
		luaK_concat(fs, &e2.t, e1.t) // list closed by luaK_infix
		e1^ = e2^
	case .OPR_CONCAT:
		luaK_exp2nextreg(fs, e2)
		codeconcat(fs, e1, e2, line)
	case .OPR_ADD, .OPR_MUL:
		codecommutative(fs, opr, e1, e2, line)
	case .OPR_SUB:
		if finishbinexpneg(fs, e1, e2, .ADDI, line, TM_SUB) {
			break // coded as (r1 + -I)
		}
		fallthrough
	case .OPR_DIV, .OPR_IDIV, .OPR_MOD, .OPR_POW:
		codearith(fs, opr, e1, e2, 0, line)
	case .OPR_BAND, .OPR_BOR, .OPR_BXOR:
		codebitwise(fs, opr, e1, e2, line)
	case .OPR_SHL:
		if isSCint(e1) {
			swapexps(e1, e2)
			codebini(fs, .SHLI, e1, e2, 1, line, TM_SHL) // I << r2
		} else if finishbinexpneg(fs, e1, e2, .SHRI, line, TM_SHL) {
			// coded as (r1 >> -I)
		} else {
			codebinexpval(fs, opr, e1, e2, line)
		}
	case .OPR_SHR:
		if isSCint(e2) {
			codebini(fs, .SHRI, e1, e2, 0, line, TM_SHR) // r1 >> I
		} else {
			codebinexpval(fs, opr, e1, e2, line)
		}
	case .OPR_EQ, .OPR_NE:
		codeeq(fs, opr, e1, e2)
	case .OPR_GT, .OPR_GE:
		// '(a > b)' <=> '(b < a)';  '(a >= b)' <=> '(b <= a)'
		swapexps(e1, e2)
		opr = BinOpr(int(opr) - int(BinOpr.OPR_GT) + int(BinOpr.OPR_LT))
		fallthrough
	case .OPR_LT, .OPR_LE:
		codeorder(fs, opr, e1, e2)
	case:
		// cannot happen
	}
}

// ---------------------------------------------------------------------------
// Line fixes, table sizing, list stores, and the final peephole pass
// ---------------------------------------------------------------------------

// Replace the line associated with the current position. Reference
// `luaK_fixline`.
luaK_fixline :: proc(fs: ^FuncState, line: int) {
	removelastlineinfo(fs)
	savelineinfo(fs, fs.f, line)
}

// Patch a NEWTABLE (plus its EXTRAARG) with the array/hash sizes. Reference
// `luaK_settablesize`.
luaK_settablesize :: proc(fs: ^FuncState, pc: int, ra: int, asize: int, hsize: int) {
	hsize := hsize
	inst := &fs.f.code[pc]
	extra := asize / (MAXARG_vC + 1) // high bits of the array size
	rc := asize % (MAXARG_vC + 1) // low bits of the array size
	k := (extra > 0) ? 1 : 0 // needs the extra-arg?
	hsize = (hsize != 0) ? int(ceil_log2(U32(hsize))) + 1 : 0
	inst^ = create_vABCk(.NEWTABLE, ra, hsize, rc, k)
	([^]Instruction)(inst)[1] = create_Ax(.EXTRAARG, extra)
}

// Emit a SETLIST storing 'tostore' values (or up to the stack top for
// LUA_MULTRET) into the table in register 'base'. Reference `luaK_setlist`.
luaK_setlist :: proc(fs: ^FuncState, base: int, nelems: int, tostore: int) {
	tostore := tostore
	nelems := nelems
	if tostore == LUA_MULTRET {
		tostore = 0
	}
	if nelems <= MAXARG_vC {
		luaK_codevABCk(fs, .SETLIST, base, tostore, nelems, 0)
	} else {
		extra := nelems / (MAXARG_vC + 1)
		nelems %= (MAXARG_vC + 1)
		luaK_codevABCk(fs, .SETLIST, base, tostore, nelems, 1)
		codeextraarg(fs, extra)
	}
	fs.freereg = base + 1 // free the registers that held the list values
}

// Follow a chain of jumps-to-jumps to its final landing pc. Reference
// `finaltarget`.
@(private = "file")
finaltarget :: proc(code: [^]Instruction, i: int) -> int {
	i := i
	for count := 0; count < 100; count += 1 { 	// bounded to avoid infinite loops
		pc := code[i]
		if get_opcode(pc) != .JMP {
			break
		}
		i += getarg_sJ(pc) + 1
	}
	return i
}

// Final peephole/cleanup pass over the finished code: fix returns/tailcalls for
// closing and hidden-vararg needs, rewrite vararg indexing when a vararg table is
// used, and collapse jumps-to-jumps. Reference `luaK_finish`.
luaK_finish :: proc(fs: ^FuncState) {
	p := fs.f
	if (p.flag & PF_VATAB) != 0 { 	// uses a vararg table?
		p.flag &= ~u8(PF_VAHID) // then it won't use hidden args
	}
	for i := 0; i < fs.pc; i += 1 {
		pc := &p.code[i]
		#partial switch get_opcode(pc^) {
		case .RETURN0, .RETURN1:
			if !(fs.needclose != 0 || (p.flag & PF_VAHID) != 0) {
				break // no extra work needed
			}
			set_opcode(pc, .RETURN) // upgrade to do the extra work
			fallthrough
		case .RETURN, .TAILCALL:
			if fs.needclose != 0 {
				setarg_k(pc, 1) // signal it needs to close upvalues
			}
			if (p.flag & PF_VAHID) != 0 {
				setarg_C(pc, int(p.numparams) + 1) // signal hidden args
			}
		case .GETVARG:
			if (p.flag & PF_VATAB) != 0 {
				set_opcode(pc, .GETTABLE) // fetch from the vararg table instead
			}
		case .VARARG:
			if (p.flag & PF_VATAB) != 0 {
				setarg_k(pc, 1)
			}
		case .JMP:
			target := finaltarget(p.code, i)
			fixjump(fs, i, target) // jump straight to the final target
		case:
			// nothing to adjust
		}
	}
}
