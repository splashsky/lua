package tests

// opcodes_test.odin -- Phase 4 tests for the instruction set (opcodes.odin).
//
// These prove the encoding is *byte-faithful* to reference Lua 5.5: the opcode
// enumeration order (which is baked into dumped bytecode), the field layout of
// every instruction format, the signed-operand excess-K biasing, and the
// per-opcode property table. If any of these drift, our bytecode stops being
// compatible with reference Lua -- so the tests assert exact, observable values
// rather than incidental internals.

import "core:testing"
import kernel "lang:kernel"

// The opcode set must have exactly the reference count, and EXTRAARG must be the
// last member (its value is NUM_OPCODES - 1). This pins the ABI contract.
@(test)
opcode_count_and_order :: proc(t: ^testing.T) {
	testing.expect_value(t, kernel.NUM_OPCODES, 85)
	testing.expect_value(t, int(kernel.Op_Code.EXTRAARG), kernel.NUM_OPCODES - 1)
	testing.expect_value(t, int(kernel.Op_Code.MOVE), 0)
	// A few interior anchors that would shift if anyone reordered the enum.
	testing.expect_value(t, int(kernel.Op_Code.JMP), 56)
	testing.expect_value(t, int(kernel.Op_Code.CALL), 68)
	testing.expect_value(t, int(kernel.Op_Code.VARARGPREP), 83)
}

// The field layout constants are an ABI contract too -- derive-and-check the
// composite ones so a typo in any size/position surfaces here.
@(test)
opcode_layout_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, kernel.SIZE_Bx, 17)
	testing.expect_value(t, kernel.SIZE_Ax, 25)
	testing.expect_value(t, kernel.SIZE_sJ, 25)
	testing.expect_value(t, kernel.MAXARG_Bx, 131071)
	testing.expect_value(t, kernel.OFFSET_sBx, 65535)
	testing.expect_value(t, kernel.MAXARG_Ax, 33554431)
	testing.expect_value(t, kernel.MAXARG_sJ, 33554431)
	testing.expect_value(t, kernel.OFFSET_sJ, 16777215)
	testing.expect_value(t, kernel.MAXARG_A, 255)
	testing.expect_value(t, kernel.MAXARG_B, 255)
	testing.expect_value(t, kernel.MAXARG_vB, 63)
	testing.expect_value(t, kernel.MAXARG_C, 255)
	testing.expect_value(t, kernel.MAXARG_vC, 1023)
	testing.expect_value(t, kernel.OFFSET_sC, 127)
	testing.expect_value(t, kernel.MAX_FSTACK, 255)
	testing.expect_value(t, kernel.NO_REG, 255)
}

// For every opcode, the low 7 bits of any instruction we build with it must read
// back as that same opcode, and it must have a printable name. This walks the
// whole set so no member is silently mis-encoded or missing a name.
@(test)
opcode_field_and_names_cover_all :: proc(t: ^testing.T) {
	for v in 0 ..< kernel.NUM_OPCODES {
		op := kernel.Op_Code(v)
		i := kernel.create_ABCk(op, 0, 0, 0, 0)
		testing.expect_value(t, kernel.get_opcode(i), op)
		testing.expect(t, len(kernel.opnames[v]) > 0)
	}
	// Spot-check a couple of names against the reference spelling.
	testing.expect_value(t, kernel.opnames[int(kernel.Op_Code.MOVE)], "MOVE")
	testing.expect_value(t, kernel.opnames[int(kernel.Op_Code.VARARGPREP)], "VARARGPREP")
	testing.expect_value(t, kernel.opnames[int(kernel.Op_Code.EXTRAARG)], "EXTRAARG")
}

// iABC: A(8) k(1) B(8) C(8). Pack the field maxima and read each back; also
// prove set_opcode rewrites only the opcode and leaves operands intact.
@(test)
encode_iABC_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_ABCk(.ADD, kernel.MAXARG_A, kernel.MAXARG_B, kernel.MAXARG_C, 1)
	testing.expect_value(t, kernel.get_opcode(i), kernel.Op_Code.ADD)
	testing.expect_value(t, kernel.getarg_A(i), kernel.MAXARG_A)
	testing.expect_value(t, kernel.getarg_B(i), kernel.MAXARG_B)
	testing.expect_value(t, kernel.getarg_C(i), kernel.MAXARG_C)
	testing.expect_value(t, kernel.getarg_k(i), 1)

	// Distinct values so a field-position swap would be caught.
	j := kernel.create_ABCk(.SUB, 1, 2, 3, 0)
	testing.expect_value(t, kernel.getarg_A(j), 1)
	testing.expect_value(t, kernel.getarg_B(j), 2)
	testing.expect_value(t, kernel.getarg_C(j), 3)
	testing.expect_value(t, kernel.getarg_k(j), 0)

	kernel.set_opcode(&j, .MUL)
	testing.expect_value(t, kernel.get_opcode(j), kernel.Op_Code.MUL)
	testing.expect_value(t, kernel.getarg_A(j), 1)
	testing.expect_value(t, kernel.getarg_B(j), 2)
	testing.expect_value(t, kernel.getarg_C(j), 3)
}

// Individual field setters must touch only their own field.
@(test)
setters_are_isolated :: proc(t: ^testing.T) {
	i := kernel.create_ABCk(.ADD, 0, 0, 0, 0)
	kernel.setarg_A(&i, 200)
	kernel.setarg_B(&i, 100)
	kernel.setarg_C(&i, 50)
	kernel.setarg_k(&i, 1)
	testing.expect_value(t, kernel.getarg_A(i), 200)
	testing.expect_value(t, kernel.getarg_B(i), 100)
	testing.expect_value(t, kernel.getarg_C(i), 50)
	testing.expect_value(t, kernel.getarg_k(i), 1)
	testing.expect_value(t, kernel.get_opcode(i), kernel.Op_Code.ADD)
}

// ivABC: the "variant" widths -- vB is 6 bits, vC is 10 bits.
@(test)
encode_ivABC_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_vABCk(.NEWTABLE, kernel.MAXARG_A, kernel.MAXARG_vB, kernel.MAXARG_vC, 1)
	testing.expect_value(t, kernel.get_opcode(i), kernel.Op_Code.NEWTABLE)
	testing.expect_value(t, kernel.getarg_A(i), kernel.MAXARG_A)
	testing.expect_value(t, kernel.getarg_vB(i), kernel.MAXARG_vB)
	testing.expect_value(t, kernel.getarg_vC(i), kernel.MAXARG_vC)
	testing.expect_value(t, kernel.getarg_k(i), 1)
}

// iABx: unsigned 17-bit Bx.
@(test)
encode_iABx_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_ABx(.LOADK, kernel.MAXARG_A, kernel.MAXARG_Bx)
	testing.expect_value(t, kernel.get_opcode(i), kernel.Op_Code.LOADK)
	testing.expect_value(t, kernel.getarg_A(i), kernel.MAXARG_A)
	testing.expect_value(t, kernel.getarg_Bx(i), kernel.MAXARG_Bx)
}

// iAx: unsigned 25-bit Ax (the EXTRAARG payload).
@(test)
encode_iAx_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_Ax(.EXTRAARG, kernel.MAXARG_Ax)
	testing.expect_value(t, kernel.get_opcode(i), kernel.Op_Code.EXTRAARG)
	testing.expect_value(t, kernel.getarg_Ax(i), kernel.MAXARG_Ax)
}

// iAsBx: signed 17-bit Bx, stored excess-OFFSET_sBx. Prove the extremes and zero.
@(test)
encode_sBx_signed_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_ABx(.LOADI, 7, 0)
	lo := -kernel.OFFSET_sBx
	hi := kernel.MAXARG_Bx - kernel.OFFSET_sBx
	for v in ([]int{lo, -1, 0, 1, hi}) {
		kernel.setarg_sBx(&i, v)
		testing.expect_value(t, kernel.getarg_sBx(i), v)
		testing.expect_value(t, kernel.getarg_A(i), 7) // A untouched
	}
}

// isJ: signed 25-bit jump displacement, stored excess-OFFSET_sJ.
@(test)
encode_sJ_signed_round_trip :: proc(t: ^testing.T) {
	i := kernel.create_sJ(.JMP, 0, 0)
	lo := -kernel.OFFSET_sJ
	hi := kernel.MAXARG_sJ - kernel.OFFSET_sJ
	for v in ([]int{lo, -100, 0, 100, hi}) {
		kernel.setarg_sJ(&i, v)
		testing.expect_value(t, kernel.getarg_sJ(i), v)
	}
}

// sC: the small signed immediate carried in an unsigned C field (ADDI/SHRI).
@(test)
encode_sC_signed_round_trip :: proc(t: ^testing.T) {
	// int2sC/sC2int are exact inverses across the whole field.
	testing.expect_value(t, kernel.sC2int(kernel.int2sC(0)), 0)
	testing.expect_value(t, kernel.sC2int(kernel.int2sC(-127)), -127)
	testing.expect_value(t, kernel.sC2int(kernel.int2sC(128)), 128)

	for v in ([]int{-kernel.OFFSET_sC, -1, 0, 1, kernel.MAXARG_C - kernel.OFFSET_sC}) {
		i := kernel.create_ABCk(.ADDI, 3, 4, kernel.int2sC(v), 0)
		testing.expect_value(t, kernel.getarg_sC(i), v)
		testing.expect_value(t, kernel.getarg_A(i), 3)
		testing.expect_value(t, kernel.getarg_B(i), 4)
	}
}

// The opcode property table must classify formats and flags exactly as reference
// Lua does -- these values drive the VM's dispatch and the code generator.
@(test)
opcode_modes_match_reference :: proc(t: ^testing.T) {
	testing.expect_value(t, kernel.get_op_mode(.MOVE), kernel.Op_Mode.iABC)
	testing.expect_value(t, kernel.get_op_mode(.NEWTABLE), kernel.Op_Mode.ivABC)
	testing.expect_value(t, kernel.get_op_mode(.LOADK), kernel.Op_Mode.iABx)
	testing.expect_value(t, kernel.get_op_mode(.LOADI), kernel.Op_Mode.iAsBx)
	testing.expect_value(t, kernel.get_op_mode(.EXTRAARG), kernel.Op_Mode.iAx)
	testing.expect_value(t, kernel.get_op_mode(.JMP), kernel.Op_Mode.isJ)

	// bit 3: sets register A.
	testing.expect(t, kernel.test_a_mode(.MOVE))
	testing.expect(t, !kernel.test_a_mode(.SETUPVAL))
	testing.expect(t, !kernel.test_a_mode(.JMP))

	// bit 4: is a test (followed by a jump).
	testing.expect(t, kernel.test_t_mode(.EQ))
	testing.expect(t, kernel.test_t_mode(.TESTSET))
	testing.expect(t, !kernel.test_t_mode(.MOVE))

	// bit 7: metamethod trailer instructions.
	testing.expect(t, kernel.test_mm_mode(.MMBIN))
	testing.expect(t, kernel.test_mm_mode(.MMBINI))
	testing.expect(t, kernel.test_mm_mode(.MMBINK))
	testing.expect(t, !kernel.test_mm_mode(.ADD))

	// bits 5/6: consumes/produces a variable result count.
	testing.expect(t, kernel.test_it_mode(.CALL))
	testing.expect(t, kernel.test_ot_mode(.CALL))
	testing.expect(t, kernel.test_it_mode(.RETURN))
	testing.expect(t, !kernel.test_ot_mode(.RETURN))
	testing.expect(t, kernel.test_ot_mode(.VARARG))
	testing.expect(t, !kernel.test_it_mode(.VARARG))
	testing.expect(t, kernel.test_it_mode(.SETLIST))
}

// luaP_isOT / luaP_isIT depend on both the mode bits *and* the C/B operand being
// zero (the "use top" marker), with TAILCALL and SETLIST as special cases.
@(test)
is_ot_and_is_it_semantics :: proc(t: ^testing.T) {
	// CALL sets top only when C == 0.
	testing.expect(t, kernel.is_ot(kernel.create_ABCk(.CALL, 0, 1, 0, 0)))
	testing.expect(t, !kernel.is_ot(kernel.create_ABCk(.CALL, 0, 1, 2, 0)))
	// TAILCALL always sets top, regardless of C.
	testing.expect(t, kernel.is_ot(kernel.create_ABCk(.TAILCALL, 0, 1, 5, 0)))

	// CALL uses top only when B == 0.
	testing.expect(t, kernel.is_it(kernel.create_ABCk(.CALL, 0, 0, 1, 0)))
	testing.expect(t, !kernel.is_it(kernel.create_ABCk(.CALL, 0, 2, 1, 0)))
	// SETLIST reads its count from vB, so it uses top when vB == 0.
	testing.expect(t, kernel.is_it(kernel.create_vABCk(.SETLIST, 0, 0, 3, 0)))
	testing.expect(t, !kernel.is_it(kernel.create_vABCk(.SETLIST, 0, 2, 3, 0)))

	// A non-OT/non-IT opcode is neither.
	testing.expect(t, !kernel.is_ot(kernel.create_ABCk(.MOVE, 0, 1, 0, 0)))
	testing.expect(t, !kernel.is_it(kernel.create_ABCk(.MOVE, 0, 0, 0, 0)))
}
