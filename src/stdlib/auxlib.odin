package stdlib

// auxlib.odin -- our analogue of reference Lua's `lauxlib.h` / `lauxlib.c`.
//
// The "auxiliary library": the convenience layer that sits on top of the raw
// embedding API and that every other standard library (and most host code) leans
// on. Argument checking (`luaL_check*` / `luaL_arg*`), the growable string
// buffer, error helpers, the registry-backed reference system, module
// registration, and the loaders that back `require` all live here.
//
// It belongs to `stdlib` rather than the kernel because it's written purely
// against the public API -- it's the first real customer of that boundary.
//
// TODO(phase-9): arg-checking helpers, luaL_Buffer, error/traceback helpers,
// ref system, and module/registration utilities.
