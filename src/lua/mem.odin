package lua

// mem.odin -- our analogue of reference Lua's `lmem.h` / `lmem.c`.
//
// The single choke-point for all kernel allocation. Every byte the kernel
// allocates flows through here, which is what lets us reproduce reference Lua's
// honest out-of-memory behavior: an allocation failure triggers an emergency
// garbage collection and a retry, and a *preallocated* memory-error value means
// reporting OOM never itself needs to allocate.
//
// Because our value and frame stacks are growable arrays, this is also where the
// grow/shrink helpers live -- and why the rest of the kernel stores indices, not
// pointers, into anything that can move (see docs/ARCHITECTURE.md, Decision 4).
//
// TODO(phase-1): define the fallible allocator abstraction (alloc/realloc/free
// returning success or Out_Of_Memory), the growth helpers (luaM_grow-family),
// and the preallocated memory-error object wiring.
