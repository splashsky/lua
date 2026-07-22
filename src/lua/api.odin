package lua

// api.odin -- our analogue of reference Lua's `lapi.h` / `lapi.c`.
//
// The embedding API: the surface the standard libraries and host programs use to
// talk to a Lua state. It's the Odin-idiomatic equivalent of Lua's C API --
// pushing and reading stack values, calling functions (protected and not),
// creating and manipulating tables and metatables, the registry and the
// reference system, and userdata.
//
// This is the boundary that keeps `stdlib` a separate package: everything the
// libraries need must be exposed here. If a library ever wants to reach past
// this into kernel internals, that's a bug in the API, not a reason to couple.
//
// TODO(phase-6): stack push/get/convert, call/pcall, table & metatable ops,
// registry/references, userdata, and the debug-API surface.
