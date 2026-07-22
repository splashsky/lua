package lua

// func.odin -- our analogue of reference Lua's `lfunc.h` / `lfunc.c`.
//
// Functions and their supporting cast: the `Proto` (a compiled function
// prototype -- bytecode, constants, nested protos, debug info), Lua closures and
// C/Odin closures, and *upvalues*, including the delicate open/closed upvalue
// machinery that lets closures share and then capture local variables as scopes
// exit.
//
// Open upvalues point into a thread's value stack while it's live, so -- per our
// index-not-pointer rule -- this interacts carefully with stack growth and the
// GC.
//
// TODO(phase-3): Proto, closures (Lua + native), upvalue open/close, and the
// upvalue list threaded through the stack.
