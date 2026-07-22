package lua

// opcodes.odin -- our analogue of `lopcodes.h`/`lopcodes.c`, plus `lopnames.h`
// and `ljumptab.h`.
//
// The instruction set of the register-based virtual machine: the opcode enum,
// the instruction *formats* (iABC/iABx/iAsBx/iAx/isJ) and the bit-field
// encoding that packs opcode + operands into a 32-bit word, the per-opcode
// mode/property table, and the human-readable opcode names used by `luac -l`.
//
// This is a place where byte-exactness matters: our encoding must match
// reference Lua so dumped bytecode is compatible (see docs/ARCHITECTURE.md,
// Decision 5).
//
// TODO(phase-4): the OpCode enum, instruction encode/decode, operand size
// constants, the opcode-mode table, and the name table.
