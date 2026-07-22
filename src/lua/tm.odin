package lua

// tm.odin -- our analogue of reference Lua's `ltm.h` / `ltm.c`.
//
// Tag methods, i.e. metamethods. This file defines the enumeration of events
// (__index, __newindex, __add, __eq, __call, __close, ...), caches their names,
// and provides the lookup that finds a metamethod on a value's metatable. The VM
// leans on this constantly for its fallback paths, so the event ordering must
// match reference Lua exactly.
//
// TODO(phase-3): the TM event enum + names, fast access to a type's metatable,
// and the metamethod lookup helpers.
