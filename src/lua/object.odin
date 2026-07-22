package lua

// object.odin -- our analogue of reference Lua's `lobject.h` / `lobject.c`.
//
// The heart of the value model. This is where the tagged-value type (`TValue`)
// lives: the union of number / boolean / nil / light-userdata / GC-collectable
// object, together with the type tags and the collectable-object header shared
// by strings, tables, closures, userdata, threads, and prototypes.
//
// Everything downstream -- the VM, the GC, the API -- speaks in these types, so
// this file defines the vocabulary of the entire implementation.
//
// TODO(phase-1): define the value tags, `TValue`, the `GCObject` header and the
// collectable union, plus the basic conversions (tostring/tonumber helpers,
// object equality) that reference Lua keeps in lobject.c.
