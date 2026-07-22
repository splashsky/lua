package lua

// code.odin -- our analogue of reference Lua's `lcode.h` / `lcode.c`.
//
// The low-level code generator the parser drives. It handles the fiddly parts of
// emitting bytecode: allocating and freeing VM registers, managing the constant
// table, folding constant arithmetic, discharging expressions into registers,
// and backpatching jump lists for control flow. It's where an expression's
// abstract description becomes concrete instructions.
//
// TODO(phase-4): instruction emission, register/constant management, expression
// discharge, jump-list backpatching, and constant folding.
