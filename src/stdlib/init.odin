package stdlib

// init.odin -- our analogue of reference Lua's `linit.c`.
//
// The single entry point that opens the whole standard library into a state:
// the equivalent of `luaL_openlibs`. It registers each library (base, package,
// coroutine, table, io, os, string, math, utf8, debug) in the canonical order
// reference Lua uses, so that globals and preloaded modules end up arranged
// identically.
//
// TODO(phase-9): open_libs(state) registering every standard library in order.
