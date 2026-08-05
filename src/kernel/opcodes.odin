package kernel
// opcodes.odin -- our analogue of `lopcodes.h`/`lopcodes.c`, plus `lopnames.h`.
//
// The instruction set of the register-based virtual machine: the opcode enum,
// the instruction *formats* (iABC/ivABC/iABx/iAsBx/iAx/isJ) and the bit-field
// encoding that packs opcode + operands into a 32-bit word, the per-opcode
// mode/property table, and the human-readable opcode names used by `luac -l`.
//
// This is a place where byte-exactness matters: our encoding must match
// reference Lua so dumped bytecode is compatible (see docs/ARCHITECTURE.md,
// Decision 5). Every layout constant, opmode byte, and name below is transcribed
// directly from the reference headers -- do not "tidy" the numbers.

// ---------------------------------------------------------------------------
// Instruction formats
// ---------------------------------------------------------------------------

// The five (well, six) shapes an instruction word can take. A 32-bit word always
// carries a 7-bit opcode in its low bits; the remaining 25 bits are sliced up
// differently depending on the format:
//
//   iABC    C(8)  | B(8)  |k|  A(8) | Op(7)
//   ivABC   vC(10)| vB(6) |k|  A(8) | Op(7)   ('v' = variant field widths)
//   iABx        Bx(17)       |  A(8) | Op(7)
//   iAsBx      sBx(17,signed)|  A(8) | Op(7)
//   iAx              Ax(25)         | Op(7)
//   isJ           sJ(25,signed)     | Op(7)
//
// A *signed* argument is stored in excess-K: the value is the written unsigned
// number minus K, where K is half (rounded down) the field's max. The member
// order here is load-bearing -- it must match reference `enum OpMode` because the
// low 3 bits of each `LUA_P_OPMODES` byte store this as an integer.
Op_Mode :: enum u8 {
	iABC,
	ivABC,
	iABx,
	iAsBx,
	iAx,
	isJ,
}

// ---------------------------------------------------------------------------
// Size and position of opcode arguments (lopcodes.h)
// ---------------------------------------------------------------------------

// Widths, in bits, of each operand field. `Bx`, `Ax`, and `sJ` are the wide
// fields formed by fusing the narrower ones (plus, for `Bx`, the `k` bit).
SIZE_C :: 8
SIZE_vC :: 10
SIZE_B :: 8
SIZE_vB :: 6
SIZE_Bx :: SIZE_C + SIZE_B + 1
SIZE_A :: 8
SIZE_Ax :: SIZE_Bx + SIZE_A
SIZE_sJ :: SIZE_Bx + SIZE_A

SIZE_OP :: 7

// Bit positions (offsets from bit 0) where each field begins.
POS_OP :: 0
POS_A :: POS_OP + SIZE_OP
POS_k :: POS_A + SIZE_A
POS_B :: POS_k + 1
POS_vB :: POS_k + 1
POS_C :: POS_B + SIZE_B
POS_vC :: POS_vB + SIZE_vB
POS_Bx :: POS_k
POS_Ax :: POS_A
POS_sJ :: POS_A

// ---------------------------------------------------------------------------
// Limits for opcode arguments (lopcodes.h)
// ---------------------------------------------------------------------------

// Because our `int` is 64-bit it always has enough bits for every field, so the
// reference's `L_INTHASBITS` fallback to `INT_MAX` never triggers; each maximum
// is simply "all ones in the field".
MAXARG_Bx :: (1 << SIZE_Bx) - 1
OFFSET_sBx :: MAXARG_Bx >> 1 // 'sBx' is signed, stored excess-OFFSET_sBx

MAXARG_Ax :: (1 << SIZE_Ax) - 1

MAXARG_sJ :: (1 << SIZE_sJ) - 1
OFFSET_sJ :: MAXARG_sJ >> 1

MAXARG_A :: (1 << SIZE_A) - 1
MAXARG_B :: (1 << SIZE_B) - 1
MAXARG_vB :: (1 << SIZE_vB) - 1
MAXARG_C :: (1 << SIZE_C) - 1
MAXARG_vC :: (1 << SIZE_vC) - 1
OFFSET_sC :: MAXARG_C >> 1

// The maximum stack size (register count) for a Lua function -- it must fit in
// the 8-bit A field, so the highest valid register is `MAX_FSTACK - 1`. `NO_REG`
// is the one-past-the-end sentinel used by the code generator to mean "no
// register".
MAX_FSTACK :: MAXARG_A
NO_REG :: MAX_FSTACK

// Convert between a plain integer and its signed-C (`sC`) representation. The
// `sC` operand (used by ADDI/SHRI/immediate compares) is stored excess-OFFSET_sC
// so it can carry a small signed value in an unsigned field.
int2sC :: #force_inline proc "contextless" (i: int) -> int {return i + OFFSET_sC}
sC2int :: #force_inline proc "contextless" (i: int) -> int {return i - OFFSET_sC}

// ---------------------------------------------------------------------------
// Bit-field masks (lopcodes.h)
// ---------------------------------------------------------------------------

// `mask1(n, p)` is a mask with `n` one-bits starting at position `p`; `mask0` is
// its complement (`n` zero-bits at `p`). These are the primitives every operand
// getter/setter is built from. `~Instruction(0)` is all ones (0xFFFF_FFFF); we
// shift a hole of `n` zeros into it, invert to get `n` ones, then slide to `p`.
mask1 :: #force_inline proc "contextless" (n, p: u32) -> Instruction {
	return (~(~Instruction(0) << n)) << p
}

mask0 :: #force_inline proc "contextless" (n, p: u32) -> Instruction {
	return ~mask1(n, p)
}

// ---------------------------------------------------------------------------
// Opcode get/set
// ---------------------------------------------------------------------------

// Read the 7-bit opcode out of an instruction word.
get_opcode :: #force_inline proc "contextless" (i: Instruction) -> Op_Code {
	return Op_Code((i >> POS_OP) & mask1(SIZE_OP, 0))
}

// Overwrite just the opcode bits of `i`, leaving its operands untouched.
set_opcode :: #force_inline proc "contextless" (i: ^Instruction, o: Op_Code) {
	i^ = (i^ & mask0(SIZE_OP, POS_OP)) | ((Instruction(o) << POS_OP) & mask1(SIZE_OP, POS_OP))
}

// ---------------------------------------------------------------------------
// Generic operand get/set
// ---------------------------------------------------------------------------

// Extract the `size`-bit field at position `pos` as a plain (unsigned-valued)
// int -- reference Lua's `getarg`.
getarg :: #force_inline proc "contextless" (i: Instruction, pos, size: u32) -> int {
	return int((i >> pos) & mask1(size, 0))
}

// Store `v` into the `size`-bit field at `pos`, mutating the instruction in
// place -- reference Lua's `setarg`. The caller guarantees `v` fits in `size`
// bits (the encode-time `luaK_*` asserts enforce that).
setarg :: #force_inline proc "contextless" (i: ^Instruction, v: int, pos, size: u32) {
	i^ = (i^ & mask0(size, pos)) | ((Instruction(u32(v)) << pos) & mask1(size, pos))
}

// ---------------------------------------------------------------------------
// Named operand accessors
// ---------------------------------------------------------------------------
//
// Each format-specific getter mirrors reference Lua's `check_exp(checkopm(...))`
// with an `assert_contextless` that the instruction really is in the format the
// field belongs to. Those asserts compile out under `-disable-assert`, exactly
// like `lua_assert`, but catch encode/decode mismatches during development.

getarg_A :: #force_inline proc "contextless" (i: Instruction) -> int {
	return getarg(i, POS_A, SIZE_A)
}
setarg_A :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_A, SIZE_A)
}

getarg_B :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .iABC)
	return getarg(i, POS_B, SIZE_B)
}
getarg_vB :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .ivABC)
	return getarg(i, POS_vB, SIZE_vB)
}
getarg_sB :: #force_inline proc "contextless" (i: Instruction) -> int {
	return sC2int(getarg_B(i))
}
setarg_B :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_B, SIZE_B)
}
setarg_vB :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_vB, SIZE_vB)
}

getarg_C :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .iABC)
	return getarg(i, POS_C, SIZE_C)
}
getarg_vC :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .ivABC)
	return getarg(i, POS_vC, SIZE_vC)
}
getarg_sC :: #force_inline proc "contextless" (i: Instruction) -> int {
	return sC2int(getarg_C(i))
}
setarg_C :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_C, SIZE_C)
}
setarg_vC :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_vC, SIZE_vC)
}

// The `k` (constant/condition) bit. `testarg_k` returns the raw masked word
// (nonzero iff set), matching reference `TESTARG_k`; `getarg_k` returns 0/1.
testarg_k :: #force_inline proc "contextless" (i: Instruction) -> int {
	return int(i & (1 << POS_k))
}
getarg_k :: #force_inline proc "contextless" (i: Instruction) -> int {
	return getarg(i, POS_k, 1)
}
setarg_k :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_k, 1)
}

getarg_Bx :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .iABx)
	return getarg(i, POS_Bx, SIZE_Bx)
}
setarg_Bx :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_Bx, SIZE_Bx)
}

getarg_Ax :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .iAx)
	return getarg(i, POS_Ax, SIZE_Ax)
}
setarg_Ax :: #force_inline proc "contextless" (i: ^Instruction, v: int) {
	setarg(i, v, POS_Ax, SIZE_Ax)
}

// `sBx` is the signed 17-bit field used by the numeric-for jumps and LOADI/LOADF.
// It is stored excess-OFFSET_sBx, so decode subtracts and encode adds the bias.
getarg_sBx :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .iAsBx)
	return getarg(i, POS_Bx, SIZE_Bx) - OFFSET_sBx
}
setarg_sBx :: #force_inline proc "contextless" (i: ^Instruction, b: int) {
	setarg_Bx(i, b + OFFSET_sBx)
}

// `sJ` is the signed 25-bit jump displacement carried by OP_JMP.
getarg_sJ :: #force_inline proc "contextless" (i: Instruction) -> int {
	assert_contextless(get_op_mode(get_opcode(i)) == .isJ)
	return getarg(i, POS_sJ, SIZE_sJ) - OFFSET_sJ
}
setarg_sJ :: #force_inline proc "contextless" (i: ^Instruction, j: int) {
	setarg(i, j + OFFSET_sJ, POS_sJ, SIZE_sJ)
}

// ---------------------------------------------------------------------------
// Instruction builders
// ---------------------------------------------------------------------------
//
// Assemble a whole instruction word from an opcode plus operands. These mirror
// reference Lua's `CREATE_*` macros one-for-one.

create_ABCk :: #force_inline proc "contextless" (o: Op_Code, a, b, c, k: int) -> Instruction {
	return(
		(Instruction(o) << POS_OP) |
		(Instruction(u32(a)) << POS_A) |
		(Instruction(u32(b)) << POS_B) |
		(Instruction(u32(c)) << POS_C) |
		(Instruction(u32(k)) << POS_k) \
	)
}

create_vABCk :: #force_inline proc "contextless" (o: Op_Code, a, b, c, k: int) -> Instruction {
	return(
		(Instruction(o) << POS_OP) |
		(Instruction(u32(a)) << POS_A) |
		(Instruction(u32(b)) << POS_vB) |
		(Instruction(u32(c)) << POS_vC) |
		(Instruction(u32(k)) << POS_k) \
	)
}

create_ABx :: #force_inline proc "contextless" (o: Op_Code, a, bc: int) -> Instruction {
	return (Instruction(o) << POS_OP) | (Instruction(u32(a)) << POS_A) | (Instruction(u32(bc)) << POS_Bx)
}

create_Ax :: #force_inline proc "contextless" (o: Op_Code, a: int) -> Instruction {
	return (Instruction(o) << POS_OP) | (Instruction(u32(a)) << POS_Ax)
}

create_sJ :: #force_inline proc "contextless" (o: Op_Code, j, k: int) -> Instruction {
	return (Instruction(o) << POS_OP) | (Instruction(u32(j)) << POS_sJ) | (Instruction(u32(k)) << POS_k)
}

// ---------------------------------------------------------------------------
// The opcode enum (ORDER OP -- lopcodes.h)
// ---------------------------------------------------------------------------
//
// Grep "ORDER OP" if you touch this. The numeric value of every member is its
// position in this list, and that value is baked into dumped bytecode, so the
// order is an ABI contract -- it must match reference Lua 5.5 exactly. The
// operand shape and a one-line description are noted for each; see lopcodes.h's
// "Notes" section for the finer semantics (multi-value top handling, the MMBIN
// metamethod trailers, comparison `k` conventions, and so on).
Op_Code :: enum u8 {
	MOVE, //       A B      R[A] := R[B]
	LOADI, //      A sBx    R[A] := sBx
	LOADF, //      A sBx    R[A] := (Number)sBx
	LOADK, //      A Bx     R[A] := K[Bx]
	LOADKX, //     A        R[A] := K[extra arg]
	LOADFALSE, //  A        R[A] := false
	LFALSESKIP, // A        R[A] := false; pc++
	LOADTRUE, //   A        R[A] := true
	LOADNIL, //    A B      R[A], R[A+1], ..., R[A+B] := nil
	GETUPVAL, //   A B      R[A] := UpValue[B]
	SETUPVAL, //   A B      UpValue[B] := R[A]
	GETTABUP, //   A B C    R[A] := UpValue[B][K[C]:shortstring]
	GETTABLE, //   A B C    R[A] := R[B][R[C]]
	GETI, //       A B C    R[A] := R[B][C]
	GETFIELD, //   A B C    R[A] := R[B][K[C]:shortstring]
	SETTABUP, //   A B C    UpValue[A][K[B]:shortstring] := RK(C)
	SETTABLE, //   A B C    R[A][R[B]] := RK(C)
	SETI, //       A B C    R[A][B] := RK(C)
	SETFIELD, //   A B C    R[A][K[B]:shortstring] := RK(C)
	NEWTABLE, //   A vB vC k R[A] := {}
	SELF, //       A B C    R[A+1] := R[B]; R[A] := R[B][K[C]:shortstring]
	ADDI, //       A B sC   R[A] := R[B] + sC
	ADDK, //       A B C    R[A] := R[B] + K[C]:number
	SUBK, //       A B C    R[A] := R[B] - K[C]:number
	MULK, //       A B C    R[A] := R[B] * K[C]:number
	MODK, //       A B C    R[A] := R[B] % K[C]:number
	POWK, //       A B C    R[A] := R[B] ^ K[C]:number
	DIVK, //       A B C    R[A] := R[B] / K[C]:number
	IDIVK, //      A B C    R[A] := R[B] // K[C]:number
	BANDK, //      A B C    R[A] := R[B] & K[C]:integer
	BORK, //       A B C    R[A] := R[B] | K[C]:integer
	BXORK, //      A B C    R[A] := R[B] ~ K[C]:integer
	SHLI, //       A B sC   R[A] := sC << R[B]
	SHRI, //       A B sC   R[A] := R[B] >> sC
	ADD, //        A B C    R[A] := R[B] + R[C]
	SUB, //        A B C    R[A] := R[B] - R[C]
	MUL, //        A B C    R[A] := R[B] * R[C]
	MOD, //        A B C    R[A] := R[B] % R[C]
	POW, //        A B C    R[A] := R[B] ^ R[C]
	DIV, //        A B C    R[A] := R[B] / R[C]
	IDIV, //       A B C    R[A] := R[B] // R[C]
	BAND, //       A B C    R[A] := R[B] & R[C]
	BOR, //        A B C    R[A] := R[B] | R[C]
	BXOR, //       A B C    R[A] := R[B] ~ R[C]
	SHL, //        A B C    R[A] := R[B] << R[C]
	SHR, //        A B C    R[A] := R[B] >> R[C]
	MMBIN, //      A B C    call C metamethod over R[A] and R[B]
	MMBINI, //     A sB C k call C metamethod over R[A] and sB
	MMBINK, //     A B C k  call C metamethod over R[A] and K[B]
	UNM, //        A B      R[A] := -R[B]
	BNOT, //       A B      R[A] := ~R[B]
	NOT, //        A B      R[A] := not R[B]
	LEN, //        A B      R[A] := #R[B]
	CONCAT, //     A B      R[A] := R[A].. ... ..R[A + B - 1]
	CLOSE, //      A        close all upvalues >= R[A]
	TBC, //        A        mark variable A "to be closed"
	JMP, //        sJ       pc += sJ
	EQ, //         A B k    if ((R[A] == R[B]) ~= k) then pc++
	LT, //         A B k    if ((R[A] <  R[B]) ~= k) then pc++
	LE, //         A B k    if ((R[A] <= R[B]) ~= k) then pc++
	EQK, //        A B k    if ((R[A] == K[B]) ~= k) then pc++
	EQI, //        A sB k   if ((R[A] == sB) ~= k) then pc++
	LTI, //        A sB k   if ((R[A] < sB) ~= k) then pc++
	LEI, //        A sB k   if ((R[A] <= sB) ~= k) then pc++
	GTI, //        A sB k   if ((R[A] > sB) ~= k) then pc++
	GEI, //        A sB k   if ((R[A] >= sB) ~= k) then pc++
	TEST, //       A k      if (not R[A] == k) then pc++
	TESTSET, //    A B k    if (not R[B] == k) then pc++ else R[A] := R[B]
	CALL, //       A B C    R[A], ... ,R[A+C-2] := R[A](R[A+1], ... ,R[A+B-1])
	TAILCALL, //   A B C k  return R[A](R[A+1], ... ,R[A+B-1])
	RETURN, //     A B C k  return R[A], ... ,R[A+B-2]
	RETURN0, //             return
	RETURN1, //    A        return R[A]
	FORLOOP, //    A Bx     update counters; if loop continues then pc-=Bx
	FORPREP, //    A Bx     check values and prepare counters; if not to run pc+=Bx+1
	TFORPREP, //   A Bx     create upvalue for R[A + 3]; pc+=Bx
	TFORCALL, //   A C      R[A+4], ... ,R[A+3+C] := R[A](R[A+1], R[A+2])
	TFORLOOP, //   A Bx     if R[A+2] ~= nil then { R[A]=R[A+2]; pc -= Bx }
	SETLIST, //    A vB vC k R[A][vC+i] := R[A+i], 1 <= i <= vB
	CLOSURE, //    A Bx     R[A] := closure(KPROTO[Bx])
	VARARG, //     A B C k  R[A], ..., R[A+C-2] = varargs
	GETVARG, //    A B C    R[A] := R[B][R[C]], R[B] is vararg parameter
	ERRNNIL, //    A Bx     raise error if R[A] ~= nil (K[Bx - 1] is global name)
	VARARGPREP, // (adjust varargs)
	EXTRAARG, //   Ax       extra (larger) argument for previous opcode
}

// The total number of opcodes -- reference Lua's `NUM_OPCODES`. Because the enum
// is dense and zero-based, this is one past the last member.
NUM_OPCODES :: int(Op_Code.EXTRAARG) + 1

// ---------------------------------------------------------------------------
// Opcode property table (lopcodes.c)
// ---------------------------------------------------------------------------
//
// `luaP_opmodes` packs six properties into each byte, in the exact layout the
// VM and code generator expect:
//   bits 0-2: op mode (the Op_Mode value)
//   bit 3:    instruction sets register A
//   bit 4:    operator is a test (the next instruction must be a jump)
//   bit 5:    instruction uses `L->top` set by a previous instruction (B == 0)
//   bit 6:    instruction sets `L->top` for the next instruction (C == 0)
//   bit 7:    instruction is an MM (metamethod) instruction
//
// `opmode` assembles one such byte; the table then lists every opcode's byte in
// ORDER OP. Building it through `opmode` (rather than hand-computed literals)
// makes each entry self-documenting and impossible to miscompute, while a test
// still checks every byte against reference.

@(private = "file")
opmode :: #force_inline proc "contextless" (mm, ot, it, t, a: u32, m: Op_Mode) -> Byte {
	return Byte((mm << 7) | (ot << 6) | (it << 5) | (t << 4) | (a << 3) | u32(m))
}

// Not `@(rodata)`: each entry is produced by the `opmode` helper, so this is a
// runtime (startup) initializer rather than a constant one. It is treated as
// read-only by convention -- nothing ever writes to it after startup.
opcode_opmodes := [NUM_OPCODES]Byte {
	//     MM OT IT T  A  mode                         opcode
	opmode(0, 0, 0, 0, 1, .iABC), // MOVE
	opmode(0, 0, 0, 0, 1, .iAsBx), // LOADI
	opmode(0, 0, 0, 0, 1, .iAsBx), // LOADF
	opmode(0, 0, 0, 0, 1, .iABx), // LOADK
	opmode(0, 0, 0, 0, 1, .iABx), // LOADKX
	opmode(0, 0, 0, 0, 1, .iABC), // LOADFALSE
	opmode(0, 0, 0, 0, 1, .iABC), // LFALSESKIP
	opmode(0, 0, 0, 0, 1, .iABC), // LOADTRUE
	opmode(0, 0, 0, 0, 1, .iABC), // LOADNIL
	opmode(0, 0, 0, 0, 1, .iABC), // GETUPVAL
	opmode(0, 0, 0, 0, 0, .iABC), // SETUPVAL
	opmode(0, 0, 0, 0, 1, .iABC), // GETTABUP
	opmode(0, 0, 0, 0, 1, .iABC), // GETTABLE
	opmode(0, 0, 0, 0, 1, .iABC), // GETI
	opmode(0, 0, 0, 0, 1, .iABC), // GETFIELD
	opmode(0, 0, 0, 0, 0, .iABC), // SETTABUP
	opmode(0, 0, 0, 0, 0, .iABC), // SETTABLE
	opmode(0, 0, 0, 0, 0, .iABC), // SETI
	opmode(0, 0, 0, 0, 0, .iABC), // SETFIELD
	opmode(0, 0, 0, 0, 1, .ivABC), // NEWTABLE
	opmode(0, 0, 0, 0, 1, .iABC), // SELF
	opmode(0, 0, 0, 0, 1, .iABC), // ADDI
	opmode(0, 0, 0, 0, 1, .iABC), // ADDK
	opmode(0, 0, 0, 0, 1, .iABC), // SUBK
	opmode(0, 0, 0, 0, 1, .iABC), // MULK
	opmode(0, 0, 0, 0, 1, .iABC), // MODK
	opmode(0, 0, 0, 0, 1, .iABC), // POWK
	opmode(0, 0, 0, 0, 1, .iABC), // DIVK
	opmode(0, 0, 0, 0, 1, .iABC), // IDIVK
	opmode(0, 0, 0, 0, 1, .iABC), // BANDK
	opmode(0, 0, 0, 0, 1, .iABC), // BORK
	opmode(0, 0, 0, 0, 1, .iABC), // BXORK
	opmode(0, 0, 0, 0, 1, .iABC), // SHLI
	opmode(0, 0, 0, 0, 1, .iABC), // SHRI
	opmode(0, 0, 0, 0, 1, .iABC), // ADD
	opmode(0, 0, 0, 0, 1, .iABC), // SUB
	opmode(0, 0, 0, 0, 1, .iABC), // MUL
	opmode(0, 0, 0, 0, 1, .iABC), // MOD
	opmode(0, 0, 0, 0, 1, .iABC), // POW
	opmode(0, 0, 0, 0, 1, .iABC), // DIV
	opmode(0, 0, 0, 0, 1, .iABC), // IDIV
	opmode(0, 0, 0, 0, 1, .iABC), // BAND
	opmode(0, 0, 0, 0, 1, .iABC), // BOR
	opmode(0, 0, 0, 0, 1, .iABC), // BXOR
	opmode(0, 0, 0, 0, 1, .iABC), // SHL
	opmode(0, 0, 0, 0, 1, .iABC), // SHR
	opmode(1, 0, 0, 0, 0, .iABC), // MMBIN
	opmode(1, 0, 0, 0, 0, .iABC), // MMBINI
	opmode(1, 0, 0, 0, 0, .iABC), // MMBINK
	opmode(0, 0, 0, 0, 1, .iABC), // UNM
	opmode(0, 0, 0, 0, 1, .iABC), // BNOT
	opmode(0, 0, 0, 0, 1, .iABC), // NOT
	opmode(0, 0, 0, 0, 1, .iABC), // LEN
	opmode(0, 0, 0, 0, 1, .iABC), // CONCAT
	opmode(0, 0, 0, 0, 0, .iABC), // CLOSE
	opmode(0, 0, 0, 0, 0, .iABC), // TBC
	opmode(0, 0, 0, 0, 0, .isJ), // JMP
	opmode(0, 0, 0, 1, 0, .iABC), // EQ
	opmode(0, 0, 0, 1, 0, .iABC), // LT
	opmode(0, 0, 0, 1, 0, .iABC), // LE
	opmode(0, 0, 0, 1, 0, .iABC), // EQK
	opmode(0, 0, 0, 1, 0, .iABC), // EQI
	opmode(0, 0, 0, 1, 0, .iABC), // LTI
	opmode(0, 0, 0, 1, 0, .iABC), // LEI
	opmode(0, 0, 0, 1, 0, .iABC), // GTI
	opmode(0, 0, 0, 1, 0, .iABC), // GEI
	opmode(0, 0, 0, 1, 0, .iABC), // TEST
	opmode(0, 0, 0, 1, 1, .iABC), // TESTSET
	opmode(0, 1, 1, 0, 1, .iABC), // CALL
	opmode(0, 1, 1, 0, 1, .iABC), // TAILCALL
	opmode(0, 0, 1, 0, 0, .iABC), // RETURN
	opmode(0, 0, 0, 0, 0, .iABC), // RETURN0
	opmode(0, 0, 0, 0, 0, .iABC), // RETURN1
	opmode(0, 0, 0, 0, 1, .iABx), // FORLOOP
	opmode(0, 0, 0, 0, 1, .iABx), // FORPREP
	opmode(0, 0, 0, 0, 0, .iABx), // TFORPREP
	opmode(0, 0, 0, 0, 0, .iABC), // TFORCALL
	opmode(0, 0, 0, 0, 1, .iABx), // TFORLOOP
	opmode(0, 0, 1, 0, 0, .ivABC), // SETLIST
	opmode(0, 0, 0, 0, 1, .iABx), // CLOSURE
	opmode(0, 1, 0, 0, 1, .iABC), // VARARG
	opmode(0, 0, 0, 0, 1, .iABC), // GETVARG
	opmode(0, 0, 0, 0, 0, .iABx), // ERRNNIL
	opmode(0, 0, 1, 0, 1, .iABC), // VARARGPREP
	opmode(0, 0, 0, 0, 0, .iAx), // EXTRAARG
}

// ---------------------------------------------------------------------------
// Property queries over the opmodes table (lopcodes.h)
// ---------------------------------------------------------------------------

// The instruction format of an opcode (low 3 bits of its opmode byte).
get_op_mode :: #force_inline proc "contextless" (o: Op_Code) -> Op_Mode {
	return Op_Mode(opcode_opmodes[int(o)] & 7)
}

// Does the opcode assign to register A? (bit 3)
test_a_mode :: #force_inline proc "contextless" (o: Op_Code) -> bool {
	return (opcode_opmodes[int(o)] & (1 << 3)) != 0
}

// Is the opcode a test whose following instruction must be a jump? (bit 4)
test_t_mode :: #force_inline proc "contextless" (o: Op_Code) -> bool {
	return (opcode_opmodes[int(o)] & (1 << 4)) != 0
}

// Does the opcode consume `L->top` set by the previous instruction? (bit 5)
test_it_mode :: #force_inline proc "contextless" (o: Op_Code) -> bool {
	return (opcode_opmodes[int(o)] & (1 << 5)) != 0
}

// Does the opcode set `L->top` for the next instruction? (bit 6)
test_ot_mode :: #force_inline proc "contextless" (o: Op_Code) -> bool {
	return (opcode_opmodes[int(o)] & (1 << 6)) != 0
}

// Is the opcode a metamethod (MMBIN*) instruction? (bit 7)
test_mm_mode :: #force_inline proc "contextless" (o: Op_Code) -> bool {
	return (opcode_opmodes[int(o)] & (1 << 7)) != 0
}

// Whether an instruction *sets* top for the next one, i.e. produces a variable
// number of results -- reference Lua's `luaP_isOT`. TAILCALL always does; other
// OT-mode opcodes only when their C operand is 0 (the "use top" marker).
is_ot :: proc "contextless" (i: Instruction) -> bool {
	op := get_opcode(i)
	if op == .TAILCALL {
		return true
	}
	return test_ot_mode(op) && getarg_C(i) == 0
}

// Whether an instruction *uses* top from the previous one, i.e. accepts a
// variable number of results -- reference Lua's `luaP_isIT`. SETLIST reads its
// count from the variant vB field; every other IT-mode opcode from B.
is_it :: proc "contextless" (i: Instruction) -> bool {
	op := get_opcode(i)
	if op == .SETLIST {
		return test_it_mode(op) && getarg_vB(i) == 0
	}
	return test_it_mode(op) && getarg_B(i) == 0
}

// ---------------------------------------------------------------------------
// Opcode names (lopnames.h)
// ---------------------------------------------------------------------------

// Human-readable names in ORDER OP, indexed by opcode value. Used by the
// bytecode lister (`luac -l`). Reference stores a trailing NULL sentinel; we
// don't need one because the array length is `NUM_OPCODES` and Odin knows it.
@(rodata)
opnames := [NUM_OPCODES]string {
	"MOVE",
	"LOADI",
	"LOADF",
	"LOADK",
	"LOADKX",
	"LOADFALSE",
	"LFALSESKIP",
	"LOADTRUE",
	"LOADNIL",
	"GETUPVAL",
	"SETUPVAL",
	"GETTABUP",
	"GETTABLE",
	"GETI",
	"GETFIELD",
	"SETTABUP",
	"SETTABLE",
	"SETI",
	"SETFIELD",
	"NEWTABLE",
	"SELF",
	"ADDI",
	"ADDK",
	"SUBK",
	"MULK",
	"MODK",
	"POWK",
	"DIVK",
	"IDIVK",
	"BANDK",
	"BORK",
	"BXORK",
	"SHLI",
	"SHRI",
	"ADD",
	"SUB",
	"MUL",
	"MOD",
	"POW",
	"DIV",
	"IDIV",
	"BAND",
	"BOR",
	"BXOR",
	"SHL",
	"SHR",
	"MMBIN",
	"MMBINI",
	"MMBINK",
	"UNM",
	"BNOT",
	"NOT",
	"LEN",
	"CONCAT",
	"CLOSE",
	"TBC",
	"JMP",
	"EQ",
	"LT",
	"LE",
	"EQK",
	"EQI",
	"LTI",
	"LEI",
	"GTI",
	"GEI",
	"TEST",
	"TESTSET",
	"CALL",
	"TAILCALL",
	"RETURN",
	"RETURN0",
	"RETURN1",
	"FORLOOP",
	"FORPREP",
	"TFORPREP",
	"TFORCALL",
	"TFORLOOP",
	"SETLIST",
	"CLOSURE",
	"VARARG",
	"GETVARG",
	"ERRNNIL",
	"VARARGPREP",
	"EXTRAARG",
}
