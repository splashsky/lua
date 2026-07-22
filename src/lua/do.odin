package lua

// do.odin -- our analogue of reference Lua's `ldo.h` / `ldo.c`.
//
// The call-and-return protocol and the protected-execution machinery. In
// reference Lua this is the home of luaD_call / luaD_pcall / luaD_throw /
// luaD_rawrunprotected and the stack-reallocation logic. For us it's where the
// explicit-frame model earns its keep (see docs/ARCHITECTURE.md, Decision 2):
//
//   * setting up and tearing down call frames on the explicit frame stack,
//   * running a computation under a protected boundary and catching Errored,
//   * driving coroutine resume/yield as transitions over that frame stack,
//   * growing the value stack (by index-safe reallocation).
//
// This file and `vm` together *are* the interpreter's spine, tied together by
// the `Exec_Outcome` from control.odin.
//
// TODO(phase-5): frame push/pop, protected call, error propagation to the
// nearest boundary, coroutine resume/yield, and stack growth.
