package lua

// dump.odin -- our analogue of reference Lua's `ldump.c`.
//
// The bytecode serializer: turns a compiled `Proto` (and its nested protos,
// constants, upvalues, and debug info) into the precompiled-chunk byte stream
// that `luac` writes and that `undump` reads back.
//
// Byte-exactness is a project goal, so this targets one fixed ABI configuration
// (little-endian, 32-bit Instruction/int, 64-bit integer, IEEE-754 binary64) and
// serializes the C-defined layout *explicitly*, preserving floating-point bit
// patterns rather than re-encoding numerically (see docs/ARCHITECTURE.md,
// Decision 5).
//
// TODO(phase-8): the header writer, and recursive serialization of Proto,
// constants, upvalues, and (optionally stripped) debug info.
