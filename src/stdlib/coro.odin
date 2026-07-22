package stdlib

// coro.odin -- our analogue of reference Lua's `lcorolib.c`.
//
// The coroutine library: create/resume/yield/status/wrap/isyieldable/running/
// close. It's a thin surface over the kernel's coroutine machinery -- but that
// machinery is only faithful because the VM uses an explicit frame stack it can
// suspend and resume (see docs/ARCHITECTURE.md, Decision 2).
//
// TODO(phase-9): implement the coroutine.* functions against the public API.
