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
import lua "luao:lua"

// The opcode set must have exactly the reference count, and EXTRAARG must be the
// last member (its value is NUM_OPCODES - 1). This pins the ABI contract.
@(test)
opcode_count_and_order :: proc(t: ^testing.T) {
	testing.expect_value(t, lua.NUM_OPCODES, 85)
	testing.expect_value(t, int(lua.Op_Code.EXTRAARG), lua.NUM_OPCODES - 1)
	testing.expect_value(t, int(lua.Op_Code.MOVE), 0)
	// A few interior anchors that would shift if anyone reordered the enum.
	testing.expect_value(t, int(lua.Op_Code.JMP), 56)
	testing.expect_value(t, int(lua.Op_Code.CALL), 68)
	testing.expect_value(t, int(lua.Op_Code.VARARGPREP), 83)
}

// The field layout constants are an ABI contract too -- derive-and-check the
// composite ones so a typo in any size/position surfaces here.
@(test)
opcode_layout_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, lua.SIZE_Bx, 17)
	testing.expect_value(t, lua.SIZE_Ax, 25)
	testing.expect_value(t, lua.SIZE_sJ, 25)
	testing.expect_value(t, lua.MAXARG_Bx, 131071)
	testing.expect_value(t, lua.OFFSET_sBx, 65535)
	testing.expect_value(t, lua.MAXARG_Ax, 33554431)
	testing.expect_value(t, lua.MAXARG_sJ, 33554431)
	testing.expect_value(t, lua.OFFSET_sJ, 16777215)
	testing.expect_value(t, lua.MAXARG_A, 255)
	testing.expect_value(t, lua.MAXARG_B, 255)
	testing.expect_value(t, lua.MAXARG_vB, 63)
	testing.expect_value(t, lua.MAXARG_C, 255)
	testing.expect_value(t, lua.MAXARG_vC, 1023)
	testing.expect_value(t, lua.OFFSET_sC, 127)
	testing.expect_value(t, lua.MAX_FSTACK, 255)
	testing.expect_value(t, lua.NO_REG, 255)
}

// For every opcode, the low 7 bits of any instruction we build with it must read
// back as that same opcode, and it must have a printable name. This walks the
// whole set so no member is silently mis-encoded or missing a name.
@(test)
opcode_field_and_names_cover_all :: proc(t: ^testing.T) {
	for v in 0 ..< lua.NUM_OPCODES {
		op := lua.Op_Code(v)
		i := lua.create_ABCk(op, 0, 0, 0, 0)
		testing.expect_value(t, lua.get_opcode(i), op)
		testing.expect(t, len(lua.opnames[v]) > 0)
	}
	// Spot-check a couple of names against the reference spelling.
	testing.expect_value(t, lua.opnames[int(lua.Op_Code.MOVE)], "MOVE")
	testing.expect_value(t, lua.opnames[int(lua.Op_Code.VARARGPREP)], "VARARGPREP")
	testing.expect_value(t, lua.opnames[int(lua.Op_Code.EXTRAARG)], "EXTRAARG")
}

// iABC: A(8) k(1) B(8) C(8). Pack the field maxima and read each back; also
// prove set_opcode rewrites only the opcode and leaves operands intact.
@(test)
encode_iABC_round_trip :: proc(t: ^testing.T) {
	i := lua.create_ABCk(.ADD, lua.MAXARG_A, lua.MAXARG_B, lua.MAXARG_C, 1)
	testing.expect_value(t, lua.get_opcode(i), lua.Op_Code.ADD)
	testing.expect_value(t, lua.getarg_A(i), lua.MAXARG_A)
	testing.expect_value(t, lua.getarg_B(i), lua.MAXARG_B)
	testing.expect_value(t, lua.getarg_C(i), lua.MAXARG_C)
	testing.expect_value(t, lua.getarg_k(i), 1)

	// Distinct values so a field-position swap would be caught.
	j := lua.create_ABCk(.SUB, 1, 2, 3, 0)
	testing.expect_value(t, lua.getarg_A(j), 1)
	testing.expect_value(t, lua.getarg_B(j), 2)
	testing.expect_value(t, lua.getarg_C(j), 3)
	testing.expect_value(t, lua.getarg_k(j), 0)

	lua.set_opcode(&j, .MUL)
	testing.expect_value(t, lua.get_opcode(j), lua.Op_Code.MUL)
	testing.expect_value(t, lua.getarg_A(j), 1)
	testing.expect_value(t, lua.getarg_B(j), 2)
	testing.expect_value(t, lua.getarg_C(j), 3)
}

// Individual field setters must touch only their own field.
@(test)
setters_are_isolated :: proc(t: ^testing.T) {
	i := lua.create_ABCk(.ADD, 0, 0, 0, 0)
	lua.setarg_A(&i, 200)
	lua.setarg_B(&i, 100)
	lua.setarg_C(&i, 50)
	lua.setarg_k(&i, 1)
	testing.expect_value(t, lua.getarg_A(i), 200)
	testing.expect_value(t, lua.getarg_B(i), 100)
	testing.expect_value(t, lua.getarg_C(i), 50)
	testing.expect_value(t, lua.getarg_k(i), 1)
	testing.expect_value(t, lua.get_opcode(i), lua.Op_Code.ADD)
}

// ivABC: the "variant" widths -- vB is 6 bits, vC is 10 bits.
@(test)
encode_ivABC_round_trip :: proc(t: ^testing.T) {
	i := lua.create_vABCk(.NEWTABLE, lua.MAXARG_A, lua.MAXARG_vB, lua.MAXARG_vC, 1)
	testing.expect_value(t, lua.get_opcode(i), lua.Op_Code.NEWTABLE)
	testing.expect_value(t, lua.getarg_A(i), lua.MAXARG_A)
	testing.expect_value(t, lua.getarg_vB(i), lua.MAXARG_vB)
	testing.expect_value(t, lua.getarg_vC(i), lua.MAXARG_vC)
	testing.expect_value(t, lua.getarg_k(i), 1)
}

// iABx: unsigned 17-bit Bx.
@(test)
encode_iABx_round_trip :: proc(t: ^testing.T) {
	i := lua.create_ABx(.LOADK, lua.MAXARG_A, lua.MAXARG_Bx)
	testing.expect_value(t, lua.get_opcode(i), lua.Op_Code.LOADK)
	testing.expect_value(t, lua.getarg_A(i), lua.MAXARG_A)
	testing.expect_value(t, lua.getarg_Bx(i), lua.MAXARG_Bx)
}

// iAx: unsigned 25-bit Ax (the EXTRAARG payload).
@(test)
encode_iAx_round_trip :: proc(t: ^testing.T) {
	i := lua.create_Ax(.EXTRAARG, lua.MAXARG_Ax)
	testing.expect_value(t, lua.get_opcode(i), lua.Op_Code.EXTRAARG)
	testing.expect_value(t, lua.getarg_Ax(i), lua.MAXARG_Ax)
}

// iAsBx: signed 17-bit Bx, stored excess-OFFSET_sBx. Prove the extremes and zero.
@(test)
encode_sBx_signed_round_trip :: proc(t: ^testing.T) {
	i := lua.create_ABx(.LOADI, 7, 0)
	lo := -lua.OFFSET_sBx
	hi := lua.MAXARG_Bx - lua.OFFSET_sBx
	for v in ([]int{lo, -1, 0, 1, hi}) {
		lua.setarg_sBx(&i, v)
		testing.expect_value(t, lua.getarg_sBx(i), v)
		testing.expect_value(t, lua.getarg_A(i), 7) // A untouched
	}
}

// isJ: signed 25-bit jump displacement, stored excess-OFFSET_sJ.
@(test)
encode_sJ_signed_round_trip :: proc(t: ^testing.T) {
	i := lua.create_sJ(.JMP, 0, 0)
	lo := -lua.OFFSET_sJ
	hi := lua.MAXARG_sJ - lua.OFFSET_sJ
	for v in ([]int{lo, -100, 0, 100, hi}) {
		lua.setarg_sJ(&i, v)
		testing.expect_value(t, lua.getarg_sJ(i), v)
	}
}

// sC: the small signed immediate carried in an unsigned C field (ADDI/SHRI).
@(test)
encode_sC_signed_round_trip :: proc(t: ^testing.T) {
	// int2sC/sC2int are exact inverses across the whole field.
	testing.expect_value(t, lua.sC2int(lua.int2sC(0)), 0)
	testing.expect_value(t, lua.sC2int(lua.int2sC(-127)), -127)
	testing.expect_value(t, lua.sC2int(lua.int2sC(128)), 128)

	for v in ([]int{-lua.OFFSET_sC, -1, 0, 1, lua.MAXARG_C - lua.OFFSET_sC}) {
		i := lua.create_ABCk(.ADDI, 3, 4, lua.int2sC(v), 0)
		testing.expect_value(t, lua.getarg_sC(i), v)
		testing.expect_value(t, lua.getarg_A(i), 3)
		testing.expect_value(t, lua.getarg_B(i), 4)
	}
}

// The opcode property table must classify formats and flags exactly as reference
// Lua does -- these values drive the VM's dispatch and the code generator.
@(test)
opcode_modes_match_reference :: proc(t: ^testing.T) {
	testing.expect_value(t, lua.get_op_mode(.MOVE), lua.Op_Mode.iABC)
	testing.expect_value(t, lua.get_op_mode(.NEWTABLE), lua.Op_Mode.ivABC)
	testing.expect_value(t, lua.get_op_mode(.LOADK), lua.Op_Mode.iABx)
	testing.expect_value(t, lua.get_op_mode(.LOADI), lua.Op_Mode.iAsBx)
	testing.expect_value(t, lua.get_op_mode(.EXTRAARG), lua.Op_Mode.iAx)
	testing.expect_value(t, lua.get_op_mode(.JMP), lua.Op_Mode.isJ)

	// bit 3: sets register A.
	testing.expect(t, lua.test_a_mode(.MOVE))
	testing.expect(t, !lua.test_a_mode(.SETUPVAL))
	testing.expect(t, !lua.test_a_mode(.JMP))

	// bit 4: is a test (followed by a jump).
	testing.expect(t, lua.test_t_mode(.EQ))
	testing.expect(t, lua.test_t_mode(.TESTSET))
	testing.expect(t, !lua.test_t_mode(.MOVE))

	// bit 7: metamethod trailer instructions.
	testing.expect(t, lua.test_mm_mode(.MMBIN))
	testing.expect(t, lua.test_mm_mode(.MMBINI))
	testing.expect(t, lua.test_mm_mode(.MMBINK))
	testing.expect(t, !lua.test_mm_mode(.ADD))

	// bits 5/6: consumes/produces a variable result count.
	testing.expect(t, lua.test_it_mode(.CALL))
	testing.expect(t, lua.test_ot_mode(.CALL))
	testing.expect(t, lua.test_it_mode(.RETURN))
	testing.expect(t, !lua.test_ot_mode(.RETURN))
	testing.expect(t, lua.test_ot_mode(.VARARG))
	testing.expect(t, !lua.test_it_mode(.VARARG))
	testing.expect(t, lua.test_it_mode(.SETLIST))
}

// luaP_isOT / luaP_isIT depend on both the mode bits *and* the C/B operand being
// zero (the "use top" marker), with TAILCALL and SETLIST as special cases.
@(test)
is_ot_and_is_it_semantics :: proc(t: ^testing.T) {
	// CALL sets top only when C == 0.
	testing.expect(t, lua.is_ot(lua.create_ABCk(.CALL, 0, 1, 0, 0)))
	testing.expect(t, !lua.is_ot(lua.create_ABCk(.CALL, 0, 1, 2, 0)))
	// TAILCALL always sets top, regardless of C.
	testing.expect(t, lua.is_ot(lua.create_ABCk(.TAILCALL, 0, 1, 5, 0)))

	// CALL uses top only when B == 0.
	testing.expect(t, lua.is_it(lua.create_ABCk(.CALL, 0, 0, 1, 0)))
	testing.expect(t, !lua.is_it(lua.create_ABCk(.CALL, 0, 2, 1, 0)))
	// SETLIST reads its count from vB, so it uses top when vB == 0.
	testing.expect(t, lua.is_it(lua.create_vABCk(.SETLIST, 0, 0, 3, 0)))
	testing.expect(t, !lua.is_it(lua.create_vABCk(.SETLIST, 0, 2, 3, 0)))

	// A non-OT/non-IT opcode is neither.
	testing.expect(t, !lua.is_ot(lua.create_ABCk(.MOVE, 0, 1, 0, 0)))
	testing.expect(t, !lua.is_it(lua.create_ABCk(.MOVE, 0, 0, 0, 0)))
}
