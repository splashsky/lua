package lua

// undump.odin -- our analogue of reference Lua's `lundump.h` / `lundump.c`.
//
// The bytecode loader: the exact inverse of `dump`. It reads a precompiled chunk
// (via ZIO), validates the header against our ABI configuration -- rejecting
// incompatible chunks precisely as reference Lua does -- and reconstructs the
// `Proto` tree. Because loading untrusted bytecode is a real hazard, the
// validation here is a correctness *and* safety matter.
//
// TODO(phase-8): header verification, and recursive deserialization of Proto,
// constants, upvalues, and debug info, with strict format checks.
