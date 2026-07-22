package lua

// state.odin -- our analogue of reference Lua's `lstate.h` / `lstate.c`.
//
// Defines the two central runtime structures:
//   * `lua_State`   -- one thread of execution: its value stack, its explicit
//                      call-frame stack, current status, error-handling boundary
//                      chain, and hook state.
//   * `global_State`-- state shared by all threads in a Lua universe: the string
//                      table (interning), the GC's bookkeeping and object lists,
//                      the registry, the main thread, and the memory allocator.
//
// A crucial deviation from a naive port (see docs/ARCHITECTURE.md, Decisions 2
// and 3): the value stack and the call-frame stack are arrays this state owns,
// addressed by *index*, never the native Odin call stack and never retained
// pointers. That is what makes faithful error unwinding and coroutine
// suspend/resume possible without setjmp/longjmp.
//
// TODO(phase-2): define lua_State / global_State, stack + frame arrays as
// index-addressed structures, thread status, and creation/teardown.
