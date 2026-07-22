package lua

// vm.odin -- our analogue of reference Lua's `lvm.h` / `lvm.c`.
//
// The interpreter itself: the loop that decodes and executes bytecode. Unlike a
// naive port, ours is a *trampoline* over the explicit frame stack rather than a
// recursive walk of the native call stack -- so a call, a yield, or an error is
// a state transition returning an `Exec_Outcome`, not a native call/return. That
// is exactly what makes faithful coroutines and pcall/error possible in Odin
// (see docs/ARCHITECTURE.md, Decision 2).
//
// It also implements the numeric tower (integer/float arithmetic, coercions),
// comparisons and equality, table indexing, and the metamethod fallback paths
// for every operation.
//
// TODO(phase-5): the dispatch loop as a trampoline, arithmetic/comparison,
// indexing, the for-loop opcodes, and metamethod fallbacks.
